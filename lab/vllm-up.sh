#!/usr/bin/env bash
#
# Levanta vLLM en la GPU del host: el motor de inferencia de toda la malla.
#
# Buena parte de lo que hay aqui NO se dedujo, se midio en dCloud durante la
# demo v1 (repo triage-multiagente, deploy/vllm-host/vllm-up.sh). Cada valor
# raro de abajo tiene su motivo escrito al lado. Si vas a cambiar uno, lee
# primero por que esta ahi.
#
# POR QUE FUERA DE KUBERNETES
# ---------------------------
# vLLM NO corre dentro de kind, corre como un contenedor suelto en el host.
# Meter la GPU dentro de kind (device plugin, time-slicing) fue la pieza mas
# fragil del proyecto anterior. Ademas el segmento 1 queda mas limpio sin
# Kubernetes de por medio: nvidia-smi, docker ps, un motor, dos agentes encima.
#
# Los agentes SI viven dentro de kind y alcanzan a vLLM por la IP del host en
# la red de Docker. Eso va a endpoint.env, que este script escribe.
#
# Uso:
#   ./vllm-up.sh
#   ./vllm-up.sh --logs
#   ./vllm-up.sh --down

set -euo pipefail

NOMBRE=vllm
PUERTO="${PUERTO:-8000}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RED_KIND="${RED_KIND:-kind}"

# ---------------------------------------------------------------------------
# La imagen: FIJA, y el motivo es el driver
# ---------------------------------------------------------------------------
# NO usar :latest. Dos razones, y la segunda es dura:
#
#   1. "latest" cambia sola y el dia del evento tiene que correr lo que se
#      ensayo.
#   2. El driver de este host es 555.42.06, que expone CUDA 12.5. Las imagenes
#      modernas de vLLM (y el NIM de NVIDIA) se compilan sobre CUDA 13, que
#      exige driver >= 580. Fallan con:
#         "CUDA driver ... too old (found version 12050)"
#      Y no hay atajo: las librerias de compatibilidad hacia adelante de CUDA
#      13 estan hechas para las ramas R535 y R570. El 555 cae en el hueco.
#
# v0.6.6.post1 esta compilada sobre CUDA 12.x y es la que ya funciono en dCloud
# en la demo v1. Es una version vieja, y eso es a proposito: el limite no lo
# pone vLLM, lo pone el driver, y en este host el driver no se puede actualizar
# (no hay reinicio disponible).
IMAGEN="${IMAGEN:-vllm/vllm-openai:v0.6.6.post1}"

# ---------------------------------------------------------------------------
# El modelo: Qwen2.5-32B-Instruct-AWQ
# ---------------------------------------------------------------------------
# AWQ es cuantizacion a 4 bits ya hecha en el repo del modelo. Dos ventajas
# sobre FP8 en esta GPU, las dos medidas en v1:
#
#   - Carga ya cuantizado (~19 GB), sin el pico de memoria que tiene el FP8
#     dinamico, que obliga a vLLM a cargar el bf16 entero y despues comprimir.
#   - En 46 GB deja muchisimo espacio para cache KV, que es lo que de verdad
#     se agota cuando varios agentes hablan a la vez.
#
# Un 32B para tool-calling agentico esta en otra liga que un 7B, y la Fase C
# depende de eso.
MODELO="${MODELO:-Qwen/Qwen2.5-32B-Instruct-AWQ}"

# awq_marlin es el kernel de AWQ para GPUs Ampere y posteriores. El L40S es
# Ada, asi que entra.
QUANT="${QUANT:-awq_marlin}"

# El parser de tool-calls DEBE coincidir con la familia del modelo.
# Qwen2.5 usa el formato "hermes".
TOOL_PARSER="${TOOL_PARSER:-hermes}"

# ---------------------------------------------------------------------------
# Memoria: aqui el reparto CAMBIO respecto de la v1, y conviene saber por que
# ---------------------------------------------------------------------------
# En v1 corrian DOS instancias sobre el mismo L40S (un 7B y este 32B), asi que
# al 32B se le daba 0.68 de la GPU para dejarle sitio al otro.
#
# Aqui corre UNA sola. Ya no hay con quien repartir, asi que sube a 0.90: los
# ~19 GB de pesos dejan del orden de 20 GB de cache KV, que es holgura de
# verdad. Si algun dia vuelven dos modelos, esto baja, no sube.
UTIL="${UTIL:-0.90}"

# 32k es la ventana nativa de Qwen2.5. Con una sola instancia cabe sin apretar.
CTX="${CTX:-32768}"

# Cache KV en fp8: la reduce a la mitad. La perdida de precision en la atencion
# es despreciable para esto.
#
# OJO PARA EL SEGMENTO 1: el TTFT medido con cache fp8 NO es el mismo que con
# fp16. Si vas a enseñar latencia en pantalla, di que dtype estas usando, o
# mide con KV_DTYPE=auto para el caso "puro". Honestidad, CLAUDE.md seccion 6.
KV_DTYPE="${KV_DTYPE:-fp8}"

# CUDA graphs encendidos (o sea, SIN --enforce-eager).
#
# En v1 el 32B iba con --enforce-eager porque compartia GPU y los grafos CUDA
# ocupan memoria que hacia falta para el otro modelo. Aqui sobra memoria, y los
# grafos hacen la inferencia mas rapida. La latencia importa: la regla de
# abandono del guion son 60 segundos.
#
# Si algo no cabe, este es el primer interruptor que tocar.
EAGER="${EAGER:-0}"

CACHE_HF="${CACHE_HF:-$HOME/.cache/huggingface}"

log() { echo ""; echo "=== $1"; }

# --- Subcomandos -----------------------------------------------------------
case "${1:-}" in
  --logs) exec docker logs -f "$NOMBRE" ;;
  --down) docker rm -f "$NOMBRE" 2>/dev/null && echo "vLLM detenido" || echo "No estaba corriendo"; exit 0 ;;
esac

# --- Verificaciones previas ------------------------------------------------
command -v docker >/dev/null || { echo "Falta docker: corre ./bootstrap.sh"; exit 1; }

log "Verificando que los contenedores vean la GPU"
if ! docker run --rm --gpus all nvidia/cuda:12.5.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: los contenedores no ven la GPU. Corre ./bootstrap.sh"
  exit 1
fi
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

# Un solo motor a la vez en el mismo puerto. Con los dos arriba, los agentes
# hablarian con el que gano la carrera: el error que no se nota hasta que las
# mediciones ya no significan nada.
if docker ps --format '{{.Names}}' | grep -qx nim; then
  echo ""
  echo "ERROR: el NIM esta corriendo y ocupa el mismo puerto."
  echo "Bajalo primero:   ./nim-up.sh --down"
  exit 1
fi

if docker ps --format '{{.Names}}' | grep -qx "$NOMBRE"; then
  log "vLLM ya estaba corriendo"
else
  # Barrido SIEMPRE, aprendido en v1: si un arranque fallo, el contenedor
  # muerto puede seguir reteniendo VRAM y el siguiente intento no cabe, con un
  # error que culpa a la cache y no al cadaver.
  docker rm -f "$NOMBRE" >/dev/null 2>&1 || true
  mkdir -p "$CACHE_HF"

  log "Levantando vLLM con $MODELO"
  echo "Imagen:  $IMAGEN  (CUDA 12.x, por el driver 555 de este host)"
  echo "Memoria: util $UTIL, ventana $CTX, cache KV $KV_DTYPE"
  echo ""
  echo "La primera vez descarga ~19 GB de pesos. Se quedan en $CACHE_HF"

  opciones=()
  [ "$EAGER" = "1" ] && opciones+=(--enforce-eager)

  # SIN --restart a proposito, tambien de v1: si el arranque falla (por ejemplo
  # porque no cabe la cache), un contenedor en bucle de reinicio vuelve a pedir
  # VRAM una y otra vez y enturbia el diagnostico. Cuando la config este
  # estable y toque preparar el modo stand, se agrega.
  docker run -d \
    --name "$NOMBRE" \
    --gpus all \
    --ipc=host \
    -p "${PUERTO}:8000" \
    -v "${CACHE_HF}:/root/.cache/huggingface" \
    -e PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True \
    "$IMAGEN" \
    --model "$MODELO" \
    --served-model-name "$MODELO" \
    --host 0.0.0.0 \
    --port 8000 \
    --quantization "$QUANT" \
    --gpu-memory-utilization "$UTIL" \
    --max-model-len "$CTX" \
    --kv-cache-dtype "$KV_DTYPE" \
    --enable-prefix-caching \
    --enable-auto-tool-choice \
    --tool-call-parser "$TOOL_PARSER" \
    "${opciones[@]}" >/dev/null
fi

# --- Esperar a que responda ------------------------------------------------
log "Esperando a que el endpoint responda"
echo "(un 32B tarda: descarga, carga a VRAM y perfila la cache)"
listo=no
for i in $(seq 1 180); do
  if curl -sf "http://localhost:${PUERTO}/health" >/dev/null 2>&1; then
    listo=si
    break
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$NOMBRE"; then
    echo ""
    echo "ERROR: el contenedor de vLLM se murio. Ultimas lineas del log:"
    docker logs --tail 50 "$NOMBRE" 2>&1
    echo ""
    echo "Pistas segun lo que diga el error:"
    echo "  'CUDA driver ... too old'   -> la imagen pide CUDA 13 y el driver"
    echo "                                 es 555. Usa una imagen CUDA 12.x."
    echo "  'No available memory for cache blocks' -> baja UTIL o CTX:"
    echo "                                 UTIL=0.85 CTX=16384 ./vllm-up.sh"
    echo "  'unrecognized arguments: --tool-call-parser' -> esta version de"
    echo "                                 vLLM no trae tool-calling. Avisame."
    exit 1
  fi
  sleep 10
done

if [ "$listo" != "si" ]; then
  echo "ERROR: vLLM sigue sin responder despues de 30 minutos."
  echo "Mira que hace:  ./vllm-up.sh --logs"
  exit 1
fi

log "vLLM listo"
curl -s "http://localhost:${PUERTO}/v1/models" | jq -r '.data[].id' 2>/dev/null || true
echo ""
nvidia-smi --query-gpu=memory.used,memory.total --format=csv

# --- El contrato compartido con nim-up.sh ----------------------------------
# Los dos motores escriben ESTE archivo y los agentes lo leen. Es lo que hace
# que cambiar de motor sea bajar uno y subir el otro, sin tocar codigo.
#
# OJO CON LA IP: la red de kind es DUAL-STACK. Si tomas el primer gateway a
# ciegas te puede tocar el IPv6 (fc00:...), y vLLM se publica en IPv4 con -p,
# asi que los pods apuntarian a una direccion inalcanzable. Esto se aprendio en
# v1. Por eso se listan todas las gateways y se filtra la que empieza con
# digitos.
IP_HOST=""
if docker network inspect "$RED_KIND" >/dev/null 2>&1; then
  IP_HOST="$(docker network inspect "$RED_KIND" -f '{{range .IPAM.Config}}{{.Gateway}} {{end}}' \
             | tr ' ' '\n' | grep -E '^[0-9]+\.' | head -1)"
fi
{
  echo "# Generado por lab/vllm-up.sh. No editar a mano: se reescribe."
  echo "MOTOR=vllm"
  echo "MODEL=$MODELO"
  echo "TOOL_CALL_PARSER=$TOOL_PARSER"
  echo "OPENAI_BASE_URL_HOST=http://localhost:${PUERTO}/v1"
  [ -n "$IP_HOST" ] && echo "OPENAI_BASE_URL=http://${IP_HOST}:${PUERTO}/v1"
} > "$DIR/endpoint.env"

echo ""
echo "Escrito lab/endpoint.env:"
sed 's/^/  /' "$DIR/endpoint.env"
echo ""
if [ -z "$IP_HOST" ]; then
  echo "El cluster de kind no existe todavia (corre ./cluster-up.sh), asi que"
  echo "falta la URL que usan los pods. Vuelve a correr esto despues."
  echo ""
fi
echo "Probar:    curl -s http://localhost:${PUERTO}/v1/models | jq"
echo "Ver logs:  ./vllm-up.sh --logs"
