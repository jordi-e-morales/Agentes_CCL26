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
import os
import pathlib
import sys

from starlette.applications import Starlette
from starlette.middleware.cors import CORSMiddleware
from starlette.responses import FileResponse, JSONResponse, StreamingResponse
from starlette.routing import Mount, Route
from starlette.staticfiles import StaticFiles

RAIZ = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ))

DIST = pathlib.Path(__file__).parent / "dist"

# ---------------------------------------------------------------------------
# EL ORQUESTADOR YA NO CORRE AQUI.
#
# Hasta el 2026-09-23 este archivo importaba malla/flujo.py y ejecutaba la
# deliberacion en su propio proceso. Ahora el orquestador es un pod, y esta interfaz
# le hace de proxy.
#
# El motivo es de red, no de arquitectura por gusto: desde el host, las llamadas
# del orquestador a los agentes no atravesaban el cluster, asi que Hubble no podia
# dibujar la flecha que pone la malla en marcha y Cilium no podia gobernar
# orquestador -> agente. El §3 dice que el orquestador "es un agente mas"; como pod eso ya
# es cierto tambien para la politica.
#
# Y LA INTERFAZ SE QUEDO EN EL HOST a proposito. Depende de cuatro cosas que un
# pod no tiene a mano: nvidia-smi (el panel de GPU), y kubectl contra Tetragon y
# el Collector (kernel y cascada), ademas de la CLI de hubble. Moverla habria
# roto el panel de GPU y habria exigido darle permiso para ejecutar comandos
# dentro de pods de kube-system, en una sesion cuyo segmento 6 trata justamente
# de minimo privilegio.
#
# El reparto que queda es el que el §3 ya describia:
#   el orquestador es un AGENTE          -> su sitio es la malla
#   la interfaz es la VENTANA       -> su sitio es el host
# ---------------------------------------------------------------------------
URL_ORQUESTADOR = os.getenv("URL_ORQUESTADOR", "http://localhost:7012")
# Solo para PREGUNTARLE que herramientas publica. La interfaz no llama ninguna:
# quien las usa son los agentes, desde dentro del cluster.
URL_MCP = os.getenv("URL_MCP", "http://localhost:9000/mcp")
# El motor de inferencia, en el host. Solo para PREGUNTARLE que modelo sirve:
# quien lo usa para inferir son los agentes, desde el cluster.
BASE_VLLM = os.getenv("BASE_VLLM", "http://localhost:8000")


async def deliberar(req):
    """Reenvia, tal cual, el SSE que el orquestador va emitiendo.

    SE REENVIA LINEA A LINEA, sin acumular. Una deliberacion tarda ~41 segundos
    y el §12 dice que "la espera es la demo": la sala ve aparecer el
    descubrimiento, la eleccion, el sobre A2A, cada herramienta con su respuesta
    y el salto lateral. Juntar todo para entregarlo al final convertiria eso en
    41 segundos de pantalla quieta, que es el unico modo de que la regla de
    abandono se dispare.
    """
    alerta = req.query_params.get("alerta", "ALR-FICTICIA-0001")
    sujeto = req.query_params.get("sujeto", "SUJ-0001")
    busca = req.query_params.get("busca", "riesgo")

    async def eventos():
        import httpx
        cuerpo = {"alerta": alerta, "sujeto": sujeto, "busca": busca}
        try:
            # timeout=None en la lectura: la deliberacion tarda lo que tarda, y
            # un limite aqui cortaria la transmision a mitad de un debate.
            limites = httpx.Timeout(10.0, read=None)
            async with httpx.AsyncClient(timeout=limites) as cli:
                async with cli.stream("POST", f"{URL_ORQUESTADOR}/deliberar",
                                      json=cuerpo) as r:
                    if r.status_code != 200:
                        yield _sse({"tipo": "error",
                                    "mensaje": f"el orquestador respondio {r.status_code}"})
                        return
                    async for linea in r.aiter_lines():
                        # Las lineas ya vienen en formato SSE del orquestador; se
                        # pasan sin tocarlas. Reinterpretarlas aqui solo añadiria
                        # un sitio mas donde el formato puede desalinearse.
                        if linea:
                            yield linea + "\n"
                        else:
                            yield "\n"
        except Exception as e:
            # El error tambien se transmite: una interfaz que se queda en blanco
            # sin decir por que es peor que un error en pantalla.
            yield _sse({
                "tipo": "error",
                "mensaje": (f"no alcanzo al orquestador en {URL_ORQUESTADOR} "
                            f"({type(e).__name__}). Falta el puente?  "
                            f"kubectl -n agentes port-forward deploy/orquestador 7012:7012"),
            })

    return StreamingResponse(eventos(), media_type="text/event-stream", headers={
        "Cache-Control": "no-cache",
        "X-Accel-Buffering": "no",   # que nadie almacene por el camino
    })


def _sse(evento: dict) -> str:
    return f"data: {json.dumps(evento, ensure_ascii=False)}\n\n"


async def agentes(_req):
    """Las Agent Cards, tal cual las publica cada agente. Segmento 2.

    El descubrimiento lo hace el ROUTER, no esta interfaz, y por eso se le
    pregunta a el. Si lo hiciera aqui, la sala veria un descubrimiento que no es
    el que el orquestador usa para decidir — dos verdades donde debe haber una.
    """
    import httpx
    try:
        async with httpx.AsyncClient(timeout=20.0) as cli:
            r = await cli.get(f"{URL_ORQUESTADOR}/agentes")
            return JSONResponse(r.json())
    except Exception as e:
        return JSONResponse({"error": f"{type(e).__name__}",
                             "detalle": f"no alcanzo al orquestador en {URL_ORQUESTADOR}"},
                            status_code=503)


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


def causa_real(e: BaseException) -> str:
    """Saca la excepcion de dentro de un ExceptionGroup.

    POR QUE HACE FALTA
    ------------------
    El cliente de MCP usa grupos de tareas de anyio, y cuando algo falla dentro
    lo que sale es `ExceptionGroup` — que como mensaje de error no dice
    absolutamente nada. Medido el 2026-09-23: el panel informaba
    "(ExceptionGroup)" cuando la causa real era que faltaba un port-forward.

    Un error que no apunta a su causa cuesta mas que no tener error, porque
    manda a buscar en el sitio equivocado.
    """
    vistos = []
    def hurgar(x, hondo=0):
        if hondo > 4:
            return
        # ExceptionGroup (3.11+) y BaseExceptionGroup llevan .exceptions.
        sub = getattr(x, "exceptions", None)
        if sub:
            for y in sub:
                hurgar(y, hondo + 1)
        else:
            texto = str(x).strip()
            vistos.append(f"{type(x).__name__}" + (f": {texto}" if texto else ""))
    hurgar(e)
    # Se quitan repetidos conservando el orden: un grupo suele traer la misma
    # causa varias veces, una por tarea.
    unicos = list(dict.fromkeys(vistos))
    return " / ".join(unicos[:3]) if unicos else type(e).__name__


# ---------------------------------------------------------------------------
# EL AGENTE NUEVO, Y LO QUE UNA ETIQUETA CONCEDE.
#
# El guion del segmento 6, en tres botones:
#
#   1. El redactor intenta LEER la alerta        -> la red lo corta
#   2. Le pones `rol: agente`                    -> lee, y ademas puede todo
#   3. Se la quitas                              -> vuelve a estar fuera
#
# Va por botones y no por terminal porque alt-tabear en medio de la sesion es
# friccion, y porque cada boton enseña el kubectl que ejecuta: la regla 2 dice
# que la interfaz hace visible el mecanismo, no que lo esconda.
# ---------------------------------------------------------------------------

# Lo que el redactor intenta hacer: leer la alerta que tiene que resumir.
# Es una llamada a herramienta normal y corriente, la misma que hace el
# investigador en cada ronda.
INTENTO_REDACTOR = """
import asyncio, sys
from mcp import Client

def causa(e, hondo=0):
    sub = getattr(e, 'exceptions', None)
    if sub and hondo < 4:
        return causa(sub[0], hondo + 1)
    t = str(e).strip()
    return type(e).__name__ + (': ' + t if t else '')

async def main():
    try:
        async with Client('http://servidor-mcp:9000/mcp') as c:
            r = await c.call_tool('contexto_alerta', {'alerta_id': 'ALR-FICTICIA-0001'})
            n = len(getattr(r, 'content', []) or [])
            print('LEYO la alerta: ' + str(n) + ' bloque(s) de contexto')
    except Exception as e:
        print('NO PUDO: ' + causa(e))

asyncio.run(main())
"""


async def redactor(req):
    """Despliega, consulta, etiqueta y desetiqueta al agente nuevo."""
    async def kubectl(*args, espera=30):
        proc = await asyncio.create_subprocess_exec(
            "kubectl", "-n", "agentes", *args,
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.STDOUT)
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=espera)
        return out.decode(errors="replace").strip()

    accion = req.query_params.get("accion", "estado")

    # El estado actual: existe? tiene la etiqueta?
    if accion == "estado":
        crudo = await kubectl("get", "pod", "-l", "app=redactor",
                              "-o", "custom-columns=N:.metadata.name,"
                                    "R:.metadata.labels.rol,L:.status.containerStatuses[0].ready",
                              "--no-headers")
        if not crudo or "No resources" in crudo:
            return JSONResponse({"existe": False})
        partes = crudo.split()
        return JSONResponse({
            "existe": True,
            "pod": partes[0] if partes else None,
            # kubectl escribe <none> cuando la etiqueta no esta.
            "etiquetado": len(partes) > 1 and partes[1] not in ("<none>", ""),
            "listo": partes[-1] == "true" if partes else False,
        })

    if accion == "intenta":
        salida = await kubectl("exec", "deploy/redactor", "--",
                               "python3", "-c", INTENTO_REDACTOR, espera=40)
        return JSONResponse({
            "comando": "kubectl -n agentes exec deploy/redactor -- python3 "
                       "(llama a contexto_alerta por MCP)",
            "salida": salida,
            # La palabra que la interfaz usa para pintarlo de rojo o verde.
            "logro": "LEYO" in salida,
        })

    if accion in ("etiqueta", "desetiqueta"):
        poner = accion == "etiqueta"
        # SE ETIQUETA EL POD, NO EL DEPLOYMENT, y por dos razones.
        #
        # 1. VELOCIDAD. Tocar el Deployment cambia la plantilla y lanza un
        #    rollout: pod nuevo, diez segundos de espera. En vivo, y dos veces,
        #    eso es una eternidad. Etiquetar el pod surte efecto al instante —
        #    Cilium recalcula su identidad en cuanto cambia la etiqueta.
        #
        # 2. IDEMPOTENCIA. La plantilla se queda SIN la etiqueta, asi que si el
        #    pod se reinicia vuelve solo al estado "antes". El §10 pide que lo
        #    que se enseñe se pueda repetir sin restaurar nada, y asi se cumple
        #    sin hacer nada.
        #
        # Lo que se dice en la sala: en un despliegue de verdad esta etiqueta
        # estaria en el YAML. Aqui se pone a mano para poder enseñar las dos
        # caras en diez segundos.
        crudo = await kubectl("get", "pod", "-l", "app=redactor",
                              "-o", "name", "--no-headers")
        pod = crudo.splitlines()[0].strip() if crudo.strip() else ""
        if not pod:
            return JSONResponse({"error": "no encuentro el pod del redactor"},
                                status_code=404)
        arg = "rol=agente" if poner else "rol-"
        # --overwrite para que volver a ponerla no falle si ya estaba.
        salida = await kubectl("label", "--overwrite", pod, arg)
        return JSONResponse({
            "comando": f"kubectl -n agentes label {pod} {arg}",
            "salida": salida,
            "etiquetado": poner,
        })

    return JSONResponse({"error": f"accion desconocida: {accion}"},
                        status_code=400)


async def modelo(_req):
    """EL MODELO. Uno solo, y es el que sostiene a los tres agentes.

    POR QUE ESTE PANEL EXISTE
    -------------------------
    El segmento 1 afirma que un agente no es un modelo, y hasta ahora enseñaba
    los agentes y del modelo no decia nada. La afirmacion se quedaba en palabra
    del presentador.

    Aqui esta el otro lado: un motor, unos pesos, unas opciones de despliegue.
    Los tres agentes que se ven al lado corren sobre esto.

    TODO SE LEE DEL PROCESO QUE ESTA CORRIENDO. Nada escrito a mano:

      /v1/models        se lo pregunta al propio motor
      docker inspect    los argumentos REALES con los que arranco
      docker logs       lo que midio al cargar los pesos

    Si alguien relanza vLLM con otra cuantizacion, este panel lo dice sin que
    nadie toque la interfaz. Una lista escrita a mano seria una descripcion, y
    podria mentir — la misma regla que aplicamos a las herramientas.
    """
    async def correr(*cmd, espera=8):
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd, stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL)
            out, _ = await asyncio.wait_for(proc.communicate(), timeout=espera)
            return out.decode(errors="replace")
        except Exception:
            return ""

    datos = {"hay": False}

    # 1. Lo que el motor dice de si mismo.
    crudo = await correr("curl", "-s", "--max-time", "5",
                         f"{BASE_VLLM}/v1/models")
    try:
        m = json.loads(crudo)["data"][0]
        datos["id"] = m.get("id")
        datos["ventana"] = m.get("max_model_len")
        datos["hay"] = True
    except Exception:
        return JSONResponse({
            "hay": False,
            "motivo": f"vLLM no responde en {BASE_VLLM}. ¿Está corriendo?",
        })

    # 2. Con que argumentos arranco. Es la parte que la sala no espera ver.
    args = await correr("docker", "inspect", "-f", "{{json .Args}}", "vllm")
    opciones = []
    try:
        lista = json.loads(args)
        i = 0
        while i < len(lista):
            a = lista[i]
            if a.startswith("--"):
                # Un flag puede llevar valor o ser un interruptor. Se mira si lo
                # siguiente es otro flag para no robarle su valor.
                if i + 1 < len(lista) and not lista[i + 1].startswith("--"):
                    opciones.append({"flag": a, "valor": lista[i + 1]}); i += 2
                else:
                    opciones.append({"flag": a, "valor": None}); i += 1
            else:
                i += 1
    except Exception:
        pass
    datos["opciones"] = opciones

    # 3. Lo que MIDIO al arrancar. Son las lineas mas elocuentes del log: dicen
    # cuanta memoria se fue en pesos y cuanta quedo para la cache, que es lo que
    # de verdad limita cuantos agentes pueden hablar a la vez.
    log = await correr("docker", "logs", "--tail", "400", "vllm", espera=10)
    medidas = []
    for linea in log.splitlines():
        b = linea.strip()
        if any(x in b for x in ("model weights took", "KV cache size",
                                "Maximum concurrency", "GPU blocks")):
            # Se quita el prefijo de fecha y nivel, que no aporta en pantalla.
            medidas.append(b.split("] ")[-1][:160])
    datos["medidas"] = medidas[-4:]
    return JSONResponse(datos)


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

    # LAS HERRAMIENTAS SE PREGUNTAN, NO SE ESCRIBEN A MANO.
    #
    # Se le piden al servidor MCP con tools/list, que es la misma llamada que
    # hace un agente al arrancar. Si alguien añade una herramienta, este panel
    # la enseña sin que nadie toque la interfaz — y si el servidor no responde,
    # se dice, en vez de pintar una lista inventada.
    #
    # La regla 2 del §6: la interfaz hace visible el mecanismo. Una lista
    # escrita a mano seria una DESCRIPCION de los permisos, y podria mentir.
    catalogo, fallo = [], None
    try:
        from mcp import Client
        async with Client(URL_MCP) as cli:
            # `.tools`, NO el resultado a secas.
            #
            # list_tools() devuelve un ListToolsResult, que es un modelo de
            # pydantic. Iterarlo directamente NO da las herramientas: da tuplas
            # (campo, valor) de sus atributos, y el error que sale es
            # "'tuple' object has no attribute 'name'" — tres niveles dentro de
            # un ExceptionGroup, o sea invisible.
            #
            # malla/agente.py ya lo hacia bien. Mirarlo habria costado diez
            # segundos y me ahorro media hora de perseguir un port-forward que
            # estaba perfecto.
            # DOS NOMBRES, no uno.
            #
            # Aqui hubo un 500 tonto: se reusaba `catalogo` para el resultado
            # de MCP y para la lista que se construye. El .append reventaba, el
            # except se lo tragaba, y lo que acababa en JSONResponse era el
            # objeto de pydantic — que no es serializable. El error final no se
            # parecia en nada a la causa.
            resultado = await cli.list_tools()
            for h in resultado.tools:
                catalogo.append({
                    "nombre": h.name,
                    "descripcion": (h.description or "").strip().split("\n")[0],
                    # Las dos que ACTUAN, frente a las cuatro que solo leen.
                    # Es la distincion que el segmento 6 necesita resaltar, y la
                    # que Cilium no puede hacer porque las seis van por /mcp.
                    "actua": h.name in ("dispone_caso", "exporta_evidencia"),
                })
    except Exception as e:
        fallo = f"no alcanzo el servidor MCP en {URL_MCP}: {causa_real(e)}"

    salida = [
        {"rol": rol, "prompt": cfg["prompt"], "vecino": cfg["vecino"],
         # Los dos agentes llevan `rol: agente`, y esa etiqueta es la que la
         # politica de red autoriza contra el servidor de herramientas. O sea:
         # las SEIS, sin excepcion. No hay forma de darle solo lectura a uno.
         "herramientas": catalogo, "herramientas_fallo": fallo}
        for rol, cfg in ROLES.items()
    ]

    # EL ORQUESTADOR, que no sale de ROLES porque no es un agente de debate.
    #
    # Va en este panel a proposito: su ausencia de herramientas es el contraste
    # que hace ver que los permisos no vienen del modelo. Mismo motor, misma
    # imagen, y no puede tocar nada.
    from malla import flujo
    salida.append({
        "rol": "orquestador",
        "prompt": flujo.PROMPT_ORQUESTADOR,
        "vecino": None,
        "herramientas": [],
        "herramientas_fallo": None,
        "nota": ("No tiene herramientas. Solo lee lo que dijeron los dos "
                 "agentes y lo resume: no consulta la base, no dispone del "
                 "caso, no ejecuta nada."),
    })
    return JSONResponse(salida)


def version_del_flujo() -> str:
    """Huella de malla/flujo.py TAL COMO ESTA EN DISCO, en esta maquina.

    Sirve para comparar, no para afirmar. Desde que el orquestador corre en un pod,
    el codigo que de verdad se ejecuta es el de la IMAGEN, y su huella la publica
    el propio router en /salud. Los dos numeros tienen que coincidir.

    Si no coinciden, la imagen es vieja:
        ./malla/agentes-up.sh

    Esta comprobacion existe porque el desfase ya mordio tres veces, y nunca da
    un error: da resultados viejos, que es peor.
    """
    return hashlib.sha256(
        (RAIZ / "malla" / "flujo.py").read_bytes()
    ).hexdigest()[:12]


async def version_del_orquestador() -> str | None:
    """Lo que el orquestador dice estar corriendo. None si no responde."""
    import httpx
    try:
        async with httpx.AsyncClient(timeout=5.0) as cli:
            r = await cli.get(f"{URL_ORQUESTADOR}/salud")
            return r.json().get("version_codigo")
    except Exception:
        return None


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
        # -c lector: el contenedor del Collector es distroless y no tiene cat.
        # El lector comparte el volumen y existe solo para esto.
        crudo = await kubectl("-n", "agentes", "exec", "deploy/otel-collector",
                              "-c", "lector", "--",
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


def solo_la_ruta(url: str | None) -> str | None:
    """De la URL entera deja solo la ruta.

    Hubble reporta la URL completa, que es larga y ruidosa en pantalla. Lo que
    la sala tiene que ver es justo lo contrario de ruido: que /mcp se repite
    IGUAL para herramientas distintas. Cortar al camino lo hace evidente.
    """
    if not url:
        return None
    sin_esquema = url.split("?")[0].split("//")[-1]
    _, _, camino = sin_esquema.partition("/")
    return "/" + camino if camino else "/"


async def hubble(_req):
    """Lo que la RED observo. La segunda fuente del CLAUDE.md §5.

    POR QUE NO ES REDUNDANTE CON LA CASCADA
    ----------------------------------------
    La cascada es lo que la aplicacion DECLARA que hizo. Esto es lo que la red
    VIO, sin preguntarle a nadie. Son fuentes independientes, y el valor esta en
    el hueco entre ellas:

      - Si un agente intenta una conexion fuera del pipeline, no va a emitir un
        span confesandolo. Hubble la registra igual.
      - Y al reves: la aplicacion dice "llame a dispone_caso"; la red vio
        "POST /mcp", la MISMA linea que cuando consulto el historial.

    Eso segundo es la lamina: la red autorizo la arista y no pudo ver la
    intencion.
    """
    async def correr(*cmd):
        proc = await asyncio.create_subprocess_exec(
            *cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
        out, err = await asyncio.wait_for(proc.communicate(), timeout=12)
        return out.decode(errors="replace"), err.decode(errors="replace")

    try:
        salida, err = await correr(
            "hubble", "observe", "--namespace", "agentes",
            "--last", "40", "--output", "json")
        if not salida.strip():
            motivo = "hubble no devolvio flujos"
            if "connect" in err.lower() or "relay" in err.lower():
                motivo = ("hubble no alcanza el relay. En otra terminal: "
                          "cilium hubble port-forward &")
            return JSONResponse({"hay": False, "motivo": motivo})

        flujos = []
        for linea in salida.splitlines():
            try:
                f = json.loads(linea)
            except Exception:
                continue
            l7 = (f.get("l7") or {}).get("http") or {}
            origen = f.get("source") or {}
            destino = f.get("destination") or {}
            flujos.append({
                "hora": f.get("time"),
                "de": origen.get("pod_name") or origen.get("identity"),
                "a": destino.get("pod_name") or destino.get("identity"),
                "veredicto": f.get("verdict"),
                "metodo": l7.get("method"),
                "ruta": solo_la_ruta(l7.get("url")),
            })
        # Solo los que llevan informacion de capa 7: son los que enseñan algo.
        con_l7 = [f for f in flujos if f["metodo"]]
        return JSONResponse({"hay": True, "flujos": (con_l7 or flujos)[-12:]})
    except FileNotFoundError:
        return JSONResponse({"hay": False,
                             "motivo": "falta la CLI de hubble (./lab/bootstrap.sh)"})
    except Exception as e:
        return JSONResponse({"hay": False, "motivo": f"{type(e).__name__}: {e}"})


async def salud(_req):
    en_disco = version_del_flujo()
    # Ojo: la del orquestador es la que manda. La del disco solo sirve para saber si
    # la imagen se quedo atras.
    en_router = await version_del_orquestador()
    return JSONResponse({
        "ok": True,
        "version_flujo": en_disco,
        "version_orquestador": en_router,
        "orquestador": URL_ORQUESTADOR,
        "al_dia": (en_router == en_disco) if en_router else None,
    })


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
    Route("/api/hubble", hubble),
    Route("/api/modelo", modelo),
    Route("/api/redactor", redactor),
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
