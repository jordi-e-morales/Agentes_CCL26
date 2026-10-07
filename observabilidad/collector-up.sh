#!/usr/bin/env bash
#
# Levanta el Collector de OpenTelemetry y dice como apuntarle el agente.
#
# Uso:
#   ./observabilidad/collector-up.sh
#   ./observabilidad/collector-up.sh --trazas   sigue las trazas en vivo
#   ./observabilidad/collector-up.sh --down

set -euo pipefail
NS=agentes
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo ""; echo "=== $1"; }

case "${1:-}" in
  --down)
    kubectl -n "$NS" delete -f "$DIR/00-collector.yaml" --ignore-not-found
    echo "Collector eliminado"; exit 0 ;;
  --trazas)
    # El plan de respaldo en accion: las trazas completas, sin Splunk.
    exec kubectl -n "$NS" logs -f deploy/otel-collector ;;
esac

kubectl get nodes >/dev/null 2>&1 || { echo "El cluster no responde: corre ./lab/cluster-up.sh"; exit 1; }
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

log "Aplicando el Collector"
kubectl apply -f "$DIR/00-collector.yaml" >/dev/null

# ESTE APPLY SE LLEVA A SPLUNK POR DELANTE.
#
# El manifiesto trae el ConfigMap con el exportador de Splunk COMENTADO, asi
# que aplicarlo devuelve la configuracion a la plantilla. Si Splunk estaba
# puesto, deja de recibir y nada lo dice: las trazas siguen saliendo al archivo
# y a los logs, asi que todo parece normal.
#
# Si hay destino apuntado y token guardado, se vuelve a poner solo.
DESTINO="$DIR/.splunk-destino"
if [ -f "$DESTINO" ] && kubectl -n "$NS" get secret splunk >/dev/null 2>&1; then
  echo ""
  echo "  Splunk estaba configurado. Volviendo a ponerlo."
  "$DIR/splunk-up.sh" "$(cat "$DESTINO")" --reusar-token
elif [ -f "$DESTINO" ]; then
  echo ""
  echo "  AVISO: habia un destino de Splunk apuntado pero no esta el Secret."
  echo "  Para volver a ponerlo:  ./observabilidad/splunk-up.sh $(cat "$DESTINO")"
fi
kubectl -n "$NS" rollout status deploy/otel-collector --timeout=120s

log "Como apuntarle el agente"
echo "  Desde un pod del cluster:"
echo "    OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.agentes.svc.cluster.local:4318"
echo ""
echo "  Desde el host (hace falta el port-forward en otra terminal):"
echo "    kubectl -n $NS port-forward deploy/otel-collector 4318:4318"
echo "    OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 \\"
echo "      .venv/bin/python spike-mcp/agente.py"
echo ""
echo "  Ver las trazas SIN Splunk (el plan de respaldo):"
echo "    ./observabilidad/collector-up.sh --trazas"
