#!/usr/bin/env bash
#
# TODO LO QUE HAY QUE REINICIAR, EN ORDEN. Un comando y se acabo.
#
# Existe porque "que tengo que reiniciar" se estaba respondiendo de memoria cada
# vez, y de memoria se olvida uno. Las piezas se reinician distinto y ninguna
# avisa cuando esta corriendo codigo viejo: los pods no fallan, sirven lo de
# antes, que es peor.
#
# Uso:
#   ./lab/reiniciar.sh            todo lo que este script puede hacer solo
#   ./lab/reiniciar.sh --rapido   sin reconstruir la imagen (solo puentes + UI)
#
# LO UNICO QUE NO PUEDE HACER es reiniciar tu terminal de ui/servidor.py, porque
# es tuya. Al final te dice si hace falta.

set -uo pipefail
NS=agentes
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAPIDO=""
[ "${1:-}" = "--rapido" ] && RAPIDO="si"

log() { echo ""; echo "=== $1"; }

cd "$DIR"

# --- 1. Los agentes y el orquestador -----------------------------------------
# Su codigo va DENTRO de la imagen, asi que un cambio en malla/*.py no llega a
# los pods hasta que se reconstruye. Es el desfase que ya mordio varias veces.
if [ -z "$RAPIDO" ]; then
  log "Reconstruyendo y relanzando los pods (malla/)"
  ./malla/agentes-up.sh 2>&1 | grep -E "^(===|  (ok|FALTAN|orquestador|investigador|defensor))" || true
else
  log "Saltando la imagen (--rapido)"
fi

# --- 2. Las politicas --------------------------------------------------------
# Se aplican en caliente, no reinician nada, y olvidarlas da el error mas
# engañoso del sistema: "ningun agente responde" cuando los agentes estan bien.
log "Aplicando las politicas de red"
kubectl apply -f seguridad/cilium-l7.yaml >/dev/null && echo "  ok"
./lab/publica-vllm.sh 2>&1 | grep -E "^  (ok|[0-9])" | sed 's/^/  /' || true

# --- 3. Los puentes ----------------------------------------------------------
# Mueren solos cuando el pod al que apuntan se reinicia, y no avisan: el
# sintoma es la interfaz diciendo que no alcanza al orquestador.
log "Rehaciendo los puentes"
pkill -f "kubectl -n $NS port-forward" 2>/dev/null
sleep 1
kubectl -n "$NS" port-forward deploy/orquestador 7012:7012 >/dev/null 2>&1 &
kubectl -n "$NS" port-forward deploy/servidor-mcp 9000:9000 >/dev/null 2>&1 &
# El relay de Hubble es otro programa y va aparte; solo se lanza si falta.
if ! hubble status >/dev/null 2>&1; then
  cilium hubble port-forward >/dev/null 2>&1 &
fi
sleep 3
for par in "7012 orquestador" "9000 servidor-mcp"; do
  set -- $par
  if curl -s --max-time 3 -o /dev/null "http://localhost:$1/" 2>/dev/null; then
    echo "  ok    $1  ($2)"
  else
    echo "  FALLA $1  ($2)"
  fi
done
hubble status >/dev/null 2>&1 && echo "  ok    4245 (relay de hubble)" \
                              || echo "  FALLA 4245 (relay de hubble)"

# --- 4. El frontend ----------------------------------------------------------
# Son archivos estaticos: se compilan y se recargan en el navegador. No reinician
# nada del backend.
log "Compilando la interfaz"
(cd ui && npm run build >/dev/null 2>&1) && echo "  ok" || echo "  FALLA el build"

# --- 5. Lo que tienes que hacer tu -------------------------------------------
log "Te toca a ti"
echo ""
echo "  1. Reinicia la terminal de ui/servidor.py   (Ctrl+C y relanzar)"
echo "     Python no recarga modulos solos: si cambio ui/servidor.py o"
echo "     malla/flujo.py, esa terminal sigue con el codigo viejo."
echo ""
echo "  2. Recarga el navegador."
echo ""
echo "  Comprueba que todo cuadra:"
echo "     bash lab/diagnostico.sh"
echo ""
