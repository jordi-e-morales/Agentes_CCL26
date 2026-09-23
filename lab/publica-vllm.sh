#!/usr/bin/env bash
#
# Publica vLLM (que corre en el HOST) como un Service dentro del cluster.
#
# EL PROBLEMA QUE RESUELVE
# ------------------------
# vLLM corre fuera de kind, como contenedor en el host: pasar la GPU a un nodo
# de kind es fragil (§8). Pero los agentes SI viven en el cluster, y necesitan
# alcanzarlo.
#
# Se podria meter la IP del host en el ConfigMap, y es mala idea: esa IP cambia
# cada vez que se reconstruye el lab, asi que quedaria un valor que funciona
# hasta que alguien recrea el cluster y entonces falla sin decir por que.
#
# LA SOLUCION, HEREDADA DE LA V1 (deploy/vllm-host/servicios.yaml)
# ---------------------------------------------------------------
# Un Service SIN selector no tiene pods detras: sus Endpoints se escriben a
# mano. Este script los escribe con la IP del host, calculada. Los agentes
# llaman a http://vllm:8000 como a cualquier otro Service y no saben que el
# modelo esta fuera del cluster.
#
# Es idempotente y NO toca vLLM: se puede correr con el modelo ya cargado, que
# es justo lo que hace falta (cargar 18 GiB de pesos tarda minutos).
#
# Uso:  ./lab/publica-vllm.sh

set -euo pipefail
NS=agentes
RED_KIND="${RED_KIND:-kind}"
PUERTO="${PUERTO:-8000}"

log() { echo ""; echo "=== $1"; }

kubectl get nodes >/dev/null 2>&1 || {
  echo "El cluster no responde: corre ./lab/cluster-up.sh"; exit 1; }

# El host, visto desde los pods de kind, es la puerta de enlace de la red Docker
# del cluster. Se calcula, no se teclea.
#
# OJO: la red de kind es dual-stack. Hay que tomar la puerta IPv4, no la IPv6
# (fc00:...): vLLM se publica con -p en IPv4, y un Endpoint IPv6 no lo alcanza.
# Este detalle costo un rato en la v1 y por eso esta escrito.
log "Calculando la IP del host, vista desde los pods"
IP_HOST="$(docker network inspect "$RED_KIND" \
  -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' \
  | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1)"

if [ -z "$IP_HOST" ]; then
  echo "No pude calcular la IP del host en la red Docker '$RED_KIND'."
  echo "Comprueba:  docker network inspect $RED_KIND"
  exit 1
fi
echo "  $IP_HOST:$PUERTO"

# El Service lo define malla/00-agentes.yaml. Aqui solo se comprueba que exista,
# porque un Endpoints sin su Service no sirve de nada y el error seria confuso.
if ! kubectl -n "$NS" get svc vllm >/dev/null 2>&1; then
  echo ""
  echo "Falta el Service 'vllm'. Lo crea:"
  echo "  kubectl apply -f malla/00-agentes.yaml"
  exit 1
fi

# El nombre del Endpoints DEBE coincidir con el del Service: asi es como
# Kubernetes los une. No hay campo que los relacione.
#
# La API Endpoints esta marcada como deprecada en favor de EndpointSlice, pero
# para un Service sin selector sigue siendo el camino soportado: el controlador
# de mirroring copia estos Endpoints a EndpointSlices solo.
log "Escribiendo los Endpoints"
kubectl apply -f - <<EOF >/dev/null
apiVersion: v1
kind: Endpoints
metadata:
  name: vllm
  namespace: $NS
subsets:
  - addresses: [{ip: "$IP_HOST"}]
    ports: [{port: $PUERTO}]
EOF

log "Comprobando desde dentro del cluster"
# Se prueba desde un pod de verdad. Comprobarlo desde el host no demuestra nada:
# el host siempre alcanza a vLLM, el que tiene que alcanzarlo es el pod.
if kubectl -n "$NS" get pod agente-demo >/dev/null 2>&1; then
  modelos=$(kubectl -n "$NS" exec agente-demo -- python3 -c "
import urllib.request, json
try:
    r = urllib.request.urlopen('http://vllm:8000/v1/models', timeout=8)
    print(','.join(m['id'] for m in json.load(r)['data']))
except Exception as e:
    print(f'FALLO {type(e).__name__}')
" 2>/dev/null | tail -1)
  if [[ "$modelos" == FALLO* ]]; then
    echo "  $modelos"
    echo ""
    echo "  Si vLLM esta corriendo, lo mas probable es la politica de red:"
    echo "    kubectl apply -f seguridad/cilium-l7.yaml"
    echo "  (la regla de salida hacia 'host' en el puerto $PUERTO)"
  else
    echo "  ok  el pod alcanza el modelo: $modelos"
  fi
else
  echo "  (sin pod de prueba; para comprobarlo:"
  echo "     kubectl apply -f seguridad/00-pods-de-prueba.yaml)"
fi

log "Listo"
echo "  Los agentes llaman a  http://vllm:8000/v1  sin saber que esta fuera."
echo "  Repetir este script cada vez que se recree el cluster o cambie la IP."
