#!/usr/bin/env bash
#
# Manda las trazas a Splunk Observability Cloud.
#
# NO ROMPE NADA SI FALLA, Y ESO ES DELIBERADO.
# El exportador `file` se queda puesto, asi que la cascada del segmento 5 se
# sigue dibujando sin internet y sin credenciales. Splunk es la validacion
# externa, no el unico sitio donde mirar (§9).
#
# Uso:
#   ./observabilidad/splunk-up.sh us1        <- tu realm
#   ./observabilidad/splunk-up.sh --down     <- lo quita y deja todo como estaba
#
# El token se pide por teclado y no se escribe en disco ni en el historial.

set -uo pipefail
NS=agentes
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFIESTO="$DIR/00-collector.yaml"
log() { echo ""; echo "=== $1"; }

if [ "${1:-}" = "--down" ]; then
  log "Quitando Splunk"
  kubectl -n "$NS" apply -f "$MANIFIESTO" >/dev/null
  kubectl -n "$NS" delete secret splunk --ignore-not-found >/dev/null
  kubectl -n "$NS" rollout status deploy/otel-collector --timeout=120s
  echo "  El Collector vuelve a exportar solo a debug y file."
  exit 0
fi

REALM="${1:-}"
if [ -z "$REALM" ]; then
  echo "Falta el realm. Es el que sale en la URL de tu Splunk Observability:"
  echo "    https://app.us1.signalfx.com  ->  el realm es  us1"
  echo ""
  echo "  ./observabilidad/splunk-up.sh us1"
  exit 1
fi

kubectl get nodes >/dev/null 2>&1 || {
  echo "El cluster no responde: corre ./lab/cluster-up.sh"; exit 1; }

# El token por teclado. -s para que no se vea, y no toca el historial ni un
# archivo. Si algun dia hay que automatizarlo, que venga por variable de
# entorno, nunca por argumento: los argumentos se ven en `ps`.
if [ -z "${SPLUNK_TOKEN:-}" ]; then
  echo ""
  read -rsp "Token de ingesta de Splunk (no se mostrara): " SPLUNK_TOKEN
  echo ""
fi
[ -z "$SPLUNK_TOKEN" ] && { echo "Sin token no hay nada que hacer."; exit 1; }

INGESTA="https://ingest.${REALM}.signalfx.com"

log "Comprobando que el CLUSTER alcanza $INGESTA"
# Desde un POD, no desde el host. Es la misma trampa que con vLLM: el host casi
# siempre llega, y quien tiene que llegar es el Collector.
alcance=$(kubectl -n "$NS" exec deploy/otel-collector -c lector -- \
  sh -c "wget -q -T 8 -O /dev/null --spider '$INGESTA' 2>&1; echo \$?" 2>/dev/null | tail -1)
if [ "$alcance" = "0" ]; then
  echo "  ok  el cluster sale a internet y resuelve el realm"
else
  echo "  AVISO: el pod no alcanzo $INGESTA"
  echo "  Puede ser la red del sitio, el DNS, o un proxy. Se continua igual:"
  echo "  la configuracion queda puesta y empezara a exportar en cuanto haya red."
fi

log "Guardando el token como Secret"
kubectl -n "$NS" delete secret splunk --ignore-not-found >/dev/null 2>&1
kubectl -n "$NS" create secret generic splunk \
  --from-literal=SPLUNK_ACCESS_TOKEN="$SPLUNK_TOKEN" >/dev/null
echo "  ok  secret/splunk  (no queda en el repo)"

log "Añadiendo el exportador al Collector"
# Se edita el manifiesto EN MEMORIA y se aplica; el archivo del repo no se toca,
# asi que no hay riesgo de commitear una configuracion con el realm de alguien.
TMP="$(mktemp)"
python3 - "$MANIFIESTO" "$REALM" > "$TMP" <<'PY'
import io, sys
manif, realm = sys.argv[1], sys.argv[2]
s = io.open(manif, encoding="utf-8").read()

# 1. Descomentar el bloque del exportador, con el realm sustituido.
viejo = """      # Splunk Observability Cloud (necesita internet y un token de ingesta):
      # otlphttp/splunk:
      #   traces_endpoint: https://ingest.<REALM>.signalfx.com/v2/trace/otlp
      #   headers:
      #     X-SF-Token: ${env:SPLUNK_ACCESS_TOKEN}"""
nuevo = f"""      # Splunk Observability Cloud. Lo pone observabilidad/splunk-up.sh.
      otlphttp/splunk:
        traces_endpoint: https://ingest.{realm}.signalfx.com/v2/trace/otlp
        headers:
          X-SF-Token: ${{env:SPLUNK_ACCESS_TOKEN}}"""
if viejo not in s:
    sys.exit("no encuentro el bloque de Splunk en el manifiesto")
s = s.replace(viejo, nuevo)

# 2. Meterlo al pipeline. SE OLVIDA SIEMPRE: un exportador definido y no
#    enchufado no exporta nada, y no da ningun error.
viejo = "          exporters: [debug, file]"
if viejo not in s:
    sys.exit("no encuentro el pipeline de trazas")
s = s.replace(viejo, "          exporters: [debug, file, otlphttp/splunk]")
sys.stdout.write(s)
PY
if [ $? -ne 0 ]; then echo "  FALLO al preparar la configuracion"; rm -f "$TMP"; exit 1; fi

kubectl apply -f "$TMP" >/dev/null && echo "  ok  configuracion aplicada"
rm -f "$TMP"

log "Dandole el token al Collector"
kubectl -n "$NS" set env deploy/otel-collector -c collector \
  --from=secret/splunk >/dev/null && echo "  ok"

kubectl -n "$NS" rollout status deploy/otel-collector --timeout=120s

log "Que dice el Collector al arrancar"
sleep 3
kubectl -n "$NS" logs deploy/otel-collector -c collector --tail=25 2>/dev/null \
  | grep -iE "error|splunk|otlphttp|exporter|started" | tail -8 | sed 's/^/  /'

log "Como comprobarlo de verdad"
echo ""
echo "  1. Lanza una deliberacion en la interfaz."
echo "  2. En Splunk, APM -> Traces. Busca los servicios:"
echo "       orquestador   agente-investigador   agente-defensor"
echo ""
echo "  Los spans llevan los atributos gen_ai.*, asi que Splunk deberia"
echo "  reconocerlos como de GenAI sin configurar nada."
echo ""
echo "  Si no aparece nada, mira si el Collector se queja:"
echo "     kubectl -n $NS logs deploy/otel-collector -c collector | grep -i error"
echo ""
echo "  Y recuerda: la cascada del segmento 5 NO depende de esto."
echo "  Sigue saliendo del archivo, sin internet."
