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
def span_agente(tracer, nombre: str):
    """Span raiz. Todo lo demas cuelga de aqui, y eso ES el hilo."""
    ctx = tracer.start_as_current_span(f"invoke_agent {nombre}")
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


@contextlib.contextmanager
def _con_atributos(ctx, atributos: dict):
    """Abre el span y le pone los atributos de entrada."""
    with ctx as span:
        for k, v in atributos.items():
            span.set_attribute(k, v)
        yield span
