# Spike de MCP: el puente

Ataca el **único riesgo vivo** del plan (`CLAUDE.md` §9).

> **El modelo no habla MCP.** vLLM devuelve `tool_calls` en formato OpenAI. El
> servidor MCP espera llamadas MCP. En medio no hay nada — y ese "nada" hay que
> escribirlo.

Son cuatro traducciones:

| | De | A |
|---|---|---|
| 1 | herramientas MCP | esquema de `tools` de OpenAI |
| 2 | `tool_call` de OpenAI | `client.call_tool` de MCP |
| 3 | `CallToolResult` | mensaje `role=tool` |
| 4 | `usage` | `tokens.prompt` / `tokens.completion` |

La cuarta parece un detalle y no lo es: esos nombres son **exactamente** los que
después serán atributos de span. Por eso llegar a Splunk será envolver y no
reescribir.

## Estado

| | |
|---|---|
| Traducciones 1, 2 y 3 | **Verificadas** el 2026-09-19, servidor y cliente reales |
| Traducción 4 y el viaje completo | Falta: necesita el vLLM del host |

## Cómo correrlo

```bash
.venv/bin/pip install mcp
```

Terminal 1 — el servidor de herramientas:

```bash
.venv/bin/python spike-mcp/servidor_mcp.py
```

Terminal 2 — el agente, que cruza el puente:

```bash
.venv/bin/python spike-mcp/agente.py
```

Necesita `lab/endpoint.env`, que escribe `vllm-up.sh`. Si no existe, asume
`http://localhost:8000/v1`.

## Criterio de corte

Si el puente no funciona, **las tools se exponen por HTTP normal** y MCP se
queda como la lámina conceptual — que es donde vive su mejor aporte de todos
modos. No se gastan horas peleando con esto.

## La trampa que ya costó un rato

El SDK de MCP va por la **2.2.0** y cambió la API:

| Ya no existe (SDK 1.x) | Ahora |
|---|---|
| `FastMCP` | `mcp.server.MCPServer` |
| `streamablehttp_client` + `ClientSession` | `mcp.Client` |
| `tool.inputSchema` | `tool.input_schema` |
| `resultado.structuredContent` | `resultado.structured_content` |

Los ejemplos que hay por internet son casi todos del 1.x. Si algo no encaja,
sospecha de la versión antes que de tu código.

## Por qué no usamos un servidor MCP de Postgres ya hecho

Existen (el oficial fue archivado en 2025; el sucesor es Postgres MCP Pro).
Todos exponen **una** herramienta: `query` o `execute_sql`, con SQL arbitrario.
Para este demo es la forma equivocada, y el porqué está en `servidor_mcp.py`.

Resumen: el `CLAUDE.md` §4 exige tools que se expliquen solas en tres segundos,
`dispone_caso` tiene que ser una acción con significado para que el ataque la
abuse, el insight #2 dice que el control vive en el ejecutor —y un paso directo
a SQL no tiene control que enseñar—, y `exporta_evidencia` necesita ejecutar un
binario, cosa que ningún servidor de Postgres hace.

Eso sí: **enseñar su lista de herramientas al lado de la nuestra** es medio
minuto y vale por un argumento entero sobre lo que no hay que desplegar.

## Lo que este spike ya deja montado para el segmento 6

Las cuatro herramientas viven detrás de **la misma ruta**: `POST /mcp`. Cilium
verá el destino pero no cuál de las cuatro se llamó — incluida `dispone_caso`.

Eso no es un defecto del spike: es la lámina.
