#!/usr/bin/env bash
#
# Lo que vio el kernel. Es el panel del final del segmento 6.
#
# POR QUE NO SIRVE "tetra getevents" A SECAS
# ------------------------------------------
# Dos motivos, y los dos cuestan un rato descubrirlos:
#
#   1. getevents TRANSMITE EN VIVO. No consulta el pasado, asi que un
#      `| grep | tail` se queda esperando para siempre y no imprime nada.
#      Para ver lo que YA paso hay que leer el archivo de exportacion.
#
#   2. Tetragon es un DaemonSet: un pod por nodo, y cada uno solo ve lo de SU
#      maquina. `ds/tetragon` elige uno cualquiera, que puede no ser donde
#      corre el pod que te interesa. Hay que preguntarle al del nodo correcto.
#
# Uso:
#   bash seguridad/ver-eventos.sh              los ultimos SIGKILL
#   bash seguridad/ver-eventos.sh --seguir     en vivo, para la demo
#   bash seguridad/ver-eventos.sh --todo       todo, no solo los SIGKILL

set -u
NS=agentes
LOG=/var/run/cilium/tetragon/eventos.log

# El pod de Tetragon que vigila el nodo donde vive el servidor de herramientas.
nodo=$(kubectl -n "$NS" get pod -l app=servidor-mcp \
        -o jsonpath='{.items[0].spec.nodeName}' 2>/dev/null)
if [ -z "$nodo" ]; then
  echo "No encuentro el pod servidor-mcp. ¿Esta desplegado?"
  exit 1
fi
tetragon=$(kubectl -n kube-system get pod -l app.kubernetes.io/name=tetragon \
            --field-selector spec.nodeName="$nodo" \
            -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [ -z "$tetragon" ]; then
  echo "No hay Tetragon en el nodo $nodo. Corre ./lab/tetragon-up.sh"
  exit 1
fi
echo "Nodo $nodo, observado por $tetragon"

# Deja solo lo legible: quien ejecutaba, que quiso correr, y que politica actuo.
LEGIBLE='select(.process_kprobe != null and .process_kprobe.action == "KPROBE_ACTION_SIGKILL")
         | {hora: .time,
            pod: .process_kprobe.process.pod.name,
            ejecutaba: .process_kprobe.process.binary,
            quiso_correr: .process_kprobe.args[0].linux_binprm_arg.path,
            politica: .process_kprobe.policy_name}'

case "${1:-}" in
  --seguir)
    echo "En vivo. Ctrl-C para parar."
    exec kubectl -n kube-system exec "$tetragon" -c tetragon -- \
      tetra getevents -o json --namespaces "$NS" \
      | jq -c "$LEGIBLE"
    ;;
  --todo)
    exec kubectl -n kube-system exec "$tetragon" -c tetragon -- \
      sh -c "tail -40 $LOG"
    ;;
esac

echo ""
echo "Ultimos procesos que el kernel mato:"
kubectl -n kube-system exec "$tetragon" -c tetragon -- sh -c "cat $LOG" 2>/dev/null \
  | jq -c "$LEGIBLE" 2>/dev/null | tail -10 | sed 's/^/  /'
echo ""
echo "Si no sale nada, es que nada se ha bloqueado todavia. Provocalo:"
echo "  bash seguridad/probar-lista-blanca.sh"
