#!/usr/bin/env bash
#
# Instala Tetragon en el cluster: el control de KERNEL del Demo 2.
#
# Que es: un DaemonSet (un pod por nodo) que usa eBPF para observar procesos,
# archivos y red desde el kernel. Con una TracingPolicy puede ademas ACTUAR:
# matar con SIGKILL un proceso que intenta algo prohibido, antes de que lo haga.
# Eso es lo que el Demo 2 muestra cuando el agente comprometido intenta ejecutar
# un binario. Necesita BTF en el kernel (lo verifica bootstrap.sh).
#
# Version fija: el dia del evento debe correr lo mismo que se ensayo.
# Idempotente: si ya esta instalado con esta version, no hace nada.
#
# Uso:  ./tetragon-up.sh

set -euo pipefail

TETRAGON_VER=1.7.1
NS=kube-system

log() { echo ""; echo "=== $1"; }

command -v helm >/dev/null || { echo "Falta helm: corre ./bootstrap.sh"; exit 1; }

log "Repositorio de charts de Cilium"
helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm repo update cilium

# `helm upgrade --install` es idempotente: instala si no existe y, si existe,
# aplica los valores de abajo (sin reinstalar si nada cambio).
log "Instalando o actualizando Tetragon $TETRAGON_VER"
# export.mode="": sin el contenedor que copia eventos a stdout (otra imagen
#   mas, hubble-export-stdout, que no usamos).
# tetragon.exportFilePerm=644: Tetragon escribe los eventos en
#   /var/run/cilium/tetragon/tetragon.log del nodo. Por omision solo root lo
#   lee (600); con 644 el observador lo lee montandolo en solo lectura y SIN
#   correr como root. Contiene eventos de procesos de los pods (no secretos).
#   OJO: el permiso solo se aplica al CREAR el archivo; uno que ya existia se
#   queda en 600. Por eso el nombre es eventos.log (y no tetragon.log, que se
#   crea con 600 en la primera instalacion).
# Recursos modestos: heredados de la VM chica donde se probo esto. En el host
# con L40S sobra memoria, asi que se pueden subir si Tetragon se queda corto,
# pero estos valores ya se ensayaron y funcionan. No los toco sin motivo.
helm upgrade --install tetragon cilium/tetragon \
  --version "$TETRAGON_VER" \
  --namespace "$NS" \
  --set export.mode="" \
  --set tetragon.exportFilePerm=644 \
  --set tetragon.exportFilename=eventos.log \
  --set tetragon.resources.requests.memory=128Mi \
  --set tetragon.resources.limits.memory=512Mi \
  --wait --timeout 10m

log "Esperando a que el DaemonSet este listo"
kubectl -n "$NS" rollout status ds/tetragon --timeout=300s

log "Tetragon listo"
kubectl -n "$NS" get pods -l app.kubernetes.io/name=tetragon -o wide
echo ""
echo "Ver eventos del kernel en vivo:"
echo "  kubectl -n $NS exec ds/tetragon -c tetragon -- tetra getevents -o compact"
