# El servidor MCP de herramientas, como imagen.
#
# POR QUE TIENE QUE SER UN POD Y NO UN PROCESO EN EL HOST
# -------------------------------------------------------
# Corriendo en el host funciona igual de bien para desarrollar, y no sirve para
# el demo. Cilium solo gobierna aristas que atraviesan el cluster, y Tetragon
# solo ve los `exec` que ocurren dentro de el. Con el servidor fuera, los
# segmentos 4 y 6 se quedan sin objeto.
#
# La imagen base fija la ruta del interprete, que es lo que mira la
# TracingPolicy. Con python:3.13-slim es /usr/local/bin/python3.13.
FROM python:3.13-slim

# /bin/sh y coreutils ya vienen en la imagen: exporta_evidencia los necesita
# para lanzar un proceso hijo de verdad, que es el punto de esa herramienta.

WORKDIR /app

# Las dependencias primero: cambian mucho menos que el codigo, asi que esta
# capa se reaprovecha entre compilaciones.
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir "mcp" "psycopg[binary]"

COPY servidor_mcp.py /app/servidor_mcp.py

EXPOSE 9000

# Sin usuario root: no hace falta para nada de lo que hace, y un ejecutor de
# herramientas es justo donde menos conviene sobrar de privilegios.
RUN useradd --create-home --uid 10001 herramientas
USER herramientas

CMD ["python", "/app/servidor_mcp.py", "--host", "0.0.0.0", "--puerto", "9000"]
