# Los agentes de la malla, como imagen. UNA imagen para los dos roles.
#
# POR QUE TIENEN QUE SER PODS
# ---------------------------
# Esto no es despliegue por gusto: es el requisito del que cuelgan dos
# segmentos enteros.
#
# Con los agentes como procesos en el host, el salto lateral
# investigador -> defensor es `localhost:7010 -> localhost:7011`. Nunca toca la
# red del cluster. Y entonces:
#
#   - Cilium no puede gobernar esa arista: no hay paquete que le pase por
#     delante.
#   - Hubble no puede dibujarla: el grafo de la malla sale vacio.
#   - Las politicas que seleccionan `rol: agente` no aplican a nadie real, y se
#     acaban probando con pods sustitutos.
#
# El §3 descarta SLIM con este argumento textual: "con A2A la arista es HTTP
# directo entre dos pods, visible y gobernable". Eso solo es cierto si los
# agentes SON pods. La v1 los tenia asi (deploy/k8s/agentes.yaml) y esta imagen
# recupera ese patron.
#
# Construir y cargar en kind:
#   ./malla/agentes-up.sh
#
# La imagen base fija la ruta del interprete, que es lo que mira la
# TracingPolicy de Tetragon. Con python:3.13-slim es /usr/local/bin/python3.13,
# igual que en el servidor de herramientas.
FROM python:3.13-slim

# Sin .pyc y sin bufer: el sistema de archivos sera de solo lectura, y
# `kubectl logs` tiene que mostrar los sobres A2A al momento. Esos sobres son
# material de la sesion, no depuracion.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

# Las dependencias primero: cambian mucho menos que el codigo, asi que esta
# capa se reaprovecha entre compilaciones.
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir \
      "mcp" "openai" "starlette" "uvicorn" "httpx" \
      "opentelemetry-sdk" "opentelemetry-exporter-otlp-proto-http"

# Solo lo que el agente necesita para correr.
#
# Las tarjetas van dentro porque el agente las sirve en
# /.well-known/agent-card.json, y el descubrimiento del segmento 2 es
# literalmente un GET a esa ruta. Si faltaran, el segmento se queda sin objeto.
COPY malla/__init__.py         /app/malla/__init__.py
COPY malla/agente.py          /app/malla/agente.py
COPY malla/flujo.py           /app/malla/flujo.py
COPY malla/servidor_orquestador.py /app/malla/servidor_orquestador.py
COPY malla/tarjetas/          /app/malla/tarjetas/
COPY observabilidad/          /app/observabilidad/

# Que `from observabilidad import trazas` funcione, y que RAIZ apunte a /app.
ENV PYTHONPATH=/app

EXPOSE 7010

# Sin root. Un agente es justo el componente que se asume comprometido en el
# segmento 6: cuanto menos pueda hacer dentro de su contenedor, mejor.
RUN useradd --create-home --uid 10001 agente
USER 10001

# El rol se pasa en el manifiesto, que es lo que hace que una sola imagen sirva
# para los TRES. Es el insight #1 de la sesion hecho despliegue: mismo codigo,
# mismos pesos, identidades distintas.
#
# Los dos agentes usan este ENTRYPOINT con `args: ["--rol", "..."]`.
# El router lo reemplaza con `command:` porque arranca otro programa
# (servidor_router.py), pero sale de la misma imagen.
ENTRYPOINT ["python", "/app/malla/agente.py", "--puerto", "7010"]
