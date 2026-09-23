#!/usr/bin/env bash
#
# Abre Hubble UI de forma que se vea DESDE OTRA MAQUINA.
#
# POR QUE NO `cilium hubble ui`
# ------------------------------
# Ese comando hace el port-forward contra 127.0.0.1 y abre un navegador. En un
# host sin escritorio las dos cosas fallan: no hay navegador que abrir, y el
# puerto solo existe para el propio host. Desde el Mac no se ve nada, y el
# sintoma es un "no se puede conectar" que no dice por que.
#
# Esto hace el port-forward contra 0.0.0.0, igual que ui/servidor.py, asi que se
# alcanza con la misma IP que ya usas para la interfaz.
#
# Ojo: el relay es OTRA COSA y va aparte. Son dos puertos distintos:
#   4245  relay  -> lo que consultan `hubble observe` y el panel de la interfaz
#   12000 UI     -> el grafo en el navegador
# Para el relay:  cilium hubble port-forward &
#
# Uso:  ./lab/hubble-ui.sh        (se queda corriendo; Ctrl+C lo cierra)

set -uo pipefail

PUERTO=${PUERTO:-12000}

# El Service se llama hubble-ui y vive en kube-system, pero se busca en vez de
# darlo por hecho: si un dia cambia, mejor un mensaje claro que un error de
# kubectl.
NS=$(kubectl get svc -A -l k8s-app=hubble-ui \
  -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
SVC=$(kubectl get svc -A -l k8s-app=hubble-ui \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -z "${SVC:-}" ]; then
  echo ""
  echo "No encuentro el Service de Hubble UI."
  echo ""
  echo "Se instala con el cluster. Si falta, el cluster se creo sin ella:"
  echo "  ./lab/cluster-up.sh"
  echo ""
  exit 1
fi

# La IP con la que el Mac tiene que entrar. Se imprime porque adivinarla es
# justo el paso donde uno se queda atorado.
IP=$(hostname -I 2>/dev/null | awk '{print $1}')

echo ""
echo "=== Hubble UI: $NS/$SVC"
echo ""
echo "    Desde tu navegador:   http://${IP:-<ip-del-host>}:$PUERTO"
echo ""
echo "    ARRANCA VACIO. Hay que elegir el namespace 'agentes' en el"
echo "    desplegable de arriba a la izquierda, o parece que no funciona."
echo ""
echo "    El grafo se dibuja con el trafico que va pasando: si nadie habla,"
echo "    no hay nada que pintar. Lanza una deliberacion y aparece."
echo ""
echo "    Ctrl+C para cerrarlo."
echo ""

exec kubectl -n "$NS" port-forward --address 0.0.0.0 "svc/$SVC" "$PUERTO:80"
