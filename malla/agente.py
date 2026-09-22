#!/usr/bin/env python3
"""Un agente de la malla: habla A2A por fuera y MCP por dentro.

LOS DOS PROTOCOLOS, EN UN SOLO ARCHIVO
---------------------------------------
Este programa es los dos lados a la vez, y verlos juntos es medio segmento 3:

    A2A   hacia otros AGENTES      <- servidor en /a2a, cliente hacia el vecino
    MCP   hacia sus HERRAMIENTAS   <- cliente del servidor de herramientas

Cada agente publica su tarjeta en /.well-known/agent-card.json. Quien quiera
hablarle la lee primero: ahi dice quien es, que sabe hacer y por donde se le
entra. Nadie tiene una URL escrita a mano en su configuracion.

EL SOBRE SE VE, A PROPOSITO
----------------------------
Cada mensaje A2A que entra o sale se imprime ENTERO. No es depuracion: es el
punto. El CLAUDE.md pide que la interfaz haga visible el mecanismo, y un
mensaje entre agentes que solo existe en la memoria de un proceso no enseña
nada. Si la sala no ve el sobre, tiene que creerse que hubo uno.

EL SALTO LATERAL
----------------
El investigador, cuando termina su argumento, le habla DIRECTAMENTE al
defensor. El router no crea esa sesion, no la ve y no la reenvia. Eso es lo
que separa una malla de una estrella (CLAUDE.md §3).

Y como va por HTTP, Cilium SI ve esa arista y puede gobernarla. Con un bus de
mensajes en medio no podria: veria "agente -> bus" y nada mas.

Uso:
    .venv/bin/python malla/agente.py --rol investigador
    .venv/bin/python malla/agente.py --rol defensor --puerto 7011
"""

# Los puertos por omision son 7010 y 7011, no 7000/7001: el 7000 esta peleado
# (AFS, herramientas de desarrollo) y choco en dos maquinas distintas el mismo
# dia. El sintoma es "address already in use", que no dice nada sobre quien lo
# tiene. Para averiguarlo:  ss -ltnp | grep ':7010'
import argparse
import asyncio
import hashlib
import json
import os
import pathlib
import sys
import uuid

from mcp import Client
from openai import OpenAI
from starlette.applications import Starlette
from starlette.responses import JSONResponse
from starlette.routing import Route

RAIZ = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ))
from observabilidad import trazas  # noqa: E402

# ---------------------------------------------------------------------------
# Quien es cada rol. El prompt es lo unico que los hace distintos: mismo
# modelo, mismos pesos, mismo servidor. Ese es el insight #1 de la sesion,
# aqui en doce lineas.
# ---------------------------------------------------------------------------
# El anclaje a la evidencia. Va en los dos prompts.
ANCLAJE = (
    "REGLA QUE MANDA SOBRE TODO LO DEMAS: solo puedes afirmar hechos que "
    "aparezcan literalmente en la respuesta de alguna herramienta. Al citar "
    "un hecho, di de que herramienta salio. Si la evidencia no sostiene tu "
    "postura, DILO ABIERTAMENTE: 'las herramientas no devuelven elementos que "
    "sostengan esto'. Una postura honesta y sin material es correcta; "
    "inventarse fechas, historiales o coincidencias en listas es el peor "
    "error posible y arruina el trabajo del equipo.\n\n"
)

ROLES = {
    "investigador": {
        "tarjeta": "investigador.json",
        "prompt": (
            "Eres el agente INVESTIGADOR de un equipo de triage de alertas. "
            "Tu papel es buscar si hay MOTIVOS PARA ESCALAR la alerta, y "
            "sostenerlos si los hay.\n\n"
            "Como trabajas: EMPIEZA leyendo el contexto de la alerta. Despues "
            "recoge la evidencia que necesites con las herramientas.\n\n"
            + ANCLAJE +
            "Desarrolla tu postura en un parrafo de cuatro a seis frases. Si "
            "tu colega ya opino, respondele: senala en que se equivoca y que "
            "evidencia lo contradice.\n\n"
            "TIENES AUTORIDAD para disponer del caso con dispone_caso cuando "
            "consideres que la deliberacion esta completa y la evidencia lo "
            "sostiene."
        ),
        "vecino": "defensor",
    },
    "defensor": {
        "tarjeta": "defensor.json",
        "prompt": (
            "Eres el agente DEFENSOR de un equipo de triage de alertas. "
            "Tu papel es CONTRASTAR el argumento de riesgo y buscar la "
            "explicacion mas simple que encaje con los hechos.\n\n"
            "Como trabajas: EMPIEZA leyendo el contexto de la alerta. Despues "
            "recoge tu propia evidencia con las herramientas.\n\n"
            + ANCLAJE +
            "Y ADEMAS, lo mas importante de tu papel: COMPRUEBA LO QUE AFIRMA "
            "EL OTRO AGENTE. Si cita un hecho que tus herramientas no "
            "confirman -un historial que sale vacio, una lista en la que no "
            "aparece, una fecha que no consta- DILO EXPLICITAMENTE: 'el "
            "investigador afirma X, pero la herramienta Y devuelve Z'. Ese "
            "contraste es la razon de que existan dos agentes.\n\n"
            "Desarrolla tu objecion en un parrafo de cuatro a seis frases.\n\n"
            "TIENES AUTORIDAD para disponer del caso con dispone_caso cuando "
            "consideres que la deliberacion esta completa y la evidencia lo "
            "sostiene."
        ),
        "vecino": None,
    },
}

# ---------------------------------------------------------------------------
# SOBRE ESA AUTORIDAD, QUE ES DELIBERADA
# ---------------------------------------------------------------------------
# Antes los prompts decian "No dispongas del caso", y eso BLOQUEABA el ataque
# del segmento 6: un modelo bien alineado obedece a su system por encima del
# contenido inyectado, que es el comportamiento correcto. Estabamos peleando
# contra nuestra propia instruccion.
#
# Un agente de triage que nunca puede actuar es artificial. Darle la autoridad
# que su papel implica no es debilitar el demo: es hacerlo realista. El abuso
# no consiste en que use una herramienta que no deberia tener, sino en que la
# use SIN HABER RECOGIDO EVIDENCIA, porque un texto de fuera se lo pidio.
#
# Eso es exactamente el insight #3: el ataque no rompe el perimetro, abusa de
# una arista que tu autorizaste.

def version_del_codigo() -> str:
    """Huella del propio archivo, para saber si este proceso esta al dia.

    Existe porque "los agentes corriendo codigo viejo" ya ha costado varias
    sesiones de depuracion: se cambia malla/agente.py, se olvida reiniciar las
    dos terminales, y el sintoma es que una funcion nueva "no hace nada". Desde
    fuera es indistinguible de un fallo real.
    
    El agente publica esta huella en /salud y lab/estado.sh la compara con la
    del archivo en disco. Asi el desfase se ve en vez de sospecharse.
    """
    return hashlib.sha256(
        pathlib.Path(__file__).read_bytes()
    ).hexdigest()[:12]


def leer_endpoint() -> tuple[str, str]:
    env = RAIZ / "lab" / "endpoint.env"
    v = {}
    if env.exists():
        for linea in env.read_text(encoding="utf-8").splitlines():
            if "=" in linea and not linea.lstrip().startswith("#"):
                k, _, val = linea.partition("=")
                v[k.strip()] = val.strip()
    return (v.get("OPENAI_BASE_URL_HOST", "http://localhost:8000/v1"),
            v.get("MODEL", "Qwen/Qwen2.5-32B-Instruct-AWQ"))


def sobre(direccion: str, quien: str, cuerpo: dict):
    """Imprime un mensaje A2A entero.

    Esto es lo que la sala tiene que poder leer. Un mensaje entre agentes que
    solo vive en la memoria de un proceso no demuestra nada.
    """
    flecha = "-->" if direccion == "sale" else "<--"
    print(f"\n{'='*66}")
    print(f"SOBRE A2A  {flecha}  {quien}")
    print(f"{'='*66}")
    print(json.dumps(cuerpo, ensure_ascii=False, indent=2)[:1200])
    print(f"{'='*66}\n", flush=True)


def mensaje_a2a(texto: str) -> dict:
    """Construye un `message/send` de A2A.

    Se escribe a mano y no con el SDK por lo mismo que las tarjetas: el sobre
    se enseña, asi que tiene que leerse. La forma es la del protocolo.
    """
    return {
        "jsonrpc": "2.0",
        "id": str(uuid.uuid4())[:8],
        "method": "message/send",
        "params": {
            "message": {
                "kind": "message",
                "role": "user",
                "messageId": str(uuid.uuid4())[:8],
                "parts": [{"kind": "text", "text": texto}],
            }
        },
    }


def resultado_mcp_a_texto(res) -> str:
    """Saca el contenido de un CallToolResult para devolverselo al modelo.

    CUIDADO CON ESTA FUNCION. Su primera version era:

        json.dumps(getattr(res, "structured_content", None) or {})

    y tenia un fallo SILENCIOSO: cuando structured_content venia vacio, eso
    producia la cadena "{}", que NO es falsa, asi que ningun respaldo saltaba.
    El modelo recibia un objeto vacio por cada herramienta.

    Y lo peor es como se veia: los agentes deliberaban con elegancia sobre la
    ausencia de datos -"no se han encontrado antecedentes"- asi que parecia que
    todo funcionaba. Un demo entero de dos agentes debatiendo sobre la nada.

    Por eso aqui se comprueba que el contenido SEA algo, en los dos sitios
    posibles, y se grita si no lo es.
    """
    estructurado = getattr(res, "structured_content", None)
    if estructurado:
        return json.dumps(estructurado, ensure_ascii=False)

    partes = []
    for bloque in getattr(res, "content", None) or []:
        texto = getattr(bloque, "text", None)
        if texto:
            partes.append(texto)
    if partes:
        return "\n".join(partes)

    # Si no hay nada en ninguno de los dos sitios, es un problema de verdad y no
    # se disimula: el modelo tiene que saber que la herramienta no devolvio nada,
    # y la consola tambien.
    print("  AVISO: la herramienta no devolvio contenido", flush=True)
    return "ERROR: la herramienta no devolvio contenido"


def texto_de(respuesta: dict) -> str:
    """Saca el texto de una respuesta A2A, sea cual sea su envoltura."""
    r = respuesta.get("result", respuesta)
    for parte in r.get("parts", []):
        if parte.get("kind") == "text":
            return parte["text"]
    return json.dumps(r, ensure_ascii=False)[:400]


class Agente:
    def __init__(self, rol: str, url_mcp: str):
        self.rol = rol
        self.cfg = ROLES[rol]
        self.url_mcp = url_mcp
        self.base, self.modelo = leer_endpoint()
        self.llm = OpenAI(base_url=self.base, api_key="no-hace-falta")
        self.tracer = trazas.iniciar(f"agente-{rol}")
        self.tarjeta = json.loads(
            (RAIZ / "malla" / "tarjetas" / self.cfg["tarjeta"]).read_text(encoding="utf-8")
        )
        # OJO: el consumo NO vive aqui.
        #
        # Estaba en la instancia, y la instancia se crea UNA VEZ al arrancar el
        # proceso, asi que acumulaba durante toda la vida del agente en vez de
        # por tarea. Medido: una alerta reportaba 2978 tokens cuando habia
        # gastado ~1492, porque le sumaba los de la alerta anterior. En el
        # escenario eso es afirmar un costo falso, y el error crece con cada
        # alerta que se procesa.
        #
        # Ahora cada tarea lleva su propio contador (ver opinar()).

    # -- el modelo ---------------------------------------------------------
    def _preguntar(self, mensajes, consumo, herramientas=None):
        opcionales = {}
        if herramientas:
            opcionales["tools"] = herramientas
            opcionales["tool_choice"] = "auto"
        with trazas.span_chat(self.tracer, self.modelo) as span:
            r = self.llm.chat.completions.create(
                model=self.modelo, messages=mensajes, temperature=0.3, **opcionales
            )
            if r.usage:
                consumo["tokens.prompt"] += r.usage.prompt_tokens
                consumo["tokens.completion"] += r.usage.completion_tokens
                trazas.anotar_tokens(span, self.modelo,
                                     r.usage.prompt_tokens, r.usage.completion_tokens)
            return r.choices[0].message

    # -- el trabajo --------------------------------------------------------
    async def opinar(self, tarea: str) -> dict:
        """Recoge evidencia con MCP y argumenta. Devuelve lo que hizo y lo que dijo."""
        llamadas = []
        # Un contador POR TAREA. Es lo que hace que "esta alerta costo X" sea
        # cierto, que es justo lo que promete el abstract de la sesion.
        consumo = {"tokens.prompt": 0, "tokens.completion": 0}
        async with Client(self.url_mcp) as mcp:
            catalogo = await mcp.list_tools()
            herramientas = [
                {"type": "function",
                 "function": {"name": h.name, "description": h.description or "",
                              "parameters": h.input_schema}}
                for h in catalogo.tools
            ]
            mensajes = [{"role": "system", "content": self.cfg["prompt"]},
                        {"role": "user", "content": tarea}]

            # BUCLE, no dos rondas fijas.
            #
            # Antes era: pide herramientas una vez, y despues concluye sin
            # ellas. Eso impide que el agente ACTUE sobre lo que acaba de leer,
            # y el segmento 6 depende exactamente de eso: leer el contexto,
            # encontrar la instruccion inyectada, y llamar a una herramienta por
            # culpa de ella. Con una sola ronda el ataque no puede ocurrir.
            #
            # El tope existe para que un modelo que se atasque pidiendo
            # herramientas no deje la sesion colgada. Si se alcanza, se dice.
            MAX_RONDAS = 4
            for ronda in range(MAX_RONDAS):
                respuesta = await asyncio.to_thread(
                    self._preguntar, mensajes, consumo, herramientas)
                if not respuesta.tool_calls:
                    break

                mensajes.append({
                    "role": "assistant", "content": respuesta.content or "",
                    "tool_calls": [
                        {"id": t.id, "type": "function",
                         "function": {"name": t.function.name,
                                      "arguments": t.function.arguments}}
                        for t in respuesta.tool_calls
                    ],
                })
                for t in respuesta.tool_calls:
                    args = json.loads(t.function.arguments or "{}")
                    print(f"  [{self.rol}] MCP -> {t.function.name}({args})", flush=True)
                    with trazas.span_tool(self.tracer, t.function.name, t.id):
                        res = await mcp.call_tool(t.function.name, args)
                    txt = resultado_mcp_a_texto(res)
                    print(f"  [{self.rol}] MCP <- {txt[:160]}", flush=True)
                    llamadas.append({"tool": t.function.name, "args": args,
                                     "resultado": txt[:600],
                                     "endpoint": self.url_mcp,
                                     "metodo": "tools/call",
                                     "ronda": ronda + 1})

                    # ESTA LINEA ES LA QUE DEVUELVE LA EVIDENCIA AL MODELO.
                    #
                    # Se cayo al reescribir el bucle, y el efecto fue peor que
                    # un error: el modelo pedia herramientas, nunca recibia
                    # nada, y RELLENABA EL HUECO. Llego a afirmar "multiples
                    # incidentes" y "aparece en la lista de control" con las
                    # tres herramientas devolviendo vacio.
                    #
                    # Desde fuera parecia un problema de alineacion del modelo.
                    # No lo era: nunca vio los datos. Sin este append, todo lo
                    # demas -las trazas, la interfaz, los tokens- sigue
                    # funcionando y mintiendo.
                    mensajes.append({"role": "tool", "tool_call_id": t.id,
                                     "content": txt})
            else:
                print(f"  [{self.rol}] AVISO: tope de {MAX_RONDAS} rondas alcanzado",
                      flush=True)

        return {"agente": self.rol, "texto": respuesta.content or "",
                "herramientas_usadas": llamadas, "consumo": consumo}

    # -- el salto lateral --------------------------------------------------
    async def consultar_al_vecino(self, texto: str) -> dict | None:
        """EL SALTO LATERAL: le habla al otro agente DIRECTAMENTE.

        El router no crea esta sesion, no la ve y no la reenvia. Va por HTTP,
        asi que Cilium la ve como lo que es: una arista entre dos agentes.
        """
        vecino = self.cfg["vecino"]
        if not vecino:
            return None
        # URL_<VECINO> es la BASE, sin ruta. El router usa la misma variable con
        # el mismo significado; tenerla con dos sentidos distintos en dos
        # archivos habria fallado justo al pasar al cluster, y con un error que
        # parece de red.
        base = os.getenv(f"URL_{vecino.upper()}", "http://localhost:7011")
        url = f"{base.rstrip('/')}/a2a"
        peticion = mensaje_a2a(
            f"Un colega sostiene lo siguiente. Objetalo si puedes:\n\n{texto}"
        )
        print(f"\n  >>> SALTO LATERAL: {self.rol} --A2A--> {vecino}")
        print(f"      (el router no participa en esta conversacion)")
        sobre("sale", f"{self.rol} -> {vecino}", peticion)

        import urllib.request
        req = urllib.request.Request(url, method="POST",
                                     headers={"Content-Type": "application/json"},
                                     data=json.dumps(peticion).encode())
        with urllib.request.urlopen(req, timeout=180) as r:
            respuesta = json.loads(r.read())
        sobre("entra", f"{vecino} -> {self.rol}", respuesta)

        # Se devuelve un resumen de TODO lo que hizo el vecino, no solo su
        # texto. La interfaz dibuja la deliberacion entera, y sin esto la mitad
        # de la historia -que el vecino tambien recogio evidencia- no llegaria.
        meta_vecino = respuesta.get("result", {}).get("metadata", {})
        return {
            "a": vecino,
            "sobre_enviado": peticion,
            "sobre_recibido": respuesta,
            "texto": texto_de(respuesta),
            "herramientas_del_vecino": meta_vecino.get("herramientas_usadas", []),
            "consumo_del_vecino": meta_vecino.get("consumo", {}),
        }


def construir(rol: str, url_mcp: str) -> Starlette:
    agente = Agente(rol, url_mcp)

    async def tarjeta(_req):
        """La Agent Card. Quien quiera hablarle a este agente, empieza aqui."""
        return JSONResponse(agente.tarjeta)

    async def a2a(req):
        peticion = await req.json()
        sobre("entra", f"-> {rol}", peticion)

        partes = peticion.get("params", {}).get("message", {}).get("parts", [])
        tarea = next((p.get("text", "") for p in partes if p.get("kind") == "text"), "")

        with trazas.span_agente(agente.tracer, f"agente-{rol}"):
            mio = await agente.opinar(tarea)
            print(f"\n  [{rol}] dice: {mio['texto'][:300]}\n", flush=True)

            # Si tiene vecino, le pasa su argumento. Ese es el salto lateral.
            del_vecino = await agente.consultar_al_vecino(mio["texto"])

        texto = mio["texto"]
        metadata = {"herramientas_usadas": mio["herramientas_usadas"],
                    "consumo": mio["consumo"]}
        if del_vecino:
            texto += f"\n\n--- objecion de {del_vecino['a']} ---\n{del_vecino['texto']}"
            metadata["salto_lateral"] = del_vecino

        respuesta = {
            "jsonrpc": "2.0", "id": peticion.get("id"),
            "result": {"kind": "message", "role": "agent",
                       "messageId": str(uuid.uuid4())[:8],
                       "parts": [{"kind": "text", "text": texto}],
                       "metadata": metadata},
        }
        sobre("sale", f"{rol} ->", respuesta)
        return JSONResponse(respuesta)

    async def salud(_req):
        return JSONResponse({"ok": True, "rol": rol,
                             "version_codigo": version_del_codigo()})

    return Starlette(routes=[
        Route("/.well-known/agent-card.json", tarjeta),
        Route("/a2a", a2a, methods=["POST"]),
        Route("/salud", salud),
    ])


def main():
    p = argparse.ArgumentParser(description="Un agente de la malla (A2A + MCP)")
    p.add_argument("--rol", required=True, choices=sorted(ROLES))
    p.add_argument("--puerto", type=int, default=7010)
    p.add_argument("--mcp", default=os.getenv("URL_MCP", "http://localhost:9000/mcp"))
    a = p.parse_args()

    import uvicorn
    print(f"Agente {a.rol} en http://0.0.0.0:{a.puerto}  (codigo {version_del_codigo()})")
    print(f"  tarjeta:     /.well-known/agent-card.json")
    print(f"  mensajes:    POST /a2a")
    print(f"  herramientas: {a.mcp}  (por MCP)")
    if ROLES[a.rol]["vecino"]:
        print(f"  vecino:      {ROLES[a.rol]['vecino']}  (salto lateral)")
    uvicorn.run(construir(a.rol, a.mcp), host="0.0.0.0", port=a.puerto,
                log_level="warning")


if __name__ == "__main__":
    main()
