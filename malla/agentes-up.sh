#!/usr/bin/env bash
#
# Compila los agentes, los mete al cluster de kind y los despliega.
#
# POR QUE ESTE SCRIPT EXISTE
# --------------------------
# Hasta ahora los agentes corrian como procesos en el host, y eso dejaba sin
# objeto la mitad de la sesion: el salto lateral investigador -> defensor era
# localhost -> localhost, o sea nada que Cilium pueda gobernar ni que Hubble
# pueda dibujar. La v1 los tenia como pods; esto recupera ese patron.
#
# El paso que se olvida siempre es `kind load`: kind corre sus nodos como
# contenedores de Docker con su PROPIO almacen de imagenes, asi que una imagen
# recien compilada en el host NO existe para el cluster.
#
# Uso:
#   ./malla/agentes-up.sh
#   ./malla/agentes-up.sh --logs investigador
#   ./malla/agentes-up.sh --down

set -euo pipefail
NS=agentes
CLUSTER=agentes
IMAGEN=ccl26/agentes:dev
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RAIZ="$(cd "$DIR/.." && pwd)"
log() { echo ""; echo "=== $1"; }

case "${1:-}" in
  --logs) exec kubectl -n "$NS" logs -f "deploy/${2:-investigador}" ;;
  --down) kubectl -n "$NS" delete -f "$DIR/00-agentes.yaml" --ignore-not-found
          # La politica y el EndpointSlice de vLLM los genera publica-vllm.sh,
          # asi que no estan en el manifiesto y hay que nombrarlos aqui.
          kubectl -n "$NS" delete ciliumnetworkpolicy agentes-vllm-host \
            --ignore-not-found >/dev/null
          kubectl -n "$NS" delete endpointslice vllm --ignore-not-found >/dev/null
          echo "agentes eliminados"; exit 0 ;;
esac

kubectl get nodes >/dev/null 2>&1 || {
  echo "El cluster no responde: corre ./lab/cluster-up.sh"; exit 1; }

# El contexto de compilacion es la RAIZ del repo, no malla/: la imagen tambien
# necesita observabilidad/ para las trazas. Por eso el -f explicito.
log "Compilando $IMAGEN"
docker build -q -t "$IMAGEN" -f "$DIR/Dockerfile" "$RAIZ"

log "Metiendo la imagen al cluster de kind"
kind load docker-image "$IMAGEN" --name "$CLUSTER"

log "Desplegando el router y los dos agentes"
kubectl apply -f "$DIR/00-agentes.yaml" >/dev/null

# Pods nuevos con la imagen recien cargada: sin esto seguirian con la vieja.
# Este es el desfase que ya nos mordio tres veces (§9 del CLAUDE.md).
kubectl -n "$NS" rollout restart \
  deploy/orquestador deploy/investigador deploy/defensor >/dev/null
for d in router investigador defensor; do
  kubectl -n "$NS" rollout status "deploy/$d" --timeout=180s
done

# El Service de vLLM no tiene selector, asi que necesita sus Endpoints escritos
# con la IP del host. Se hace aqui para que no haya que recordarlo.
log "Publicando vLLM dentro del cluster"
"$RAIZ/lab/publica-vllm.sh" 2>&1 | sed 's/^/  /'

# LAS POLITICAS QUE ESTE DESPLIEGUE NECESITA.
#
# Se comprueba aqui porque ya fallo dos veces seguidas, y el sintoma no se parece
# a su causa: los pods arrancan bien, /salud responde bien, y la deliberacion muere
# diciendo "ningun agente responde" — que suena a que los agentes estan caidos
# cuando lo que pasa es que la red no deja pasar la peticion.
#
# El orden importa: `rol: agente` los pone en denegacion por omision de salida en
# cuanto alguna politica los selecciona, asi que desplegar sin las reglas deja un
# sistema que parece sano y no funciona.
log "Comprobando las politicas de red"
faltan=""
for pol in agentes-salida router-descubrimiento; do
  kubectl -n "$NS" get ciliumnetworkpolicy "$pol" >/dev/null 2>&1 || faltan="$faltan $pol"
done
if [ -n "$faltan" ]; then
  echo "  FALTAN:$faltan"
  echo ""
  echo "  Sin ellas la deliberacion dira 'ningun agente responde', que NO"
  echo "  significa que los agentes esten caidos: significa que la red corta"
  echo "  la peticion. Aplicalas:"
  echo ""
  echo "    kubectl apply -f seguridad/cilium-l7.yaml"
  echo "    ./lab/publica-vllm.sh      # la de vLLM necesita la IP del host"
  echo ""
else
  echo "  ok  las dos estan aplicadas"
fi

log "Comprobando que los tres arrancaron"
# La huella del codigo: la misma que la interfaz compara contra el disco. Los
# tres salen de la MISMA imagen, asi que sus huellas no son iguales entre si
# (cada programa mezcla archivos distintos) pero cada una tiene que coincidir con
# su fuente.
comprobar() {  # nombre  puerto
  salud=$(kubectl -n "$NS" exec "deploy/$1" -- python3 -c "
import urllib.request, json
print(json.load(urllib.request.urlopen('http://localhost:$2/salud', timeout=5)))
" 2>/dev/null | tail -1)
  echo "  $1: ${salud:-sin respuesta}"
}
comprobar orquestador 7012
comprobar investigador 7010
comprobar defensor 7010

log "Las aristas que ahora SI atraviesan el cluster"
echo "  orquestador -> agentes             GET /.well-known/agent-card.json  <-- descubrir"
echo "  orquestador -> investigador        POST /a2a                         <-- despachar"
echo "  investigador -> defensor      POST /a2a                         <-- salto lateral"
echo "  agente -> servidor-mcp        POST /mcp"
echo "  agente -> vllm (host)         inferencia"
echo ""
echo "  El grafo de Hubble ya esta completo: la flecha que pone la malla en"
echo "  marcha tambien es un paquete. Antes salia del host y no se veia."

log "Para que la interfaz del host alcance al orquestador"
echo "  Un solo puente, porque la interfaz ya solo habla con el orquestador:"
echo ""
echo "    kubectl -n $NS port-forward deploy/orquestador 7012:7012"
echo ""
echo "  Los de investigador y defensor YA NO HACEN FALTA: quien les habla es el"
echo "  router, desde dentro del cluster. Si los dejas puestos no estorban, pero"
echo "  tampoco sirven."
