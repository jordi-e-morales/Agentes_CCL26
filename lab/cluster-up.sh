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

# LA VERSION DE CILIUM, FIJA.
#
# `cilium install` sin --version instala lo que la CLI traiga por default ese
# dia. Eso convierte a este script en algo que da un cluster distinto cada
# semana, y el §8 pide lo contrario: que migrar sea `git clone && bootstrap`.
#
# 1.20.1 es la que esta verificada funcionando aqui el 2026-09-23, con toda la
# cadena encima: politicas L7, Hubble, el 403 y el SIGKILL.
#
# Esta version tambien es la que fija el relay de Hubble, y por tanto el
# desajuste con la CLI (que va por la 1.19.4, la ultima que existe). Si ese
# desajuste alguna vez rompe de verdad, la salida es bajar ESTE numero a la
# linea 1.19 — no subir la CLI, porque no hay a donde.
CILIUM_VER=1.20.1

log "Instalando Cilium $CILIUM_VER como red del cluster"
# kubeProxyReplacement=true: Cilium reemplaza a kube-proxy usando eBPF.
# hubble: es el sistema de observabilidad. Sin esto no puedes VER el trafico,
#         y ver el trafico es la mitad de la demo.
# envoy.streamIdleTimeoutDurationSeconds: cuando haya politicas L7, el trafico
#         HTTP entre agentes pasa por Envoy, que corta una peticion tras 300 s
#         sin actividad. En CPU un agente tarda hasta ~6 min en responder sin
#         mandar un byte (medido: 345 s el Arbitro), asi que se sube a 30 min.
#         En GPU sobra, pero no estorba.
IDLE_ENVOY=1800
# hubble.eventBufferCapacity: cuanta HISTORIA de trafico guarda cada nodo.
#
#         El default son 4095 flujos por nodo. Medido el 2026-09-23 en este
#         cluster: 50 flujos/s y el buffer al 100%, o sea ~164 segundos de
#         historia antes de que empiece a tirar lo viejo.
#
#         Eso alcanza para la deliberacion (~41 s) pero NO para narrarla
#         despues: a los tres minutos los flujos que quieres enseñar ya no
#         existen. Y una demo en la que el panel se vacia solo mientras hablas
#         es peor que no tenerlo.
#
#         65535 da mas de 20 minutos al mismo ritmo. Son flujos en memoria del
#         agente, unas decenas de MB: barato comparado con perder el segmento.
#
#         El valor TIENE que ser una potencia de dos menos uno. Cilium rechaza
#         cualquier otro, y el error no dice por que.
BUFFER_HUBBLE=65535
if ! cilium status >/dev/null 2>&1; then
  cilium install \
    --version "$CILIUM_VER" \
    --set kubeProxyReplacement=true \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --set hubble.eventBufferCapacity=$BUFFER_HUBBLE \
    --set envoy.streamIdleTimeoutDurationSeconds=$IDLE_ENVOY
else
  instalado=$(cilium version --client=false 2>/dev/null \
    | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
  echo "Cilium ya estaba instalado (${instalado:-version desconocida})"
  if [ -n "$instalado" ] && [ "$instalado" != "$CILIUM_VER" ]; then
    echo "  OJO: este script fija $CILIUM_VER. No se reinstala sobre un"
    echo "       cluster vivo. Para igualar hay que recrearlo:"
    echo "         kind delete cluster --name agentes && ./lab/cluster-up.sh"
  fi
  # Clusters creados antes de este ajuste: aplicarlo sin reinstalar.
  # `cilium config set` cambia el ConfigMap y reinicia los pods de Cilium.
  actual=$(kubectl -n kube-system get configmap cilium-config \
    -o jsonpath='{.data.http-stream-idle-timeout}')
  if [ "$actual" != "$IDLE_ENVOY" ]; then
    echo "Ajustando http-stream-idle-timeout de ${actual:-?} a $IDLE_ENVOY"
    cilium config set http-stream-idle-timeout "$IDLE_ENVOY"
  fi
  # Lo mismo para el buffer de Hubble, en clusters creados antes de fijarlo.
  #
  # Va con `|| true` y comprobando que la clave exista: este script es camino
  # critico y no puede caerse por un ajuste de observabilidad. Si el nombre de
  # la clave cambia en una version futura de Cilium, se avisa y se sigue.
  buf=$(kubectl -n kube-system get configmap cilium-config \
    -o jsonpath='{.data.hubble-event-buffer-capacity}' 2>/dev/null || true)
  if [ -z "$buf" ]; then
    echo "  (no encuentro hubble-event-buffer-capacity; se queda el default)"
  elif [ "$buf" != "$BUFFER_HUBBLE" ]; then
    echo "Ajustando hubble-event-buffer-capacity de $buf a $BUFFER_HUBBLE"
    cilium config set hubble-event-buffer-capacity "$BUFFER_HUBBLE" || \
      echo "  (no se pudo; se queda en $buf)"
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
