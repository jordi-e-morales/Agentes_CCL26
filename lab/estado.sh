#!/usr/bin/env bash
#
# Que esta arriba y que falta. Una sola pantalla.
#
# Existe porque el demo ya son diez piezas en cuatro sitios distintos, y antes
# de una sesion en vivo nadie deberia tener que acordarse de todas. Tambien es
# lo primero que hay que correr cuando algo no funciona.
#
# No arregla nada: solo mira. Para levantar cada cosa, ver GUIA.md.
#
# Uso:  bash lab/estado.sh

set -u
NS=agentes
faltan=0

ok()    { printf "  \033[32m ok \033[0m  %s\n" "$1"; }
falta() { printf "  \033[31mFALTA\033[0m  %s\n" "$1"; [ "${2:-}" ] && printf "         %s\n" "$2"; faltan=$((faltan+1)); }
nota()  { printf "         \033[2m%s\033[0m\n" "$1"; }

titulo() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# ---------------------------------------------------------------------------
titulo "El modelo"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx vllm; then
  if curl -sf http://localhost:8000/v1/models >/dev/null 2>&1; then
    modelo=$(curl -s http://localhost:8000/v1/models | jq -r '.data[0].id' 2>/dev/null)
    ok "vLLM responde  ($modelo)"
  else
    falta "vLLM esta arrancando todavia" "docker logs -f vllm"
  fi
else
  falta "vLLM no corre" "./lab/vllm-up.sh"
fi

if [ -f lab/endpoint.env ]; then
  ok "lab/endpoint.env escrito"
else
  falta "falta lab/endpoint.env" "lo escribe ./lab/vllm-up.sh"
fi

# ---------------------------------------------------------------------------
titulo "El cluster"
if kubectl get nodes >/dev/null 2>&1; then
  ok "el cluster responde  ($(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ') nodos)"

  for d in postgres servidor-mcp otel-collector; do
    listos=$(kubectl -n "$NS" get deploy "$d" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    if [ "${listos:-0}" -ge 1 ] 2>/dev/null; then
      ok "$d"
    else
      case "$d" in
        postgres)       falta "$d" "./datos/postgres-up.sh" ;;
        servidor-mcp)   falta "$d" "./herramientas/servidor-up.sh" ;;
        otel-collector) falta "$d" "./observabilidad/collector-up.sh" ;;
      esac
    fi
  done

  if kubectl -n kube-system get ds tetragon >/dev/null 2>&1; then
    ok "Tetragon"
  else
    falta "Tetragon" "./lab/tetragon-up.sh"
  fi

  titulo "Las politicas"
  kubectl -n "$NS" get tracingpolicynamespaced herramientas-lista-blanca >/dev/null 2>&1 \
    && ok "lista blanca de kernel" \
    || falta "lista blanca de kernel" "kubectl apply -f seguridad/tetragon-herramientas-lista-blanca.yaml"
  kubectl -n "$NS" get cnp agentes-salida >/dev/null 2>&1 \
    && ok "politicas L7 de Cilium" \
    || falta "politicas L7 de Cilium" "kubectl apply -f seguridad/cilium-l7.yaml"
else
  falta "el cluster no responde" "./lab/cluster-up.sh"
fi

# ---------------------------------------------------------------------------
titulo "Las cuatro terminales"
puerto() {  # puerto  descripcion  como_levantarlo
  if (echo >/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1; then
    ok "$2"
  else
    falta "$2" "$3"
  fi
}
puerto 9000 "port-forward del MCP (:9000)" "kubectl -n $NS port-forward deploy/servidor-mcp 9000:9000"
# Los agentes no solo tienen que estar ARRIBA: tienen que estar AL DIA.
#
# "Reinicie los agentes?" ha sido la causa de varias sesiones de depuracion:
# se cambia malla/agente.py, se olvida reconstruir, y el sintoma es que algo
# nuevo "no hace nada" -indistinguible de un fallo real-.
#
# DESDE QUE SON PODS el riesgo es MAYOR, no menor, y por eso sigue aqui: antes
# bastaba con reiniciar un proceso; ahora hay que reconstruir la imagen, meterla
# a kind y reiniciar el Deployment. Tres pasos donde antes habia uno, y olvidar
# cualquiera de ellos deja el pod con el codigo viejo sin ninguna señal.
#
# Se compara la huella del archivo EN EL DISCO con la del archivo DENTRO del
# pod. Como no hay recarga en caliente, el archivo del pod es exactamente el
# codigo que corre.
pod_al_dia() {  # deployment  archivo_en_malla  descripcion
  local d="$1" f="$2" desc="$3"
  if ! kubectl -n "$NS" get deploy "$d" >/dev/null 2>&1; then
    falta "$desc: no existe el Deployment" "./malla/agentes-up.sh"; return
  fi
  local listas en_disco en_pod
  listas=$(kubectl -n "$NS" get deploy "$d" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "${listas:-0}" -lt 1 ]; then
    falta "$desc: sin replicas listas" "kubectl -n $NS rollout status deploy/$d"; return
  fi
  en_disco=$(python3 -c "import hashlib,pathlib;print(hashlib.sha256(pathlib.Path('malla/$f').read_bytes()).hexdigest()[:12])" 2>/dev/null)
  en_pod=$(kubectl -n "$NS" exec "deploy/$d" -- python -c \
    "import hashlib,pathlib;print(hashlib.sha256(pathlib.Path('/app/malla/$f').read_bytes()).hexdigest()[:12])" \
    2>/dev/null | tr -d '\r\n')
  if [ -z "$en_pod" ]; then
    nota "$desc: esta arriba, pero no pude leer su codigo para comparar"
  elif [ "$en_pod" != "$en_disco" ]; then
    falta "$desc corre CODIGO VIEJO ($en_pod != $en_disco)" \
          "./malla/agentes-up.sh   # reconstruye, carga en kind y reinicia"
  else
    ok "$desc"
  fi
}
pod_al_dia investigador agente.py "agente investigador (pod)"
pod_al_dia defensor     agente.py "agente defensor (pod)"
pod_al_dia orquestador  flujo.py  "orquestador (pod)"
# La interfaz importa malla/flujo.py AL ARRANCAR, asi que tiene el mismo
# problema que los agentes: cambias el flujo, olvidas reiniciar, y unos pasos
# dejan de salir sin que nada parezca roto.
if (echo >/dev/tcp/127.0.0.1/8080) >/dev/null 2>&1; then
  d=$(python3 -c "import hashlib,pathlib;print(hashlib.sha256(pathlib.Path('malla/flujo.py').read_bytes()).hexdigest()[:12])" 2>/dev/null)
  m=$(curl -s http://127.0.0.1:8080/api/salud 2>/dev/null | jq -r '.version_flujo // empty' 2>/dev/null)
  if [ -z "$m" ]; then
    falta "la interfaz corre CODIGO VIEJO (sin version_flujo)" "reinicia: .venv/bin/python ui/servidor.py"
  elif [ "$m" != "$d" ]; then
    falta "la interfaz corre FLUJO VIEJO ($m != $d)" "reinicia: .venv/bin/python ui/servidor.py"
  else
    ok "la interfaz (:8080)"
  fi
else
  falta "la interfaz (:8080)" ".venv/bin/python ui/servidor.py"
fi

# Opcional: solo hace falta si se quieren trazas.
if (echo >/dev/tcp/127.0.0.1/4318) >/dev/null 2>&1; then
  ok "port-forward del Collector (:4318)"
else
  nota "opcional: port-forward del Collector (:4318) para exportar trazas"
fi

# ---------------------------------------------------------------------------
titulo "El redactor, listo para el segmento 6"
# La demo consiste en etiquetarlo EN VIVO. Si ya viene etiquetado de la corrida
# anterior, la politica ya aplica y no queda nada que demostrar: el 403 sale
# antes de que toques nada, y el momento se pierde.
#
# Se comprueba aqui y no en agentes-up.sh porque el caso malo es correr la demo
# DOS VECES sin redesplegar, que es justo cuando agentes-up.sh no se ejecuta.
# OJO CON .items[0]: durante un reinicio hay DOS pods -el viejo terminando y el
# nuevo- y el orden de la lista no esta garantizado. Leer el primero puede dar
# el equivocado, y el sintoma es un aviso que no se va aunque el reset funcione.
#
# Se miran TODOS los pods y solo los que estan corriendo: un pod en Terminating
# ya no recibe trafico, asi que su etiqueta no gobierna nada.
_sucios=$(kubectl -n agentes get pod -l app=redactor \
  -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{" "}{.metadata.labels.rol}{"\n"}{end}' \
  2>/dev/null | awk 'NF==2 {print $1}')
_vivos=$(kubectl -n agentes get pod -l app=redactor \
  --field-selector=status.phase=Running -o name 2>/dev/null | wc -l | tr -d ' ')
if [ "${_vivos:-0}" -eq 0 ]; then
  falta "no hay ningun pod del redactor corriendo" "./malla/agentes-up.sh"
elif [ -z "$_sucios" ]; then
  ok "el redactor NO tiene rol=agente (asi debe estar antes de demostrar)"
else
  falta "el redactor ya tiene la etiqueta: $(echo $_sucios)" \
        "./seguridad/redactor-limpio.sh"
fi

# ---------------------------------------------------------------------------
titulo "La interfaz compilada"
if [ -f ui/dist/index.html ]; then
  ok "ui/dist existe"
else
  falta "la interfaz no esta compilada" "cd ui && npm install && npm run build"
fi

# ---------------------------------------------------------------------------
echo ""
if [ "$faltan" -eq 0 ]; then
  printf "\033[32mTODO ARRIBA.\033[0m  La demo esta lista.\n"
else
  printf "\033[31mFALTAN %s cosa(s).\033[0m  El orden completo esta en GUIA.md\n" "$faltan"
fi
exit "$faltan"
