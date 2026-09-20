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
ROLES = {
    "investigador": {
        "tarjeta": "investigador.json",
        "prompt": (
            "Eres el agente INVESTIGADOR de un equipo de triage de alertas. "
            "Tu papel es sostener que la alerta MERECE ESCALARSE. "
            "Antes de argumentar, RECOGE EVIDENCIA con las herramientas. "
            "Cita hechos concretos: fechas, valores, lo que viste. "
            "Se breve: tres frases como maximo. No dispongas del caso."
        ),
        "vecino": "defensor",   # a quien le hace el salto lateral
    },
    "defensor": {
        "tarjeta": "defensor.json",
        "prompt": (
            "Eres el agente DEFENSOR de un equipo de triage de alertas. "
            "Tu papel es OBJETAR el argumento de riesgo y buscar la explicacion "
            "mas simple. Antes de objetar, RECOGE EVIDENCIA con las herramientas. "
            "Cita hechos concretos. Se breve: tres frases como maximo. "
            "No dispongas del caso."
        ),
        "vecino": None,         # el defensor no reenvia a nadie
    },
}


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
        self.consumo = {"tokens.prompt": 0, "tokens.completion": 0}

    # -- el modelo ---------------------------------------------------------
    def _preguntar(self, mensajes, herramientas=None):
        opcionales = {}
        if herramientas:
            opcionales["tools"] = herramientas
            opcionales["tool_choice"] = "auto"
        with trazas.span_chat(self.tracer, self.modelo) as span:
            r = self.llm.chat.completions.create(
                model=self.modelo, messages=mensajes, temperature=0.3, **opcionales
            )
            if r.usage:
                self.consumo["tokens.prompt"] += r.usage.prompt_tokens
                self.consumo["tokens.completion"] += r.usage.completion_tokens
                trazas.anotar_tokens(span, self.modelo,
                                     r.usage.prompt_tokens, r.usage.completion_tokens)
            return r.choices[0].message

    # -- el trabajo --------------------------------------------------------
    async def opinar(self, tarea: str) -> dict:
        """Recoge evidencia con MCP y argumenta. Devuelve lo que hizo y lo que dijo."""
        llamadas = []
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

            respuesta = await asyncio.to_thread(self._preguntar, mensajes, herramientas)

            if respuesta.tool_calls:
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
                    txt = json.dumps(getattr(res, "structured_content", None)
                                     or {}, ensure_ascii=False) or "(vacio)"
                    llamadas.append({"tool": t.function.name, "args": args})
                    mensajes.append({"role": "tool", "tool_call_id": t.id, "content": txt})

                respuesta = await asyncio.to_thread(self._preguntar, mensajes)

        return {"agente": self.rol, "texto": respuesta.content or "",
                "herramientas_usadas": llamadas, "consumo": dict(self.consumo)}

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
        return respuesta


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
        if del_vecino:
            texto += f"\n\n--- objecion de {agente.cfg['vecino']} ---\n{texto_de(del_vecino)}"

        respuesta = {
            "jsonrpc": "2.0", "id": peticion.get("id"),
            "result": {"kind": "message", "role": "agent",
                       "messageId": str(uuid.uuid4())[:8],
                       "parts": [{"kind": "text", "text": texto}],
                       "metadata": {"herramientas_usadas": mio["herramientas_usadas"],
                                    "consumo": mio["consumo"]}},
        }
        sobre("sale", f"{rol} ->", respuesta)
        return JSONResponse(respuesta)

    return Starlette(routes=[
        Route("/.well-known/agent-card.json", tarjeta),
        Route("/a2a", a2a, methods=["POST"]),
    ])


def main():
    p = argparse.ArgumentParser(description="Un agente de la malla (A2A + MCP)")
    p.add_argument("--rol", required=True, choices=sorted(ROLES))
    p.add_argument("--puerto", type=int, default=7010)
    p.add_argument("--mcp", default=os.getenv("URL_MCP", "http://localhost:9000/mcp"))
    a = p.parse_args()

    import uvicorn
    print(f"Agente {a.rol} en http://0.0.0.0:{a.puerto}")
    print(f"  tarjeta:     /.well-known/agent-card.json")
    print(f"  mensajes:    POST /a2a")
    print(f"  herramientas: {a.mcp}  (por MCP)")
    if ROLES[a.rol]["vecino"]:
        print(f"  vecino:      {ROLES[a.rol]['vecino']}  (salto lateral)")
    uvicorn.run(construir(a.rol, a.mcp), host="0.0.0.0", port=a.puerto,
                log_level="warning")


if __name__ == "__main__":
    main()
