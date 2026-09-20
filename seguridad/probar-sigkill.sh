#!/usr/bin/env bash
#
# Prueba que el control de kernel funciona, SIN necesitar ningun agente.
#
# Version minima de herramientas/probar_tetragon.sh de la demo v1, recortada
# para que corra contra dos pods pelados en vez de contra seis servicios.
#
# Que demuestra, en este orden:
#   1. Un pod con rol=agente NO puede ejecutar un binario: muere con SIGKILL (-9)
#   2. Otro binario distinto tambien muere: no hay lista negra que esquivar
#   3. Un pod SIN esa etiqueta SI puede ejecutar: la politica discrimina
#   4. Tetragon dejo el evento registrado, con quien lo intento y que quiso correr
#
# El punto 3 es el que convence. La misma orden, dos resultados, y la unica
# diferencia entre los dos pods es una etiqueta.
#
# Uso:  bash seguridad/probar-sigkill.sh

set -u
NS=agentes
fallas=0

comprobar() {  # descripcion  esperado  obtenido
  if [ "$2" = "$3" ]; then
    echo "  ok    $1  (=$3)"
  else
    echo "  FALLA $1: esperaba $2, obtuve $3"
    fallas=$((fallas + 1))
  fi
}

# Intenta DOS binarios distintos. Con uno solo alguien podria pensar que hay
# una lista negra; con dos se ve que lo que se filtra es QUIEN ejecuta, no QUE
# se ejecuta.
INTENTO='
import subprocess
a = subprocess.run(["/bin/sh", "-c", "echo hola"], capture_output=True).returncode
b = subprocess.run(["/usr/bin/env"], capture_output=True).returncode
print(a, b)
'

echo ""
echo "=== 0. La politica esta aplicada?"
if kubectl -n "$NS" get tracingpolicynamespaced agentes-sin-exec >/dev/null 2>&1; then
  echo "  ok    agentes-sin-exec existe"
else
  echo "  FALTA la politica. Aplicala:"
  echo "        kubectl apply -f seguridad/tetragon-agentes-sin-exec.yaml"
  exit 1
fi

# Tetragon corre como DaemonSet: hay que preguntarle al pod que esta en el
# MISMO nodo que el agente, porque cada uno solo ve lo de su maquina.
nodo=$(kubectl -n "$NS" get pod agente-demo -o jsonpath='{.spec.nodeName}')
tetragon=$(kubectl -n kube-system get pod -l app.kubernetes.io/name=tetragon \
  --field-selector spec.nodeName="$nodo" -o jsonpath='{.items[0].metadata.name}')
echo "  info  agente-demo vive en el nodo $nodo; lo observa $tetragon"

mkdir -p ~/capturas
kubectl -n kube-system exec "$tetragon" -c tetragon -- \
  tetra getevents -o json --namespaces "$NS" > ~/capturas/sigkill.jsonl 2>/dev/null &
lector=$!
sleep 3

echo ""
echo "=== 1. Pod CON rol=agente intenta ejecutar binarios"
salida=$(kubectl -n "$NS" exec agente-demo -- python3 -c "$INTENTO" 2>&1 | tail -1)
comprobar "/bin/sh muere con SIGKILL"     "-9" "$(echo "$salida" | awk '{print $1}')"
comprobar "/usr/bin/env tambien muere"    "-9" "$(echo "$salida" | awk '{print $2}')"

echo ""
echo "=== 2. Pod SIN esa etiqueta hace lo mismo y le sale bien"
salida=$(kubectl -n "$NS" exec servicio-demo -- python3 -c "$INTENTO" 2>&1 | tail -1)
comprobar "/bin/sh se ejecuta"            "0"  "$(echo "$salida" | awk '{print $1}')"
comprobar "/usr/bin/env se ejecuta"       "0"  "$(echo "$salida" | awk '{print $2}')"

echo ""
echo "=== 3. El pod del agente sigue vivo (murio el hijo, no el servicio)"
reinicios=$(kubectl -n "$NS" get pod agente-demo -o jsonpath='{.status.containerStatuses[0].restartCount}')
comprobar "reinicios del contenedor"      "0"  "$reinicios"

sleep 3
kill "$lector" 2>/dev/null

echo ""
echo "=== 4. Lo que vio el kernel"
jq -c 'select(.process_kprobe != null and .process_kprobe.action == "KPROBE_ACTION_SIGKILL")
       | {pod: .process_kprobe.process.pod.name,
          ejecutaba: .process_kprobe.process.binary,
          quiso_correr: .process_kprobe.args[0].linux_binprm_arg.path,
          politica: .process_kprobe.policy_name}' \
  ~/capturas/sigkill.jsonl 2>/dev/null
n=$(jq -c 'select(.process_kprobe.action == "KPROBE_ACTION_SIGKILL")' ~/capturas/sigkill.jsonl 2>/dev/null | wc -l)
comprobar "eventos SIGKILL registrados (>=2)" "si" "$([ "$n" -ge 2 ] && echo si || echo no)"

echo ""
if [ "$fallas" -eq 0 ]; then
  echo "TODO PASO. El segmento 6 tiene su capa de kernel en pie."
else
  echo "FALLAS: $fallas"
fi
exit "$fallas"
