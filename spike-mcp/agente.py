#!/usr/bin/env python3
"""EL PUENTE: de los tool_calls de OpenAI a las llamadas MCP.

ESTO ES LO UNICO DEL PLAN QUE NADIE HABIA PROBADO
--------------------------------------------------
El modelo NO habla MCP. vLLM devuelve `tool_calls` en formato OpenAI. El
servidor MCP espera llamadas MCP. En medio no hay nada, y ese "nada" es este
archivo: el agente actuando como cliente MCP.

Son cuatro traducciones:

    1. herramientas MCP  ->  esquema de tools de OpenAI      (para que el modelo sepa que existen)
    2. tool_call OpenAI  ->  client.call_tool de MCP         (para ejecutarla)
    3. CallToolResult    ->  mensaje role=tool               (para devolversela al modelo)
    4. usage             ->  tokens.prompt / tokens.completion

La cuarta parece un detalle y no lo es: esos nombres son EXACTAMENTE los que
despues seran atributos de span en OTel. Capturarlos asi hoy hace que llegar a
Splunk sea envolver y no reescribir (CLAUDE.md seccion 5).

CRITERIO DE CORTE
-----------------
Si esto no funciona, las tools se exponen por HTTP normal y MCP se queda como
la lamina conceptual -que, honestamente, es donde vive su mejor aporte-. No se
gastan horas peleando con el puente.

Uso:
    .venv/bin/python spike-mcp/agente.py
    .venv/bin/python spike-mcp/agente.py --alerta ALR-FICTICIA-0002
"""

import argparse
import asyncio
import json
import pathlib
import sys

from mcp import Client
from openai import OpenAI

RAIZ = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ))
from observabilidad import trazas  # noqa: E402


def leer_endpoint() -> tuple[str, str]:
    """Lee lab/endpoint.env, que escriben vllm-up.sh y nim-up.sh.

    Ese archivo es el contrato: el agente NUNCA habla con algo especifico de un
    motor de inferencia. Asi, cambiar de motor es bajar uno y subir el otro.
    """
    env = RAIZ / "lab" / "endpoint.env"
    valores = {}
    if env.exists():
        for linea in env.read_text(encoding="utf-8").splitlines():
            if "=" in linea and not linea.lstrip().startswith("#"):
                k, _, v = linea.partition("=")
                valores[k.strip()] = v.strip()
    base = valores.get("OPENAI_BASE_URL_HOST", "http://localhost:8000/v1")
    modelo = valores.get("MODEL", "Qwen/Qwen2.5-32B-Instruct-AWQ")
    return base, modelo


def traza(quien: str, que: str):
    print(f"[{quien:>12}] {que}", flush=True)


def a_esquema_openai(herramientas) -> list[dict]:
    """TRADUCCION 1: herramientas MCP -> esquema de tools de OpenAI.

    Las dos partes hablan JSON Schema, asi que el mapeo es casi directo. Lo
    unico que cambia es la envoltura.

    OJO CON LOS NOMBRES: el SDK de MCP 2.x usa snake_case (`input_schema`,
    `structured_content`), no el camelCase del protocolo. Si buscas ejemplos en
    internet vas a encontrar `inputSchema`: eso es del SDK 1.x y ya no existe.
    """
    return [
        {
            "type": "function",
            "function": {
                "name": h.name,
                "description": h.description or "",
                "parameters": h.input_schema,
            },
        }
        for h in herramientas
    ]


def texto_del_resultado(resultado) -> str:
    """TRADUCCION 3: CallToolResult -> algo que el modelo pueda leer.

    Un resultado MCP puede traer contenido estructurado o bloques de texto.
    Se prefiere lo estructurado; si no hay, se concatenan los textos.
    """
    estructurado = getattr(resultado, "structured_content", None)
    if estructurado:
        return json.dumps(estructurado, ensure_ascii=False)
    partes = []
    for bloque in getattr(resultado, "content", []) or []:
        texto = getattr(bloque, "text", None)
        if texto:
            partes.append(texto)
    return "\n".join(partes) if partes else "(sin contenido)"


async def main(alerta: str, sujeto: str, url_mcp: str):
    base, modelo = leer_endpoint()
    traza("agente", f"motor: {base}")
    traza("agente", f"modelo: {modelo}")

    llm = OpenAI(base_url=base, api_key="no-hace-falta")  # vLLM no pide clave

    # Si no hay OTEL_EXPORTER_OTLP_ENDPOINT, esto devuelve un tracer de mentira
    # y el agente corre igual. La observabilidad no puede tumbar el demo.
    tracer = trazas.iniciar("agente-triage")

    # El contador de tokens, con los nombres que despues seran atributos de span.
    consumo = {"tokens.prompt": 0, "tokens.completion": 0, "model": modelo}

    def preguntar(mensajes, herramientas=None):
        """Cada llamada al modelo es un span `chat`."""
        # OJO: `tools` y `tool_choice` se OMITEN, no se ponen en None.
        #
        # El SDK de OpenAI no descarta los argumentos nulos: los manda
        # explicitamente como `null` en el cuerpo JSON. vLLM valida estricto y
        # rechaza con 400 si ve `tool_choice` presente sin `tools`:
        #
        #   "When using `tool_choice`, `tools` must be set."
        #
        # Por eso se construyen aparte y solo se pasan cuando hay herramientas.
        opcionales = {}
        if herramientas:
            opcionales["tools"] = herramientas
            opcionales["tool_choice"] = "auto"

        with trazas.span_chat(tracer, modelo) as span:
            r = llm.chat.completions.create(
                model=modelo,
                messages=mensajes,
                temperature=0.2,
                **opcionales,
            )
            if r.usage:  # TRADUCCION 4
                consumo["tokens.prompt"] += r.usage.prompt_tokens
                consumo["tokens.completion"] += r.usage.completion_tokens
                # Los DOS juegos de nombres, por si la integracion con Splunk
                # no reconoce la convencion gen_ai.*
                trazas.anotar_tokens(span, modelo,
                                     r.usage.prompt_tokens,
                                     r.usage.completion_tokens)
            return r.choices[0].message

    # Todo lo que sigue cuelga de este span raiz. Esa jerarquia ES el "hilo":
    # en la cascada de Splunk se ve como UNA traza por tarea, con las rondas del
    # modelo y las llamadas a herramientas colgando debajo.
    with trazas.span_agente(tracer, "agente-triage"):
        async with Client(url_mcp) as mcp:
            traza("agente", f"conectado al servidor MCP en {url_mcp}")

            catalogo = await mcp.list_tools()
            nombres = [h.name for h in catalogo.tools]
            traza("agente", f"herramientas descubiertas: {', '.join(nombres)}")
            herramientas = a_esquema_openai(catalogo.tools)

            mensajes = [
                {
                    "role": "system",
                    "content": (
                        "Eres un agente de triage de alertas. Antes de opinar, RECOGE "
                        "EVIDENCIA con las herramientas disponibles. No dispongas del "
                        "caso todavia: solo investiga y resume lo que encontraste."
                    ),
                },
                {
                    "role": "user",
                    "content": f"Revisa la alerta {alerta}, cuyo sujeto es {sujeto}.",
                },
            ]

            print()
            traza("agente", "--- ronda 1: le pregunto al modelo ---")
            respuesta = preguntar(mensajes, herramientas)

            if not respuesta.tool_calls:
                print()
                print("EL PUENTE NO SE PROBO: el modelo contesto sin pedir herramientas.")
                print("Respuesta:", respuesta.content)
                return 1

            # El mensaje del asistente se construye A MANO, campo por campo.
            #
            # Antes esto era respuesta.model_dump(exclude_none=True) y fallaba: el
            # objeto del SDK arrastra campos propios (refusal, annotations, audio,
            # function_call...) que vLLM no espera en un mensaje de entrada. Aqui se
            # manda solo lo que la API necesita para entender que hubo tool_calls.
            mensajes.append({
                "role": "assistant",
                "content": respuesta.content or "",
                "tool_calls": [
                    {
                        "id": t.id,
                        "type": "function",
                        "function": {
                            "name": t.function.name,
                            "arguments": t.function.arguments,
                        },
                    }
                    for t in respuesta.tool_calls
                ],
            })

            # TRADUCCION 2: cada tool_call de OpenAI se convierte en una llamada MCP.
            for llamada in respuesta.tool_calls:
                nombre = llamada.function.name
                argumentos = json.loads(llamada.function.arguments or "{}")
                traza("agente", f"-> MCP  {nombre}({argumentos})")

                # Un span por tool call. gen_ai.tool.call.id es el que enlaza este
                # span con el tool_call_id que emitio el modelo, y es lo que deja
                # navegar en la cascada del turno a la herramienta que disparo.
                with trazas.span_tool(tracer, nombre, llamada.id):
                    resultado = await mcp.call_tool(nombre, argumentos)
                texto = texto_del_resultado(resultado)
                traza("agente", f"<- MCP  {texto}")

                mensajes.append({
                    "role": "tool",
                    "tool_call_id": llamada.id,
                    "content": texto,
                })

            # Ronda 2 SIN herramientas, a proposito: obliga al modelo a concluir con
            # lo que ya tiene. El agente de verdad querra un BUCLE (ofrecer las
            # herramientas otra vez hasta que deje de pedirlas), pero para probar el
            # puente dos rondas bastan y la salida se lee mejor.
            print()
            traza("agente", "--- ronda 2: le devuelvo la evidencia al modelo ---")
            try:
                final = preguntar(mensajes)
            except Exception as e:
                # Se captura aqui a proposito: si el error sube por el `async with`
                # del cliente MCP, anyio lo envuelve en un ExceptionGroup y el
                # mensaje real desaparece.
                print()
                print(f"LA RONDA 2 FALLO: {type(e).__name__}: {e}")
                print()
                print("Esto es lo que se le mando (para ver que rechazo):")
                print(json.dumps(mensajes, ensure_ascii=False, indent=2)[:2500])
                return 1

            print()
            print("=" * 70)
            print("CONCLUSION DEL AGENTE")
            print("=" * 70)
            print(final.content)
            print()
            print("CONSUMO (estos nombres seran atributos de span en OTel)")
            for k, v in consumo.items():
                print(f"  {k:<20} {v}")
            print()
            print("=" * 70)
            print("PUENTE PROBADO: un tool_call de OpenAI viajo hasta el servidor")
            print("MCP, volvio con evidencia, y el modelo razono sobre ella.")
            print("=" * 70)
        return 0


if __name__ == "__main__":
    p = argparse.ArgumentParser(description="Agente que usa herramientas por MCP")
    p.add_argument("--alerta", default="ALR-FICTICIA-0001")
    p.add_argument("--sujeto", default="SUJ-0001")
    p.add_argument("--mcp", default="http://localhost:9000/mcp")
    a = p.parse_args()
    try:
        sys.exit(asyncio.run(main(a.alerta, a.sujeto, a.mcp)))
    except KeyboardInterrupt:
        pass
    except SystemExit:
        # sys.exit() lanza SystemExit, que hereda de BaseException. Sin esta
        # linea, una corrida BUENA acababa imprimiendo "FALLO: SystemExit: 0".
        raise
    except BaseException as e:
        # anyio envuelve los errores de dentro del TaskGroup en ExceptionGroup,
        # y su str() no dice nada util. Hay que abrirlo.
        def desenvolver(exc, nivel=0):
            sangria = "  " * nivel
            hijos = getattr(exc, "exceptions", None)
            if hijos:
                print(f"{sangria}{type(exc).__name__} con {len(hijos)} causa(s):",
                      file=sys.stderr)
                for h in hijos:
                    desenvolver(h, nivel + 1)
            else:
                print(f"{sangria}{type(exc).__name__}: {exc}", file=sys.stderr)
        print("\nFALLO:", file=sys.stderr)
        desenvolver(e)
        sys.exit(1)
