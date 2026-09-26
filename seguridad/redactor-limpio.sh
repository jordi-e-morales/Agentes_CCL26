#!/usr/bin/env bash
#
# Deja al redactor SIN la etiqueta `rol: agente`, pase lo que pase.
#
# POR QUE HACE FALTA
# ------------------
# La demo del segmento 6 consiste en etiquetar al redactor EN VIVO y ver como
# Cilium empieza a gobernarlo. Si el pod ya viene etiquetado de la corrida
# anterior, no hay nada que demostrar: la politica ya aplica y el 403 sale
# antes de que toques nada.
#
# COMO SE GARANTIZA
# -----------------
# La etiqueta solo puede vivir en el POD, porque el Deployment no la lleva
# (malla/00-redactor.yaml: `labels: {app: redactor}` y nada mas). Asi que un
# pod nuevo nace limpio POR CONSTRUCCION, no porque alguien se acuerde de
# quitarla.
#
# Se reinicia en vez de hacer `kubectl label pod ... rol-` por dos motivos:
#
#   1. Es idempotente de verdad. Funciona igual si la etiqueta estaba, si no
#      estaba, o si alguien dejo el pod a medias.
#   2. Deja Hubble limpio. Quitar la etiqueta cambia la identidad otra vez, y
#      el buffer de Hubble se queda con las DOS -y encima con el mismo nombre
#      de pod-. Con un pod nuevo, los flujos viejos quedan claramente
#      asociados a un pod que ya no existe.
#
# CUANDO CORRERLO: al EMPEZAR, no al terminar. Si se deja para el final y algo
# se corta antes, la siguiente corrida arranca sucia.
#
# Uso:
#   ./seguridad/redactor-limpio.sh
#   ./seguridad/redactor-limpio.sh --verificar    (solo mira, no toca nada)

set -uo pipefail
NS=agentes

mirar() {
  kubectl -n "$NS" get pod -l app=redactor \
    -o jsonpath='{range .items[*]}{.metadata.name}{" rol="}{.metadata.labels.rol}{"\n"}{end}' 2>/dev/null
}

echo ""
echo "=== Como esta ahora"
actual=$(mirar)
[ -z "$actual" ] && { echo "  No hay pod del redactor. Corre ./malla/agentes-up.sh"; exit 1; }
echo "$actual" | sed 's/^/  /'

# La comprobacion que de verdad importa: que el MANIFIESTO siga sin la
# etiqueta. Si alguien la metiera ahi, reiniciar no limpiaria nada y el
# sintoma seria desconcertante.
plantilla=$(kubectl -n "$NS" get deploy redactor \
  -o jsonpath='{.spec.template.metadata.labels.rol}' 2>/dev/null)
if [ -n "$plantilla" ]; then
  echo ""
  echo "  PROBLEMA: la plantilla del Deployment lleva rol=$plantilla."
  echo "  Reiniciar NO va a limpiarlo: cada pod nuevo nacera etiquetado."
  echo "  Quitala de malla/00-redactor.yaml y vuelve a aplicarlo."
  exit 1
fi

if [ "${1:-}" = "--verificar" ]; then
  if echo "$actual" | grep -q "rol=agente"; then
    echo ""
    echo "  SUCIO: el redactor tiene la etiqueta. Corre este script sin --verificar."
    exit 1
  fi
  echo ""
  echo "  LIMPIO: listo para demostrar."
  exit 0
fi

echo ""
echo "=== Pod nuevo desde la plantilla"
kubectl -n "$NS" rollout restart deploy/redactor >/dev/null
kubectl -n "$NS" rollout status deploy/redactor --timeout=90s

echo ""
echo "=== Como queda"
mirar | sed 's/^/  /'
echo ""
echo "  Sin valor despues de rol= quiere decir que no la tiene. Eso es lo bueno."
echo ""
echo "  Para la demo, cuando toque:"
echo "    kubectl -n $NS label pod -l app=redactor rol=agente"
echo ""
