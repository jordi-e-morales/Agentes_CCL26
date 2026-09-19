#!/usr/bin/env bash
#
# Levanta un NVIDIA NIM con Nemotron 3 Nano (30B A3B) en la GPU del host.
#
# Es el HERMANO de vllm-up.sh, no su reemplazo. Los dos exponen la misma API
# (la de OpenAI) en el mismo puerto y los dos escriben el mismo archivo de
# configuracion, endpoint.env. Por eso cambiar de motor es bajar uno y subir el
# otro: los agentes no se enteran.
#
# Esa simetria es deliberada. Mientras los agentes lean OPENAI_BASE_URL y MODEL
# de configuracion y nunca hablen con algo especifico de vLLM o de NIM, elegir
# motor es una decision reversible que se toma con mediciones, no con opiniones.
#
# POR QUE UN NIM Y NO SOLO vLLM
# -----------------------------
# El encuadre de la sesion es "un AI POD, no una maqueta". Un Cisco AI POD lleva
# NVIDIA AI Enterprise, que es lo que licencia NIM. Correr un NIM es mas fiel a
# esa historia que vLLM crudo. Es un argumento de narrativa, no de rendimiento,
# y esta bien que lo sea.
#
# POR QUE EL MODELO DE TEXTO Y NO EL "OMNI"
# -----------------------------------------
# El omni entiende video, audio e imagen, y ninguno de los seis segmentos usa
# eso. Sus encoders de vision y audio se quedan en BF16 y ocupan GPU que aqui
# sirve mejor como KV cache.
#
# RAZONAMIENTO
# ------------
# Este modelo razona POR OMISION: genera una traza de razonamiento y despues la
# respuesta. Eso es bueno para dos cosas del plan: las tareas agenticas con
# tool-calling salen mejor, y los tokens de completado suben, que es justo lo
# que hace visible la atribucion de costos en las trazas (CLAUDE.md, seccion 5).
#
# OJO, Y ESTO IMPORTA: el razonamiento NO es una bandera del servidor. Es un
# parametro POR PETICION. Este script no puede encenderlo ni apagarlo; lo
# deciden los agentes en cada llamada:
#
#   {"model": "...", "messages": [...],
#    "chat_template_kwargs": {"enable_thinking": true}}
#
# Omitirlo deja el razonamiento encendido. Ponerlo en false lo apaga, que es lo
# que vas a querer en el segmento donde la latencia importe mas que los tokens.
#
# Uso:
#   ./nim-up.sh                 # levanta el NIM
#   ./nim-up.sh --profiles      # QUE PERFILES tiene el NIM para ESTA GPU
#   ./nim-up.sh --logs
#   ./nim-up.sh --down

set -euo pipefail

NOMBRE=nim
PUERTO="${PUERTO:-8000}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# La imagen: MISMA DEUDA QUE EN vllm-up.sh
# ---------------------------------------------------------------------------
# "latest" cambia sola y el dia del evento tiene que correr lo que se ensayo.
# En el catalogo de NGC existe al menos la 2.0.12; fija una version concreta en
# cuanto la primera corrida funcione.
IMAGEN="${IMAGEN:-nvcr.io/nim/nvidia/nemotron-3-nano:latest}"

# El id con el que los agentes piden el modelo en la API.
MODELO="${MODELO:-nvidia/nemotron-3-nano}"

# Cache de pesos. Vive fuera del contenedor a proposito: sin esto, cada
# reinicio vuelve a descargar decenas de GB, y el modo stand pide reiniciar en
# menos de 10 segundos entre visitantes.
CACHE="${CACHE:-$HOME/.cache/nim}"

log() { echo ""; echo "=== $1"; }

# ---------------------------------------------------------------------------
# La credencial de NGC
# ---------------------------------------------------------------------------
# NUNCA va escrita en este archivo ni en el repo. Se busca, en orden:
#   1. la variable de entorno NGC_API_KEY
#   2. el archivo ~/.ngc-api-key (una sola linea)
# Se pasa a docker login por stdin para que no quede en el historial del shell
# ni en la lista de procesos.
cargar_credencial() {
  if [ -z "${NGC_API_KEY:-}" ] && [ -f "$HOME/.ngc-api-key" ]; then
    NGC_API_KEY="$(tr -d '[:space:]' < "$HOME/.ngc-api-key")"
  fi
  if [ -z "${NGC_API_KEY:-}" ]; then
    echo "ERROR: falta la clave de NGC."
    echo ""
    echo "Consiguela en https://ngc.nvidia.com (Personal API Key) y luego:"
    echo "  echo 'TU_CLAVE' > ~/.ngc-api-key && chmod 600 ~/.ngc-api-key"
    echo ""
    echo "Ojo: la primera vez hay que aceptar los terminos del contenedor en el"
    echo "navegador, en su pagina del catalogo de NGC. Sin eso el pull falla"
    echo "aunque la clave sea correcta."
    exit 1
  fi
  export NGC_API_KEY
}

ngc_login() {
  # '$oauthtoken' es un usuario literal de NGC: significa "me autentico con
  # una API key". No es una variable, por eso va en comillas simples.
  echo "$NGC_API_KEY" | docker login nvcr.io --username '$oauthtoken' --password-stdin >/dev/null
}

# --- Subcomandos -----------------------------------------------------------
case "${1:-}" in
  --logs) exec docker logs -f "$NOMBRE" ;;
  --down) docker rm -f "$NOMBRE" 2>/dev/null && echo "NIM detenido" || echo "No estaba corriendo"; exit 0 ;;
  --profiles)
    # Esto contesta LA pregunta abierta de este modelo en esta GPU.
    #
    # El model card del FP8 en Hugging Face solo lista H100 y A100. La matriz
    # de soporte de NIM si incluye L40S. No se cual gana, asi que en vez de
    # adivinar se le pregunta al contenedor: list-model-profiles reporta que
    # perfiles puede correr en el hardware que tiene enfrente.
    cargar_credencial
    ngc_login
    log "Perfiles que este NIM puede correr en esta GPU"
    exec docker run --rm --gpus all -e NGC_API_KEY "$IMAGEN" list-model-profiles
    ;;
esac

# --- Verificaciones previas ------------------------------------------------
command -v docker >/dev/null || { echo "Falta docker: corre ./bootstrap.sh"; exit 1; }

log "Verificando que los contenedores vean la GPU"
if ! docker run --rm --gpus all nvidia/cuda:12.5.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
  echo "ERROR: los contenedores no ven la GPU. Corre ./bootstrap.sh"
  exit 1
fi
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader

# Un solo motor a la vez en el mismo puerto. Si los dos estuvieran arriba, los
# agentes hablarian con el que gano la carrera, que es la peor clase de error:
# el que no se nota hasta que las mediciones ya no significan nada.
if docker ps --format '{{.Names}}' | grep -qx vllm; then
  echo ""
  echo "ERROR: vLLM esta corriendo y ocupa el mismo puerto."
  echo "Bajalo primero:   ./vllm-up.sh --down"
  echo "O levanta el NIM en otro puerto:   PUERTO=8001 ./nim-up.sh"
  exit 1
fi

cargar_credencial

if docker ps --format '{{.Names}}' | grep -qx "$NOMBRE"; then
  log "El NIM ya estaba corriendo"
else
  docker rm -f "$NOMBRE" >/dev/null 2>&1 || true
  mkdir -p "$CACHE"

  log "Autenticando contra nvcr.io"
  ngc_login

  log "Levantando el NIM con $MODELO"
  echo "La primera vez descarga el modelo (decenas de GB) y compila el perfil"
  echo "para esta GPU. Puede tardar bastante. Las siguientes veces no: se queda"
  echo "en $CACHE"

  # --shm-size=16GB: el NIM usa memoria compartida entre procesos y el limite
  #   por omision de Docker (64 MB) no le alcanza.
  # --restart unless-stopped: si el host reinicia, vuelve solo.
  docker run -d \
    --name "$NOMBRE" \
    --gpus all \
    --shm-size=16GB \
    --restart unless-stopped \
    -e NGC_API_KEY \
    -v "$CACHE:/opt/nim/.cache" \
    -p "${PUERTO}:8000" \
    "$IMAGEN"
fi

# --- Esperar a que responda ------------------------------------------------
log "Esperando a que el endpoint responda"
echo "(la primera vez esto puede tomar mucho: descarga mas compilacion de perfil)"
listo=no
for i in $(seq 1 180); do
  if curl -sf "http://localhost:${PUERTO}/v1/models" >/dev/null 2>&1; then
    listo=si
    break
  fi
  if ! docker ps --format '{{.Names}}' | grep -qx "$NOMBRE"; then
    echo ""
    echo "ERROR: el contenedor del NIM se murio. Ultimas lineas del log:"
    docker logs --tail 60 "$NOMBRE" 2>&1
    echo ""
    echo "Si el error habla de perfiles incompatibles o de la GPU, es la duda"
    echo "que este script documenta arriba. Preguntale al contenedor que puede"
    echo "correr aqui:"
    echo "  ./nim-up.sh --profiles"
    exit 1
  fi
  sleep 10
done

if [ "$listo" != "si" ]; then
  echo "ERROR: el NIM sigue sin responder despues de 30 minutos."
  echo "Mira que esta haciendo:  ./nim-up.sh --logs"
  exit 1
fi

log "NIM listo"
curl -s "http://localhost:${PUERTO}/v1/models" | jq -r '.data[].id' 2>/dev/null || true

# --- El contrato compartido con vllm-up.sh ---------------------------------
# Los dos motores escriben ESTE archivo, y los agentes lo leen. Es lo que hace
# que cambiar de motor no sea tocar codigo.
if docker network inspect kind >/dev/null 2>&1; then
  IP_HOST=$(docker network inspect kind -f '{{(index .IPAM.Config 0).Gateway}}')
else
  IP_HOST=""
fi
{
  echo "# Generado por lab/nim-up.sh. No editar a mano: se reescribe."
  echo "MOTOR=nim"
  echo "MODEL=$MODELO"
  echo "TOOL_CALL_PARSER=qwen3_coder"
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
echo "Probar el razonamiento (encendido por omision):"
cat <<EJEMPLO
  curl -s http://localhost:${PUERTO}/v1/chat/completions \\
    -H 'Content-Type: application/json' \\
    -d '{"model":"${MODELO}",
         "messages":[{"role":"user","content":"Cuantas erres tiene ferrocarril?"}],
         "max_tokens":512}' | jq -r '.choices[0].message'
EJEMPLO
echo ""
echo "Para apagarlo en una peticion, agrega:"
echo '  "chat_template_kwargs": {"enable_thinking": false}'
echo ""
echo "Ver logs:  ./nim-up.sh --logs"
