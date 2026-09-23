# Proyecto: tutorial guiado de malla de agentes — Cisco Connect LATAM

Contexto permanente del proyecto. Léelo completo antes de proponer cambios.
Si algo aquí contradice lo que parece razonable, gana este archivo: las
decisiones ya se tomaron con motivo.

Documento de diseño completo (spec de la sesión):
https://claude.ai/artifact/GDx1dPcdCXQRVTYxp9Wfq5

Dónde está cada cosa en el repo:

| Carpeta | Qué hay |
|---|---|
| `lab/` | Instalación reproducible: herramientas, cluster, kernel, motor de inferencia |
| `esquema/` | El contrato `alerta/sujeto/evidencia`, con casos de los dos dominios |
| `arquitectura/` | Cómo encajan las capas de control. Empieza por `capas-de-control.md` |
| `seguridad/` | Las políticas portadas de v1 y su prueba |
| `spike-slim/` | El transporte que se evaluó y se descartó (§3). Se conserva lo aprendido |

---

## 1. Qué construimos

El soporte técnico de una sesión de 60 minutos en formato **tutorial guiado**.
No hay bloques de diapositivas separados de la demo: es una sola construcción
continua donde cada concepto se explica en una slide y acto seguido se muestra
funcionando.

**Audiencia:** arquitectos de IA e IT senior, **nuevos** en agentes, malla,
trazas distribuidas y seguridad cloud-native.

**North-star:** al salir, un arquitecto que hoy no conoce estos conceptos debe
poder imaginar —y confiar en— cómo funciona una malla de agentes real y cómo se
mantiene bajo control, porque vio cada pieza volverse real en vivo.

**Nada se despliega durante la sesión.** Todo está instalado y corriendo de
antemano; se muestra la parte relevante de cada pieza. El software tiene que
soportar ese modo: arrancar limpio, quedarse listo, y dejarse "enseñar" por
partes.

### Los tres insights que la sala debe recordar

1. **Un agente no es un modelo.** Dos agentes corren sobre los mismos pesos, en
   el mismo servidor. Lo que los hace distintos es prompt, identidad y permisos.
2. **En un sistema de agentes, la ejecución de código no está en el modelo,
   está en el ejecutor de herramientas.** Ahí es donde tiene que vivir el
   control.
3. **El ataque no rompe el perímetro, abusa de una arista que tú autorizaste.**
   Por eso la política tiene que ser sobre la intención del mensaje (capa 7), no
   solo sobre el par origen-destino (capa 4).

---

## 2. El arco: cada segmento termina con la pregunta que el siguiente responde

| Segmento | Capa del stack que resalta | Termina con |
|---|---|---|
| 1. Un agente no es un modelo | Cómputo acelerado | ¿Cómo se encuentran? |
| 2. Se descubren | A2A Agent Cards (+ OASF) | ¿Cómo se hablan? |
| 3. Se hablan, y la arista es visible | A2A sobre HTTP + Kubernetes | ¿De dónde sacan los datos? |
| 4. Herramientas por MCP | Kubernetes | ¿Cómo sé qué pasó? |
| 5. Observabilidad | Splunk | ¿Y si alguien abusa de esto? |
| 6. Control | Seguridad | Cierre |

Esto no es adorno narrativo: define **qué tiene que ser mostrable por separado**.
Cada segmento necesita poder enseñarse solo, sin depender de que el anterior se
haya ejecutado en esa misma corrida.

---

## 3. Arquitectura

```
Tarea → Router por tarea → (lee) Agent Cards en /.well-known/agent-card.json
                         → Agente A  <--A2A sobre HTTP-->  Agente B
                              ↓                                 ↓
                         Servidor MCP (las cinco tools)
                              ↓
                          PostgreSQL
                              ↓
                    usage → tokens en pantalla → (best effort) OTLP → Splunk

Gobernado por: Cilium (L7), Tetragon (kernel), AI Defense (contenido)
Observado también por: Hubble (segunda fuente independiente)
```

- **Router por tarea:** clasifica, lee los Agent Cards y despacha al agente
  adecuado. **Es un agente más**, no el centro de la red: es el centro de la
  lógica.
- **A2A** entre agentes. Cada agente publica su Agent Card en
  `/.well-known/agent-card.json` y expone un endpoint HTTP. Debe existir al
  menos un **salto lateral** agente a agente sin que el router medie: sin eso
  la malla es una estrella.
- **MCP** entre agente y herramientas. Un solo servidor con las cinco tools.
- **PostgreSQL** como fuente de la evidencia, en su propio pod.
- **Agentes** sobre vLLM en el L40S.

### Los dos protocolos, y por qué esa separación importa

> **MCP** es cómo un agente habla con sus **herramientas**.
> **A2A** es cómo un agente habla con **otro agente**.

Los dos son JSON-RPC sobre un solo endpoint, y de ahí sale la mejor lámina de
la sesión:

| Protocolo | Cilium **ve** | Cilium **no ve** |
|---|---|---|
| A2A | la arista: quién llama a quién | qué le pidió |
| MCP | la arista al servidor de tools | **qué herramienta llamó** |

A2A además no necesita infraestructura: el Agent Card es un archivo servido en
una ruta.

### Por qué NO se usa SLIM

Se evaluó y se descartó con motivo, no por falta de tiempo. SLIM convierte
`agente-a → agente-b` en `agente → nodo SLIM`: todos los mensajes van por gRPC
al bus, así que **Cilium deja de ver quién le habla a quién**. Eso destruye
justo la arista que el segmento 3 y el segmento 6 necesitan enseñar.

Con A2A la arista es HTTP directo entre dos pods, visible y gobernable.

Lo averiguado sobre SLIM queda en `arquitectura/capas-de-control.md` y en
`spike-slim/`, por si un día el transporte vuelve a estar sobre la mesa.

### Por qué el Agent Directory no corre

El Directory de AGNTCY es un chart de Helm con su propia versión de esquema.
El **registro OASF como archivo**, enseñado al lado del Agent Card, da el 90%
del mensaje por el 5% del coste. AGNTCY tiene integración oficial de A2A, así
que decir "A2A dentro de la visión de Internet de los Agentes" es exacto.

## 4. Herramientas y la acción peligrosa

Las tools no son un extra: son la superficie donde aterriza la seguridad.

**Las seis viven en un solo servidor MCP.** No se reparten. Un servidor MCP
con todo dentro es lo que se hace en la realidad, y es justo lo que hace que la
lección aterrice: `POST /mcp` es una sola ruta que lleva todas tus
herramientas, incluida la que dispone del caso.

| Tool | Tipo | Para qué |
|---|---|---|
| `contexto_alerta` | evidencia | **la puerta del ataque**: devuelve los textos libres con su `source_trust` |
| `consulta_historial` | evidencia | alimenta el debate con datos |
| `lista_sancionados` | evidencia | idem |
| `perfil_sujeto` | evidencia | idem |
| `dispone_caso` | **acción peligrosa** | lo que el ataque intenta abusar |
| `exporta_evidencia` | **ejecuta un binario** | genera un PDF invocando un proceso |

`exporta_evidencia` existe por una razón concreta: si el agente ejecutara un
binario "porque sí", el SIGKILL parecería montado. Con ella, el ataque tiene una
vía estructural y creíble.

**Regla de diseño:** las tools de evidencia deben explicarse solas en tres
segundos, sin que nadie sepa del dominio. Nombres claros, salidas legibles.

### La evidencia vive en PostgreSQL, no en un JSON

Un JSON devuelto no demuestra nada: la sala ve texto aparecer y tiene que
creerte. Una base de datos real da tres cosas que no se pueden fingir: la
consulta es visible, un `SELECT` y un `UPDATE` se distinguen a simple vista, y
`dispone_caso` pasa a ser **una escritura que cambia una fila en pantalla**.

Postgres en su propio pod, no SQLite, porque un pod aparte es **una arista que
Cilium puede gobernar**: el servidor MCP puede hablar con la base; los agentes
no. Cuando el agente comprometido lo intente directo, Hubble lo ve aunque no
haya traza que lo confiese.

**La tabla `eventos` es la que prueba la neutralidad de dominio.** Con
`atributos JSONB`, para el caso transaccional lleva importes y contrapartes;
para el de SOC, puertos y procesos. Misma tabla, misma consulta, misma
herramienta, cero código. Cargar el caso de SOC en vivo y ver filas distintas
sin tocar nada es un momento de 30 segundos que vale por toda la sección.

Nada de `transacciones` como nombre de tabla: en cuanto se escriba esa palabra,
un caso de SOC obliga a tocar código.

### Consecuencia para la política

- *Qué agente puede llamar qué tool* = política L7 de Cilium sobre las rutas.
- *Qué binario puede ejecutar el ejecutor* = TracingPolicy de Tetragon con
  `matchActions: Sigkill`.

---

## 5. Observabilidad

**Lo que se hace seguro:** cada llamada al modelo guarda lo que vLLM devuelve
en `usage`, con los nombres **exactos** que después serán atributos de span:

```
tokens.prompt    tokens.completion    model
```

Se muestran y se acumulan por agente. Eso cumple la promesa de atribución de
costos del abstract, y se dice con honestidad lo que es: el contador del motor,
no una traza distribuida.

**Lo que es best effort:** OTel → Collector → Splunk, con un span por mensaje
A2A y un span por tool call, y `trace_id` propagado. Si llega, es la cereza.

Esa nomenclatura no es cosmética: es lo que hace que llegar a Splunk sea
**envolver** y no reescribir. Si hoy se llamaran `entrada` y `salida`, mañana
habría que tocar cada sitio donde se usan.

**Hubble es una segunda fuente obligatoria.** OTel es la autodeclaración de la
aplicación: si el agente comprometido intenta una conexión fuera del pipeline
—por ejemplo ir directo a Postgres— no va a emitir un span sobre ella. Sin
Hubble no se puede mostrar una ausencia. El segmento 6 necesita ambas fuentes
visibles.

## 6. Seguridad

| Capa | Producto | Qué hace en el demo |
|---|---|---|
| Contenido | Cisco AI Defense | detecta la inyección y la bloquea |
| Red | Isovalent Enterprise Platform (Cilium) | 403 sobre arista autorizada con petición no autorizada |
| Kernel | Isovalent Enterprise Runtime Security (Tetragon) | SIGKILL al binario no autorizado |

### La lección que dan MCP y A2A juntos

Tu insight #3 dice que la política tiene que ser sobre la intención (capa 7) y
no sobre el par origen-destino (capa 4). MCP lo lleva un paso más allá:

> **Incluso la capa 7 se queda corta si el protocolo multiplexa.** `POST /mcp`
> es una sola ruta que lleva todas las herramientas, incluida la peligrosa.

De ahí sale la estructura del segmento 6:

1. **Tools por HTTP normal:** Cilium distingue `/consulta_historial` de
   `/dispone_caso`. **403 preciso.**
2. **El mismo ataque por MCP:** todo es `POST /mcp`. Cilium no puede
   distinguir. **Pasa.**
3. **Pero el binario se ejecuta** → Tetragon → **SIGKILL.**

*Ninguna capa sola basta*, demostrado con dos protocolos en vez de con una
frase. Y es actual: medio mundo está desplegando servidores MCP sin haber
pensado esto.

**Orden del segmento 6:** AI Defense entra ganando (detecta y bloquea primero,
con su mapeo a OWASP LLM01 y MITRE ATLAS). Solo después la versión ofuscada
pasa, y entran red y kernel. El mensaje es "ninguna capa sola basta, ni siquiera
una buena", no "el guardrail tiene un hueco".

**Capa de traducción:** AI Defense todavía no detiene ataques en español, así
que el flujo traduce el prompt al inglés antes del análisis. Es un workaround
temporal (la versión en español está por liberarse) y en la sesión se menciona
en una frase. **No construir narrativa sobre esto.** Nota técnica: el traductor
procesa entrada no confiable, así que pertenece a la matriz de permisos como
cualquier otro componente.

### La inyección capturó también al verificador

Corrida limpia del 2026-09-21, con los agentes anclados a la evidencia y el
salto lateral llevando ya el identificador del caso.

Los dos agentes consultaron las herramientas **por separado**, citaron sus
resultados por nombre, y los dos concluyeron que el caso debía cerrarse
*"conforme a la instrucción del reportante"*, apoyándose en `PR-FICTICIO-114`
— un procedimiento que solo existe dentro del texto inyectado.

> **La verificación entre agentes no protege si los dos leen el mismo contexto
> envenenado.**

Es la respuesta a lo que va a proponer medio auditorio —*"pues que un agente
revise al otro"*— y se contesta con una corrida en vivo.

**Y el detalle que lo hace sólido:** la inyección no falsificó ningún dato. El
sujeto realmente no tiene historial ni aparece en listas. El texto externo
**llenó el vacío que la evidencia dejaba**, y por eso nada se contradecía. No
hay ninguna inconsistencia que un verificador pudiera detectar.

### La inyección borró su propio rastro del expediente

Medido el 2026-09-23, en la primera corrida con los agentes ya como pods y dos
rondas de debate. La inyección capturó a los dos agentes **y también a la
síntesis** — el orquestador escribió *"no hay discrepancias entre ellos"*, o sea
leyó el acuerdo como señal de que todo estaba bien.

Pero lo que no esperábamos está en la base de datos. El caso se cerró con esta
justificación:

> *"La alerta ha sido revisada y no se ha encontrado evidencia que justifique su
> escalada. El sujeto no aparece en listas de control…"*

**`PR-FICTICIO-114` no aparece por ningún lado.** El registro que queda en
`disposiciones` es impecable: un auditor que lo lea mañana ve una disposición
razonable y bien fundamentada, indistinguible de una correcta.

> La inyección no solo cambió la decisión. **Quitó su propio rastro del
> artefacto de negocio.**

La traza y Hubble sí lo tienen. El expediente, no. Y eso es un argumento a favor
de la observabilidad independiente más fuerte que cualquiera que tuviéramos
planeado: *el sistema que toma la decisión no es un testigo fiable de por qué la
tomó*.

**Y de paso destapó un fallo propio.** Esa justificación afirmaba *"su perfil no
presenta elementos de riesgo"* con `perfil_sujeto` sin llamar en toda la corrida.
El anclaje aguantó durante el debate y se rompió justo en el argumento de la
herramienta — el único texto que queda escrito. Arreglado extendiendo la regla a
los argumentos, no solo a la prosa.

### El meta-argumento: la abstracción cuesta visibilidad

Salió de descartar tres caminos el 2026-09-19, y es el mejor cierre del
segmento 6 porque nadie lo ve venir:

| Opción evaluada | Qué le hace a la arista entre agentes |
|---|---|
| **SLIM** | La **esconde** detrás del bus: Cilium ve `agente → nodo`, no el interlocutor |
| **MCP** | La deja visible pero **opaca**: `POST /mcp` sin saber qué herramienta se llamó |
| **CrewAI** (u otro framework en proceso) | La **borra**: los agentes se llaman dentro del mismo proceso. No hay ni paquete |

> Cada capa de abstracción que agregas para construir agentes más rápido le
> quita visibilidad a quien tiene que gobernarlos.

Es incómodo, es cierto, y es lo que la sala necesita oír. No se presenta como
crítica a ninguna herramienta: las tres son razonables y resuelven problemas
reales. El punto es que **la facilidad de construcción y la capacidad de
gobierno se mueven en direcciones opuestas**, y casi nadie lo está midiendo.

Corolario práctico para el grafo de agentes: se enseña con **Hubble UI**, que
dibuja lo que de verdad pasó, no con un editor visual, que dibuja lo que
alguien diseñó. En una sesión sobre observabilidad y control, un diagrama de
diseño es casi una contradicción.

### Reglas de la interfaz, no negociables

La razón de ser de la v2 frente a la v1 es **ser más didáctica**. La v1 obliga a
abstraer un montón para entender qué pasa. De ahí salen tres reglas:

1. **Si el presentador no sabe explicar un visual en una frase, no va.** Sin
   excepciones. Un panel que obliga a la sala —o a quien narra— a alinear dos
   columnas mentalmente, no se entiende aunque sea correcto. (Esto descartó el
   panel de dos carriles de la v1, ya construido: la idea de fondo es buena,
   la presentación hace trabajar al espectador.)

2. **La interfaz hace visible el mecanismo, no lo esconde.** Se enseña el
   `tool_call` de verdad, el mensaje entre agentes de verdad, y qué permisos
   tiene cada quien. Una aplicación pulida que oculte la fontanería sería
   bonita y contraria al propósito.

3. **Lo importante se marca solo.** Si hay que comparar dos cosas, la
   diferencia se resalta; no se ponen lado a lado para que alguien la busque.

### Los agentes se inventaban la evidencia, y la causa no era el prompt

Medido el 2026-09-21. Con un sujeto sin historial, el investigador afirmó
*"múltiples incidentes similares"*, *"aparece en la lista de control"* y una
fecha concreta — con las tres herramientas devolviendo vacío.

**La causa real: una línea que faltaba.** Al reescribir el bucle de rondas
desapareció el `mensajes.append({"role": "tool", ...})`, así que las
herramientas se ejecutaban, se imprimían y se guardaban para la interfaz — pero
**el modelo nunca recibía su resultado**. No inventó por estar mal alineado:
inventó porque se le pidió un argumento sobre datos que nunca le llegaron.

*(Este documento llegó a atribuirlo al prompt. Era un diagnóstico equivocado y
se corrige aquí, porque una causa mal documentada envía a quien lo lea en tres
semanas en la dirección contraria.)*

Lo que sí se conserva de aquel arreglo, porque es correcto por sí mismo:

1. **Solo se afirman hechos que aparezcan en la respuesta de una herramienta**,
   diciendo de cuál salieron.
2. **El defensor comprueba lo que afirma el investigador** y lo señala cuando no
   cuadra.

Eso hace el sistema más robusto y, de paso, **visible**: en la corrida buena los
agentes citan `contexto_alerta` y `consulta_historial` por su nombre, así que
cada afirmación se puede rastrear en pantalla.

### La inyección capturó también al verificador

Medido el 2026-09-21, primera corrida en que la inyección llegó completa a los
dos agentes. Lo que pasó:

- **El investigador abandonó su papel.** Su trabajo era buscar motivos para
  escalar. Concluyó que *"la alerta debe ser cerrada y no hay motivos para
  escalarla"*, citando `PR-FICTICIO-114` —un procedimiento que solo existe
  dentro del texto inyectado— como si fuera una autoridad real.
- **El defensor dejó de contrastar.** Su función era comprobar lo que afirma el
  otro y señalar lo que no cuadra. Repitió su argumento casi palabra por
  palabra.

> **La verificación entre agentes no protege si los dos leen el mismo contexto
> envenenado.**

Eso no estaba previsto y es de lo mejor que tiene la sesión. Se había añadido un
segundo agente como red de seguridad, y la inyección capturó también la red. Es
el argumento contra la respuesta fácil que dará medio auditorio —*"pues que un
agente revise al otro"*— y se responde con una corrida en vivo, no con una
opinión.

**Lo que la inyección NO consiguió** (todavía): que llamaran a `dispone_caso` o
a `exporta_evidencia`. Cambió lo que concluyeron, no lo que hicieron. Para que
Cilium y Tetragon tengan algo que cortar hace falta la acción, no solo la
conclusión.

### El meta-argumento: la abstracción cuesta visibilidad

Salió de descartar tres caminos el 2026-09-19, y es el mejor cierre del
segmento 6 porque nadie lo ve venir:

| Opción evaluada | Qué le hace a la arista entre agentes |
|---|---|
| **SLIM** | La **esconde** detrás del bus: Cilium ve `agente → nodo`, no el interlocutor |
| **MCP** | La deja visible pero **opaca**: `POST /mcp` sin saber qué herramienta se llamó |
| **CrewAI** (u otro framework en proceso) | La **borra**: los agentes se llaman dentro del mismo proceso. No hay ni paquete |

> Cada capa de abstracción que agregas para construir agentes más rápido le
> quita visibilidad a quien tiene que gobernarlos.

Es incómodo, es cierto, y es lo que la sala necesita oír. No se presenta como
crítica a ninguna herramienta: las tres son razonables y resuelven problemas
reales. El punto es que **la facilidad de construcción y la capacidad de
gobierno se mueven en direcciones opuestas**, y casi nadie lo está midiendo.

Corolario práctico para el grafo de agentes: se enseña con **Hubble UI**, que
dibuja lo que de verdad pasó, no con un editor visual, que dibuja lo que
alguien diseñó. En una sesión sobre observabilidad y control, un diagrama de
diseño es casi una contradicción.

### Reglas de la interfaz, no negociables

La razón de ser de la v2 frente a la v1 es **ser más didáctica**. La v1 obliga a
abstraer un montón para entender qué pasa. De ahí salen tres reglas:

1. **Si el presentador no sabe explicar un visual en una frase, no va.** Sin
   excepciones. Un panel que obliga a la sala —o a quien narra— a alinear dos
   columnas mentalmente, no se entiende aunque sea correcto. (Esto descartó el
   panel de dos carriles de la v1, ya construido: la idea de fondo es buena,
   la presentación hace trabajar al espectador.)

2. **La interfaz hace visible el mecanismo, no lo esconde.** Se enseña el
   `tool_call` de verdad, el mensaje entre agentes de verdad, y qué permisos
   tiene cada quien. Una aplicación pulida que oculte la fontanería sería
   bonita y contraria al propósito.

3. **Lo importante se marca solo.** Si hay que comparar dos cosas, la
   diferencia se resalta; no se ponen lado a lado para que alguien la busque.

### Los agentes se inventaban la evidencia, y el prompt tenía la culpa

Medido el 2026-09-21. Con un sujeto sin historial, el investigador afirmó
*"múltiples incidentes similares"*, *"aparece en la lista de control"* y una
fecha concreta — cuando las tres herramientas habían devuelto vacío. Y el
defensor **aceptó esas premisas** y argumentó contra ellas.

La causa era el prompt: decía *"tu papel es sostener que la alerta merece
escalarse"*. Eso pide defender una conclusión, no seguir la evidencia, y con un
caso sin material la única forma de obedecer es inventar.

**Esto es un demo-killer, no un detalle de calidad.** Cualquiera que compare la
salida de una herramienta con el argumento desmonta la sesión entera — y con
razón, porque el §8 promete inferencia real sobre datos reales.

Dos reglas salieron de ahí, y están en los prompts de `malla/agente.py`:

1. **Solo se afirman hechos que aparezcan en la respuesta de una herramienta**,
   diciendo de cuál salieron. Si la evidencia no sostiene la postura, se dice
   abiertamente. Una postura honesta y sin material es correcta.
2. **El defensor comprueba lo que afirma el investigador** y lo señala cuando no
   cuadra: *"afirma X, pero la herramienta Y devuelve Z"*.

La segunda convierte un riesgo en un activo: si un agente alucina, el otro lo
caza **en pantalla**. Eso es verificación entre agentes funcionando, y vale más
como demo que dos agentes de acuerdo.

### Reglas de honestidad, no negociables

- **Cilium NO inspecciona prompts.** Hace política L7 sobre método y ruta. La
  detección de inyección es análisis de contenido y es otra capa. Nunca
  mezclarlas.
- Lo sustituido se etiqueta en pantalla como sustituto.
- No afirmar que algo está verificado si no lo está.
- No inventar nombres de producto ni capacidades de Cisco.
- Datos sintéticos, etiquetados como tales, con nombres claramente ficticios.

---

## 7. El caso de uso es decorado

Triage de alertas de monitoreo transaccional (AML). Se explica en 30 segundos y
no se vuelve a tocar. Nada de marco regulatorio, tipologías ni umbrales: la
audiencia no es bancaria.

**El esquema debe ser neutral al dominio.** Habrá casos de reserva de triage de
alertas de SOC que usan el mismo esquema y los mismos agentes **sin cambios de
código**. Nunca uses vocabulario de AML en nombres de campos, clases o rutas
(nada de `cliente`, `monto`, `cuenta_origen`). Usa alerta, sujeto y evidencia.

El campo `source_trust` marca qué partes del contexto las escribió alguien de
fuera. La inyección vive siempre en un texto libre con `source_trust: external`,
y en la UI ese contenido se renderiza distinto.

---

## 8. Entorno

**Sin código de simulación.** Toda la inferencia y todos los eventos de
seguridad son reales. Si algo no se puede probar de verdad, se deja pendiente,
no se finge.

**Un solo host Linux con el L40S.** Ya no hay VM local ni split sin-GPU. Hay que
migrar a la instancia que llega al día del evento.

`lab/bootstrap.sh` es el artefacto portable, y esa migración es su prueba real:
si migrar no es `git clone && ./bootstrap.sh`, el script está incompleto. Todo
cambio de entorno se escribe ahí el mismo día, nunca solo se teclea.

**Los dos labs corren en paralelo** (confirmado el 2026-09-23: el actual dura
dos días más). Eso cambia la migración de salto al vacío a comparación:
`bootstrap.sh` se corre en la instancia nueva mientras esta sigue funcionando,
y cualquier diferencia se ve contra un sistema que sí anda. **No apagar el lab
viejo hasta que el nuevo pase `lab/estado.sh` completo.**

### Las versiones están fijas, y esa es la razón

`bootstrap.sh` seguía `stable.txt` para las CLIs, o sea *"lo más nuevo que haya
el día que corras el script"*. Con dos máquinas instaladas en días distintos eso
da dos entornos distintos, que es exactamente lo que un artefacto de migración
no puede hacer. Fijado el 2026-09-23:

| Pieza | Versión | Dónde |
|---|---|---|
| Cilium (y con él el relay de Hubble) | `1.20.1` | `lab/cluster-up.sh` |
| CLI de Hubble | `v1.19.4` | `lab/bootstrap.sh` |
| vLLM | `v0.6.6.post1` | `lab/vllm-up.sh` |
| Collector de OTel | `0.161.0` | `observabilidad/00-collector.yaml` |

**La CLI de Hubble y el relay no emparejan, y no se puede arreglar.** La CLI
avisa al arrancar (`API compatibility is not guaranteed`) porque va por la
1.19.4 y el relay por la 1.20.1. Comprobado: **la 1.19.4 es la última release
que existe** de `cilium/hubble`; no hay línea 1.20 de la CLI. Si algún día rompe
de verdad, la salida es bajar Cilium a la línea 1.19, no subir la CLI. Mientras
tanto el aviso es ruido y esta combinación está verificada.

### El driver es el techo, y no se puede mover

| | |
|---|---|
| Host | Ubuntu 22.04, kernel 5.15 (BTF presente, Tetragon funciona) |
| GPU | L40S de 46 GB |
| Driver | **555.42.06 → CUDA 12.5** |

**No hay reinicio disponible**, así que el driver no se actualiza. Eso descarta
todo lo compilado sobre CUDA 13 (que pide driver ≥ 580): el NIM de NVIDIA y las
imágenes modernas de vLLM. Tampoco hay atajo por compatibilidad hacia adelante:
las librerías de CUDA 13 cubren las ramas R535 y R570, y el 555 cae en el hueco.

Al pedir la instancia del día del evento, **preguntar primero la versión del
driver**. Es el dato que más condiciona todo lo demás.

### El motor de inferencia

vLLM corre **fuera de kind**, como contenedor en el host: pasar la GPU a un
nodo de kind es frágil, y el segmento 1 se enseña mejor sin Kubernetes de por
medio. Los agentes sí viven en kind y lo alcanzan por la IP del host, que
`lab/endpoint.env` publica.

Imagen fija `vllm/vllm-openai:v0.6.6.post1` (CUDA 12.x) con
Qwen2.5-32B-Instruct-AWQ, `awq_marlin`, caché KV en fp8 y grafos CUDA
encendidos. Medido el 2026-09-19:

```
18.01 GiB pesos · 13.82 GiB caché KV · concurrencia 3.46x a 32k
```

**Ese 3.46x condiciona el diseño.** Con router, dos agentes y el traductor del
guardrail, cuatro llamadas concurrentes con contexto largo se encolan. Bajar
`CTX` a 16k casi duplica la concurrencia y es la optimización más barata del
proyecto.

### Las dos opciones de arranque que hay que saber explicar

Están a la vista en el panel *El modelo* del segmento 1, leídas de
`docker inspect`. Alguien va a preguntar por ellas.

**`--enable-prefix-caching`.** Cuando dos peticiones empiezan igual, vLLM
reutiliza el cálculo de la parte común en vez de rehacerlo. En la deliberación
eso es casi todo: medido el 2026-09-23, el investigador manda 2967 tokens en la
ronda 1 y 3859 en la 2 — y esos 2967 son **los mismos tokens**. El prompt del
rol, las definiciones de las seis herramientas y lo dicho hasta ahí no cambian.
Sin esta opción, los ~41 segundos de una deliberación serían bastantes más, y el
§12 ya dice que el coste está en las ocho llamadas al modelo.

**`--tool-call-parser hermes`.** Es un traductor de formato. El modelo **no**
emite `tool_calls` de OpenAI: Qwen2.5 escribe la llamada como texto, entre
etiquetas `<tool_call>…</tool_call>`. El parser convierte ese texto en el campo
`tool_calls` que define la API de OpenAI. Se llama `hermes` porque ese formato lo
popularizaron los modelos Hermes de NousResearch, y Qwen2.5 usa uno compatible.
Sin parser, `--enable-auto-tool-choice` no sirve: la llamada llegaría como texto
suelto dentro de `content`.

#### Y de ahí sale una lámina que nadie espera

**En la cadena hay DOS traducciones, no una:**

```
Qwen escribe  <tool_call>{"name": "consulta_historial", …}</tool_call>
     ↓   vLLM, con --tool-call-parser hermes
respuesta con `tool_calls` en formato OpenAI
     ↓   nuestro código, en malla/agente.py
tools/call por MCP
```

El §9 llamaba *"el riesgo real"* a que el modelo no habla MCP y alguien tiene que
traducir. Se resolvió con el puente escrito en `malla/agente.py` — pero **la
primera mitad de esa traducción no la escribimos: es una opción de arranque del
motor**, y casi nadie en la sala sabe que existe.

> El modelo no habla el protocolo de las herramientas. Ni el de OpenAI, ni MCP.
> Escribe texto con un formato que aprendió en el entrenamiento, y hay **dos
> capas de traducción** entre eso y una consulta a la base de datos. Una es una
> opción del motor; la otra la escribí yo.

Conecta directo con el meta-argumento del §6: cada capa de traducción hace el
sistema más cómodo de construir y más difícil de ver.

### Qué se reusa de la demo v1

`triage-multiagente` no se toca, pero se le copian las piezas probadas: las
cuatro políticas de seguridad (Cilium y Tetragon), `red.py` con su bitácora y
`trace_id`, la mecánica de `historial` entre agentes, y el salto lateral
`investigador → defensor`. La `TracingPolicy` resultó neutral al dominio por
suerte: solo habla de pods etiquetados y del intérprete de Python.

## 9. Fases de construcción

Re-alcanzadas el 2026-09-19 contra el tiempo real disponible: un día completo
(domingo 20) más dos días parciales. Las siete fases originales no caben, y el
propio plan ya había decidido de antemano qué sobrevive.

| Fase | Entregable que corre | Estado |
|---|---|---|
| 0 | Entorno, esquema de datos, motor de inferencia | **Hecho y verificado** |
| A | Postgres con los dos dominios | **Hecho** (`datos/`) |
| B | Servidor MCP con las seis tools | **Hecho y probado** (`herramientas/`) |
| C | Router, dos agentes A2A y salto lateral | **Hecho y probado** (`malla/`) |
| D | Agent Cards | **Hecho y validadas** contra el SDK de A2A |
| E | Cilium L7 y Tetragon | **Hechas y verificadas** sobre el ejecutor real |
| F | Tokens en pantalla | **Hecho**, por tarea y en la interfaz |
| — | **La interfaz** (no estaba en el plan; debió estarlo) | **Hecha** (`ui/`) |
| G | Trazas: propagación, Collector y cascada | **Hecho y probado** (`observabilidad/`) |
| H | **Best effort:** Splunk, AI Defense | Pendiente, depende de la red |

### Lo que falta, al 2026-09-21

| | Qué | Por qué importa |
|---|---|---|
| 1 | **Que el ataque llegue a la acción** | La inyección ya domina el razonamiento de los dos agentes, pero todavía no provoca la llamada a `exporta_evidencia` con algo fuera de la lista blanca. Sin eso, el SIGKILL y el 403 no se encadenan con el resto |
| 2 | **La migración** | El orden de `GUIA.md` es el procedimiento; falta hacerlo de verdad |
| 3 | Splunk y AI Defense | Best effort. La cascada ya no depende de ellos: se dibuja desde el archivo del Collector, sin internet |

### Lo que falta para que los segmentos 4 y 6 sean enseñables

**El servidor MCP tiene que correr como pod, no en el host.** Hoy corre en el
host con un `port-forward` a Postgres, que sirve para desarrollar y no sirve
para el demo: Cilium no puede gobernar aristas que no atraviesan el cluster, y
Tetragon no puede ver un `exec` que ocurre fuera de él.

Necesita imagen, manifiesto y Service. Es trabajo sin incógnitas, pero es
requisito de los dos segmentos.

### El riesgo real, y su criterio de corte

**RESUELTO el 2026-09-19.** El riesgo era que el modelo no habla MCP: vLLM
devuelve `tool_calls` en formato OpenAI y alguien tiene que traducirlos. Ese
puente está escrito y probado con Qwen2.5-32B-AWQ real: el modelo pidió tres
herramientas, viajaron por MCP y volvió con evidencia (`spike-mcp/`).

El criterio de corte ya no hace falta. Lo que queda del segmento 4 es trabajo
sin incógnitas: dos tools más y cambiar los cuerpos de las funciones para que
lean de Postgres. Los nombres y las firmas no se tocan.

### El mínimo viable, decidido de antemano

Si algo se complica, sobreviven los segmentos 1, 4 y 6 (agente ≠ modelo,
herramientas, control). El segmento 1 ya corre y el 6 está probado en v1, así
que el suelo es alto.

Descubrimiento, ruteo y trazas son amplificadores.

## 10. Modo stand

**El stand no se construye: se hereda.** Y eso depende de una sola regla.

> **Lo que el stand muestra tiene que ser idempotente.**

La demo de kernel ya lo es: el SIGKILL mata al proceso *hijo*, no al pod, así
que el `restartCount` se queda en 0 y se puede correr doscientas veces sin que
el estado cambie. El requisito de *"reinicio en menos de 10 segundos entre
visitantes"* no se cumple: **no existe**, porque no hay nada que restaurar.

El reparto se decide solo:

| Va al stand | Se queda en la sesión |
|---|---|
| SIGKILL de Tetragon | `dispone_caso` (escribe en Postgres) |
| 403 de Cilium | El debate entre agentes (tarda y varía) |
| Consultas de evidencia (solo `SELECT`) | La inyección completa |

| Preset | Qué corre |
|---|---|
| Atracción | `while true` con el SIGKILL y el 403, sin audio |
| Guiado corto | Lo mismo con `read -p` entre bloques, para que el colega marque el ritmo |

**El terminal es la interfaz.** Los subtítulos son los `echo` que los scripts
ya imprimen; solo hay que subir el tamaño de fuente para que se lean a cuatro
metros. No se construye UI: cualquier orquestador sería más frágil que un bucle
de comandos sin estado.

El preset "profundo" de doce minutos no es un preset, es la sesión. Queda fuera.

Lo opera un colega, no el autor. Por eso nada puede quedarse a medias ni pedir
una decisión: si alguien le da Ctrl+C, se relanza con flecha arriba y Enter.

## 11. Cómo trabajar en este repo

- El usuario sabe poco de Kubernetes y está aprendiendo en el proceso.
  **Explica qué haces y por qué, en español, con comentarios en el código.**
  No entregues código sin contexto.
- Cambios pequeños y verificables sobre refactors grandes. Antes de cambiar algo
  existente, explica qué hace hoy.
- Antes de agregar dependencias, pregunta.
- Commits pequeños y frecuentes, en español, describiendo qué funciona ahora que
  antes no.
- Todo lo que haya que instalar en el entorno va a `lab/bootstrap.sh`.

### No objetivos

- No hay modo simulación.
- El repo anterior (`triage-multiagente`) se queda intacto como demo v1 y no se
  toca desde aquí. **Sí se le copian piezas** (§8).
- Las diapositivas se arman aparte.
- No se construye UI del stand: el terminal es la interfaz (§10).

---

## 12. Decisiones, cerradas el 2026-09-19

| Decisión | Resuelto |
|---|---|
| **Transporte** | A2A sobre HTTP. SLIM descartado: esconde la arista de Cilium |
| **Descubrimiento** | Agent Cards en `/.well-known/`. El Directory de AGNTCY no corre; el registro OASF se enseña como archivo |
| **Herramientas** | Un solo servidor MCP con las cinco |
| **Modelo chico** | No hay. Un 32B AWQ ocupa 18 GiB y no caben dos tiers en esta GPU |
| **Splunk** | Best effort. Los tokens se capturan hoy con los nombres de span para que llegar sea envolver |
| **El traductor** | Si llega AI Defense, sidecar del guardrail. No merece Agent Card propia |

### Riesgos vivos

- **El puente OpenAI → MCP** es lo único sin probar. Tiene criterio de corte
  (§9).
- **Internet el día del evento.** Splunk y AI Defense lo requieren. Mitigación:
  video de respaldo **por segmento**, no uno solo, y medir la red desde el piso
  el día de armado.
- **Seis encendidos en vivo.** Regla de abandono, **redefinida el 2026-09-22**:
  no es sobre la duración total, es sobre el **silencio**. Si pasan 60 segundos
  sin que aparezca nada nuevo en pantalla, se pasa al vídeo sin disculparse.

  La regla original —60 segundos de duración total— se escribió cuando la demo
  era terminal, y ahí 41 segundos mirando un cursor son insoportables. Con la
  interfaz transmitiendo en vivo, la sala ve aparecer el descubrimiento, la
  elección, el sobre A2A, cada herramienta con su respuesta y el salto lateral.
  **La espera es la demo**, no una pausa dentro de ella.

  Medido el 2026-09-22: una deliberación completa con disposición tarda **~41
  segundos** y 47 spans. El coste está en las ocho llamadas al modelo (3 a 7 s
  cada una); las herramientas no pintan nada (20 a 96 ms). Si alguna vez hace
  falta acortar, las palancas son `CTX=16384`, prompts más cortos, y que el
  paso 8 no vuelva a saltar al vecino. Hoy no hace falta.
- **El driver de la instancia final.** Preguntarlo al pedirla. Si trae ≥ 580 se
  destraba el NIM con razonamiento; si trae 555, ya está todo resuelto.
