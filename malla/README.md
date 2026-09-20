# La malla

Dos agentes que deliberan, un router que los descubre, y los dos protocolos
donde les toca:

```
                A2A  entre AGENTES          MCP  hacia HERRAMIENTAS
```

## Cómo correrla

Hacen falta cuatro terminales, más vLLM y el servidor MCP ya arriba.

```bash
kubectl -n agentes port-forward deploy/servidor-mcp 9000:9000
```

```bash
.venv/bin/python malla/agente.py --rol investigador --puerto 7010
```

```bash
.venv/bin/python malla/agente.py --rol defensor --puerto 7011
```

```bash
.venv/bin/python malla/router.py
```

## El segmento 2, solo

Descubrir y elegir no necesitan el modelo. Son diez segundos y no tocan la GPU:

```bash
.venv/bin/python malla/router.py --solo-descubrir
```

```
1. DESCUBRIR — leyendo las Agent Cards
  agente-investigador
    sabe hacer : Argumentar riesgo
    tags       : triage, evidencia, riesgo
  agente-defensor
    sabe hacer : Objetar riesgo
    tags       : triage, evidencia, contraste

2. ELEGIR — la tarea necesita: 'riesgo'
  'riesgo' esta en los tags de agente-investigador  ->  elegido
```

**Nadie tenía la dirección de nadie.** El router la leyó de la tarjeta y eligió
por capacidad. Si mañana aparece un agente nuevo, lo encuentra sin que nadie lo
reprograme.

## Qué hace visible cada pieza

| | Qué enseña |
|---|---|
| Las Agent Cards | Segmento 2. Se leen de un vistazo |
| El sobre A2A impreso entero | Que hubo un mensaje, y qué decía |
| `MCP -> consulta_historial(...)` | Que la evidencia no la inventó el modelo |
| El salto lateral | Que es una malla y no una estrella |

### Por qué el sobre se imprime entero

No es depuración. El `CLAUDE.md` pide que la interfaz **haga visible el
mecanismo**, y un mensaje entre agentes que solo existe en la memoria de un
proceso no demuestra nada: la sala tendría que creerse que hubo uno.

### Qué hace distintos a los dos agentes

El prompt. Nada más.

Mismo modelo, mismos pesos, mismo servidor, las mismas cinco herramientas. Uno
sostiene que hay riesgo y el otro lo objeta porque su `system` dice cosas
distintas — y porque su tarjeta declara capacidades distintas.

Ese es el insight #1 de la sesión, y está en doce líneas de `agente.py`.

### El salto lateral

Cuando el investigador termina su argumento, **le habla directamente al
defensor**. El router no crea esa conversación, no la ve y no la reenvía.

Y como va por HTTP, **Cilium sí ve esa arista** y puede gobernarla. Con un bus
de mensajes en medio no podría: vería `agente → bus` y nada más. Por eso se
descartó SLIM (`CLAUDE.md` §3).

## Las tarjetas se validan, no se confían

```bash
.venv/bin/python malla/valida_tarjetas.py
```

Se escriben como JSON legible —porque se enseñan en pantalla— y se comprueban
contra el SDK de A2A. Ya cazó tres campos que me había inventado antes de que
llegaran a una lámina.
