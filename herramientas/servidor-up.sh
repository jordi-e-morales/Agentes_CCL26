#!/usr/bin/env bash
#
# Compila el servidor MCP, lo mete al cluster de kind y lo despliega.
#
# El paso que se olvida siempre es `kind load`: kind corre sus nodos como
# contenedores de Docker con su PROPIO almacen de imagenes, asi que una imagen
# recien compilada en el host NO existe para el cluster. El sintoma es un pod
# en ErrImagePull buscando en Docker Hub una imagen que solo esta a diez
# centimetros de distancia.
#
# Uso:
#   ./herramientas/servidor-up.sh
#   ./herramientas/servidor-up.sh --logs
#   ./herramientas/servidor-up.sh --down

set -euo pipefail
NS=agentes
CLUSTER=agentes
IMAGEN=ccl26/servidor-mcp:dev
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
log() { echo ""; echo "=== $1"; }

case "${1:-}" in
  --logs) exec kubectl -n "$NS" logs -f deploy/servidor-mcp ;;
  --down) kubectl -n "$NS" delete -f "$DIR/00-servidor-mcp.yaml" --ignore-not-found
          echo "servidor-mcp eliminado"; exit 0 ;;
esac

kubectl get nodes >/dev/null 2>&1 || { echo "El cluster no responde: corre ./lab/cluster-up.sh"; exit 1; }

log "Compilando $IMAGEN"
docker build -q -t "$IMAGEN" "$DIR"

log "Metiendo la imagen al cluster de kind"
kind load docker-image "$IMAGEN" --name "$CLUSTER"

log "Desplegando"
kubectl apply -f "$DIR/00-servidor-mcp.yaml" >/dev/null
# Un pod nuevo con la imagen recien cargada: sin esto seguiria corriendo la vieja.
kubectl -n "$NS" rollout restart deploy/servidor-mcp >/dev/null
kubectl -n "$NS" rollout status deploy/servidor-mcp --timeout=180s

log "Comprobando que hable con Postgres"
kubectl -n "$NS" logs deploy/servidor-mcp | head -3

log "Como alcanzarlo"
echo "  Desde otro pod:  http://servidor-mcp.agentes.svc.cluster.local:9000/mcp"
echo ""
echo "  Desde el host, para desarrollar:"
echo "    kubectl -n $NS port-forward deploy/servidor-mcp 9000:9000"
echo ""
echo "  Ahora las dos aristas que importan SI atraviesan el cluster:"
echo "    agente -> servidor-mcp     (Cilium ve POST /mcp, no que tool es)"
echo "    servidor-mcp -> postgres   (Cilium puede permitirla solo a este pod)"
