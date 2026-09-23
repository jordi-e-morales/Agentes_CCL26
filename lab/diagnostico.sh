#!/usr/bin/env bash
#
# Donde esta atorado el demo. Una sola corrida, todo lo que hace falta saber.
#
# Existe porque el sintoma mas comun de este sistema no es un error: es que algo
# se queda a medias y en pantalla no aparece nada. Preguntarse "y ahora que
# miro" cuesta mas que este script.
#
# Uso:  bash lab/diagnostico.sh

set -u
NS=agentes
ok() { echo "  ok    $1"; }
mal() { echo "  MAL   $1"; }
nota() { echo "        $1"; }

echo ""
echo "=== 1. Procesos viejos en el host"
# LA CAUSA MAS COMUN al pasar los agentes a pods. Si un `python agente.py`
# quedo vivo, ocupa el 7010 o el 7011, el port-forward no puede escuchar y la
# interfaz sigue hablando con el proceso viejo sin que nada avise.
viejos=$(pgrep -af "malla/agente.py" 2>/dev/null)
if [ -n "$viejos" ]; then
  mal "hay agentes viejos corriendo en el host:"
  echo "$viejos" | sed 's/^/        /'
  nota ""
  nota "Matalos, o la interfaz les seguira hablando a ellos:"
  nota "  pkill -f malla/agente.py"
else
  ok "sin agentes viejos en el host"
fi

echo ""
echo "=== 2. Los pods"
kubectl -n "$NS" get pod -l rol=agente \
  -o custom-columns=POD:.metadata.name,LISTO:.status.containerStatuses[0].ready,REINICIOS:.status.containerStatuses[0].restartCount,ESTADO:.status.phase \
  2>/dev/null | sed 's/^/  /'

echo ""
echo "=== 3. Los puentes que la interfaz necesita"
for par in "7010 investigador" "7011 defensor" "9000 servidor-mcp"; do
  set -- $par
  if curl -sf --max-time 3 "http://localhost:$1/salud" >/dev/null 2>&1 \
     || curl -s --max-time 3 -o /dev/null "http://localhost:$1/" 2>/dev/null; then
    quien=$(curl -s --max-time 3 "http://localhost:$1/salud" 2>/dev/null)
    ok "$1 responde  ${quien:-(sin /salud, normal en el MCP)}"
  else
    mal "$1 NO responde ($2)"
    nota "  kubectl -n $NS port-forward deploy/$2 $1:${1/9000/9000}"
  fi
done
nota ""
nota "OJO: si el 7010 responde pero NO dice version_codigo, es un agente"
nota "     viejo del host, no el pod."

echo ""
echo "=== 4. El agente alcanza sus dos dependencias?"
# Esto es lo que distingue "atorado en el paso 3" de "no arranco": el paso 3
# despacha al investigador, que necesita el modelo Y las herramientas.
for destino in "http://vllm:8000/v1/models modelo" "http://servidor-mcp:9000/mcp herramientas"; do
  set -- $destino
  r=$(kubectl -n "$NS" exec deploy/investigador -- python3 -c "
import urllib.request
try:
    urllib.request.urlopen('$1', timeout=8)
    print('ok')
except urllib.error.HTTPError as e:
    print('ok')          # responde, aunque sea 405/406: hay conexion
except Exception as e:
    print(type(e).__name__)
" 2>/dev/null | tail -1)
  if [ "$r" = "ok" ]; then ok "el pod alcanza el $2"
  else
    mal "el pod NO alcanza el $2 ($r)"
    [ "$2" = "modelo" ] && nota "  ./lab/publica-vllm.sh"
    [ "$2" = "herramientas" ] && nota "  ./herramientas/servidor-up.sh"
  fi
done

echo ""
echo "=== 5. Lo ultimo que dijo el investigador"
# Aqui se ve exactamente donde se quedo: si esta esperando al modelo, si una
# herramienta devolvio vacio, o si el salto lateral no salio.
kubectl -n "$NS" logs deploy/investigador --tail=25 2>/dev/null | sed 's/^/  /' \
  || echo "  (sin logs)"

echo ""
echo "=== 6. Flujos bloqueados, si Hubble esta a mano"
if command -v hubble >/dev/null 2>&1 && hubble status >/dev/null 2>&1; then
  caidos=$(hubble observe --namespace "$NS" --verdict DROPPED --last 8 2>/dev/null)
  if [ -n "$caidos" ]; then
    mal "la red corto estos:"
    echo "$caidos" | sed 's/^/        /'
  else
    ok "nada bloqueado por la red"
  fi
else
  nota "(hubble no esta a mano: cilium hubble port-forward &)"
fi
echo ""
