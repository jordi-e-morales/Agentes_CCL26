#!/usr/bin/env bash
#
# Es el token, o es como se lo pasamos?
#
# Habla con Splunk DIRECTAMENTE, sin Collector de por medio. Asi se separan dos
# cosas que dan el mismo 401:
#
#   a) el token no vale para ingesta
#   b) el token vale, pero al Collector le llega mal
#
# La (b) es mas comun de lo que parece: si `${env:SPLUNK_ACCESS_TOKEN}` no se
# expande, el Collector manda esa cadena LITERAL como token, y Splunk contesta
# exactamente el mismo 401.
#
# Uso:
#   bash observabilidad/splunk-probar-token.sh https://ingest.us1.observability.splunkcloud.com

set -uo pipefail
NS=agentes
INGESTA="${1:-}"
[ -z "$INGESTA" ] && { echo "Falta el endpoint de ingesta."; exit 1; }
INGESTA="${INGESTA%/}"

echo ""
echo "=== 1. Que token tiene el Collector AHORA MISMO"
# Se lee del Secret, que es lo que de verdad se le esta dando.
TOKEN=$(kubectl -n "$NS" get secret splunk \
  -o jsonpath='{.data.SPLUNK_ACCESS_TOKEN}' 2>/dev/null | base64 -d 2>/dev/null)
if [ -z "$TOKEN" ]; then
  echo "  MAL   no hay secret/splunk. Corre ./observabilidad/splunk-up.sh"
  exit 1
fi
echo "  longitud: ${#TOKEN} caracteres"
echo "  empieza por: ${TOKEN:0:4}…   termina en: …${TOKEN: -4}"
# Un token con espacios dentro casi seguro se pego mal.
case "$TOKEN" in
  *\ *|*$'\n'*) echo "  MAL   tiene espacios o saltos de linea DENTRO" ;;
  *) echo "  ok    sin espacios raros" ;;
esac

echo ""
echo "=== 2. Splunk acepta ese token?"
# Se manda un cuerpo vacio a proposito. Si la autenticacion pasa, Splunk se
# queja del CUERPO (400, 415...). Si no pasa, contesta 401. Esa diferencia es
# justo lo que queremos saber, y no envia ningun dato de verdad.
codigo=$(curl -s -o /tmp/splunk-resp.txt -w "%{http_code}" \
  --max-time 15 \
  -X POST "$INGESTA/v2/trace/otlp" \
  -H "X-SF-Token: $TOKEN" \
  -H "Content-Type: application/x-protobuf" \
  --data-binary '' 2>/dev/null)

echo "  HTTP $codigo"
[ -s /tmp/splunk-resp.txt ] && sed 's/^/        /' /tmp/splunk-resp.txt | head -5
rm -f /tmp/splunk-resp.txt

echo ""
case "$codigo" in
  401|403)
    echo "  EL TOKEN NO VALE PARA INGESTA."
    echo ""
    echo "  En Splunk: Settings -> Access Tokens. Mira la columna de alcances"
    echo "  (Authorization Scopes) del token que estas usando: tiene que incluir"
    echo "  INGEST. Un token que solo tenga API da este mismo 401."
    echo ""
    echo "  Comprueba tambien que el token sea de ESTA organizacion: uno de otra"
    echo "  cuenta tambien da 401 aunque tenga INGEST."
    ;;
  400|415|422)
    echo "  EL TOKEN VALE. Splunk se quejo del cuerpo vacio, que es lo esperado:"
    echo "  quiere decir que la autenticacion paso."
    echo ""
    echo "  Entonces el 401 del Collector viene de como le llega el token, no del"
    echo "  token. Lo mas probable: \\${env:SPLUNK_ACCESS_TOKEN} no se esta"
    echo "  expandiendo y manda esa cadena literal. Se comprueba asi:"
    echo "     kubectl -n $NS logs deploy/otel-collector -c collector | grep -i 'env'"
    ;;
  404)
    echo "  LA RUTA NO ES ESA. El token puede estar bien."
    echo "  Comprueba en la documentacion de tu Splunk cual es la ruta OTLP de"
    echo "  trazas para $INGESTA"
    ;;
  000)
    echo "  NO HUBO RESPUESTA. Desde ESTE host no se alcanza el endpoint."
    echo "  Ojo: el Collector corre en el cluster, no aqui, asi que esto no"
    echo "  significa que el Collector tampoco llegue."
    ;;
  *)
    echo "  Respuesta inesperada. Lo que importa es que NO sea 401:"
    echo "  cualquier otra cosa quiere decir que la autenticacion paso."
    ;;
esac
echo ""
