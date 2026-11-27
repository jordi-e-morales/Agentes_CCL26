#!/usr/bin/env bash
#
# Instala Isovalent Enterprise (Cilium + Runtime Security) desde Artifactory
# de Cisco, EN LUGAR de las versiones de codigo abierto.
#
# POR QUE ESTO EXISTE
# -------------------
# El §7 de PUNTOS-CLAVE.md tiene cuatro puntos marcados como "confirmar con
# material oficial". Correr la plataforma empresarial de verdad convierte el
# primero -que añade Isovalent sobre Cilium- de afirmacion a demostracion.
#
# LO QUE ESTE SCRIPT HACE DISTINTO DE LAS INSTRUCCIONES DE CISCO
# ---------------------------------------------------------------
# Las instrucciones tienen cuatro erratas que cuestan una tarde cada una:
#
#   1. `set CEC=<tu CEC>`            -> eso es sintaxis de cmd, no de bash
#   2. `--docker-password=$ACCESS-TOKEN` -> es $ACCESS seguido de "-TOKEN"
#   3. `--docker-username=<your=CEC>`    -> el `=` sobra
#   4. `k8s-apiserver: https://$CP\_IP:$CP\_PORT` -> las barras producen
#      literales, y Tetragon acaba apuntando a un host que no existe
#
# Y tres cosas que SE PERDERIAN si se usan los valores tal cual:
#
#   - hubble.ui NO se activa en el values de ejemplo. Sin ella no hay grafo,
#     y el grafo es la mitad del segmento 3.
#   - hubble.eventBufferCapacity vuelve al default (4095 = ~164 s de
#     historia). Lo subimos a 65535 a proposito el 2026-09-23 porque a los
#     tres minutos los flujos que quieres narrar ya no existen.
#   - envoy.streamIdleTimeoutDurationSeconds vuelve a 300 s. Con politicas L7
#     el trafico pasa por Envoy, y un agente en CPU tarda hasta ~6 min sin
#     mandar un byte: la peticion se cortaria sola.
#
# EL TOKEN CADUCA A LOS 90 DIAS. Eso lo vuelve una dependencia con fecha, asi
# que al final se ofrece precargar las imagenes en kind: una vez dentro, el
# cluster se puede rehacer sin Artifactory y sin token.
#
# Uso:
#   ./lab/isovalent-up.sh                 (pide el token por teclado)
#   CEC=jmorales ./lab/isovalent-up.sh
#   ./lab/isovalent-up.sh --precargar     (guarda las imagenes para despues)

set -uo pipefail

REGISTRO=artifactory.devhub-cloud.cisco.com
REPO_HELM="https://$REGISTRO/artifactory/isovalent-iep-helm/"
CILIUM_VER=${CILIUM_VER:-1.19.8}
TETRAGON_VER=${TETRAGON_VER:-1.19.3}

# Los mismos valores que el cluster de codigo abierto, por los motivos escritos
# en lab/cluster-up.sh. No son preferencias: son cosas medidas.
IDLE_ENVOY=${IDLE_ENVOY:-1800}
BUFFER_HUBBLE=${BUFFER_HUBBLE:-65535}

# TIMESCAPE APAGADO POR OMISION, y no es desconfianza.
#
# Timescape guarda historia de flujos en un backend propio. Si ese backend no
# esta, los pods de Cilium pueden quedar intentando exportar a un sitio que no
# existe -y eso rompe lo que hoy funciona-. La regla del §11 es cambios
# pequeños y verificables: primero que el cluster viva, despues Timescape.
#
#   ./lab/isovalent-up.sh --con-timescape
TIMESCAPE=no

# L2 announcements anuncia IPs de LoadBalancer por ARP en una red fisica. En
# kind no hay tal red: a los servicios se llega por port-forward. Se deja
# apagado porque encender lo que no se usa solo añade superficie de fallo.
L2=no

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
log() { echo ""; echo "=== $1"; }

for arg in "$@"; do
  case "$arg" in
    --con-timescape) TIMESCAPE=si ;;
    --con-l2)        L2=si ;;
    --precargar)     PRECARGAR=si ;;
  esac
done

# --- Lo que tiene que estar antes --------------------------------------------
command -v helm >/dev/null || { echo "Falta helm: corre ./lab/bootstrap.sh"; exit 1; }
kubectl get nodes >/dev/null 2>&1 || {
  echo "No hay cluster. Corre ./lab/cluster-up.sh --solo-kind primero."; exit 1; }

if [ -z "${CEC:-}" ]; then
  echo ""
  echo "Tu CEC de Cisco (el usuario, NO el correo)."
  read -rp "CEC: " CEC
fi
[ -z "$CEC" ] && { echo "Sin CEC no se puede autenticar."; exit 1; }

# Por teclado y no por argumento: los argumentos se ven en `ps` y quedan en el
# historial. Mismo criterio que observabilidad/splunk-up.sh.
if [ -z "${ACCESS_TOKEN:-}" ]; then
  echo ""
  echo "Token de ACCESO de Artifactory (no el ID token con el que lo creaste)."
  read -rsp "Token: " ACCESS_TOKEN
  echo ""
fi
ACCESS_TOKEN="$(printf '%s' "$ACCESS_TOKEN" | tr -d '[:space:]')"
[ -z "$ACCESS_TOKEN" ] && { echo "Sin token no hay nada que hacer."; exit 1; }

# --- Lo que las instrucciones piden a mano, aqui se deduce -------------------
log "Mirando el cluster"
# `kubectl cluster-info` imprime la URL con color; se le quitan los escapes
# ANSI o el sed de abajo se come caracteres de mas.
URL_CP=$(kubectl cluster-info 2>/dev/null \
  | sed -e 's/\x1b\[[0-9;]*m//g' \
  | grep -i "control plane" | grep -oE 'https?://[^ ]+' | head -1)
CP_IP=$(echo "$URL_CP"   | sed -E 's#^https?://##; s#:.*##')
CP_PORT=$(echo "$URL_CP" | sed -E 's#.*:([0-9]+).*#\1#')
# Nodos SCHEDULABLES, que no es lo mismo que nodos. En kind el control-plane
# lleva taint, asi que con 1 worker las replicas son 1. Poner 2 aqui deja la
# segunda del operador en Pending para siempre, por antiafinidad.
NODOS=$(kubectl get nodes \
  -o jsonpath='{range .items[*]}{.spec.taints[?(@.effect=="NoSchedule")].key}{"|"}{end}' \
  2>/dev/null | tr '|' '\n' | grep -c '^$')
[ "${NODOS:-0}" -lt 1 ] && NODOS=1
echo "  control plane : $CP_IP:$CP_PORT"
echo "  nodos donde se puede programar: $NODOS"
[ -z "$CP_IP" ] && { echo "No pude leer la IP del control plane."; exit 1; }

# --- Credenciales ------------------------------------------------------------
log "Secretos para bajar las imagenes"
kubectl create ns tetragon >/dev/null 2>&1 || true
for ns in kube-system tetragon; do
  kubectl -n "$ns" delete secret devhub-registry --ignore-not-found >/dev/null 2>&1
  kubectl -n "$ns" create secret docker-registry devhub-registry \
    --docker-server="$REGISTRO" \
    --docker-username="$CEC" \
    --docker-password="$ACCESS_TOKEN" >/dev/null && echo "  ok  $ns"
done

log "Repositorio de Helm"
helm repo add devhub "$REPO_HELM" --username "$CEC" --password "$ACCESS_TOKEN" \
  >/dev/null 2>&1 || helm repo add devhub "$REPO_HELM" --username "$CEC" \
  --password "$ACCESS_TOKEN" --force-update >/dev/null
helm repo update devhub >/dev/null && echo "  ok"

# Comprobar ANTES de tocar el cluster que el token sirve. Si no, el fallo sale
# mas tarde como pods en ImagePullBackOff, que no dice nada del token.
if ! helm search repo devhub/cilium --version "$CILIUM_VER" 2>/dev/null | grep -q cilium; then
  echo ""
  echo "  No veo devhub/cilium $CILIUM_VER en el repositorio."
  echo "  Causas, por probabilidad:"
  echo "    - el token caduco (duran 90 dias)"
  echo "    - es el ID token y no el token de ACCESO que se genera con el"
  echo "    - el CEC no es el correcto (va el usuario, no el correo)"
  exit 1
fi

# --- Los values --------------------------------------------------------------
log "Preparando la configuracion"
cat > "$TMP/cilium.yaml" <<EOF
operator:
  replicas: $NODOS
kubeProxyReplacement: true
k8sServiceHost: $CP_IP
k8sServicePort: $CP_PORT
nodeinit:
  enabled: true
ipam:
  mode: cluster-pool
l2announcements:
  enabled: $([ "$L2" = si ] && echo true || echo false)
enterprise:
  featureGate:
    approved:
      - HubbleTimescape
      - L2Announcement
hubble:
  enabled: true
  tls:
    enabled: true
  # LAS TRES LINEAS QUE EL VALUES DE EJEMPLO NO TRAE, y sin las que la demo
  # pierde el grafo y la historia de trafico.
  relay:
    enabled: true
  ui:
    enabled: true
  eventBufferCapacity: $BUFFER_HUBBLE
  timescape:
    enabled: $([ "$TIMESCAPE" = si ] && echo true || echo false)
# Con politicas L7 el trafico HTTP pasa por Envoy. 300 s por omision cortaria
# una deliberacion en CPU; medido 345 s sin mandar un byte.
envoy:
  streamIdleTimeoutDurationSeconds: $IDLE_ENVOY
EOF

cat > "$TMP/tetragon.yaml" <<EOF
tetragon:
  config:
    k8s-apiserver: https://$CP_IP:$CP_PORT
  extraEnv:
    - name: KUBERNETES_SERVICE_HOST
      value: "$CP_IP"
    - name: KUBERNETES_SERVICE_PORT
      value: "$CP_PORT"
  manager:
    extraEnv:
      - name: KUBERNETES_SERVICE_HOST
        value: "$CP_IP"
      - name: KUBERNETES_SERVICE_PORT
        value: "$CP_PORT"
EOF
echo "  ok   (timescape: $TIMESCAPE, l2: $L2)"

# --- Instalar ----------------------------------------------------------------
log "CRDs de Prometheus"
kubectl apply --server-side -f \
  https://github.com/prometheus-operator/prometheus-operator/releases/latest/download/stripped-down-crds.yaml \
  >/dev/null 2>&1 && echo "  ok" || echo "  (ya estaban o no hizo falta)"

log "Cilium Enterprise $CILIUM_VER"
helm upgrade --install cilium devhub/cilium --version "$CILIUM_VER" \
  --namespace kube-system -f "$TMP/cilium.yaml" \
  --set "imagePullSecrets[0].name=devhub-registry" \
  --wait --timeout 10m || { echo "  FALLO. kubectl -n kube-system get pods"; exit 1; }

log "Isovalent Runtime Security $TETRAGON_VER"
helm upgrade --install tetragon devhub/tetragon --version "$TETRAGON_VER" \
  --namespace tetragon -f "$TMP/tetragon.yaml" \
  --set "imagePullSecrets[0].name=devhub-registry" \
  --wait --timeout 10m || { echo "  FALLO. kubectl -n tetragon get pods"; exit 1; }

# --- Que de verdad quedo arriba ----------------------------------------------
log "Comprobando"
kubectl -n kube-system get pods -l k8s-app=cilium \
  -o custom-columns='POD:.metadata.name,ESTADO:.status.phase' --no-headers | sed 's/^/  /'
kubectl -n tetragon get pods \
  -o custom-columns='POD:.metadata.name,ESTADO:.status.phase' --no-headers | sed 's/^/  /'

echo ""
echo "=== Y ahora, lo que de verdad importa comprobar"
echo ""
echo "  Las politicas son el MISMO CRD, asi que deberian aplicar igual:"
echo "    kubectl apply -f seguridad/"
echo "    ./lab/estado.sh"
echo ""
echo "  Si algo falla, lo primero que yo miraria es la politica L7: es lo que"
echo "  mas depende de Envoy, y Envoy es lo que mas cambia entre versiones."
echo ""

if [ "${PRECARGAR:-no}" = si ]; then
  log "Guardando las imagenes en kind"
  echo "  Para poder rehacer el cluster sin token ni Artifactory."
  for img in $(kubectl -n kube-system get pods -l k8s-app=cilium \
                 -o jsonpath='{.items[0].spec.containers[*].image}' 2>/dev/null) \
             $(kubectl -n tetragon get pods \
                 -o jsonpath='{.items[0].spec.containers[*].image}' 2>/dev/null); do
    docker pull "$img" >/dev/null 2>&1 && \
      kind load docker-image "$img" --name agentes >/dev/null 2>&1 && \
      echo "  ok  $img"
  done
fi
