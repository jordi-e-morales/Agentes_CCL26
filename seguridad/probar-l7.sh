#!/usr/bin/env bash
#
# Prueba el control de red sobre las aristas del servidor de herramientas.
#
# Usa el pod agente-demo (rol=agente) como cliente. No hace falta el agente
# real: la politica mira la ETIQUETA del pod, no lo que el pod sabe hacer.
#
# Que demuestra, en este orden:
#   1. La arista autorizada funciona:  POST /mcp pasa
#   2. Cilium SI distingue ruta:       GET / se corta con 403
#   3. La arista prohibida no existe:  agente -> postgres no conecta
#   4. LA INCOMODA: dos herramientas distintas se ven IGUAL para la red
#
# Uso:  bash seguridad/probar-l7.sh

set -u
NS=agentes
fallas=0

comprobar() {
  if [ "$2" = "$3" ]; then echo "  ok    $1  (=$3)"
  else echo "  FALLA $1: esperaba $2, obtuve $3"; fallas=$((fallas+1)); fi
}

# El pod cliente no trae curl, asi que se usa urllib. Ademas eso evita un exec,
# que la politica de kernel de los agentes mataria.
pedir() {  # metodo  url  [cuerpo]
  kubectl -n "$NS" exec agente-demo -- python3 -c "
import urllib.request, json, sys
req = urllib.request.Request('$2', method='$1')
req.add_header('Content-Type','application/json')
req.add_header('Accept','application/json, text/event-stream')
cuerpo = ${3:-None}
try:
    r = urllib.request.urlopen(req, data=json.dumps(cuerpo).encode() if cuerpo else None, timeout=8)
    print(r.status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:
    print(type(e).__name__)
" 2>/dev/null | tail -1
}

echo ""
echo "=== 0. Requisitos"
kubectl -n "$NS" get pod agente-demo >/dev/null 2>&1 \
  || { echo "  FALTA agente-demo. Aplica: kubectl apply -f seguridad/00-pods-de-prueba.yaml"; exit 1; }
kubectl -n "$NS" get cnp agentes-salida >/dev/null 2>&1 \
  || { echo "  FALTA la politica. Aplica: kubectl apply -f seguridad/cilium-l7.yaml"; exit 1; }
echo "  ok    agente-demo y las politicas existen"

MCP=http://servidor-mcp.agentes.svc.cluster.local:9000/mcp

echo ""
echo "=== 1. La arista AUTORIZADA: POST /mcp"
INIT='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"prueba","version":"1"}}}'
salida=$(pedir POST "$MCP" "$INIT")
comprobar "POST /mcp pasa" "200" "$salida"

echo ""
echo "=== 2. Cilium SI distingue la ruta: GET / al mismo pod"
salida=$(pedir GET "http://servidor-mcp.agentes.svc.cluster.local:9000/")
comprobar "GET / se corta con 403" "403" "$salida"

echo ""
echo "=== 3. La arista PROHIBIDA: el agente va directo a la base"
salida=$(kubectl -n "$NS" exec agente-demo -- python3 -c "
import socket
s = socket.socket(); s.settimeout(5)
try:
    s.connect(('postgres.agentes.svc.cluster.local', 5432)); print('CONECTO')
except Exception:
    print('BLOQUEADO')
" 2>/dev/null | tail -1)
comprobar "agente -> postgres no conecta" "BLOQUEADO" "$salida"
echo "        (el agente tiene que pasar por la herramienta; no hay atajo)"

echo ""
echo "=== 4. LA INCOMODA: dos herramientas distintas, para la red son iguales"
echo "  Llamando consulta_historial y despues dispone_caso..."
LLAMAR='{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"%s","arguments":%s}}'
# shellcheck disable=SC2059
pedir POST "$MCP" "$(printf "$LLAMAR" consulta_historial '{"sujeto_id":"SUJ-0001"}')" >/dev/null
# shellcheck disable=SC2059
pedir POST "$MCP" "$(printf "$LLAMAR" dispone_caso '{"alerta_id":"ALR-FICTICIA-0001","estado":"cerrada","justificacion":"x"}')" >/dev/null
echo ""
echo "  Lo que Hubble vio de esas dos llamadas:"
hubble observe --namespace "$NS" --to-label app=servidor-mcp --protocol http --last 6 2>/dev/null \
  | sed 's/^/    /' \
  || echo "    (hubble no responde; abre el port-forward: cilium hubble port-forward &)"
echo ""
echo "  Una lee evidencia. La otra CIERRA EL CASO. Para la red son la misma"
echo "  peticion: POST /mcp. Eso es lo que MCP le esconde a la capa 7."

echo ""
if [ "$fallas" -eq 0 ]; then
  echo "TODO PASO. La red gobierna las aristas, pero no la intencion."
else
  echo "FALLAS: $fallas"
fi
exit "$fallas"
