#!/usr/bin/env python3
"""Trazas de OpenTelemetry para la malla.

DOS JUEGOS DE NOMBRES, A PROPOSITO
-----------------------------------
Cada span lleva los atributos DOS VECES:

    gen_ai.usage.input_tokens   <-- convencion estandar de OpenTelemetry
    tokens.prompt               <-- el nombre que fija el CLAUDE.md §5

No es redundancia por indecision. Es un seguro:

  - Con los nombres ESTANDAR, Splunk Observability (y cualquier APM moderno)
    reconoce los spans como de GenAI y da vistas ya hechas, sin configurar nada.
  - Con los NUESTROS, si esa integracion no sale o el backend no los entiende,
    los tableros se montan a mano y la sesion cumple igual lo que promete el
    abstract.

Emitir ambos cuesta una linea por atributo. Quedarse corto el dia del evento
cuesta el segmento 5 entero.

Salvedad honesta: las convenciones `gen_ai.*` siguen marcadas como *Development*
en el registro de OpenTelemetry, no *Stable*. Los atributos del nucleo llevan
estables de forma desde la v1.37.0, asi que el riesgo es bajo, pero existe. Esa
es otra razon para no depender solo de ellos.

NO ROMPE NADA SI NO HAY COLLECTOR
----------------------------------
Sin OTEL_EXPORTER_OTLP_ENDPOINT, el tracer es de mentira y no pasa nada. Sin el
paquete de OpenTelemetry instalado, tambien. Un demo no puede caerse porque
falte la observabilidad: eso seria exactamente al reves.

Uso:
    from observabilidad import trazas
    tracer = trazas.iniciar("agente-a")

    with trazas.span_agente(tracer, "agente-a") as raiz:
        with trazas.span_chat(tracer, modelo) as s:
            ...
            trazas.anotar_tokens(s, modelo, prompt=120, completion=45)
"""

import contextlib
import json
import os

# ---------------------------------------------------------------------------
# Carga opcional. Si OpenTelemetry no esta, todo lo de abajo se vuelve inocuo.
# ---------------------------------------------------------------------------
try:
    from opentelemetry import trace
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    HAY_OTEL = True
except ImportError:  # pragma: no cover
    HAY_OTEL = False


class _SpanFalso:
    """Se traga todo lo que le pidas. Asi el codigo del agente no necesita
    preguntar si hay trazas o no: siempre hay algo con la misma forma."""
    def set_attribute(self, *_a, **_k): pass
    def set_status(self, *_a, **_k): pass
    def record_exception(self, *_a, **_k): pass
    def add_event(self, *_a, **_k): pass


class _TracerFalso:
    @contextlib.contextmanager
    def start_as_current_span(self, *_a, **_k):
        yield _SpanFalso()


def iniciar(servicio: str):
    """Devuelve un tracer. De verdad si hay a donde exportar; de mentira si no.

    El endpoint sale de OTEL_EXPORTER_OTLP_ENDPOINT, la variable estandar.
    Con el Collector en el cluster suele ser http://otel-collector:4318
    """
    endpoint = os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT")
    if not HAY_OTEL or not endpoint:
        return _TracerFalso()

    try:
        from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
            OTLPSpanExporter,
        )
    except ImportError:
        print("  (hay OTEL_EXPORTER_OTLP_ENDPOINT pero falta el exportador OTLP; sin trazas)")
        return _TracerFalso()

    proveedor = TracerProvider(
        resource=Resource.create({"service.name": servicio})
    )
    proveedor.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(proveedor)
    print(f"  trazas hacia {endpoint} (servicio: {servicio})")
    return trace.get_tracer(servicio)


# ---------------------------------------------------------------------------
# Los tres tipos de span de la convencion de agentes.
#
# El arbol que producen es exactamente la cascada que se quiere ver en Splunk:
#
#     invoke_agent                        <- la traza entera, el "hilo"
#     ├── chat                            <- una ronda con el modelo
#     ├── execute_tool  perfil_sujeto     ┐
#     ├── execute_tool  consulta_historial├── las tres en paralelo
#     ├── execute_tool  lista_sancionados ┘
#     └── chat                            <- la ronda que concluye
# ---------------------------------------------------------------------------
def span_agente(tracer, nombre: str, padre=None):
    """Span del agente. Con `padre`, cuelga de la traza de quien lo llamo.

    Ese argumento es lo que convierte tres trazas sueltas en una sola cascada.
    """
    ctx = tracer.start_as_current_span(f"invoke_agent {nombre}", context=padre)
    return _con_atributos(ctx, {
        "gen_ai.operation.name": "invoke_agent",
        "gen_ai.agent.name": nombre,
    })


def span_chat(tracer, modelo: str):
    """Una llamada al modelo."""
    ctx = tracer.start_as_current_span(f"chat {modelo}")
    return _con_atributos(ctx, {
        "gen_ai.operation.name": "chat",
        "gen_ai.provider.name": "vllm",
        "gen_ai.request.model": modelo,
    })


def span_tool(tracer, nombre: str, call_id: str):
    """Una llamada a herramienta.

    `gen_ai.tool.call.id` es el atributo que MAS importa de los tres: enlaza
    este span con el tool_call_id que emitio el modelo en el turno anterior.
    Es lo que deja ir, en la cascada, desde el turno del modelo hasta la
    herramienta concreta que disparo. Sin el, la correlacion hay que montarla
    a mano.
    """
    ctx = tracer.start_as_current_span(f"execute_tool {nombre}")
    return _con_atributos(ctx, {
        "gen_ai.operation.name": "execute_tool",
        "gen_ai.tool.name": nombre,
        "gen_ai.tool.type": "function",
        "gen_ai.tool.call.id": call_id,
        "tool.name": nombre,          # alias legible sin conocer la convencion
    })


# ---------------------------------------------------------------------------
# EL CONTENIDO DE LOS MENSAJES
#
# Esto es opcional en la convencion de OTel, y a proposito: un prompt lleva lo
# que el usuario escribio, y en un sistema real eso puede ser datos personales,
# claves o secretos de negocio. La convencion dice que capturarlo se ACTIVA,
# nunca viene de serie.
#
# Aqui viene ACTIVADO porque todos los datos son sinteticos (CLAUDE.md §6) y
# porque es lo que hace util el segmento 5: con el contenido en la traza, la
# INYECCION se ve dentro de Splunk, en el mismo sitio donde se ve la latencia.
# Se apaga con OTEL_CAPTURAR_CONTENIDO=0 si alguna vez corre con datos reales.
CAPTURAR = os.getenv("OTEL_CAPTURAR_CONTENIDO", "1") != "0"

# Un prompt de este proyecto ronda los 3000 tokens, o sea unos 12 KB. Cabe de
# sobra en un span, pero se corta por si algun caso crece: un span gigante no
# falla, se encola y retrasa el lote entero.
TOPE = int(os.getenv("OTEL_TOPE_CONTENIDO", "16000"))


def _recortar(texto: str) -> str:
    if texto is None:
        return ""
    texto = str(texto)
    if len(texto) <= TOPE:
        return texto
    return texto[:TOPE] + f"\n... [cortado, {len(texto)} caracteres en total]"


def anotar_mensajes(span, mensajes: list, respuesta=None):
    """Mete la conversacion en el span: lo que entro y lo que salio.

    `mensajes` es la lista que se le mando al modelo -el prompt del rol, el
    caso, el debate hasta ahora y los resultados de las herramientas-. Es
    exactamente el contexto sobre el que razono, y por eso vale tanto: si el
    agente dice algo raro, aqui esta el porque.

    LOS DOS JUEGOS DE NOMBRES otra vez, por el mismo motivo que en
    anotar_tokens: los de la convencion para que un APM los reconozca solo, y
    unos planos de respaldo por si no lo hace.
    """
    if not CAPTURAR or not mensajes:
        return

    # --- entrada ---------------------------------------------------------
    entrada = []
    for m in mensajes:
        papel = m.get("role", "?") if isinstance(m, dict) else getattr(m, "role", "?")
        cuerpo = m.get("content") if isinstance(m, dict) else getattr(m, "content", None)
        entrada.append({"role": papel, "content": _recortar(cuerpo)})

    span.set_attribute("gen_ai.input.messages", _recortar(json.dumps(entrada, ensure_ascii=False)))
    # Plano: el ultimo turno del usuario, legible sin desplegar un JSON.
    ultimo = next((m for m in reversed(entrada) if m["role"] == "user"), None)
    if ultimo:
        span.set_attribute("gen_ai.prompt", ultimo["content"])

    if respuesta is None:
        return

    # --- salida ----------------------------------------------------------
    texto = _recortar(getattr(respuesta, "content", None))
    salida = {"role": "assistant", "content": texto}

    # Las herramientas pedidas van DENTRO de la salida, no aparte: cuando el
    # modelo pide una herramienta su `content` viene vacio, y sin esto el span
    # pareceria una respuesta en blanco. Ademas es justo donde se ve el ataque
    # llegar a la accion.
    llamadas = getattr(respuesta, "tool_calls", None)
    if llamadas:
        salida["tool_calls"] = [
            {"name": t.function.name, "arguments": _recortar(t.function.arguments)}
            for t in llamadas
        ]
        span.set_attribute("gen_ai.response.tool_names",
                           ", ".join(t.function.name for t in llamadas))

    span.set_attribute("gen_ai.output.messages",
                       _recortar(json.dumps([salida], ensure_ascii=False)))
    if texto:
        span.set_attribute("gen_ai.completion", texto)


def anotar_tokens(span, modelo: str, prompt: int, completion: int):
    """LOS DOS JUEGOS DE NOMBRES. Aqui es donde se paga el seguro."""
    # Convencion estandar: lo que Splunk puede reconocer solo.
    span.set_attribute("gen_ai.usage.input_tokens", prompt)
    span.set_attribute("gen_ai.usage.output_tokens", completion)
    span.set_attribute("gen_ai.response.model", modelo)
    # Los del CLAUDE.md §5: el plan B si la integracion no reconoce lo anterior.
    span.set_attribute("tokens.prompt", prompt)
    span.set_attribute("tokens.completion", completion)
    span.set_attribute("model", modelo)


# ---------------------------------------------------------------------------
# PROPAGACION ENTRE AGENTES.
#
# Sin esto, cada proceso abre su propio span raiz y en Splunk se ven TRES
# trazas sueltas: el router por un lado, cada agente por el suyo. Lo que se
# quiere ver es una sola, con el salto lateral ANIDADO dentro de la
# conversacion del investigador — el ping-pong de las cuatro terminales en una
# imagen.
#
# El mecanismo es el estandar de W3C: una cabecera `traceparent` viaja con la
# peticion HTTP. Quien la recibe la extrae y cuelga sus spans de ahi.
#
# Funciona porque A2A va sobre HTTP. Con un bus de mensajes en medio habria que
# meter el contexto dentro del sobre y que el bus lo respetara.
# ---------------------------------------------------------------------------
def inyectar(cabeceras: dict) -> dict:
    """Mete el contexto de traza actual en unas cabeceras HTTP."""
    if not HAY_OTEL:
        return cabeceras
    try:
        from opentelemetry.propagate import inject
        inject(cabeceras)
    except Exception:
        pass
    return cabeceras


def extraer(cabeceras) -> object | None:
    """Saca el contexto de traza de unas cabeceras recibidas.

    Devuelve None si no hay nada que extraer, y entonces el span que se abra
    sera raiz. Eso es lo correcto: una peticion sin traceparent empieza una
    traza nueva.
    """
    if not HAY_OTEL:
        return None
    try:
        from opentelemetry.propagate import extract
        return extract({k.lower(): v for k, v in dict(cabeceras).items()})
    except Exception:
        return None


@contextlib.contextmanager
def _con_atributos(ctx, atributos: dict):
    """Abre el span y le pone los atributos de entrada."""
    with ctx as span:
        for k, v in atributos.items():
            span.set_attribute(k, v)
        yield span
