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
# Los agentes no solo tienen que estar ARRIBA: tienen que estar al dia.
#
# "Reinicie los agentes?" ha sido la causa de varias sesiones de depuracion:
# se cambia malla/agente.py, se olvida reiniciar, y el sintoma es que algo
# nuevo "no hace nada" -indistinguible de un fallo real-. Cada agente publica
# la huella de su propio codigo en /salud; aqui se compara con la del disco.
agente_al_dia() {  # puerto  descripcion  como_levantarlo
  if ! (echo >/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1; then
    falta "$2" "$3"; return
  fi
  local en_disco en_memoria
  en_disco=$(python3 -c "import hashlib,pathlib;print(hashlib.sha256(pathlib.Path('malla/agente.py').read_bytes()).hexdigest()[:12])" 2>/dev/null)
  en_memoria=$(curl -s "http://127.0.0.1:$1/salud" 2>/dev/null | jq -r '.version_codigo // empty' 2>/dev/null)
  if [ -z "$en_memoria" ]; then
    falta "$2 corre CODIGO VIEJO (sin /salud)" "reinicialo: $3"
  elif [ "$en_memoria" != "$en_disco" ]; then
    falta "$2 corre CODIGO VIEJO ($en_memoria != $en_disco)" "reinicialo: $3"
  else
    ok "$2"
  fi
}
agente_al_dia 7010 "agente investigador (:7010)" ".venv/bin/python malla/agente.py --rol investigador"
agente_al_dia 7011 "agente defensor (:7011)"     ".venv/bin/python malla/agente.py --rol defensor --puerto 7011"
puerto 8080 "la interfaz (:8080)"          ".venv/bin/python ui/servidor.py"

# Opcional: solo hace falta si se quieren trazas.
if (echo >/dev/tcp/127.0.0.1/4318) >/dev/null 2>&1; then
  ok "port-forward del Collector (:4318)"
else
  nota "opcional: port-forward del Collector (:4318) para exportar trazas"
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
