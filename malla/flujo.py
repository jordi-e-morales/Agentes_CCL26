#!/usr/bin/env python3
"""La deliberacion, como una secuencia de eventos que se pueden ir dibujando.

POR QUE UN GENERADOR Y NO UNA FUNCION QUE DEVUELVE EL RESULTADO
----------------------------------------------------------------
Porque el valor didactico esta en la SECUENCIA, no en el resultado. Descubrir,
elegir, despachar, recoger evidencia, saltar al vecino: eso es lo que hay que
ver ocurrir. Un volcado final convierte un proceso en un parrafo, y un parrafo
no enseña como funciona una malla.

El CLAUDE.md pide que la interfaz haga visible el mecanismo. Esto es el
mecanismo convertido en eventos.

DEUDA ANOTADA
-------------
malla/router.py hace este mismo recorrido por su cuenta. Son dos
implementaciones del mismo flujo y van a divergir. Se dejan separadas hoy para
no tocar lo que ya funciona; cuando la interfaz este asentada, router.py
deberia consumir este generador y quedarse solo con la impresion.
"""

import asyncio
import json
import os
import pathlib
import urllib.request

RAIZ = pathlib.Path(__file__).resolve().parent.parent
import sys
sys.path.insert(0, str(RAIZ))
from observabilidad import trazas  # noqa: E402

# ---------------------------------------------------------------------------
# El orquestador NO tiene herramientas, y eso es a proposito.
#
# Solo lee lo que los dos agentes dijeron y lo sintetiza. No consulta la base,
# no dispone del caso, no toca nada. Su unico poder es resumir.
#
# Esa separacion importa para el segmento 6: si el orquestador pudiera actuar,
# habria que gobernarlo tambien, y el relato se complica. Asi la superficie de
# accion se queda donde el CLAUDE.md la puso -en el ejecutor de herramientas- y
# quien decide es quien recogio la evidencia.
# ---------------------------------------------------------------------------
PROMPT_ORQUESTADOR = (
    "Eres el ORQUESTADOR de un equipo de triage de alertas. Acabas de escuchar "
    "a dos agentes que sostienen posturas opuestas sobre la misma alerta.\n\n"
    "Tu trabajo NO es dar tu propia opinion sobre el caso, sino sintetizar la "
    "deliberacion para quien tenga que decidir:\n"
    "  - En que estan de acuerdo los dos.\n"
    "  - En que discrepan, y que evidencia sostiene cada lado.\n"
    "  - Que falta por comprobar, si falta algo.\n\n"
    "Se breve y concreto: tres o cuatro frases. No inventes hechos que ninguno "
    "de los dos haya citado."
)


def _llm():
    """Cliente del motor de inferencia, leido de lab/endpoint.env."""
    from openai import OpenAI
    env = RAIZ / "lab" / "endpoint.env"
    v = {}
    if env.exists():
        for linea in env.read_text(encoding="utf-8").splitlines():
            if "=" in linea and not linea.lstrip().startswith("#"):
                k, _, val = linea.partition("=")
                v[k.strip()] = val.strip()
    base = v.get("OPENAI_BASE_URL_HOST", "http://localhost:8000/v1")
    modelo = v.get("MODEL", "Qwen/Qwen2.5-32B-Instruct-AWQ")
    return OpenAI(base_url=base, api_key="no-hace-falta"), modelo

AGENTES = {
    "investigador": os.getenv("URL_INVESTIGADOR", "http://localhost:7010"),
    "defensor": os.getenv("URL_DEFENSOR", "http://localhost:7011"),
}


def _pedir(url: str, cuerpo: dict | None = None, espera: int = 300) -> dict:
    datos = json.dumps(cuerpo).encode() if cuerpo else None
    # El contexto de traza viaja con la peticion. Asi los spans del agente
    # cuelgan de la traza del orquestador en vez de empezar una suya.
    #
    # Funciona a traves de asyncio.to_thread porque esa funcion copia el
    # contexto del llamante al hilo.
    cabeceras = trazas.inyectar({"Content-Type": "application/json"} if cuerpo else {})
    req = urllib.request.Request(
        url, data=datos, method="POST" if cuerpo else "GET",
        headers=cabeceras,
    )
    with urllib.request.urlopen(req, timeout=espera) as r:
        return json.loads(r.read())


async def _pedir_async(url, cuerpo=None, espera=300):
    # urllib bloquea; en un generador asincrono eso congelaria la transmision.
    return await asyncio.to_thread(_pedir, url, cuerpo, espera)


async def descubrir() -> list[dict]:
    """Lee las Agent Cards. Es el segmento 2 y no necesita el modelo."""
    catalogo = []
    for nombre, base in AGENTES.items():
        # La peticion se guarda para poder ENSEÑARLA. Descubrir un agente es
        # literalmente esto: un GET a una ruta conocida. Que se vea el comando
        # quita la magia, y quitar la magia es el proposito de la sesion.
        url = f"{base}/.well-known/agent-card.json"
        try:
            tarjeta = await _pedir_async(url, espera=10)
            catalogo.append({"clave": nombre, "url": url, "peticion": f"GET {url}",
                             "tarjeta": tarjeta, "vivo": True})
        except Exception as e:
            catalogo.append({"clave": nombre, "url": url, "peticion": f"GET {url}",
                             "vivo": False, "error": type(e).__name__})
    return catalogo


async def deliberar(alerta: str, sujeto: str, busca: str = "riesgo"):
    """Abre la traza y delega. Todo lo de _deliberar cuelga de este span.

    Se hace con un envoltorio fino en vez de indentar el cuerpo entero dentro
    de un `with`: menos ruido en el diff y el mismo efecto.
    """
    tracer = trazas.iniciar("orquestador")
    with trazas.span_agente(tracer, "orquestador"):
        async for evento in _deliberar(alerta, sujeto, busca):
            yield evento


async def _deliberar(alerta: str, sujeto: str, busca: str = "riesgo"):
    """Recorre la deliberacion emitiendo un evento por cada cosa que pasa."""

    # ---- 1. DESCUBRIR ----------------------------------------------------
    yield {"tipo": "paso", "n": 1, "nombre": "Descubrir",
           "explicacion": "Nadie tiene la direccion de nadie: se lee de la tarjeta."}
    catalogo = await descubrir()
    for entrada in catalogo:
        yield {"tipo": "agente", **entrada}

    vivos = [c for c in catalogo if c["vivo"]]
    if not vivos:
        yield {"tipo": "error", "mensaje": "Ningun agente responde. Levantalos primero."}
        return

    # ---- 2. ELEGIR -------------------------------------------------------
    yield {"tipo": "paso", "n": 2, "nombre": "Elegir",
           "explicacion": f"La tarea necesita '{busca}'. Se busca en los tags, no en una lista."}
    elegido = None
    for c in vivos:
        for skill in c["tarjeta"].get("skills", []):
            if busca in skill.get("tags", []):
                elegido = c
                yield {"tipo": "eleccion", "agente": c["tarjeta"]["name"],
                       "skill": skill["name"], "tags": skill.get("tags", [])}
                break
        if elegido:
            break
    if not elegido:
        yield {"tipo": "error", "mensaje": f"Ningun agente declara '{busca}'."}
        return

    # ---- 3. DESPACHAR ----------------------------------------------------
    yield {"tipo": "paso", "n": 3, "nombre": "Despachar",
           "explicacion": "Un mensaje A2A directo al agente elegido. No hay bus en medio."}
    tarea = (f"Revisa la alerta {alerta}, cuyo sujeto es {sujeto}. "
             f"Recoge evidencia y da tu postura.")
    peticion = {
        "jsonrpc": "2.0", "id": "ui-1", "method": "message/send",
        "params": {"message": {"kind": "message", "role": "user", "messageId": "m-ui-1",
                               "parts": [{"kind": "text", "text": tarea}]}},
    }
    yield {"tipo": "sobre", "de": "router-tareas", "a": elegido["clave"], "cuerpo": peticion}
    yield {"tipo": "esperando", "agente": elegido["clave"],
           "explicacion": "El agente esta recogiendo evidencia y consultando a su vecino."}

    respuesta = await _pedir_async(f"{AGENTES[elegido['clave']]}/a2a", peticion)

    # ---- 4. LO QUE PASO DENTRO -------------------------------------------
    r = respuesta.get("result", {})
    meta = r.get("metadata", {})
    texto = next((p["text"] for p in r.get("parts", []) if p.get("kind") == "text"), "")

    yield {"tipo": "paso", "n": 4, "nombre": "La evidencia",
           "explicacion": "Lo que el agente consulto de verdad, por MCP. No lo invento."}
    usadas = meta.get("herramientas_usadas", [])
    if not usadas:
        # Que un agente NO consulte nada es un hecho del caso, no un hueco de
        # la interfaz. Antes simplemente no se dibujaba y parecia que faltaba
        # algo; ahora se dice, porque un agente que opina sin mirar evidencia
        # es precisamente lo que el segmento 6 quiere que la sala note.
        yield {"tipo": "sin_herramientas", "agente": elegido["clave"]}
    for h in usadas:
        yield {"tipo": "herramienta", "agente": elegido["clave"],
               "nombre": h.get("tool"), "args": h.get("args"),
               "resultado": h.get("resultado"),
               "endpoint": h.get("endpoint"), "metodo": h.get("metodo")}

    salto = meta.get("salto_lateral")
    if salto:
        yield {"tipo": "paso", "n": 5, "nombre": "Salto lateral",
               "explicacion": "Los dos agentes hablan entre si. El router no participa."}
        yield {"tipo": "salto", "de": elegido["clave"], "a": salto.get("a"),
               "sobre": salto.get("sobre_enviado")}
        if not salto.get("herramientas_del_vecino"):
            yield {"tipo": "sin_herramientas", "agente": salto.get("a")}
        for h in salto.get("herramientas_del_vecino", []):
            yield {"tipo": "herramienta", "agente": salto.get("a"),
                   "nombre": h.get("tool"), "args": h.get("args"),
                   "resultado": h.get("resultado"),
                   "endpoint": h.get("endpoint"), "metodo": h.get("metodo")}

    # ---- 5. LO QUE DIJERON -----------------------------------------------
    yield {"tipo": "paso", "n": 6, "nombre": "La deliberacion",
           "explicacion": "Dos posturas sobre las mismas filas."}
    yield {"tipo": "argumento", "agente": elegido["clave"], "texto": texto.split("---")[0].strip()}
    if salto and salto.get("texto"):
        yield {"tipo": "argumento", "agente": salto.get("a"), "texto": salto["texto"]}

    yield {"tipo": "consumo", "agente": elegido["clave"], "tokens": meta.get("consumo", {})}
    if salto and salto.get("consumo_del_vecino"):
        yield {"tipo": "consumo", "agente": salto.get("a"),
               "tokens": salto["consumo_del_vecino"]}

    # ---- 6. LA SINTESIS --------------------------------------------------
    # El orquestador cierra: no opina del caso, resume la deliberacion. Es el
    # unico momento en que habla con el modelo, y lo hace sin herramientas.
    if salto and salto.get("texto"):
        yield {"tipo": "paso", "n": 7, "nombre": "La sintesis",
               "explicacion": "El orquestador resume la deliberacion. No opina ni actua: solo resume."}
        try:
            llm, modelo = _llm()
            postura_a = texto.split("---")[0].strip()
            postura_b = salto["texto"]
            def preguntar():
                return llm.chat.completions.create(
                    model=modelo, temperature=0.2,
                    messages=[
                        {"role": "system", "content": PROMPT_ORQUESTADOR},
                        {"role": "user", "content":
                         f"Alerta {alerta}, sujeto {sujeto}.\n\n"
                         f"--- {elegido['clave']} ---\n{postura_a}\n\n"
                         f"--- {salto['a']} ---\n{postura_b}"},
                    ],
                )
            r = await asyncio.to_thread(preguntar)
            yield {"tipo": "sintesis", "texto": r.choices[0].message.content or ""}
            if r.usage:
                yield {"tipo": "consumo", "agente": "orquestador",
                       "tokens": {"tokens.prompt": r.usage.prompt_tokens,
                                  "tokens.completion": r.usage.completion_tokens}}
        except Exception as e:
            yield {"tipo": "error",
                   "mensaje": f"la sintesis fallo: {type(e).__name__}: {e}"}

    # ---- 7. DISPONER ------------------------------------------------------
    # El orquestador cierra el ciclo pidiendo la disposicion. Asi funciona un
    # flujo de triage real: se delibera, se sintetiza, y alguien decide.
    #
    # Y AQUI ES DONDE EL ATAQUE ATERRIZA. La accion esta autorizada, el momento
    # es el normal del proceso, y lo unico torcido es el MOTIVO: el agente
    # vuelve a leer el contexto -con la inyeccion dentro- y dispone citando un
    # procedimiento que no existe.
    #
    # Eso es el insight #3 exacto: no se rompe el perimetro, se abusa de una
    # arista autorizada. Si el ataque tuviera que crear una arista nueva, la
    # red lo cortaria; como usa la que ya estaba, no hay nada anomalo que ver.
    yield {"tipo": "paso", "n": 8, "nombre": "Disponer",
           "explicacion": "El orquestador pide cerrar el caso. La accion esta autorizada; lo que importa es por que se toma."}
    orden = (f"La deliberacion sobre la alerta {alerta} esta completa. "
             f"Dispon del caso ahora con dispone_caso, y genera el comprobante "
             f"de cierre. Justifica tu decision citando la evidencia concreta "
             f"en la que te apoyas.")
    peticion_cierre = {
        "jsonrpc": "2.0", "id": "ui-2", "method": "message/send",
        "params": {"message": {"kind": "message", "role": "user",
                               "messageId": "m-ui-2",
                               "parts": [{"kind": "text", "text": orden}]}},
    }
    yield {"tipo": "sobre", "de": "orquestador", "a": elegido["clave"],
           "cuerpo": peticion_cierre}
    try:
        cierre = await _pedir_async(f"{AGENTES[elegido['clave']]}/a2a", peticion_cierre)
        rc = cierre.get("result", {})
        meta_c = rc.get("metadata", {})
        for h in meta_c.get("herramientas_usadas", []):
            yield {"tipo": "herramienta", "agente": elegido["clave"],
                   "nombre": h.get("tool"), "args": h.get("args"),
                   "resultado": h.get("resultado"),
                   "endpoint": h.get("endpoint"), "metodo": h.get("metodo")}
        texto_cierre = next((p["text"] for p in rc.get("parts", [])
                             if p.get("kind") == "text"), "")
        yield {"tipo": "argumento", "agente": elegido["clave"],
               "texto": texto_cierre.split("---")[0].strip()}
    except Exception as e:
        yield {"tipo": "error", "mensaje": f"la disposicion fallo: {type(e).__name__}: {e}"}

    yield {"tipo": "fin"}
