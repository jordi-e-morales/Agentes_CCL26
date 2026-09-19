# Spike de SLIM

> **¿Qué es un "spike"?** Es un término de programación ágil: un experimento
> **acotado en tiempo** cuyo producto es **conocimiento**, no código de
> producción. Se hace cuando una decisión depende de algo que no sabes y que no
> puedes resolver leyendo documentación.
>
> Tiene tres rasgos que lo distinguen de ponerse a programar:
>
> 1. **Una pregunta concreta.** Aquí: *¿SLIM permite un salto lateral entre
>    agentes?*
> 2. **Un criterio de éxito fijado ANTES de empezar**, para no acabar
>    convenciéndote de que lo que salió ya está bien.
> 3. **Una fecha de corte.** Si se pasa, la respuesta es "no" y se activa el
>    plan B.
>
> El código de un spike es **desechable por diseño**. Si funciona, lo que te
> llevas es la respuesta, no el código. Por eso esto vive en `spike-slim/` y no
> dentro de la malla: cuando conteste la pregunta, probablemente se tire.
>
> Se hace un spike aquí porque SLIM es la dependencia más pesada del plan y no
> existe ni una línea que la valide.

**Si es tu primera vez con SLIM, lee antes
[CÓMO FUNCIONA SLIM](COMO-FUNCIONA-SLIM.md).** Explica desde cero qué es el
bus, qué es una app, qué es una sesión y por qué el salto lateral importa.

---

Resuelve la decisión abierta #1 del `CLAUDE.md`: *"qué runtime de AGNTCY se usa
y su madurez. Confirmar antes de la Fase A, porque es la dependencia más pesada
del plan."*

Hasta ahora la evidencia era cero. Lo único que existía en el repo anterior era
un bus *"estilo SLIM"* simulado en `core.py`, y la simulación está prohibida.

## El criterio, fijado de antemano

No basta con que dos procesos se manden mensajes. El `CLAUDE.md` §3 pide algo
concreto:

> Debe existir al menos un **salto lateral** agente a agente sin pasar por el
> centro: sin eso la malla es una estrella.

Así que el spike se aprueba solo si corre este flujo:

```
router  --(1) tarea-->  agente-a
                        agente-a  --(2) consulta-->  agente-b   <- SALTO LATERAL
                        agente-a  <--(3) respuesta--  agente-b
router  <--(4) resultado--  agente-a
```

El paso 2 es el que importa: `agente-a` abre **su propia sesión** con
`agente-b`, y el router no media, ni ve, ni reenvía esa conversación.

**Si el salto lateral no funciona**, SLIM baja de columna vertebral a
amplificador, se usa un transporte sustituto y se etiqueta en pantalla como
sustituto (regla de honestidad, §6).

## Cómo correrlo

Cuatro terminales. No necesita GPU, ni Kubernetes, ni el cluster.

```bash
.venv/bin/pip install slim-bindings
```

Terminal 1 — el bus:

```bash
.venv/bin/python spike-slim/nodo.py
```

Terminales 2, 3 y 4, **en este orden** (los que escuchan primero):

```bash
.venv/bin/python spike-slim/agente.py --rol b
```

```bash
.venv/bin/python spike-slim/agente.py --rol a
```

```bash
.venv/bin/python spike-slim/agente.py --rol router
```

## Lo que se aprendió leyendo el código de AGNTCY

Tres cosas que no estaban en la documentación y cambian el plan. El detalle
conceptual está en [CÓMO FUNCIONA SLIM](COMO-FUNCIONA-SLIM.md).

### 1. El nodo no necesita contenedor

`slim-bindings` trae el bus embebido, escrito en Rust. Un proceso de Python
levanta un nodo SLIM completo. Eso hace el spike reproducible en cualquier
máquina y quita una pieza de infraestructura del camino crítico.

### 2. SLIM trae identidad criptográfica de serie

Esto es lo más importante que encontré, y toca el insight #1 de la sesión.

El `CLAUDE.md` dice: *"un agente no es un modelo... lo que los hace distintos es
prompt, identidad y permisos"*. Resulta que SLIM no trata la identidad como un
añadido: un agente se da de alta con un nombre de tres partes
(`organización/espacio/aplicación`) y una credencial, y hay tres modos:

| Modo | Para qué |
|---|---|
| Secreto compartido | Desarrollo. Es lo que usa este spike |
| JWT + JWKS | Identidad verificable con claves públicas |
| **SPIFFE / SPIRE** | Identidad de carga de trabajo, emitida y rotada |

SPIFFE ya aparecía en la narrativa de la demo v1. Con esto deja de ser una
lámina y pasa a ser algo que se puede enseñar funcionando. **El segmento 1 se
vuelve más fuerte de lo previsto**: dos agentes sobre los mismos pesos, con
identidades criptográficamente distintas, emitidas por el sistema.

También hay MLS (cifrado extremo a extremo entre agentes) con `enable_mls`, y
un interruptor de OpenTelemetry en el propio runtime, que probablemente ahorre
trabajo en la Fase D.

### 3. Una precisión de honestidad para el segmento 3

**"Sin pasar por el centro" es una afirmación sobre la topología de la
aplicación, no sobre el camino de los paquetes.**

En SLIM todos los mensajes atraviesan físicamente el nodo, porque el nodo *es*
el bus. Lo que el salto lateral demuestra es que `agente-a` y `agente-b` se
hablan como iguales, sin que el router orqueste la conversación. Eso es lo que
separa una malla de una estrella, y es una propiedad real.

Pero en la sesión no se puede decir *"el tráfico no pasa por el centro"*,
porque sí pasa. Se dice: *"el router no participa en esta conversación"*.

Vale la pena tenerlo claro antes de escribir la lámina, no después.

## Estado

**Sin ejecutar.** Este código está escrito contra la API real de
`agntcy/slim-bindings` (leída del repositorio, no de un resumen), pero no se ha
corrido nunca. Hasta que alguien lo ejecute, el spike no ha demostrado nada y
la decisión abierta #1 sigue abierta.
