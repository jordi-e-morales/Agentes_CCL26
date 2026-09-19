#!/usr/bin/env bash
#
# Levanta vLLM en la GPU del host: el motor de inferencia de toda la malla.
#
# POR QUE FUERA DE KUBERNETES
# ---------------------------
# vLLM NO corre dentro de kind, corre como un contenedor suelto en el host.
# Eso es a proposito y no es pereza:
#
#   1. Pasar la GPU hacia adentro de un nodo de kind (que ya es un contenedor)
#      es fragil y se rompe en cada reinicio. No vale la pena el riesgo.
#   2. El segmento 1 de la sesion ("un agente no es un modelo") queda mas
#      limpio: se enseña con nvidia-smi y docker ps, sin Kubernetes de por
#      medio. Un solo motor, dos agentes encima. Ese ES el mensaje.
#   3. Se reinicia sin tocar el cluster, que es lo que necesita el modo stand.
#
# Los agentes SI viven dentro de kind, y alcanzan a vLLM por la IP del host en
# la red de Docker. Este script te la imprime al final.
#
# Idempotente: si el contenedor ya esta corriendo, no hace nada.
#
# Uso:
#   ./vllm-up.sh                 # levanta con los valores de abajo
#   MODELO=otro/modelo ./vllm-up.sh
#   ./vllm-up.sh --logs          # sigue los logs del contenedor
#   ./vllm-up.sh --down          # lo baja

set -euo pipefail

NOMBRE=vllm
PUERTO=8000

# ---------------------------------------------------------------------------
# La imagen: AQUI HAY UNA DEUDA, y esta anotada a proposito
# ---------------------------------------------------------------------------
# "latest" es una mina para el dia del evento: la imagen cambia sola y lo que
# ensayaste deja de ser lo que corre. Hay que fijarla a una version concreta.
#
# Y hay un motivo extra en este lab. El driver del host es 555.42.06 (CUDA 12.5):
#
#   - Una imagen de vLLM sobre CUDA 12.x funciona por compatibilidad de version
#     menor. Es la ruta segura.
#   - Una imagen sobre CUDA 13.x exige driver >= 580. El L40S es GPU de
#     datacenter, asi que las librerias de forward-compat que trae la imagen
#     de vLLM PUEDEN salvarla, pero es una ruta que hay que probar, no asumir.
#
# Cuando la primera corrida funcione, fija el digest exacto aqui:
#   docker inspect --format='{{index .RepoDigests 0}}' vllm/vllm-openai:latest
IMAGEN="${IMAGEN:-vllm/vllm-openai:latest}"

# ---------------------------------------------------------------------------
# El modelo: DECISION ABIERTA (CLAUDE.md, seccion 12)
# ---------------------------------------------------------------------------
# Falta decidir si hay uno o dos tiers de modelo. Mientras tanto, uno solo:
# Qwen2.5-7B-Instruct, porque no esta restringido (no pide token de Hugging
# Face), cabe de sobra en los 46 GB del L40S, y hace function-calling, que la
# Fase C necesita para las tools.
MODELO="${MODELO:-Qwen/Qwen2.5-7B-Instruct}"

# El parser de tool-calls DEBE coincidir con la familia del modelo.
# Qwen2.5 usa el formato "hermes". Si cambias de modelo, cambia esto tambien.
TOOL_PARSER="${TOOL_PARSER:-hermes}"

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
  echo "ERROR: los contenedores no ven la GPU."
  echo "Falta el nvidia-container-toolkit. Corre ./bootstrap.sh"
  exit 1
fi
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

if docker ps --format '{{.Names}}' | grep -qx "$NOMBRE"; then
  log "vLLM ya estaba corriendo"
else
  docker rm -f "$NOMBRE" >/dev/null 2>&1 || true

  log "Levantando vLLM con $MODELO"
  echo "La primera vez descarga el modelo (varios GB). Las siguientes no:"
  echo "se guarda en ~/.cache/huggingface, que se monta en el contenedor."

  # --ipc=host: vLLM usa memoria compartida entre procesos y el limite por
  #   omision de Docker (64 MB) no le alcanza.
  # --restart unless-stopped: si el host reinicia, vuelve solo. El modo stand
  #   pide reinicio en menos de 10 s entre visitantes; esto es parte de eso.
  # --host 0.0.0.0: para que los pods de kind puedan alcanzarlo. Sin esto solo
  #   escucharia en localhost del contenedor y la malla no lo veria.
  docker run -d \
    --name "$NOMBRE" \
    --gpus all \
    --ipc=host \
    --restart unless-stopped \
    -p "${PUERTO}:8000" \
    -v "$HOME/.cache/huggingface:/root/.cache/huggingface" \
    "$IMAGEN" \
    --model "$MODELO" \
    --host 0.0.0.0 \
    --port 8000 \
    --enable-auto-tool-choice \
    --tool-call-parser "$TOOL_PARSER"
fi

# --- Esperar a que responda ------------------------------------------------
log "Esperando a que el endpoint responda (la carga del modelo tarda)"
for i in $(seq 1 60); do
  if curl -sf "http://localhost:${PUERTO}/v1/models" >/dev/null 2>&1; then
    echo "Responde."
    break
  fi
  # Si el contenedor ya murio, no tiene caso seguir esperando: muestra por que.
  if ! docker ps --format '{{.Names}}' | grep -qx "$NOMBRE"; then
    echo ""
    echo "ERROR: el contenedor de vLLM se murio. Ultimas lineas del log:"
    docker logs --tail 40 "$NOMBRE" 2>&1
    echo ""
    echo "Si el error menciona CUDA, driver o 'forward compatibility', es lo"
    echo "que advierte el comentario de IMAGEN arriba: esta imagen pide un"
    echo "driver mas nuevo que el 555 del host. Prueba una imagen sobre CUDA 12.x."
    exit 1
  fi
  sleep 10
done

log "vLLM listo"
curl -s "http://localhost:${PUERTO}/v1/models" | jq -r '.data[].id' 2>/dev/null || true

# --- Como lo alcanzan los agentes dentro de kind ---------------------------
# Los pods no pueden usar "localhost": eso es el propio pod. Necesitan la IP
# del host en la red de Docker donde viven los nodos de kind.
echo ""
if docker network inspect kind >/dev/null 2>&1; then
  IP_HOST=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}')
  echo "Desde los pods de kind, el endpoint es:"
  echo "  http://${IP_HOST}:${PUERTO}/v1"
else
  echo "El cluster de kind todavia no existe (corre ./cluster-up.sh)."
  echo "Despues vuelve a correr esto para ver la IP que deben usar los pods."
fi
echo ""
echo "Desde el host:  curl http://localhost:${PUERTO}/v1/models"
echo "Ver logs:       ./vllm-up.sh --logs"
