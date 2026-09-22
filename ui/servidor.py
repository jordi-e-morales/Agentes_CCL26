#!/usr/bin/env python3
"""El backend de la interfaz. Sirve la pagina y transmite lo que va pasando.

POR QUE PYTHON Y NO NODE
------------------------
El repo del que se toma el diseño visual (agntcy-mortgage-demo) era Node de
punta a punta. Aqui no: ya hay Python que sabe hablar A2A, MCP y Postgres, y
`starlette` viene gratis con `mcp`. Reescribir esa capa en otro lenguaje seria
duplicarla, y ademas una cosa mas que instalar en la instancia del dia 4.

React y Vite se quedan donde importan: el control visual del frontend.

DE DONDE SALEN LOS DATOS, QUE ES LO QUE IMPORTA
------------------------------------------------
De la malla de verdad. Este servidor no fabrica nada.

Esa distincion no es purismo. El segmento 5 argumenta que OTel es la
AUTODECLARACION de la aplicacion, y que por eso hace falta Hubble como segunda
fuente independiente. Si la cascada la dibujara esta misma aplicacion con datos
que ella se invento, ese argumento se cae: seria la aplicacion calificando su
propio examen.

El CLAUDE.md §8 lo dice mas corto: sin codigo de simulacion.

Uso:
    .venv/bin/python ui/servidor.py
    # y en otra terminal, para desarrollar el frontend:  cd ui && npm run dev
"""

import argparse
import asyncio
import hashlib
import json
import pathlib
import sys

from starlette.applications import Starlette
from starlette.middleware.cors import CORSMiddleware
from starlette.responses import FileResponse, JSONResponse, StreamingResponse
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles

RAIZ = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ))
from malla import flujo  # noqa: E402

DIST = pathlib.Path(__file__).parent / "dist"


async def deliberar(req):
    """Transmite la deliberacion segun ocurre, por Server-Sent Events.

    Se transmite en vivo y no se devuelve al final a proposito: el valor
    didactico esta en VER la secuencia -descubrir, elegir, despachar, recoger
    evidencia, saltar al vecino- y no en el resultado. Un volcado final
    convierte un proceso en un parrafo.
    """
    alerta = req.query_params.get("alerta", "ALR-FICTICIA-0001")
    sujeto = req.query_params.get("sujeto", "SUJ-0001")
    busca = req.query_params.get("busca", "riesgo")

    async def eventos():
        try:
            async for evento in flujo.deliberar(alerta, sujeto, busca):
                yield f"data: {json.dumps(evento, ensure_ascii=False)}\n\n"
        except Exception as e:
            # El error tambien se transmite: una interfaz que se queda en
            # blanco sin decir por que es peor que un error en pantalla.
            yield f"data: {json.dumps({'tipo': 'error', 'mensaje': f'{type(e).__name__}: {e}'})}\n\n"

    return StreamingResponse(eventos(), media_type="text/event-stream", headers={
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",   # que nadie almacene por el camino
    })


async def agentes(_req):
    """Las Agent Cards tal cual las publica cada agente. Segmento 2."""
    return JSONResponse(await flujo.descubrir())


async def gpu(_req):
    """La salida CRUDA de nvidia-smi.

    POR QUE ESTO VALE MAS DE LO QUE PARECE
    ---------------------------------------
    Es el segmento 1 hecho evidencia. Mientras los dos agentes deliberan, en la
    tabla se ve UN SOLO proceso de Python ocupando la GPU. No dos.

    Ahi esta el insight #1 sin necesidad de explicarlo: los agentes no son
    modelos. Son dos prompts y dos identidades sobre los mismos pesos, en el
    mismo proceso, en la misma tarjeta. La sala lo ve en una tabla que no
    dibujamos nosotros.

    Se devuelve tal cual la imprime nvidia-smi, sin reformatear: es de las
    pocas pantallas que un arquitecto reconoce al instante.
    """
    async def correr(*cmd):
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        salida, _ = await asyncio.wait_for(proc.communicate(), timeout=8)
        return salida.decode(errors="replace")

    try:
        salida = await correr("nvidia-smi")
        # Ademas de la tabla cruda, las CIFRAS SUELTAS.
        #
        # La tabla es la prueba -nadie sospecha de nvidia-smi- pero proyectada
        # obliga a buscar el dato entre marcos ascii. Las cifras van aparte para
        # poder ponerlas grandes, y la tabla se queda debajo como respaldo.
        csv = await correr(
            "nvidia-smi",
            "--query-gpu=utilization.gpu,memory.used,memory.total,temperature.gpu",
            "--format=csv,noheader,nounits")
        campos = [c.strip() for c in csv.strip().split(",")]
        cifras = {}
        if len(campos) >= 4:
            cifras = {"util": campos[0], "usada": campos[1],
                      "total": campos[2], "temp": campos[3]}
        # Cuantos procesos usan la GPU. Que sea UNO es el insight #1.
        procs = await correr("nvidia-smi",
                             "--query-compute-apps=pid", "--format=csv,noheader")
        cifras["procesos"] = len([l for l in procs.splitlines() if l.strip()])
        return JSONResponse({"hay_gpu": True, "salida": salida, "cifras": cifras})
    except FileNotFoundError:
        return JSONResponse({"hay_gpu": False,
                             "salida": "nvidia-smi no esta en esta maquina."})
    except Exception as e:
        return JSONResponse({"hay_gpu": False,
                             "salida": f"no se pudo consultar la GPU: {type(e).__name__}: {e}"})


async def prompts(_req):
    """Los prompts de los agentes, tal cual estan en el codigo.

    Se enseñan porque SON la respuesta al insight #1. Dos agentes sobre los
    mismos pesos, en el mismo proceso, en la misma GPU -y uno acusa mientras el
    otro defiende-. La diferencia entera cabe en estos dos parrafos.

    Se leen del modulo, no de una copia: si alguien cambia el prompt y no
    actualiza la interfaz, la interfaz estaria mintiendo sobre lo unico que
    esta sesion afirma que importa.
    """
    from malla.agente import ROLES
    return JSONResponse([
        {"rol": rol, "prompt": cfg["prompt"], "vecino": cfg["vecino"]}
        for rol, cfg in ROLES.items()
    ])


def version_del_flujo() -> str:
    """Huella de malla/flujo.py, que este proceso importo AL ARRANCAR.

    Existe por el mismo motivo que la de los agentes: Python no recarga modulos
    solos. Se cambia el flujo, se olvida reiniciar esta terminal, y el sintoma
    es que unos pasos "no salen" -indistinguible de que el flujo se rompiera-.
    Ya costo varios intentos.
    """
    return hashlib.sha256(
        (RAIZ / "malla" / "flujo.py").read_bytes()
    ).hexdigest()[:12]


async def eventos_kernel(_req):
    """Lo que Tetragon vio: los procesos que el kernel mato.

    Mismas dos trampas que documenta seguridad/ver-eventos.sh y por las que
    `tetra getevents` a secas no sirve: transmite en vivo en vez de consultar el
    pasado, y hay un Tetragon por NODO que solo ve lo de su maquina.

    Aqui se lee el archivo de exportacion del nodo donde vive el servidor de
    herramientas, que es donde ocurren los exec que importan.
    """
    async def kubectl(*args):
        proc = await asyncio.create_subprocess_exec(
            "kubectl", *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        salida, _ = await asyncio.wait_for(proc.communicate(), timeout=10)
        return salida.decode(errors="replace").strip()

    try:
        nodo = await kubectl("-n", "agentes", "get", "pod", "-l", "app=servidor-mcp",
                             "-o", "jsonpath={.items[0].spec.nodeName}")
        if not nodo:
            return JSONResponse({"hay": False, "motivo": "el servidor MCP no esta desplegado"})
        pod = await kubectl("-n", "kube-system", "get", "pod",
                            "-l", "app.kubernetes.io/name=tetragon",
                            "--field-selector", f"spec.nodeName={nodo}",
                            "-o", "jsonpath={.items[0].metadata.name}")
        if not pod:
            return JSONResponse({"hay": False, "motivo": f"no hay Tetragon en {nodo}"})
        crudo = await kubectl("-n", "kube-system", "exec", pod, "-c", "tetragon", "--",
                              "sh", "-c", "cat /var/run/cilium/tetragon/eventos.log")
        muertes = []
        for linea in crudo.splitlines():
            try:
                ev = json.loads(linea)
            except Exception:
                continue
            k = ev.get("process_kprobe")
            if not k or k.get("action") != "KPROBE_ACTION_SIGKILL":
                continue
            muertes.append({
                "hora": ev.get("time"),
                "pod": (k.get("process", {}).get("pod") or {}).get("name"),
                "ejecutaba": k.get("process", {}).get("binary"),
                "quiso_correr": (k.get("args") or [{}])[0]
                                .get("linux_binprm_arg", {}).get("path"),
                "politica": k.get("policy_name"),
            })
        # Se devuelven mas de las que se pintan: la interfaz necesita saber
        # cuales ya existian ANTES de la corrida para no mezclarlas con las de
        # ahora. El archivo de exportacion acumula desde que arranco Tetragon.
        return JSONResponse({"hay": True, "nodo": nodo, "muertes": muertes[-50:]})
    except Exception as e:
        return JSONResponse({"hay": False, "motivo": f"{type(e).__name__}: {e}"})


async def trazas_recientes(_req):
    """La ultima traza completa, como arbol. Es la cascada del segmento 5.

    Se lee del archivo que escribe el exportador `file` del Collector, no de
    Splunk. Asi la cascada se dibuja sin internet y sin credenciales, y Splunk
    queda como la validacion externa en vez de ser el unico sitio donde mirar.
    """
    async def kubectl(*args):
        proc = await asyncio.create_subprocess_exec(
            "kubectl", *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL)
        salida, _ = await asyncio.wait_for(proc.communicate(), timeout=15)
        return salida.decode(errors="replace")

    def atributo(span, clave):
        for a in span.get("attributes", []):
            if a.get("key") == clave:
                v = a.get("value", {})
                return v.get("stringValue") or v.get("intValue") or v.get("doubleValue")
        return None

    try:
        crudo = await kubectl("-n", "agentes", "exec", "deploy/otel-collector", "--",
                              "cat", "/trazas/trazas.json")
        spans = []
        for linea in crudo.splitlines():
            try:
                d = json.loads(linea)
            except Exception:
                continue
            for rs in d.get("resourceSpans", []):
                servicio = None
                for a in rs.get("resource", {}).get("attributes", []):
                    if a.get("key") == "service.name":
                        servicio = a.get("value", {}).get("stringValue")
                for ss in rs.get("scopeSpans", []):
                    for sp in ss.get("spans", []):
                        ini = int(sp.get("startTimeUnixNano", 0))
                        fin = int(sp.get("endTimeUnixNano", 0))
                        spans.append({
                            "trace": sp.get("traceId"),
                            "id": sp.get("spanId"),
                            "padre": sp.get("parentSpanId") or None,
                            "nombre": sp.get("name"),
                            "servicio": servicio,
                            "ini": ini, "fin": fin,
                            "ms": round((fin - ini) / 1e6, 1) if fin > ini else 0,
                            "operacion": atributo(sp, "gen_ai.operation.name"),
                            "herramienta": atributo(sp, "gen_ai.tool.name"),
                            "entrada": atributo(sp, "gen_ai.usage.input_tokens"),
                            "salida": atributo(sp, "gen_ai.usage.output_tokens"),
                        })
        if not spans:
            return JSONResponse({"hay": False,
                                 "motivo": "el Collector no ha recibido spans todavia"})
        # La traza mas reciente: la del span que empezo mas tarde.
        ultima = max(spans, key=lambda x: x["ini"])["trace"]
        de_esa = [x for x in spans if x["trace"] == ultima]
        t0 = min(x["ini"] for x in de_esa)
        total = max(x["fin"] for x in de_esa) - t0
        for x in de_esa:
            # Posicion y ancho en porcentaje: con eso la interfaz dibuja las
            # barras sin tener que saber nada de nanosegundos.
            x["desde_pct"] = round((x["ini"] - t0) / total * 100, 2) if total else 0
            x["ancho_pct"] = round((x["fin"] - x["ini"]) / total * 100, 2) if total else 0
        de_esa.sort(key=lambda x: x["ini"])
        return JSONResponse({"hay": True, "trace": ultima,
                             "total_ms": round(total / 1e6, 1), "spans": de_esa})
    except Exception as e:
        return JSONResponse({"hay": False, "motivo": f"{type(e).__name__}: {e}"})


async def salud(_req):
    return JSONResponse({"ok": True, "version_flujo": version_del_flujo()})


async def indice(_req):
    """Cualquier ruta desconocida devuelve la pagina: es una SPA."""
    if (DIST / "index.html").exists():
        return FileResponse(DIST / "index.html")
    return JSONResponse(
        {"error": "La interfaz no esta compilada.",
         "como": "cd ui && npm install && npm run build"},
        status_code=503,
    )


rutas = [
    Route("/api/salud", salud),
    Route("/api/gpu", gpu),
    Route("/api/eventos-kernel", eventos_kernel),
    Route("/api/trazas", trazas_recientes),
    Route("/api/prompts", prompts),
    Route("/api/agentes", agentes),
    Route("/api/deliberar", deliberar),
]
if (DIST / "assets").exists():
    rutas.append(Mount("/assets", StaticFiles(directory=DIST / "assets")))
rutas.append(Route("/{resto:path}", indice))

app = Starlette(routes=rutas)

# CORS solo para desarrollo: con `npm run dev` el frontend vive en otro puerto.
# En produccion la pagina la sirve este mismo proceso y no hace falta.
app.add_middleware(CORSMiddleware, allow_origins=["http://localhost:5173"],
                   allow_methods=["*"], allow_headers=["*"])


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Backend de la interfaz")
    p.add_argument("--puerto", type=int, default=8080)
    a = p.parse_args()
    import uvicorn
    print(f"Interfaz en http://localhost:{a.puerto}  (flujo {version_del_flujo()})")
    if not (DIST / "index.html").exists():
        print("  (la pagina aun no esta compilada: cd ui && npm install && npm run build)")
    uvicorn.run(app, host="0.0.0.0", port=a.puerto, log_level="warning")
