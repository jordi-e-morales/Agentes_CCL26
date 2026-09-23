#!/usr/bin/env bash
#
# Por que Splunk no ve las trazas. Los cuatro sitios donde se puede romper,
# en orden, del mas cercano al mas lejano.
#
# Uso:  bash observabilidad/splunk-diagnostico.sh

set -uo pipefail
NS=agentes
ok() { echo "  ok    $1"; }
mal() { echo "  MAL   $1"; }
nota() { echo "        $1"; }

echo ""
echo "=== 1. Llegan spans AL COLLECTOR?"
# Si esto no crece con cada deliberacion, el problema no es Splunk: es que los
# agentes no estan exportando, y Splunk no tiene nada que recibir.
n=$(kubectl -n "$NS" exec deploy/otel-collector -c lector -- \
  sh -c "wc -l < /trazas/trazas.json 2>/dev/null || echo 0" 2>/dev/null | tr -d ' ')
if [ "${n:-0}" -gt 0 ]; then
  ok "el archivo tiene $n lineas de trazas"
  nota "Si ese numero no sube tras deliberar, el problema esta ANTES de Splunk."
else
  mal "el Collector no ha recibido ningun span"
  nota "Lanza una deliberacion en la interfaz y repite esto."
  nota "Sin spans, Splunk no puede enseñar nada."
fi

echo ""
echo "=== 2. Que dice el exportador"
salida=$(kubectl -n "$NS" logs deploy/otel-collector -c collector --tail=300 2>/dev/null \
  | grep -iE "otlp_?http|splunk|export|fail|retry|drop|401|403|404|x509|certificate" \
  | tail -12)
if [ -n "$salida" ]; then
  echo "$salida" | sed 's/^/        /'
else
  nota "(el exportador no ha dicho nada: ni exito ni error)"
  nota "Eso pasa cuando todavia no ha intentado enviar nada."
fi

echo ""
echo "=== 3. Que hay configurado"
kubectl -n "$NS" get cm otel-collector-config -o yaml 2>/dev/null \
  | grep -E "traces_endpoint|exporters: \[" | sed 's/^ */        /'

echo ""
echo "=== 4. El cluster alcanza el destino"
HOST=$(kubectl -n "$NS" get cm otel-collector-config -o yaml 2>/dev/null \
  | grep traces_endpoint | head -1 | sed -E 's#.*https?://##; s#/.*##')
if [ -n "$HOST" ]; then
  r=$(kubectl -n "$NS" exec deploy/otel-collector -c lector -- \
    sh -c "nslookup $HOST >/dev/null 2>&1 && nc -z -w 6 $HOST 443 >/dev/null 2>&1 && echo si || echo no" \
    2>/dev/null | tail -1)
  [ "$r" = "si" ] && ok "$HOST resuelve y acepta conexiones en el 443" \
                  || mal "$HOST no responde desde el cluster"
fi

echo ""
echo "=== Como leer esto"
echo ""
echo "    1 vacio            -> no es Splunk: los agentes no exportan"
echo "    2 con 401/403      -> el token no vale o no tiene alcance INGEST"
echo "    2 con 404          -> la ruta del endpoint no es esa"
echo "    2 con x509         -> un proxy intercepta el TLS"
echo "    2 vacio y 1 lleno  -> recibio spans pero no intento enviarlos"
echo "    todo ok y Splunk vacio -> mirar permisos o el sitio de la UI"
echo ""
