#!/usr/bin/env bash
#
# Repara el cluster kind cuando queda "colgado" tras reiniciar la laptop/VM.
#
# Síntoma: los pods quedan en Unknown o ContainerCreating y no se recuperan;
# los eventos muestran "unable to connect to Cilium agent" o el init de Cilium
# reinicia con "connection refused" al apiserver.
#
# Causa: al reiniciarse los contenedores de los nodos de kind, Docker puede
# INTERCAMBIAR sus IPs. Cilium tiene la IP del apiserver fija en una variable
# de entorno (KUBERNETES_SERVICE_HOST); si el control-plane cambió de IP,
# Cilium ya no lo encuentra y sin Cilium no hay red para ningún pod.
#
# Esto detecta la IP real del control-plane, corrige Cilium si hace falta, y
# fuerza la recreación de los pods colgados. Idempotente.
#
# Uso (dentro de la VM):  bash ~/demo/lab/reparar-cluster.sh

set -uo pipefail
log() { echo ""; echo "=== $1"; }

log "IP actual del control-plane"
CP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' agentes-control-plane)
echo "control-plane = $CP"
[ -z "$CP" ] && { echo "No pude leer la IP; ¿está corriendo el contenedor agentes-control-plane?"; exit 1; }

log "Esperando a que el apiserver responda"
for i in $(seq 1 30); do kubectl get --raw=/healthz >/dev/null 2>&1 && { echo "apiserver OK"; break; }; sleep 5; done

log "Revisando la IP del apiserver que usa Cilium"
ACTUAL=$(kubectl -n kube-system get ds cilium \
  -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}' \
  | awk -F= '/^KUBERNETES_SERVICE_HOST=/{print $2}')
echo "Cilium apunta a: ${ACTUAL:-<vacío>}"
if [ "$ACTUAL" != "$CP" ]; then
  echo "No coincide con $CP: corrigiendo Cilium"
  kubectl -n kube-system set env ds/cilium KUBERNETES_SERVICE_HOST="$CP"
  kubectl -n kube-system set env deploy/cilium-operator KUBERNETES_SERVICE_HOST="$CP" 2>/dev/null || true
  kubectl -n kube-system rollout restart ds/cilium
else
  echo "Coincide; no toco Cilium"
fi

log "Esperando a Cilium"
kubectl -n kube-system rollout status ds/cilium --timeout=300s

log "Forzando la recreación de pods colgados (Unknown)"
for ns in kube-system agentes; do
  kubectl -n "$ns" get pods --no-headers 2>/dev/null \
    | awk '$3=="Unknown"{print $1}' \
    | xargs -r kubectl -n "$ns" delete pod --force --grace-period=0 2>/dev/null
done
# Los que sigan atascados en ContainerCreating por el sandbox viejo:
kubectl -n agentes delete pods --field-selector=status.phase!=Running,status.phase!=Succeeded \
  --force --grace-period=0 2>/dev/null || true

log "Estado final (espera a que todo quede Running)"
kubectl -n agentes get pods
echo ""
echo "Si algún pod sigue en ContainerCreating, dale un minuto y vuelve a correr esto."
echo "Recuerda relanzar los port-forward: la IP de la VM también pudo cambiar."
