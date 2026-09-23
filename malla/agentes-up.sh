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

log "Desplegando los dos agentes"
kubectl apply -f "$DIR/00-agentes.yaml" >/dev/null

# Pods nuevos con la imagen recien cargada: sin esto seguirian con la vieja.
# Este es el desfase que ya nos mordio tres veces (§9 del CLAUDE.md).
kubectl -n "$NS" rollout restart deploy/investigador deploy/defensor >/dev/null
kubectl -n "$NS" rollout status deploy/investigador --timeout=180s
kubectl -n "$NS" rollout status deploy/defensor --timeout=180s

# El Service de vLLM no tiene selector, asi que necesita sus Endpoints escritos
# con la IP del host. Se hace aqui para que no haya que recordarlo.
log "Publicando vLLM dentro del cluster"
"$RAIZ/lab/publica-vllm.sh" 2>&1 | sed 's/^/  /'

log "Comprobando que los agentes arrancaron"
for rol in investigador defensor; do
  # La huella del codigo: la misma que lab/estado.sh compara contra el disco.
  salud=$(kubectl -n "$NS" exec "deploy/$rol" -- \
    python3 -c "
import urllib.request, json
print(json.load(urllib.request.urlopen('http://localhost:7010/salud', timeout=5)))
" 2>/dev/null | tail -1)
  echo "  $rol: ${salud:-sin respuesta}"
done

log "Las aristas que ahora SI atraviesan el cluster"
echo "  investigador -> defensor      POST /a2a    <-- el salto lateral"
echo "  agente -> servidor-mcp        POST /mcp"
echo "  agente -> vllm (host)         inferencia"
echo ""
echo "  Eso es lo que Hubble puede dibujar y Cilium gobernar. Antes no existia."

log "Para que la interfaz del host los alcance"
echo "  En dos terminales, o con & al final:"
echo "    kubectl -n $NS port-forward deploy/investigador 7010:7010"
echo "    kubectl -n $NS port-forward deploy/defensor     7011:7010"
echo ""
echo "  Asi ui/servidor.py sigue hablando a localhost:7010 y :7011 sin cambios."
