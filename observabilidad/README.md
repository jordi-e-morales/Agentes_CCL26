# Trazas

Un span por ronda con el modelo y uno por llamada a herramienta, todo colgando
de una traza por tarea.

## La cascada que produce

```
invoke_agent                          ← la traza entera: el "hilo"
├── chat                              ← ronda 1, con sus tokens
├── execute_tool  perfil_sujeto       ┐
├── execute_tool  consulta_historial  ├── los tres en paralelo
├── execute_tool  lista_sancionados   ┘
└── chat                              ← la ronda que concluye
```

`gen_ai.tool.call.id` es el atributo que más rinde: **enlaza el span de la
herramienta con el `tool_call_id` que emitió el modelo** en el turno anterior.
Es lo que deja navegar, en la cascada, desde el turno del modelo hasta la
herramienta concreta que disparó.

## Los dos juegos de nombres

Cada span lleva los atributos **dos veces**:

| Estándar de OpenTelemetry | El del `CLAUDE.md` §5 |
|---|---|
| `gen_ai.usage.input_tokens` | `tokens.prompt` |
| `gen_ai.usage.output_tokens` | `tokens.completion` |
| `gen_ai.response.model` | `model` |

No es indecisión, es un seguro. Con los estándar, Splunk Observability
reconoce los spans como de GenAI y da vistas ya hechas. Con los nuestros, si
esa integración no sale, los tableros se montan a mano y la sesión cumple igual
lo que promete el abstract.

Emitir ambos cuesta una línea por atributo. Quedarse corto el día del evento
cuesta el segmento 5 entero.

**Salvedad:** las convenciones `gen_ai.*` siguen marcadas como *Development* en
el registro de OpenTelemetry, no *Stable*. El núcleo lleva estable de forma
desde la v1.37.0, así que el riesgo es bajo — pero es otra razón para no
depender solo de ellas.

## El Collector es el plan de respaldo

**El agente nunca habla con Splunk.** Habla con el Collector, y el Collector
decide a dónde. Esa indirección convierte una dependencia dura en una línea de
configuración.

Por omisión solo está el exportador `debug`, que imprime las trazas completas
en los logs del pod:

```bash
./observabilidad/collector-up.sh --trazas
```

Eso significa que **puedes enseñar la cascada sin Splunk, sin credenciales y
sin internet** — la mitigación directa del riesgo que el `CLAUDE.md` §12 llama
*dependencia de internet el día del evento*. Si la red del recinto falla, el
segmento 5 no se cae: cambia de pantalla.

Añadir Splunk es descomentar un bloque del ConfigMap y listarlo en el pipeline.
El agente no se entera.

## Cómo correrlo

```bash
./observabilidad/collector-up.sh
```

```bash
kubectl -n agentes port-forward deploy/otel-collector 4318:4318
```

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 .venv/bin/python spike-mcp/agente.py
```

**Sin esa variable, el agente corre exactamente igual y no exporta nada.** Eso
es deliberado: la observabilidad no puede tumbar el demo. `trazas.iniciar()`
devuelve un tracer de mentira que se traga todas las llamadas.

## Lo que falta

**Las trazas cubren el agente, no el servidor MCP.** Los spans `execute_tool`
se crean del lado del agente, así que ves qué herramienta se llamó y cuánto
tardó — que es lo que preguntaste. Lo que **no** ves todavía es qué pasó dentro
del servidor MCP (el `SELECT` a Postgres).

Para eso haría falta que el contexto de traza viaje en la llamada HTTP a MCP.
Es posible —MCP va sobre HTTP y podría llevar la cabecera `traceparent`— pero
**no está comprobado si el SDK lo propaga solo**. Eso es la cereza de la
cereza.
