#!/usr/bin/env bash
#
# Prueba la lista blanca sobre el servidor MCP.
#
# Que demuestra:
#   1. Lo LEGITIMO sigue funcionando: exporta_evidencia lanza su shell y vive
#   2. Lo NO AUTORIZADO muere con SIGKILL, aunque salga del mismo pod
#   3. El evento queda registrado, con quien lo intento y que quiso correr
#
# El contraste es el demo: el MISMO pod, el MISMO interprete, y la unica
# diferencia es QUE binario se intento ejecutar.
#
# Uso:  bash seguridad/probar-lista-blanca.sh

set -u
NS=agentes
POD_LABEL=app=servidor-mcp
fallas=0

comprobar() {
  if [ "$2" = "$3" ]; then echo "  ok    $1  (=$3)"
  else echo "  FALLA $1: esperaba $2, obtuve $3"; fallas=$((fallas+1)); fi
}

echo ""
echo "=== 0. La politica esta aplicada?"
if kubectl -n "$NS" get tracingpolicynamespaced herramientas-lista-blanca >/dev/null 2>&1; then
  echo "  ok    herramientas-lista-blanca existe"
else
  echo "  FALTA la politica. Aplicala:"
  echo "        kubectl apply -f seguridad/tetragon-herramientas-lista-blanca.yaml"
  exit 1
fi

# ---------------------------------------------------------------------------
# Salvaguarda contra el fallo silencioso.
#
# Si la ruta real del shell no esta en la lista blanca, la politica matara
# tambien lo legitimo. Y si el interprete no coincide con matchBinaries, no
# matara NADA y parecera que todo esta protegido. Las dos formas de fallar son
# invisibles, asi que se comprueban antes de sacar conclusiones.
# ---------------------------------------------------------------------------
echo ""
echo "=== 1. Las rutas reales dentro del pod"
SH_REAL=$(kubectl -n "$NS" exec deploy/servidor-mcp -- readlink -f /bin/sh 2>/dev/null)
PY_REAL=$(kubectl -n "$NS" exec deploy/servidor-mcp -- sh -c 'readlink -f "$(command -v python3)"' 2>/dev/null)
echo "  /bin/sh resuelve a:  $SH_REAL"
echo "  python3 resuelve a:  $PY_REAL"

POL=seguridad/tetragon-herramientas-lista-blanca.yaml
grep -q -- "\"$SH_REAL\"" "$POL" \
  && echo "  ok    el shell esta en la lista blanca" \
  || { echo "  AVISO: $SH_REAL NO esta en la lista blanca de $POL"; echo "         Agregalo o la politica matara tambien lo legitimo."; fallas=$((fallas+1)); }
grep -q -- "\"$PY_REAL\"" "$POL" \
  && echo "  ok    el interprete esta en matchBinaries" \
  || { echo "  AVISO: $PY_REAL NO esta en matchBinaries de $POL"; echo "         Sin eso la politica no dispara Y NO AVISA."; fallas=$((fallas+1)); }

nodo=$(kubectl -n "$NS" get pod -l "$POD_LABEL" -o jsonpath='{.items[0].spec.nodeName}')
tetragon=$(kubectl -n kube-system get pod -l app.kubernetes.io/name=tetragon \
  --field-selector spec.nodeName="$nodo" -o jsonpath='{.items[0].metadata.name}')
mkdir -p ~/capturas
kubectl -n kube-system exec "$tetragon" -c tetragon -- \
  tetra getevents -o json --namespaces "$NS" > ~/capturas/lista-blanca.jsonl 2>/dev/null &
lector=$!
sleep 3

echo ""
echo "=== 2. Lo LEGITIMO: el shell del generador de comprobantes"
LEGITIMO='import subprocess;print(subprocess.run(["/bin/sh","-c","printf hola > /tmp/x"]).returncode)'
salida=$(kubectl -n "$NS" exec deploy/servidor-mcp -- python3 -c "$LEGITIMO" 2>&1 | tail -1)
comprobar "el shell autorizado se ejecuta" "0" "$salida"

echo ""
echo "=== 3. Lo NO AUTORIZADO: otro binario desde el mismo pod"
ATAQUE='import subprocess;print(subprocess.run(["/bin/sh","-c","id"]).returncode)'
salida=$(kubectl -n "$NS" exec deploy/servidor-mcp -- python3 -c "$ATAQUE" 2>&1 | tail -1)
comprobar "el binario no autorizado muere" "-9" "$salida"

echo ""
echo "=== 4. El servidor sigue vivo (murio el hijo, no el servicio)"
reinicios=$(kubectl -n "$NS" get pod -l "$POD_LABEL" -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}')
comprobar "reinicios del contenedor" "0" "$reinicios"

sleep 3
kill "$lector" 2>/dev/null

echo ""
echo "=== 5. Lo que vio el kernel"
jq -c 'select(.process_kprobe != null and .process_kprobe.action == "KPROBE_ACTION_SIGKILL")
       | {pod: .process_kprobe.process.pod.name,
          ejecutaba: .process_kprobe.process.binary,
          quiso_correr: .process_kprobe.args[0].linux_binprm_arg.path,
          politica: .process_kprobe.policy_name}' \
  ~/capturas/lista-blanca.jsonl 2>/dev/null

echo ""
if [ "$fallas" -eq 0 ]; then
  echo "TODO PASO. El ejecutor de herramientas solo corre lo que esta autorizado."
else
  echo "FALLAS: $fallas"
fi
exit "$fallas"
