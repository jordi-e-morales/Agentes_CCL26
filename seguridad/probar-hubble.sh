#!/usr/bin/env bash
#
# LA AUSENCIA: lo unico que la cascada de trazas no puede enseñar.
#
# El CLAUDE.md §5 pide dos fuentes de observabilidad, y la razon es esta:
#
#   OTel  = lo que la aplicacion DECLARA haber hecho.
#   Hubble = lo que la red VIO, sin preguntarle a nadie.
#
# Un agente comprometido que intenta una conexion fuera del pipeline no va a
# emitir un span confesandola. No por malicia del codigo: simplemente nadie
# instrumenta el camino que no existe. La red la registra igual.
#
# Este script provoca ese intento y luego mira LAS DOS FUENTES:
#   - Hubble: aparece, como trafico sin respuesta.
#   - El archivo del Collector: no aparece nada.
#
# SUSTITUTO, Y SE DICE EN PANTALLA
# --------------------------------
# El cliente es el pod agente-demo (rol=agente), no el agente real, que hoy
# corre en el host. La politica de Cilium mira la ETIQUETA del pod, asi que
# para la red los dos son lo mismo. Pero la regla de honestidad del §6 dice
# que lo sustituido se etiqueta, y aqui se etiqueta.
#
# Uso:  bash seguridad/probar-hubble.sh

set -u
NS=agentes
TRAZAS=/trazas/trazas.json

echo ""
echo "=== 0. Requisitos"
if ! command -v hubble >/dev/null 2>&1; then
  echo "  FALTA la CLI de hubble. Corre ./lab/bootstrap.sh"; exit 1
fi
if ! hubble status >/dev/null 2>&1; then
  echo "  hubble no alcanza el relay. En otra terminal:"
  echo "    cilium hubble port-forward &"
  exit 1
fi
kubectl -n "$NS" get pod agente-demo >/dev/null 2>&1 || {
  echo "  falta el pod de prueba:  kubectl apply -f seguridad/00-pods-de-prueba.yaml"
  exit 1
}
echo "  ok  hubble responde y el pod cliente existe"
echo ""
echo "  NOTA: el cliente es agente-demo, SUSTITUTO del agente real."
echo "        Lleva rol=agente, que es lo unico que la politica mira."

echo ""
echo "=== 1. El agente intenta ir DIRECTO a Postgres"
echo "    Nadie le autorizo esa arista: cilium-l7.yaml no tiene ninguna regla"
echo "    que la permita, a proposito. Que no exista la regla es la politica."
echo ""
# Marca de tiempo para no recoger trafico de corridas anteriores.
DESDE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
sleep 1

kubectl -n "$NS" exec agente-demo -- python3 -c "
import socket
s = socket.socket()
s.settimeout(6)
try:
    s.connect(('postgres.agentes.svc.cluster.local', 5432))
    print('  CONECTO. La politica no esta puesta:')
    print('    kubectl apply -f seguridad/cilium-l7.yaml')
except Exception as e:
    print(f'  no conecto ({type(e).__name__}) — es lo que se esperaba')
" 2>/dev/null

echo ""
echo "=== 2. Fuente A — la red. Hubble lo vio."
echo ""
hubble observe --namespace "$NS" --from-label rol=agente \
  --to-port 5432 --since "$DESDE" --last 10 2>/dev/null | sed 's/^/    /' \
  || echo "    (sin flujos)"
echo ""
echo "    Si aparecen lineas hacia :5432 sin nada de vuelta, eso es el intento."
echo "    Con la politica puesta el veredicto es DROPPED; sin ella, la conexion"
echo "    simplemente no encuentra a nadie. En los dos casos la red LO VIO."

echo ""
echo "=== 3. Fuente B — la aplicacion. Ni una palabra."
echo ""
POD=$(kubectl -n "$NS" get pod -l app=otel-collector -o name 2>/dev/null | head -1)
if [ -z "$POD" ]; then
  echo "    (el Collector no esta corriendo; sin el no hay con que comparar)"
else
  # El contenedor 'lector' existe porque la imagen del Collector es distroless
  # y no trae ni cat.
  encontrados=$(kubectl -n "$NS" exec "$POD" -c lector -- \
    sh -c "grep -c 5432 $TRAZAS 2>/dev/null || true" 2>/dev/null | tr -d '[:space:]')
  echo "    spans que mencionan el puerto 5432:  ${encontrados:-0}"
  echo ""
  echo "    Cero. Y no es un fallo de instrumentacion: el agente no declara el"
  echo "    camino que no tiene. Por eso una sola fuente no alcanza."
fi

echo ""
echo "=== Lo que queda dicho"
echo ""
echo "    La cascada enseña lo que el sistema hizo BIEN, con todo detalle."
echo "    Hubble enseña lo que alguien INTENTO, aunque nadie lo cuente."
echo ""
echo "    Un panel de observabilidad alimentado solo por la aplicacion no puede"
echo "    mostrar una ausencia. Ese es el argumento entero, y hacen falta las"
echo "    dos fuentes en pantalla para poder hacerlo."
echo ""
