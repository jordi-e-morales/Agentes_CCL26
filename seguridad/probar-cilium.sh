#!/usr/bin/env bash
#
# LO QUE CILIUM HACE, DESDE EL AGENTE DE VERDAD.
#
# Antes esto solo se podia enseñar con el pod sustituto `agente-demo`, porque los
# agentes corrian en el host y su trafico no atravesaba el cluster. Desde el
# 2026-09-23 son pods, asi que el cliente de estas pruebas es el INVESTIGADOR —
# el mismo proceso que delibera. No hay nada que etiquetar como sustituto.
#
# Cuatro intentos, en orden de menos a mas incomodo:
#
#   1. La arista autorizada         POST /mcp          pasa
#   2. Otra ruta en el mismo pod    POST /dispone_caso 403 preciso
#   3. La base de datos, directo    postgres:5432      DROPPED
#   4. Cualquier cosa fuera         internet           DROPPED
#
# El 3 es el que vale doble: Cilium lo corta Y la aplicacion no emite ningun
# span sobre el. Es la unica forma de enseñar una AUSENCIA (CLAUDE.md §5).
#
# Uso:  bash seguridad/probar-cilium.sh

set -uo pipefail
NS=agentes
CLIENTE=deploy/investigador

titulo() { echo ""; echo "=== $1"; }
sub() { echo "    $1"; }

# Se pide desde dentro del pod con urllib: el agente no trae curl, y ademas un
# `exec` de binario lo mataria la TracingPolicy de Tetragon que gobierna a los
# agentes. Que la prueba tenga que respetar eso es, en si mismo, parte del demo.
pedir() {  # metodo  url
  kubectl -n "$NS" exec "$CLIENTE" -- python3 -c "
import urllib.request, json, socket
req = urllib.request.Request('$2', method='$1')
req.add_header('Content-Type','application/json')
req.add_header('Accept','application/json, text/event-stream')
try:
    r = urllib.request.urlopen(req, data=b'{}' if '$1'=='POST' else None, timeout=8)
    print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:
    print(type(e).__name__)
" 2>/dev/null | tail -1
}

kubectl -n "$NS" get "$CLIENTE" >/dev/null 2>&1 || {
  echo "Falta el investigador. Corre ./malla/agentes-up.sh"; exit 1; }
kubectl -n "$NS" get ciliumnetworkpolicy agentes-salida >/dev/null 2>&1 || {
  echo "Falta la politica. Corre: kubectl apply -f seguridad/cilium-l7.yaml"; exit 1; }

DESDE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 1

titulo "1. La arista autorizada:  POST /mcp"
r=$(pedir POST "http://servidor-mcp:9000/mcp")
sub "-> $r"
sub "Cualquier cosa que no sea 403 significa que la peticion LLEGO al servidor."
sub "Es la arista que el agente usa para todo su trabajo."

titulo "2. Otra ruta en el MISMO pod:  POST /dispone_caso"
r=$(pedir POST "http://servidor-mcp:9000/dispone_caso")
sub "-> $r"
if [ "$r" = "403" ]; then
  sub "403. Y fijate en donde se decidio: el servidor NUNCA vio esta peticion."
  sub "La corto Cilium, en el kernel, mirando el metodo y la ruta."
else
  sub "Se esperaba 403. Si no lo es, la politica no esta haciendo L7."
fi
sub ""
sub "HONESTIDAD: esta ruta no existe en el servidor, asi que tampoco habria"
sub "funcionado sin politica. Lo que prueba es que Cilium DISTINGUE rutas, no"
sub "que impida algo que de otro modo pasaria. Para eso hacen falta las tools"
sub "expuestas por HTTP normal — ver el final de este script."

titulo "3. La base de datos, directo:  postgres:5432"
r=$(kubectl -n "$NS" exec "$CLIENTE" -- python3 -c "
import socket
s = socket.socket(); s.settimeout(6)
try:
    s.connect(('postgres.agentes.svc.cluster.local', 5432)); print('CONECTO')
except Exception as e: print(type(e).__name__)
" 2>/dev/null | tail -1)
sub "-> $r"
sub "No hay ninguna regla agente -> postgres. Esa omision ES la politica."
sub "El agente tiene que pasar por la herramienta, que si puede."

titulo "4. Cualquier cosa fuera del cluster"
r=$(pedir GET "http://example.com/")
sub "-> $r"
sub "El agente no tiene salida a internet. Si la inyeccion le pidiera traerse"
sub "un 'procedimiento' de una URL externa, moriria aqui."

titulo "Lo que la RED vio, que es la prueba"
if command -v hubble >/dev/null 2>&1 && hubble status >/dev/null 2>&1; then
  hubble observe --namespace "$NS" --from-label app=investigador \
    --since "$DESDE" --last 20 2>/dev/null | sed 's/^/    /'
  echo ""
  sub "Las lineas con DROPPED son las que Cilium corto. Fijate que la ruta"
  sub "aparece en las de capa 7: eso es politica sobre la INTENCION, no sobre"
  sub "el par origen-destino."
else
  sub "(hubble no esta a mano: cilium hubble port-forward &)"
fi

titulo "Lo que ESTO todavia no demuestra"
sub "El paso 2 corta una ruta que el servidor no sirve. Para la lamina completa"
sub "del §6 hacen falta las seis tools expuestas TAMBIEN por HTTP normal, una"
sub "ruta cada una. Entonces se puede enseñar el contraste de verdad:"
sub ""
sub "  por HTTP:  /consulta_historial pasa, /dispone_caso 403   <- Cilium acierta"
sub "  por MCP:   las dos son POST /mcp, las dos pasan          <- Cilium ciego"
sub ""
sub "Ese es el argumento de que ni la capa 7 basta cuando el protocolo"
sub "multiplexa, y hoy solo esta contado a medias."
echo ""
