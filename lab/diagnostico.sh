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
#
# EL -v /app/ NO ES OPCIONAL, y este script nacio sin el.
#
# Los nodos de kind son contenedores, asi que sus procesos SE VEN en la tabla de
# procesos del host. Un `pgrep -af malla/agente.py` a secas encuentra tambien a
# los agentes que corren DENTRO de los pods, y los delata como si fueran
# procesos viejos del host. La primera corrida de este script acuso a los dos
# pods que acababan de arrancar bien.
#
# La ruta es lo que los distingue: dentro del contenedor el codigo esta en
# /app/malla/agente.py; en el host es una ruta del repo. La otra pista, por si
# alguna vez hace falta a mano, es que los dos pods dicen --puerto 7010 (cada
# uno tiene su propia IP), mientras que en el host el defensor era el 7011.
viejos=$(pgrep -af "malla/agente.py" 2>/dev/null | grep -v " /app/")
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
# SOLO DOS, desde que el router es un pod.
#
# La interfaz ya no habla con los agentes: habla con el router, y el router les
# habla desde dentro del cluster. Los puentes de 7010 y 7011 sobran, y este paso
# los pedia todavia — reportando MAL algo que estaba bien.
#
# El del servidor MCP se queda solo para poder probar herramientas a mano; la
# deliberacion no lo usa.
comprobar_puente() {  # puerto  deploy  destino_en_el_pod
  if curl -s --max-time 3 -o /dev/null "http://localhost:$1/" 2>/dev/null; then
    quien=$(curl -s --max-time 3 "http://localhost:$1/salud" 2>/dev/null)
    ok "$1 responde  ${quien:-(sin /salud, normal en el MCP)}"
  else
    mal "$1 NO responde ($2)"
    nota "  kubectl -n $NS port-forward deploy/$2 $1:$3"
  fi
}
comprobar_puente 7012 router 7012
comprobar_puente 9000 servidor-mcp 9000

# Si quedan los viejos puestos no rompen nada, pero conviene saberlo: tenerlos
# invita a pensar que la interfaz les habla.
for viejo in 7010 7011; do
  if curl -s --max-time 2 -o /dev/null "http://localhost:$viejo/salud" 2>/dev/null; then
    nota "(el $viejo sigue reenviado; ya no hace falta, no estorba)"
  fi
done

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
echo "=== 5. El router alcanza las tarjetas?"
# "Ningun agente responde" es el mensaje mas engañoso del sistema: suena a que
# los agentes estan caidos, y lo que suele pasar es que falta la politica
# router-descubrimiento y la red corta el GET de la tarjeta.
for pol in agentes-salida router-descubrimiento; do
  if kubectl -n "$NS" get ciliumnetworkpolicy "$pol" >/dev/null 2>&1; then
    ok "politica $pol aplicada"
  else
    mal "politica $pol NO aplicada"
    nota "  kubectl apply -f seguridad/cilium-l7.yaml"
  fi
done
if kubectl -n "$NS" get deploy router >/dev/null 2>&1; then
  r=$(kubectl -n "$NS" exec deploy/router -- python3 -c "
import urllib.request, json
vivos = []
for n in ('investigador','defensor'):
    try:
        urllib.request.urlopen(f'http://{n}:7010/.well-known/agent-card.json', timeout=8)
        vivos.append(n)
    except Exception as e:
        vivos.append(f'{n}:{type(e).__name__}')
print(' '.join(vivos))
" 2>/dev/null | tail -1)
  case "$r" in
    "investigador defensor") ok "el router lee las dos tarjetas" ;;
    *) mal "el router no las lee todas: $r" ;;
  esac
fi

echo ""
echo "=== 6. Lo ultimo que dijo el investigador"
# Aqui se ve exactamente donde se quedo: si esta esperando al modelo, si una
# herramienta devolvio vacio, o si el salto lateral no salio.
kubectl -n "$NS" logs deploy/investigador --tail=25 2>/dev/null | sed 's/^/  /' \
  || echo "  (sin logs)"

echo ""
echo "=== 7. Flujos bloqueados, si Hubble esta a mano"
# CON LA HORA, Y NO ES UN ADORNO.
#
# El buffer de Hubble guarda ~20 minutos de historia (se subio a proposito, para
# poder narrar una corrida despues de que ocurra). El efecto secundario es que
# un bloqueo YA ARREGLADO sigue en pantalla y parece actual: paso el 2026-09-23,
# con dos DROPPED de hace seis minutos que ya no se reproducian.
#
# Por eso se imprime la hora de ahora al lado, y se acota la ventana.
if command -v hubble >/dev/null 2>&1 && hubble status >/dev/null 2>&1; then
  echo "        son las $(date +%H:%M:%S) — compara con las horas de abajo"
  caidos=$(hubble observe --namespace "$NS" --verdict DROPPED \
    --since 5m --last 8 2>/dev/null)
  if [ -n "$caidos" ]; then
    # LA MEJOR SEÑAL DE QUE UN BLOQUEO ES HISTORIA NO ES LA HORA: es que el pod
    # que aparece ya no exista.
    #
    # Cada `rollout restart` cambia el sufijo del nombre del pod. Un DROPPED que
    # menciona un pod muerto ocurrio antes de ese reinicio, y eso es un hecho, no
    # una estimacion — mientras comparar relojes obliga a recordar a que hora se
    # aplico el arreglo.
    vivos=$(kubectl -n "$NS" get pod -o name 2>/dev/null | sed 's|pod/||')
    frescos=0
    viejos=0
    while IFS= read -r linea; do
      [ -z "$linea" ] && continue
      # Los pods que menciona esta linea.
      mencionados=$(echo "$linea" | grep -oE "$NS/[a-z0-9.-]+" | sed "s|$NS/||" \
        | sed 's/:[0-9]*$//' | sort -u)
      muerto=""
      for m in $mencionados; do
        echo "$vivos" | grep -qx "$m" || muerto="si"
      done
      if [ -n "$muerto" ]; then
        echo "        $linea   <-- POD MUERTO, es historia"
        viejos=$((viejos+1))
      else
        echo "        $linea"
        frescos=$((frescos+1))
      fi
    done <<< "$caidos"
    nota ""
    if [ "$frescos" -eq 0 ]; then
      ok "los $viejos son de pods que ya no existen: nada bloqueado AHORA"
    else
      mal "$frescos de pods vivos — estos si estan pasando"
    fi
  else
    ok "nada bloqueado en los ultimos 5 minutos"
  fi
else
  nota "(hubble no esta a mano: cilium hubble port-forward &)"
fi
echo ""
