#!/usr/bin/env bash
#
# Instala el lab completo sobre un Ubuntu limpio con GPU NVIDIA.
#
# Este script es EL ARTEFACTO PORTABLE del proyecto. El host es desechable:
# si se rompe, lo borras y corres esto de nuevo.
#
# Y eso no es teoria. La reserva actual dura hasta el 2026-09-23; despues hay
# que migrar todo a la instancia que llega al dia del evento. Esa migracion es
# la prueba real de este archivo: si migrar no es "git clone && ./bootstrap.sh",
# el script esta incompleto. Todo lo que instales a mano, escribelo aqui el
# mismo dia, no despues.
#
# Uso:
#   chmod +x bootstrap.sh
#   ./bootstrap.sh
#
# Es idempotente: puedes correrlo varias veces sin romper nada.

set -euo pipefail

# ---------------------------------------------------------------------------
# Que apt no pregunte nada
# ---------------------------------------------------------------------------
# Este script tiene que correr DESATENDIDO. Si se queda esperando una respuesta
# en un menu, deja de servir para lo unico que existe: migrar a una instancia
# nueva sin que nadie se acuerde de los detalles.
#
# Hay dos cosas distintas que preguntan, y hay que callar a las dos:
#
#   DEBIAN_FRONTEND=noninteractive
#     Apaga los dialogos de configuracion de los paquetes (debconf): el clasico
#     "¿conservar tu version del archivo de configuracion?".
#
#   NEEDRESTART_MODE=l
#     needrestart es una utilidad de Ubuntu que, despues de instalar algo que
#     actualiza librerias, abre un cuadro semigrafico preguntando que servicios
#     reiniciar. Con "l" solo los LISTA y sigue de largo.
#
#     Se usa "l" y no "a" (reiniciar automaticamente) a proposito: "a" podria
#     reiniciar Docker a media instalacion, y debajo de Docker estan los nodos
#     de kind. Los servicios se quedan con las librerias viejas hasta el
#     siguiente reinicio del host, lo cual en un lab no le importa a nadie.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l

log() { echo ""; echo "=== $1"; }

# ---------------------------------------------------------------------------
# 0. Verificacion previa: BTF
# ---------------------------------------------------------------------------
# BTF es informacion de depuracion que el kernel expone sobre si mismo.
# Tetragon la necesita para saber donde engancharse. Sin esto, la Fase 2
# no funciona, y es mejor enterarse ahora que la semana del evento.
log "Verificando soporte de BTF en el kernel"
if [ -f /sys/kernel/btf/vmlinux ]; then
  echo "BTF disponible. Tetragon va a poder correr."
else
  echo "ADVERTENCIA: este kernel no expone BTF en /sys/kernel/btf/vmlinux"
  echo "El lab de red va a funcionar, pero Tetragon no."
  echo "Sin Tetragon no hay SIGKILL, que es la capa de kernel del segmento 6."
  echo "Revisa si el kernel se compilo con CONFIG_DEBUG_INFO_BTF=y."
fi
echo "Kernel: $(uname -r)"

# ---------------------------------------------------------------------------
# 0b. DNS de respaldo (solo si hace falta)
# ---------------------------------------------------------------------------
# Sin DNS no funciona apt, ni la descarga de imágenes, ni la de modelos, y el
# síntoma engaña: el host sí tiene salida a internet por IP.
#
# Por eso: si el DNS actual resuelve, NO tocamos nada (la instancia puede tener
# un DNS interno que hay que respetar). Solo si falla, agregamos servidores
# públicos como respaldo a systemd-resolved, el servicio que resuelve nombres
# en Ubuntu. "Domains=~." le dice que los use para todos los dominios.
#
# Este bloque nació de un problema de otro entorno (el switch de Hyper-V), pero
# se queda: es defensivo, no toca nada si el DNS está bien, y una instancia
# nueva es justo donde esto vuelve a fallar.
#
# Notas de lo que se aprendió probándolo:
# - Se verifica con "ahostsv4" (solo IPv4). Las consultas IPv6 siguen
#   colgándose contra el DNS del switch, pero apt, Docker y Ollama funcionan.
# - Justo después de reiniciar systemd-resolved la primera consulta puede
#   tardar; por eso se reintenta antes de declarar error.
# - No hace falta reiniciar Docker: los nodos de kind reenvían sus consultas
#   al resolvedor del host (127.0.0.53), así que heredan el respaldo.
dns_ok() {
  for _ in 1 2 3 4 5; do
    timeout 5 getent ahostsv4 github.com >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

log "Verificando DNS"
if dns_ok; then
  echo "El DNS resuelve. No se cambia nada."
else
  echo "El DNS no resuelve. Configurando respaldo 1.1.1.1 / 8.8.8.8"
  sudo mkdir -p /etc/systemd/resolved.conf.d
  printf '[Resolve]\nDNS=1.1.1.1 8.8.8.8\nFallbackDNS=1.0.0.1 8.8.4.4\nDomains=~.\n' \
    | sudo tee /etc/systemd/resolved.conf.d/10-respaldo-lab.conf >/dev/null
  sudo systemctl restart systemd-resolved
  if dns_ok; then
    echo "DNS de respaldo funcionando."
  else
    echo "ERROR: ni con DNS de respaldo se resuelven nombres. Revisa la red del host."
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 1. Paquetes base
# ---------------------------------------------------------------------------
log "Instalando paquetes base"
sudo apt-get update -qq
sudo apt-get install -y -qq ca-certificates curl gnupg jq git

# ---------------------------------------------------------------------------
# 2. Docker
# ---------------------------------------------------------------------------
# kind (el Kubernetes de mentiras que vamos a usar) corre cada nodo del
# cluster como un contenedor de Docker. Por eso Docker va primero.
if ! command -v docker >/dev/null 2>&1; then
  log "Instalando Docker"
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io
  sudo usermod -aG docker "$USER"
  echo "Docker instalado. Vas a necesitar cerrar y abrir la sesion para usarlo sin sudo."
else
  log "Docker ya estaba instalado"
fi

# ---------------------------------------------------------------------------
# 3. kubectl
# ---------------------------------------------------------------------------
# kubectl es el control remoto de Kubernetes. Todo lo que hagas contra el
# cluster pasa por aqui.
if ! command -v kubectl >/dev/null 2>&1; then
  log "Instalando kubectl"
  KVER="$(curl -L -s https://dl.k8s.io/release/stable.txt)"
  curl -sLO "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
  rm -f kubectl
else
  log "kubectl ya estaba instalado"
fi

# ---------------------------------------------------------------------------
# 4. kind
# ---------------------------------------------------------------------------
# kind = Kubernetes IN Docker. Levanta un cluster completo en tu maquina
# usando contenedores como si fueran servidores.
if ! command -v kind >/dev/null 2>&1; then
  log "Instalando kind"
  curl -sLo ./kind https://kind.sigs.k8s.io/dl/latest/kind-linux-amd64
  chmod +x ./kind
  sudo mv ./kind /usr/local/bin/kind
else
  log "kind ya estaba instalado"
fi

# ---------------------------------------------------------------------------
# 5. CLI de Cilium
# ---------------------------------------------------------------------------
if ! command -v cilium >/dev/null 2>&1; then
  log "Instalando la CLI de Cilium"
  CVER="$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)"
  curl -sL --fail --remote-name-all \
    "https://github.com/cilium/cilium-cli/releases/download/${CVER}/cilium-linux-amd64.tar.gz"
  sudo tar xzf cilium-linux-amd64.tar.gz -C /usr/local/bin
  rm -f cilium-linux-amd64.tar.gz
else
  log "La CLI de Cilium ya estaba instalada"
fi

# ---------------------------------------------------------------------------
# 6. CLI de Hubble
# ---------------------------------------------------------------------------
# Ojo: 'cilium' y 'hubble' son DOS PROGRAMAS DISTINTOS.
#   cilium  -> instala y administra la red del cluster
#   hubble  -> consulta el trafico que Cilium esta viendo
# Instalar uno no instala el otro. Y hubble es el que te deja VER los bloqueos,
# que es la mitad de la demo.
if ! command -v hubble >/dev/null 2>&1; then
  log "Instalando la CLI de Hubble"
  HVER="$(curl -s https://raw.githubusercontent.com/cilium/hubble/master/stable.txt)"
  curl -sL --fail --remote-name-all \
    "https://github.com/cilium/hubble/releases/download/${HVER}/hubble-linux-amd64.tar.gz"
  sudo tar xzf hubble-linux-amd64.tar.gz -C /usr/local/bin
  rm -f hubble-linux-amd64.tar.gz
else
  log "La CLI de Hubble ya estaba instalada"
fi

# ---------------------------------------------------------------------------
# 7. Helm
# ---------------------------------------------------------------------------
# Helm instala "charts": paquetes de manifiestos de Kubernetes con valores
# configurables. Lo usamos para Tetragon (el control de kernel del Demo 2),
# que se distribuye asi. Version fija y suma de verificacion comprobada.
HELM_VER=v4.3.0
if ! command -v helm >/dev/null 2>&1; then
  log "Instalando Helm $HELM_VER"
  tmp=$(mktemp -d)
  curl -sL --fail -o "$tmp/helm.tgz" "https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz"
  curl -sL --fail -o "$tmp/helm.tgz.sha256sum" "https://get.helm.sh/helm-${HELM_VER}-linux-amd64.tar.gz.sha256sum"
  esperado=$(awk '{print $1}' "$tmp/helm.tgz.sha256sum")
  echo "$esperado  $tmp/helm.tgz" | sha256sum -c -
  tar xzf "$tmp/helm.tgz" -C "$tmp"
  sudo install -m 0755 "$tmp/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "$tmp"
else
  log "Helm ya estaba instalado"
fi

# ---------------------------------------------------------------------------
# 8. GPU dentro de contenedores (nvidia-container-toolkit)
# ---------------------------------------------------------------------------
# Esto confunde a todo el mundo la primera vez, asi que vale la pena decirlo:
# son DOS cosas distintas.
#
#   driver NVIDIA          -> deja que el HOST vea la GPU     (nvidia-smi funciona)
#   nvidia-container-toolkit -> deja que un CONTENEDOR la vea (docker --gpus funciona)
#
# Tener lo primero no te da lo segundo. Y vLLM corre en contenedor, asi que sin
# esto no hay inferencia y el segmento 1 no existe.
#
# En el host del 2026-09-19 ya estaba puesto, pero se queda aqui: la instancia
# a la que hay que migrar no tiene por que traerlo.
if command -v nvidia-smi >/dev/null 2>&1; then
  log "Verificando acceso a la GPU desde contenedores"
  # La imagen 12.5.1 se elige a proposito: coincide con el CUDA del driver 555
  # del lab. Es solo la prueba, no es la imagen con la que corre vLLM.
  if sudo docker run --rm --gpus all nvidia/cuda:12.5.1-base-ubuntu22.04 \
       nvidia-smi >/dev/null 2>&1; then
    echo "Los contenedores ya ven la GPU. No se instala nada."
  else
    echo "Los contenedores NO ven la GPU. Instalando nvidia-container-toolkit"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
      | sudo gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
      | sudo tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq nvidia-container-toolkit
    # Registra el runtime de NVIDIA en Docker y lo reinicia para que lo tome.
    sudo nvidia-ctk runtime configure --runtime=docker
    sudo systemctl restart docker
    echo "Instalado. Verificando de nuevo:"
    sudo docker run --rm --gpus all nvidia/cuda:12.5.1-base-ubuntu22.04 nvidia-smi
  fi
else
  log "Sin nvidia-smi: este host no tiene GPU, se omite el toolkit"
  echo "El lab de red y kernel funciona igual; vLLM no."
fi

# ---------------------------------------------------------------------------
# 9. Entorno virtual de Python
# ---------------------------------------------------------------------------
# Un venv es una carpeta con su propio Python y sus propios paquetes. Todo lo
# que instales dentro no toca el Python del sistema, que en Ubuntu ademas esta
# protegido: pip se niega a instalar cosas globalmente (PEP 668) porque apt
# depende de esa instalacion y romperla rompe el sistema.
#
# Vive en la RAIZ DEL REPO (.venv), no en el home, para que se borre junto con
# el repo y para que nunca haya dos copias compitiendo.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="$REPO/.venv"

log "Entorno virtual de Python"
# Solo se instala si de verdad falta. Ubuntu trae python3, pero el modulo venv
# viene en un paquete aparte que no siempre esta.
#
# Se comprueba en vez de instalar a ciegas porque cada apt-get install en este
# host es una interrupcion potencial (dialogos de apt, needrestart) y un cambio
# que no pediste. Si ya esta, no se toca nada.
if python3 -m venv --help >/dev/null 2>&1; then
  echo "El modulo venv ya esta disponible. No se instala nada."
else
  echo "Falta el modulo venv. Instalando python3-venv"
  sudo apt-get install -y -qq python3-venv
fi

if [ -d "$VENV" ]; then
  echo "Ya existe en $VENV"
else
  python3 -m venv "$VENV"
  echo "Creado en $VENV"
fi
# pip viejo falla con ruedas modernas; se actualiza siempre, es barato.
"$VENV/bin/pip" install --quiet --upgrade pip wheel
if [ -f "$REPO/requirements.txt" ]; then
  echo "Instalando requirements.txt"
  "$VENV/bin/pip" install --quiet -r "$REPO/requirements.txt"
fi
echo "Para usarlo:  source $VENV/bin/activate"


log "Listo"
echo ""
echo "Herramientas instaladas:"
for cmd in docker kubectl kind cilium hubble helm; do
  if command -v "$cmd" >/dev/null 2>&1; then echo "  ok   $cmd"; else echo "  FALTA $cmd"; fi
done
if command -v nvidia-smi >/dev/null 2>&1; then
  if sudo docker run --rm --gpus all nvidia/cuda:12.5.1-base-ubuntu22.04 \
       nvidia-smi >/dev/null 2>&1; then
    echo "  ok   GPU visible desde contenedores"
  else
    echo "  FALTA GPU visible desde contenedores"
  fi
fi
[ -x "$VENV/bin/python" ] && echo "  ok   venv ($VENV)" || echo "  FALTA venv"
echo ""
echo "Siguiente paso:  ./cluster-up.sh"
echo "Si Docker se acaba de instalar, primero cierra sesion y vuelve a entrar."
