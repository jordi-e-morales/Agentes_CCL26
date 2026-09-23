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

# EndpointSlice, no Endpoints.
#
# La v1 usaba `kind: Endpoints`, y sigue funcionando, pero en Kubernetes 1.33+
# avisa de que esta deprecado. Un warning en pantalla el dia del evento es ruido
# que hay que explicar, asi que se usa el recurso moderno.
#
# La diferencia que importa: un EndpointSlice se une a su Service por la
# ETIQUETA `kubernetes.io/service-name`, no por el nombre. Con Endpoints era el
# nombre. Si esa etiqueta falta, el Service se queda sin destinos y no hay
# ningun error — simplemente nada conecta.
# Limpieza del recurso viejo, si quedo de una corrida anterior de este script.
#
# Un Service no puede tener las dos cosas: el controlador de mirroring convierte
# un `Endpoints` manual en su propio EndpointSlice, asi que junto con el nuestro
# el Service acabaria con destinos duplicados. Funcionaria por casualidad hasta
# que uno de los dos quedara desactualizado.
if kubectl -n "$NS" get endpoints vllm >/dev/null 2>&1; then
  log "Quitando el Endpoints viejo (lo reemplaza el EndpointSlice)"
  kubectl -n "$NS" delete endpoints vllm >/dev/null
  # El slice espejo que creo el controlador se va con el.
  kubectl -n "$NS" delete endpointslice \
    -l "endpointslice.kubernetes.io/managed-by=endpointslicemirroring-controller,kubernetes.io/service-name=vllm" \
    --ignore-not-found >/dev/null 2>&1 || true
  echo "  quitado"
fi

log "Escribiendo el EndpointSlice"
kubectl apply -f - <<EOF >/dev/null
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: vllm
  namespace: $NS
  labels:
    kubernetes.io/service-name: vllm
addressType: IPv4
ports:
  - {name: http, port: $PUERTO, protocol: TCP}
endpoints:
  - addresses: ["$IP_HOST"]
    conditions: {ready: true}
EOF

# LA POLITICA DE SALIDA HACIA EL MODELO, CON LA IP REAL.
#
# Esto no esta en seguridad/cilium-l7.yaml a proposito, y la razon esta medida:
#
#   `toEntities: [host]` NO MATCHEA en kind. Cilium no clasifica la puerta de
#   enlace de la red Docker como la entidad `host` — esa entidad es el nodo, que
#   tiene otra IP. La regla no aplica y el egress al modelo se queda en timeout,
#   sin nada en el log que apunte a la politica.
#
# La v1 llego a la misma conclusion y la dejo escrita en
# deploy/vllm-host/egress-up.sh. Se copia de ahi.
#
# REQUISITO DE ORDEN: `agentes-salida` (en cilium-l7.yaml) tiene que existir
# ANTES, porque es la que lleva la regla de DNS. Cualquier politica con egress
# pone al pod en denegacion por omision; si esta se aplicara sola, los agentes
# perderian la resolucion de nombres y el fallo no se pareceria a su causa.
if kubectl -n "$NS" get ciliumnetworkpolicy agentes-salida >/dev/null 2>&1; then
  log "Permitiendo la salida al modelo ($IP_HOST/32:$PUERTO)"
  kubectl apply -f - <<EOF >/dev/null
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: agentes-vllm-host
  namespace: $NS
spec:
  endpointSelector:
    matchLabels:
      rol: agente
  egress:
    - toCIDRSet:
        - cidr: $IP_HOST/32
      toPorts:
        - ports:
            - {port: "$PUERTO", protocol: TCP}
EOF
  echo "  ok"
else
  log "Sin politica de red todavia"
  echo "  No encuentro 'agentes-salida', asi que los agentes no estan en"
  echo "  denegacion por omision y alcanzan el modelo sin necesitar regla."
  echo ""
  echo "  Cuando apliques las politicas, vuelve a correr este script:"
  echo "    kubectl apply -f seguridad/cilium-l7.yaml"
  echo "    ./lab/publica-vllm.sh"
fi

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
    echo "  Para saber si es la red o es vLLM, comprueba desde el HOST:"
    echo "    curl -s http://$IP_HOST:$PUERTO/v1/models | head -c 120"
    echo ""
    echo "  Si eso responde, vLLM esta bien y el problema es la politica."
    echo "  Si no responde, vLLM no escucha en esa interfaz:"
    echo "    docker ps --filter name=vllm --format '{{.Ports}}'"
    echo "  Tiene que decir 0.0.0.0:$PUERTO, no 127.0.0.1:$PUERTO."
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
