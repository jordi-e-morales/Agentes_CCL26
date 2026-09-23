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
#   ./observabilidad/splunk-up.sh https://ingest.us1.observability.splunkcloud.com
#   ./observabilidad/splunk-up.sh --down     <- lo quita y deja todo como estaba
#
# EL ENDPOINT SE PASA ENTERO, NO SE DEDUCE DEL REALM.
# Hay dos dominios en circulacion y no se puede adivinar cual te toca:
#
#   ingest.<realm>.signalfx.com                      (organizaciones antiguas)
#   ingest.<realm>.observability.splunkcloud.com     (las nuevas)
#
# El tuyo esta escrito en tu pagina de perfil de Splunk, como "Real-time Data
# Ingest Endpoint". Copialo de ahi. La regla de honestidad del §6 dice que no
# inventemos endpoints, y este script no lo hace.
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

INGESTA="${1:-}"
if [ -z "$INGESTA" ]; then
  echo "Falta el endpoint de ingesta."
  echo ""
  echo "Esta en tu pagina de perfil de Splunk Observability, como"
  echo "\"Real-time Data Ingest Endpoint\". Algo asi:"
  echo "    https://ingest.us1.observability.splunkcloud.com"
  echo ""
  echo "  ./observabilidad/splunk-up.sh https://ingest.us1.observability.splunkcloud.com"
  exit 1
fi
case "$INGESTA" in
  http://*|https://*) ;;
  *)
    echo "Eso parece un realm, no un endpoint."
    echo ""
    echo "Hay dos dominios en circulacion y este script no adivina cual es el"
    echo "tuyo. Copia el \"Real-time Data Ingest Endpoint\" de tu perfil:"
    echo "    https://ingest.$INGESTA.observability.splunkcloud.com   (nuevas)"
    echo "    https://ingest.$INGESTA.signalfx.com                    (antiguas)"
    exit 1 ;;
esac
# Sin barra final: luego se le pega la ruta.
INGESTA="${INGESTA%/}"
TRAZAS_URL="$INGESTA/v2/trace/otlp"

kubectl get nodes >/dev/null 2>&1 || {
  echo "El cluster no responde: corre ./lab/cluster-up.sh"; exit 1; }

# El token por teclado. -s para que no se vea, y no toca el historial ni un
# archivo. Si algun dia hay que automatizarlo, que venga por variable de
# entorno, nunca por argumento: los argumentos se ven en `ps`.
if [ -z "${SPLUNK_TOKEN:-}" ]; then
  echo ""
  echo "Necesitas un token con alcance INGEST (Settings -> Access Tokens)."
  echo "El de API NO sirve para enviar trazas: da 401."
  read -rsp "Token de ingesta (no se mostrara): " SPLUNK_TOKEN
  echo ""
fi
# Se quitan espacios y saltos de linea de los extremos.
#
# Copiar un token de una pagina web se lleva de propina un espacio o un \n mas
# veces de las que parece, y el sintoma es un 401 identico al de un token
# equivocado: horas persiguiendo permisos cuando sobraba un caracter.
SPLUNK_TOKEN="$(printf '%s' "$SPLUNK_TOKEN" | tr -d '[:space:]')"
[ -z "$SPLUNK_TOKEN" ] && { echo "Sin token no hay nada que hacer."; exit 1; }

# Un token de ingesta de Splunk es un UUID. Si lo que pegaste es mucho mas
# largo, casi seguro es un token de API o de sesion, que dan 401 en ingesta.
if [ "${#SPLUNK_TOKEN}" -gt 60 ]; then
  echo ""
  echo "  AVISO: ese token tiene ${#SPLUNK_TOKEN} caracteres, y los de ingesta"
  echo "  suelen ser bastante mas cortos. Comprueba en Settings -> Access Tokens"
  echo "  que el que usas tenga el alcance INGEST y no solo API."
  echo ""
fi

log "Comprobando que el CLUSTER alcanza Splunk"
# Desde un POD, no desde el host. Es la misma trampa que con vLLM: el host casi
# siempre llega, y quien tiene que llegar es el Collector.
#
# SE COMPRUEBAN DNS Y TCP, NO HTTPS.
# La primera version usaba `wget --spider` de busybox y daba falsas alarmas: el
# TLS de busybox es limitado y falla contra endpoints modernos aunque la
# conectividad sea perfecta. Lo que hay que saber es si el nombre resuelve y si
# el 443 acepta conexiones; del TLS ya se encarga el Collector, que lleva su
# propia pila.
HOST=$(echo "$INGESTA" | sed -E 's#^https?://##; s#/.*##')
resuelve=$(kubectl -n "$NS" exec deploy/otel-collector -c lector -- \
  sh -c "nslookup $HOST >/dev/null 2>&1 && echo si || echo no" 2>/dev/null | tail -1)
abierto=$(kubectl -n "$NS" exec deploy/otel-collector -c lector -- \
  sh -c "nc -z -w 6 $HOST 443 >/dev/null 2>&1 && echo si || echo no" 2>/dev/null | tail -1)

if [ "$resuelve" = "si" ] && [ "$abierto" = "si" ]; then
  echo "  ok  $HOST resuelve y el 443 responde"
else
  [ "$resuelve" != "si" ] && echo "  MAL  el DNS no resuelve $HOST"
  [ "$abierto" != "si" ]  && echo "  MAL  el 443 de $HOST no responde"
  echo ""
  echo "  Puede ser la red del sitio, un proxy, o que el cluster no salga."
  echo "  Se continua igual: la configuracion queda puesta y exportara en"
  echo "  cuanto haya red."
  echo ""
  echo "  La prueba que MANDA es el log del Collector despues de deliberar:"
  echo "    kubectl -n $NS logs deploy/otel-collector -c collector | grep -i error"
fi

log "Guardando el token como Secret"
kubectl -n "$NS" delete secret splunk --ignore-not-found >/dev/null 2>&1
kubectl -n "$NS" create secret generic splunk \
  --from-literal=SPLUNK_ACCESS_TOKEN="$SPLUNK_TOKEN" >/dev/null
echo "  ok  secret/splunk  (no queda en el repo)"

log "Añadiendo el exportador al Collector"
echo "  trazas -> $TRAZAS_URL"
# Se edita el manifiesto EN MEMORIA y se aplica; el archivo del repo no se toca,
# asi que no hay riesgo de commitear una configuracion con el realm de alguien.
TMP="$(mktemp)"
python3 - "$MANIFIESTO" "$TRAZAS_URL" > "$TMP" <<'PY'
import io, sys
manif, trazas_url = sys.argv[1], sys.argv[2]
s = io.open(manif, encoding="utf-8").read()

# 1. Descomentar el bloque del exportador, con el realm sustituido.
viejo = """      # Splunk Observability Cloud (necesita internet y un token de ingesta).
      # `otlp_http` y no `otlphttp`: el segundo es un alias deprecado y el
      # Collector 0.161 avisa de ello al arrancar. Un warning en pantalla el dia
      # del evento es ruido que hay que explicar.
      # otlp_http/splunk:
      #   traces_endpoint: https://ingest.<REALM>.signalfx.com/v2/trace/otlp
      #   headers:
      #     X-SF-Token: ${env:SPLUNK_ACCESS_TOKEN}"""
nuevo = f"""      # Splunk Observability Cloud. Lo pone observabilidad/splunk-up.sh.
      otlp_http/splunk:
        traces_endpoint: {trazas_url}
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
s = s.replace(viejo, "          exporters: [debug, file, otlp_http/splunk]")
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
  | grep -iE "error|splunk|otlp_?http|exporter|started" | tail -8 | sed 's/^/  /'

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
