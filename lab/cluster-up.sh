#!/usr/bin/env bash
#
# Crea el cluster de Kubernetes con Cilium como red.
#
# Idempotente: si el cluster ya existe, no lo vuelve a crear.
# Para borrarlo y empezar de cero:  kind delete cluster --name agentes

set -euo pipefail

CLUSTER=agentes
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo ""; echo "=== $1"; }

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER"; then
  log "El cluster '$CLUSTER' ya existe"
else
  log "Creando el cluster '$CLUSTER'"
  # Ojo con la configuracion: creamos el cluster SIN red.
  # Eso es a proposito. Cilium va a ser la red, y necesita ser el unico.
  kind create cluster --name "$CLUSTER" --config "$DIR/kind-cluster.yaml"
fi

log "Instalando Cilium como red del cluster"
# kubeProxyReplacement=true: Cilium reemplaza a kube-proxy usando eBPF.
# hubble: es el sistema de observabilidad. Sin esto no puedes VER el trafico,
#         y ver el trafico es la mitad de la demo.
# envoy.streamIdleTimeoutDurationSeconds: cuando haya politicas L7, el trafico
#         HTTP entre agentes pasa por Envoy, que corta una peticion tras 300 s
#         sin actividad. En CPU un agente tarda hasta ~6 min en responder sin
#         mandar un byte (medido: 345 s el Arbitro), asi que se sube a 30 min.
#         En GPU sobra, pero no estorba.
IDLE_ENVOY=1800
if ! cilium status >/dev/null 2>&1; then
  cilium install \
    --set kubeProxyReplacement=true \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set envoy.streamIdleTimeoutDurationSeconds=$IDLE_ENVOY
else
  echo "Cilium ya estaba instalado"
  # Clusters creados antes de este ajuste: aplicarlo sin reinstalar.
  # `cilium config set` cambia el ConfigMap y reinicia los pods de Cilium.
  actual=$(kubectl -n kube-system get configmap cilium-config \
    -o jsonpath='{.data.http-stream-idle-timeout}')
  if [ "$actual" != "$IDLE_ENVOY" ]; then
    echo "Ajustando http-stream-idle-timeout de ${actual:-?} a $IDLE_ENVOY"
    cilium config set http-stream-idle-timeout "$IDLE_ENVOY"
  fi
fi

log "Esperando a que Cilium este listo (puede tardar unos minutos)"
cilium status --wait

log "Cluster listo"
kubectl get nodes
echo ""
echo "Siguientes pasos:"
echo "  ./tetragon-up.sh    control de kernel (el SIGKILL del segmento 6)"
echo "  ./vllm-up.sh        el modelo en la GPU (el segmento 1)"
