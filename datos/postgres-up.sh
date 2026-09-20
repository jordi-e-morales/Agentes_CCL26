#!/usr/bin/env bash
#
# Levanta PostgreSQL en el cluster con el esquema y la semilla ya cargados.
#
# Idempotente, y con una propiedad util: como PGDATA vive en un emptyDir y el
# esquema se monta en /docker-entrypoint-initdb.d, CADA POD NUEVO reconstruye la
# base desde cero. Asi que este script tambien sirve de "reset": si cambias los
# .sql y lo vuelves a correr, la base queda con lo nuevo, sin migraciones.
#
# Uso:
#   ./datos/postgres-up.sh            levanta o actualiza
#   ./datos/postgres-up.sh --reset    fuerza un pod nuevo (base limpia)
#   ./datos/postgres-up.sh --psql     abre una sesion interactiva
#   ./datos/postgres-up.sh --down     lo baja

set -euo pipefail

NS=agentes
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() { echo ""; echo "=== $1"; }
sql() { kubectl -n "$NS" exec -i deploy/postgres -- psql -U triage -d triage -qtA "$@"; }

case "${1:-}" in
  --down)
    kubectl -n "$NS" delete -f "$DIR/00-postgres.yaml" --ignore-not-found
    kubectl -n "$NS" delete configmap postgres-arranque --ignore-not-found
    echo "Postgres eliminado"; exit 0 ;;
  --psql)
    exec kubectl -n "$NS" exec -it deploy/postgres -- psql -U triage -d triage ;;
esac

command -v kubectl >/dev/null || { echo "Falta kubectl: corre ./lab/bootstrap.sh"; exit 1; }
kubectl get nodes >/dev/null 2>&1 || { echo "El cluster no responde: corre ./lab/cluster-up.sh"; exit 1; }

# ---------------------------------------------------------------------------
# El ConfigMap se GENERA desde los .sql, no se escribe a mano.
#
# Asi los archivos del repo son la unica fuente de verdad. Si el SQL viviera
# copiado dentro del YAML, tarde o temprano las dos copias divergirian y el
# error aparecerian en el peor momento.
# ---------------------------------------------------------------------------
log "Generando el ConfigMap desde los .sql"
kubectl create configmap postgres-arranque \
  --namespace "$NS" \
  --from-file="$DIR/01-esquema.sql" \
  --from-file="$DIR/02-semilla.sql" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "  01-esquema.sql  y  02-semilla.sql"

log "Aplicando los manifiestos"
kubectl apply -f "$DIR/00-postgres.yaml" >/dev/null

# Si el pod ya existia, su base se construyo con el SQL VIEJO: el initdb solo
# corre en un directorio vacio. Un pod nuevo es la unica forma de recargar.
if [ "${1:-}" = "--reset" ] || [ -n "${FORZAR_RESET:-}" ]; then
  log "Forzando un pod nuevo (base limpia)"
  kubectl -n "$NS" rollout restart deploy/postgres >/dev/null
fi

log "Esperando a que Postgres este listo"
kubectl -n "$NS" rollout status deploy/postgres --timeout=180s

# ---------------------------------------------------------------------------
# Verificacion
# ---------------------------------------------------------------------------
log "Lo que hay cargado"
sql -c "
  SELECT 'sujetos', count(*) FROM sujetos
  UNION ALL SELECT 'alertas', count(*) FROM alertas
  UNION ALL SELECT 'eventos', count(*) FROM eventos
  UNION ALL SELECT 'listas', count(*) FROM listas
  UNION ALL SELECT 'fragmentos', count(*) FROM fragmentos
  UNION ALL SELECT 'disposiciones', count(*) FROM disposiciones
  ORDER BY 1;" | sed 's/|/  /' | sed 's/^/  /'

# ---------------------------------------------------------------------------
# LA PRUEBA DE NEUTRALIDAD, que es el momento de 30 segundos de la sesion.
#
# La MISMA consulta, sobre la MISMA tabla, para dos dominios que no se parecen.
# Lo unico distinto es el contenido de `atributos`.
# ---------------------------------------------------------------------------
log "La misma consulta, dos dominios (esto es la lamina)"
CONSULTA="SELECT tipo, atributos FROM eventos WHERE sujeto_id = '%s' ORDER BY momento;"

echo ""
echo "  SUJ-0001  (organizacion, monitoreo transaccional)"
# shellcheck disable=SC2059
sql -c "$(printf "$CONSULTA" SUJ-0001)" | sed 's/^/    /'
echo ""
echo "  SUJ-0002  (host, alertas de SOC)"
# shellcheck disable=SC2059
sql -c "$(printf "$CONSULTA" SUJ-0002)" | sed 's/^/    /'
echo ""
echo "  Ni una columna distinta. Ni una linea de codigo distinta."

log "Como alcanzarlo"
echo "  Desde otro pod del cluster:"
echo "    postgres.agentes.svc.cluster.local:5432   (base triage, usuario triage)"
echo ""
echo "  Desde el host, para desarrollar:"
echo "    kubectl -n $NS port-forward deploy/postgres 5432:5432"
echo ""
echo "  Sesion interactiva:"
echo "    ./datos/postgres-up.sh --psql"
