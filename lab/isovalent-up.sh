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
#   5. `read -rsp "ID Token: "` SIN nombre de variable -> lo que pegues cae en
#      $REPLY, no en $ID_TOKEN, asi que el curl de abajo manda "Bearer " vacio
#      y devuelve un 401 que parece culpa del token
#
# ANTES DEL TOKEN: EL GRUPO. Esto es lo primero y lo que mas cuesta descubrir.
# ----------------------------------------------------------------------------
# El acceso de lectura a los artefactos de Isovalent NO va por ticket de
# Artifactory: va por pertenencia a un grupo en MyID Groups.
#
#     isovalent-artifactory-read-ext
#
# Sin esa membresia todo lo demas funciona y aun asi falla: el token se crea
# bien, autentica bien, ve 140 repositorios -y el de Isovalent da 403-. Nada
# en ese 403 menciona un grupo, asi que es facil perder horas regenerando
# tokens que ya estaban bien. Comprobado el 2026-11-27.
#
# Y UNA VEZ QUE TE APRUEBEN: REGENERA EL TOKEN. La pertenencia a grupos se
# sincroniza desde el proveedor de identidad y el token que creaste antes
# puede seguir llevando el conjunto viejo. Si sigue dando 403 justo despues
# de la aprobacion, eso es lo primero que hay que descartar.
#
# CUANTO TARDA: ~25 minutos medidos el 2026-11-27 (403 a las 17:18, 200 a las
# 17:43), con el token ya regenerado despues del join. O sea que un 403 justo
# despues de entrar al grupo es NORMAL y no hay que hacer nada mas que
# esperar. En vez de estar pendiente:
#
#   while :; do c=$(curl -s -o /dev/null -w '%{http_code}' \
#     -H "Authorization: Bearer $(cat ~/.devhub-token)" \
#     https://artifactory.devhub-cloud.cisco.com/artifactory/isovalent-iep-helm/index.yaml); \
#     printf '%s  %s\n' "$(date +%H:%M)" "$c"; [ "$c" = 200 ] && break; sleep 300; done
#
# Guarda el token en ~/.devhub-token con `umask 077`, NUNCA dentro de este
# repo: vive en OneDrive y es git. Y borralo al terminar.
#
# Dos cosas que nos hicieron perder vueltas y que el bucle de arriba evita:
#   - un 401 en vez de 403 NO es progreso: es que la variable del token esta
#     vacia, normalmente por correr el curl en otra pestaña donde nunca se
#     definio. Por eso el bucle lee de un archivo y no de $TOK.
#   - `read -rs` no muestra NADA al pegar, ni asteriscos, asi que la linea
#     parece congelada y es facil darle Enter en vacio. El intercambio
#     entonces falla en silencio y el token queda vacio.
#
# COMO SE SACA EL TOKEN QUE ESTE SCRIPT PIDE
# ------------------------------------------
# Son DOS tokens distintos y es la confusion que mas cuesta:
#
#   ID token      lo creas a mano en la UI de Artifactory. Solo sirve para
#                 pedir el de acceso; no vale como password.
#   Access token  lo devuelve el intercambio de abajo. ES EL QUE VA AQUI.
#
# El intercambio, corriendo en cualquier maquina con red (la laptop sirve, y
# asi el ID token no pasa por el host del lab):
#
#   read -rsp "ID Token: " ID_TOKEN && echo && \
#   curl -sL -H "Authorization: Bearer $ID_TOKEN" \
#        -H "Content-type: application/json" -XPOST \
#        https://artifactory.devhub-cloud.cisco.com/access/api/v1/tokens \
#        -d '{"description":"isovalent CCL26","token_id":"ccl26-isovalent","token_type":"access_token"}' \
#     | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("access_token") or d)'
#
# Y comprobarlo ANTES de correr este script, contra el repo que de verdad usa:
#
#   curl -s -o /dev/null -w "%{http_code}\n" -u "$CEC:$TOKEN" \
#     https://artifactory.devhub-cloud.cisco.com/artifactory/isovalent-iep-helm/index.yaml
#
#   200 -> adelante
#   401 -> token mal, caducado, o pusiste el ID token
#   403 -> el token sirve pero tu cuenta no tiene acceso al repo de Isovalent.
#          Eso se pide; no se arregla generando otro token.
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

# TETRAGON VA A kube-system, NO AL NAMESPACE "tetragon" QUE PIDEN LAS
# INSTRUCCIONES. Es deliberado y tiene una razon concreta.
#
# Dos cosas del repo leen los eventos del kernel entrando al pod de Tetragon:
# el panel "Lo que vio el kernel" (ui/servidor.py) y seguridad/ver-eventos.sh.
# Las dos descubren el pod por etiqueta, pero tienen que mirar en ALGUN
# namespace. Instalar en "tetragon" dejaria el SIGKILL funcionando y el panel
# en blanco -el peor fallo posible: silencioso, y justo en el segmento 6.
#
# Para instalarlo donde dicen las instrucciones:  NS_TETRAGON=tetragon
NS_TETRAGON=${NS_TETRAGON:-kube-system}

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

# DOS CILIUM NO CABEN. Cilium tiene que ser el unico CNI, y `cilium install`
# de la CLI deja su propia release de Helm. Hacer `helm upgrade` encima es
# pedirle a Helm que adopte una instalacion que no hizo: a veces funciona, y
# cuando no, falla a mitad y deja el cluster sin red.
#
# Mas vale pararse aqui que a medias.
if kubectl -n kube-system get ds cilium >/dev/null 2>&1; then
  version_actual=$(kubectl -n kube-system get ds cilium \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
  case "$version_actual" in
    *devhub-cloud.cisco.com*|*isovalent*)
      echo ""
      echo "Ya hay Cilium empresarial. Esto lo va a actualizar en sitio." ;;
    *)
      echo ""
      echo "  Hay Cilium de CODIGO ABIERTO instalado:"
      echo "    $version_actual"
      echo ""
      echo "  No se puede poner el empresarial encima: Cilium tiene que ser el"
      echo "  unico CNI, y esta instalacion la hizo la CLI, no este chart."
      echo ""
      echo "  El camino limpio es rehacer el cluster sin red:"
      echo "    kind delete cluster --name agentes"
      echo "    ./lab/cluster-up.sh --solo-kind"
      echo "    ./lab/isovalent-up.sh"
      echo ""
      echo "  Rehacer el cluster se lleva Postgres, el servidor MCP, los"
      echo "  agentes y el Collector. Todos vuelven con sus scripts; el que"
      echo "  tarda es ./malla/agentes-up.sh porque reconstruye la imagen."
      echo "  vLLM NO se toca: corre en el host, fuera de kind."
      exit 1 ;;
  esac
fi

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
kubectl create ns "$NS_TETRAGON" >/dev/null 2>&1 || true
for ns in $(printf '%s\n' kube-system "$NS_TETRAGON" | sort -u); do
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
  echo "    - pusiste el ID token y no el de ACCESO que se pide con el"
  echo "      (el intercambio esta en la cabecera de este script)"
  echo "    - NO eres miembro de isovalent-artifactory-read-ext en MyID"
  echo "      Groups. Es la causa mas probable, y el 403 no la menciona."
  echo "    - te aprobaron el grupo pero el token es anterior: regeneralo"
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

# LOS TRES VALORES DE EXPORTACION NO SON COSMETICA.
#
# Tetragon escribe los eventos en un archivo del nodo, y el repo lo lee de una
# ruta concreta con un permiso concreto:
#
#   exportFilename=eventos.log  el nombre por omision es tetragon.log, y el
#       archivo se crea con 600 la PRIMERA vez. Un archivo que ya existe se
#       queda en 600 para siempre, asi que cambiar el permiso despues no
#       arregla nada: hay que estrenar nombre. De ahi "eventos.log".
#   exportFilePerm=644          para leerlo sin ser root.
#   export.mode=""              sin el sidecar que copia a stdout, que es otra
#       imagen mas que bajar de Artifactory y no usamos.
#
# Si el chart empresarial renombro alguna de estas claves, Helm NO avisa: las
# acepta y las ignora. Por eso al final se comprueba el archivo de verdad.
cat > "$TMP/tetragon.yaml" <<EOF
export:
  mode: ""
tetragon:
  exportFilename: eventos.log
  exportFilePerm: 644
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
  --namespace "$NS_TETRAGON" -f "$TMP/tetragon.yaml" \
  --set "imagePullSecrets[0].name=devhub-registry" \
  --wait --timeout 10m || { echo "  FALLO. kubectl -n $NS_TETRAGON get pods"; exit 1; }

# --- Que de verdad quedo arriba ----------------------------------------------
log "Comprobando"
kubectl -n kube-system get pods -l k8s-app=cilium \
  -o custom-columns='POD:.metadata.name,ESTADO:.status.phase' --no-headers | sed 's/^/  /'
kubectl -n "$NS_TETRAGON" get pods -l app.kubernetes.io/name=tetragon \
  -o custom-columns='POD:.metadata.name,ESTADO:.status.phase' --no-headers | sed 's/^/  /'

# Helm acepta claves que el chart no conoce y las ignora en silencio. La unica
# forma de saber si exportFilename se aplico es mirar el archivo.
log "El archivo de eventos del kernel"
pod_tet=$(kubectl -n "$NS_TETRAGON" get pods -l app.kubernetes.io/name=tetragon \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -n "$pod_tet" ]; then
  listado=$(kubectl -n "$NS_TETRAGON" exec "$pod_tet" -c tetragon -- \
    sh -c 'ls -l /var/run/cilium/tetragon/ 2>/dev/null' 2>/dev/null)
  echo "$listado" | sed 's/^/  /'
  if echo "$listado" | grep -q 'eventos\.log'; then
    echo "  ok   el panel y ver-eventos.sh van a encontrarlo"
  else
    echo ""
    echo "  OJO: no veo eventos.log. El chart empresarial debe usar otro"
    echo "  nombre de clave para exportFilename. El SIGKILL va a funcionar"
    echo "  igual, pero el panel 'Lo que vio el kernel' y ver-eventos.sh se"
    echo "  van a quedar en blanco, sin dar error."
    echo "  Mira que nombre aparece arriba y ajusta las dos rutas:"
    echo "    ui/servidor.py            (la ruta del cat)"
    echo "    seguridad/ver-eventos.sh  (la variable LOG)"
  fi
else
  echo "  (no encuentro el pod de Tetragon todavia)"
fi

echo ""
echo "=== Y ahora, lo que de verdad importa comprobar"
echo ""
if [ "$NS_TETRAGON" != "kube-system" ]; then
  echo "  OJO: Tetragon quedo en el namespace '$NS_TETRAGON'. ui/servidor.py y"
  echo "  seguridad/ver-eventos.sh buscan en kube-system: hay que ajustarlos."
  echo ""
fi
echo "  Las politicas son el MISMO CRD, asi que deberian aplicar igual:"
echo "    kubectl apply -f seguridad/"
echo "    ./lab/estado.sh"
echo ""
echo "  Si algo falla, lo primero que yo miraria es la politica L7: es lo que"
echo "  mas depende de Envoy, y Envoy es lo que mas cambia entre versiones."
echo ""

if [ "${PRECARGAR:-no}" = si ]; then
  log "Guardando las imagenes para poder rehacer el cluster sin token"
  #
  # POR QUE ESTO NO ES "kind load" Y SE ACABO
  # -----------------------------------------
  # Tres cosas que no son obvias:
  #
  #  1. Las imagenes YA estan dentro del nodo de kind -por eso los pods
  #     corren-. Cargarlas otra vez ahi no sirve de nada. Lo que hace falta es
  #     que esten en el DOCKER DEL HOST, que es de donde `kind load` las saca
  #     cuando rehagas el cluster.
  #
  #  2. `docker pull` del host NO usa el Secret de Kubernetes. El Secret es
  #     para que el kubelet baje imagenes; el docker del host no lo ve. Hace
  #     falta `docker login` aparte, y sin el los pull fallan por 401.
  #
  #  3. Un `docker image prune` se lleva lo que no esta en uso. Por eso ademas
  #     se guardan en un tar: eso sobrevive a cualquier limpieza.
  #
  DESTINO=${DESTINO_IMAGENES:-$HOME/isovalent-imagenes}
  mkdir -p "$DESTINO"

  # El login del host, que es el paso que faltaba.
  if printf '%s' "$ACCESS_TOKEN" \
       | docker login "$REGISTRO" --username "$CEC" --password-stdin >/dev/null 2>&1; then
    echo "  ok   docker login en $REGISTRO"
  else
    echo "  FALLO el docker login. Sin el, los pull dan 401."
    echo "  Las imagenes se quedan solo dentro del nodo de kind, asi que un"
    echo "  'kind delete' las perderia. Reintenta con:"
    echo "    ACCESS_TOKEN=... ./lab/isovalent-up.sh --precargar"
    exit 1
  fi

  # Todas las imagenes de las dos instalaciones, initContainers incluidos: el
  # chart de Cilium trae varios, y olvidarlos deja el cluster a medias en el
  # rearranque sin token.
  IMAGENES=$(
    { kubectl -n kube-system get pods -l k8s-app=cilium -o json
      kubectl -n kube-system get pods -l 'io.cilium/app=operator' -o json
      kubectl -n kube-system get pods -l k8s-app=hubble-relay -o json
      kubectl -n kube-system get pods -l k8s-app=hubble-ui -o json
      kubectl -n "$NS_TETRAGON" get pods -l app.kubernetes.io/name=tetragon -o json
    } 2>/dev/null \
      | grep -oE '"image": *"[^"]+"' \
      | sed -E 's/.*"image": *"([^"]+)".*/\1/' \
      | sort -u
  )
  [ -z "$IMAGENES" ] && { echo "  No encontre imagenes que guardar."; exit 1; }

  fallos=0
  for img in $IMAGENES; do
    tar="$DESTINO/$(echo "$img" | tr '/:' '__').tar"
    if docker pull "$img" >/dev/null 2>&1 && docker save -o "$tar" "$img" 2>/dev/null; then
      echo "  ok   $img"
    else
      echo "  FALLO $img"
      fallos=$((fallos + 1))
    fi
  done

  echo ""
  if [ "$fallos" -eq 0 ]; then
    echo "  Guardadas en $DESTINO"
    echo ""
    echo "  Para rehacer el cluster cuando el token ya no sirva:"
    echo "    kind delete cluster --name agentes"
    echo "    ./lab/cluster-up.sh --solo-kind"
    echo "    for t in $DESTINO/*.tar; do docker load -i \"\$t\"; done"
    echo "    ./lab/isovalent-up.sh        (ya no baja nada de Artifactory)"
  else
    echo "  $fallos imagenes no se pudieron guardar. El cluster de HOY funciona"
    echo "  igual, pero rehacerlo sin token no esta garantizado."
  fi
fi
