#!/usr/bin/env bash
#
# CILIUM, EN 30 SEGUNDOS. El mismo comando, dos veces, dos resultados.
#
# Esto no prueba nada nuevo: prueba lo mismo que probar-cilium.sh pero de la
# forma que se entiende sin explicar nada. La sala ve la base contestar, ve
# aplicarse una politica, y ve la base dejar de contestar.
#
# Se toca UNA sola politica, la de entrada a Postgres. No se tocan las de los
# agentes, asi que la deliberacion sigue funcionando mientras esto corre.
#
# Uso:
#   bash seguridad/demo-cilium.sh          <- el antes y el despues
#   bash seguridad/demo-cilium.sh --pausa  <- para entre pasos (con publico)

set -u
NS=agentes
POL=seguridad/cilium-l7.yaml
PAUSA=""
[ "${1:-}" = "--pausa" ] && PAUSA="si"

alto() { [ -n "$PAUSA" ] && { echo ""; read -rp "   [Enter] "; }; }

# Se prueba desde servicio-demo: un pod cualquiera, SIN la etiqueta rol=agente.
# Representa "cualquier cosa que corra en tu cluster".
probar() {
  kubectl -n "$NS" exec servicio-demo -- python3 -c "
import socket
s = socket.socket(); s.settimeout(5)
try:
    s.connect(('postgres.agentes.svc.cluster.local', 5432))
    print('CONECTO  <-- la base acepta la conexion')
except Exception as e:
    print(f'BLOQUEADO  ({type(e).__name__})')
" 2>/dev/null | tail -1
}

kubectl -n "$NS" get pod servicio-demo >/dev/null 2>&1 || {
  echo "Falta el pod de prueba:"
  echo "  kubectl apply -f seguridad/00-pods-de-prueba.yaml"; exit 1; }

echo ""
echo "############################################################"
echo "#  Un pod cualquiera del cluster, hablandole a la base.     #"
echo "############################################################"

echo ""
echo "=== 1. SIN la politica"
kubectl -n "$NS" delete ciliumnetworkpolicy postgres-solo-herramientas \
  --ignore-not-found >/dev/null 2>&1
sleep 2
echo ""
echo "    $(probar)"
echo ""
echo "    Asi esta tu cluster por omision: cualquier pod alcanza la base."
echo "    Y la base tiene la evidencia de todos los casos."
alto

echo ""
echo "=== 2. Se aplica la politica"
echo ""
echo "    Una regla: a Postgres solo le habla el servidor de herramientas."
kubectl apply -f "$POL" >/dev/null
sleep 3
echo ""
echo "    $(probar)"
echo ""
echo "    Mismo pod. Mismo comando. No se reinicio nada."
alto

echo ""
echo "=== 3. Lo que vio la red"
if command -v hubble >/dev/null 2>&1 && hubble status >/dev/null 2>&1; then
  hubble observe --namespace "$NS" --to-port 5432 --last 6 2>/dev/null \
    | sed 's/^/    /'
else
  echo "    (hubble no esta a mano: cilium hubble port-forward &)"
fi

echo ""
echo "=== Y lo que importa"
echo ""
echo "    El agente NUNCA tuvo ese permiso, ni siquiera sin la politica de"
echo "    arriba: su propia regla de salida no incluye la base."
echo ""
echo "    Puede pedirle datos a la herramienta. No puede ir a buscarlos."
echo "    Da igual lo que la inyeccion le convenza de intentar."
echo ""
