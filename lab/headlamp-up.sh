#!/usr/bin/env bash
#
# Headlamp: un visor del cluster en el navegador.
#
# PARA QUE, EN ESTA DEMO
# ----------------------
# Para enseñar pods, Deployments y logs sin teclear kubectl en vivo. Es una
# ventana del presentador, no una pieza de la malla: nada depende de ella y
# apagarla no rompe nada.
#
# NO SUSTITUYE A HUBBLE UI, Y LA DIFERENCIA IMPORTA (§6 del CLAUDE.md):
#
#   Headlamp dibuja lo que esta DECLARADO: objetos de la API de Kubernetes.
#   Hubble UI dibuja lo que de verdad PASO: trafico observado.
#
# El grafo de agentes del segmento 3 se enseña con Hubble, no con esto. Un
# visor de objetos es un diagrama de diseño con otro nombre, y en una sesion
# sobre observabilidad eso es casi una contradiccion.
#
# POR QUE 0.0.0.0 Y NO localhost
# -------------------------------
# Mismo motivo que lab/hubble-ui.sh: el host no tiene escritorio, asi que un
# port-forward contra 127.0.0.1 solo existe para el propio host y desde tu
# maquina no se ve nada. El sintoma es un "no se puede conectar" que no dice
# por que.
#
# Uso:
#   ./lab/headlamp-up.sh              instala si falta, y abre el puente
#   ./lab/headlamp-up.sh --token      solo imprime un token nuevo
#   ./lab/headlamp-up.sh --down       lo quita del cluster

set -uo pipefail

NS=headlamp
# VERSION FIJA, por el §8: el dia del evento debe correr lo mismo que se
# ensayo, y un chart sin version da un cluster distinto cada semana.
# 0.46.0 es la ultima del repo oficial al 2026-11-27.
VERSION=${VERSION:-0.46.0}
REPO=https://kubernetes-sigs.github.io/headlamp/
PUERTO=${PUERTO:-12001}
SA=headlamp-admin
# Cuanto dura el token que se imprime. Corto a proposito: es una credencial
# con permisos amplios y no tiene por que sobrevivir a la jornada.
DURACION=${DURACION:-24h}

log() { echo ""; echo "=== $1"; }

for arg in "$@"; do
  case "$arg" in
    --down)  ACCION=down ;;
    --token) ACCION=token ;;
  esac
done

command -v helm >/dev/null || { echo "Falta helm: corre ./lab/bootstrap.sh"; exit 1; }
kubectl get nodes >/dev/null 2>&1 || { echo "No hay cluster."; exit 1; }

if [ "${ACCION:-}" = down ]; then
  log "Quitando Headlamp"
  helm -n "$NS" uninstall headlamp >/dev/null 2>&1 && echo "  ok  release"
  kubectl delete clusterrolebinding "$SA" --ignore-not-found >/dev/null 2>&1
  kubectl delete ns "$NS" --ignore-not-found >/dev/null 2>&1 && echo "  ok  namespace"
  exit 0
fi

# --- La cuenta con la que entras ---------------------------------------------
#
# Headlamp no tiene usuarios propios: se autentica con un token de
# ServiceAccount, y ve exactamente lo que ese ServiceAccount puede ver.
#
# Aqui va cluster-admin, y conviene decir en voz alta por que: es un LAB, y lo
# que se quiere es poder mirarlo todo. En una sesion cuyo segmento 6 trata de
# minimo privilegio, esto es justo lo contrario — asi que si alguien pregunta,
# la respuesta honesta es "es una herramienta de presentador, no parte del
# sistema que estamos gobernando". Para dar solo lectura, cambia cluster-admin
# por `view` en la linea del ClusterRoleBinding.
crear_cuenta() {
  kubectl create ns "$NS" >/dev/null 2>&1 || true
  kubectl -n "$NS" create serviceaccount "$SA" >/dev/null 2>&1 || true
  kubectl create clusterrolebinding "$SA" \
    --clusterrole=cluster-admin \
    --serviceaccount="$NS:$SA" >/dev/null 2>&1 || true
}

imprimir_token() {
  echo ""
  echo "    Pega esto en la pantalla de login de Headlamp (caduca en $DURACION):"
  echo ""
  kubectl -n "$NS" create token "$SA" --duration="$DURACION" | sed 's/^/      /'
  echo ""
  echo "    Para otro token mas tarde:  ./lab/headlamp-up.sh --token"
}

if [ "${ACCION:-}" = token ]; then
  crear_cuenta
  imprimir_token
  exit 0
fi

# --- Instalacion -------------------------------------------------------------
log "Repositorio de Helm"
helm repo add headlamp "$REPO" >/dev/null 2>&1 || true
helm repo update headlamp >/dev/null && echo "  ok"

log "Headlamp $VERSION"
# `helm upgrade --install` es idempotente: instala si falta y no hace nada si
# ya esta con estos mismos valores.
helm upgrade --install headlamp headlamp/headlamp \
  --version "$VERSION" --namespace "$NS" --create-namespace \
  --wait --timeout 5m || { echo "  FALLO. kubectl -n $NS get pods"; exit 1; }

crear_cuenta

kubectl -n "$NS" get pods -o custom-columns='POD:.metadata.name,ESTADO:.status.phase' \
  --no-headers | sed 's/^/  /'

SVC=$(kubectl -n "$NS" get svc -l app.kubernetes.io/name=headlamp \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
[ -z "$SVC" ] && SVC=headlamp

# La IP con la que entras desde tu maquina. Se imprime porque adivinarla es
# justo donde uno se queda atorado.
IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo "=== Headlamp"
echo ""
echo "    Desde tu navegador:   http://${IP:-<ip-del-host>}:$PUERTO"
imprimir_token
echo ""
echo "    Ctrl+C para cerrar el puente. Headlamp sigue instalado en el"
echo "    cluster; para quitarlo del todo:  ./lab/headlamp-up.sh --down"
echo ""

exec kubectl -n "$NS" port-forward --address 0.0.0.0 "svc/$SVC" "$PUERTO:80"
