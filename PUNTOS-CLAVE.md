# Los siete puntos del código, para las diapositivas

Material de apoyo para armar la PPT. Cada sección tiene **el concepto en una
frase**, el fragmento mínimo de código real, y **qué decir**.

Los fragmentos están recortados: son del código que corre, pero sin el ruido que
no aporta en una lámina. El archivo de origen está indicado en cada uno por si
hay que ir a verlo.

> **Regla al usar esto:** si un fragmento no se explica en una frase, no va a la
> diapositiva. Es la regla 1 de la interfaz aplicada a las slides.

---

## 1. La personalidad de un agente

> **Un agente es un prompt sobre un modelo compartido. Nada más.**

`malla/agente.py`

```python
ROLES = {
    "investigador": {
        "prompt": "Eres el agente INVESTIGADOR... Tu papel es buscar si hay "
                  "MOTIVOS PARA ESCALAR la alerta, y sostenerlos si los hay.",
        "vecino": "defensor",
    },
    "defensor": {
        "prompt": "Eres el agente DEFENSOR... Tu papel es CONTRASTAR el "
                  "argumento de riesgo y buscar la explicación más simple.",
        "vecino": None,
    },
}
```

**Qué decir:** los dos corren la misma imagen, sobre los mismos pesos, en la
misma GPU. Lo que los separa cabe en esas dos frases.

### Y la regla que evita que se inventen cosas

```python
ANCLAJE = (
    "REGLA QUE MANDA SOBRE TODO LO DEMAS: solo puedes afirmar hechos que "
    "aparezcan literalmente en la respuesta de alguna herramienta. Al citar "
    "un hecho, di de qué herramienta salió..."
)
```

**Qué decir:** sin esto, un agente al que le pides un argumento sobre un caso
sin material **inventa el material**. Lo medimos.

---

## 2. La tarjeta de un agente

> **Descubrir un agente es un GET a un archivo. No hace falta infraestructura.**

`malla/tarjetas/investigador.json`

```json
{
  "name": "agente-investigador",
  "description": "Sostiene que la alerta tiene riesgo...",
  "supportedInterfaces": [
    { "protocolBinding": "JSONRPC",
      "url": "http://investigador.agentes.svc.cluster.local:7010/a2a" }
  ],
  "skills": [
    { "id": "argumentar-riesgo",
      "name": "Argumentar riesgo",
      "tags": ["triage", "evidencia", "riesgo"] }
  ]
}
```

**Qué decir:** los `tags` no son decoración — son **por lo que el router elige**.
La tarjeta declara qué sabe hacer el agente; nadie tiene URLs escritas a mano en
un archivo de configuración.

---

## 3. A2A: tres rutas y se acabó

> **Un agente A2A es un servidor HTTP con tres rutas.**

`malla/agente.py`

```python
Starlette(routes=[
    Route("/.well-known/agent-card.json", tarjeta),   # quién soy
    Route("/a2a", a2a, methods=["POST"]),             # háblame
    Route("/salud", salud),                           # ¿vives?
])
```

### El descubrimiento

`malla/flujo.py`

```python
async def descubrir():
    for nombre, base in AGENTES.items():
        url = f"{base}/.well-known/agent-card.json"
        tarjeta = await _pedir_async(url)      # un GET. Eso es todo.
```

### La elección

```python
for c in catalogo:
    for skill in c["tarjeta"]["skills"]:
        if busca in skill["tags"]:            # "riesgo" -> investigador
            elegido = c
```

**Qué decir:** el router **no sabe quién hace qué**. Lo pregunta. Si mañana
aparece un agente nuevo, lo encuentra sin que nadie lo reprograme.

### Y el punto que hace que esto sea una malla

```python
# El salto lateral: el agente le habla al otro DIRECTAMENTE.
# El router no crea esta sesión, no la ve y no la reenvía.
base = os.getenv(f"URL_{vecino.upper()}")
resp = urllib.request.urlopen(f"{base}/a2a", ...)
```

**Qué decir:** sin al menos un salto agente→agente, esto es una **estrella**, no
una malla. Y como va por HTTP entre dos pods, es una arista que la red puede ver
y gobernar.

---

## 4. MCP: el puente que casi nadie ve

> **El modelo no habla MCP. Alguien tiene que traducir, y ese alguien eres tú.**

`malla/agente.py`

```python
async with Client(self.url_mcp) as mcp:
    catalogo = await mcp.list_tools()

    # 1. Las herramientas de MCP, en el formato que el modelo entiende
    herramientas = [
        {"type": "function",
         "function": {"name": h.name,
                      "description": h.description,
                      "parameters": h.input_schema}}
        for h in catalogo.tools
    ]

    # 2. El modelo pide una herramienta (formato OpenAI)
    respuesta = self.llm.chat.completions.create(
        model=..., messages=mensajes, tools=herramientas)

    # 3. Se traduce a MCP y se ejecuta
    for t in respuesta.tool_calls:
        res = await mcp.call_tool(t.function.name, json.loads(t.function.arguments))

        # 4. LA LÍNEA QUE SE CAYÓ UNA VEZ, y el agente empezó a inventar
        mensajes.append({"role": "tool", "tool_call_id": t.id, "content": txt})
```

**Qué decir, y es lo que menos gente sabe:** hay **dos** capas de traducción
antes de que una consulta llegue a la base de datos.

```
Qwen escribe   <tool_call>{"name": "consulta_historial", ...}</tool_call>
     ↓   vLLM, con --tool-call-parser hermes
respuesta con `tool_calls` en formato OpenAI
     ↓   nuestro código (el fragmento de arriba)
tools/call por MCP
```

La primera la hace una opción de arranque del motor. La segunda la escribes tú.

### El detalle del paso 4

Al reescribir el bucle desapareció ese `mensajes.append(...)`. Las herramientas
se ejecutaban, se imprimían, se guardaban para la interfaz — **pero el modelo
nunca recibía su resultado.** No dio ningún error: el agente empezó a afirmar
"múltiples incidentes similares" sobre un sujeto sin historial.

> Una pieza que falta no produce un error. Produce una mentira plausible.

---

## 5. Observabilidad: tres tipos de span y una cabecera

> **Instrumentar no es añadir logs. Es nombrar las cosas como el estándar espera.**

`observabilidad/trazas.py`

```python
def span_agente(tracer, nombre, padre=None):
    ctx = tracer.start_as_current_span(f"invoke_agent {nombre}", context=padre)
    return _con_atributos(ctx, {
        "gen_ai.operation.name": "invoke_agent",
        "gen_ai.agent.name": nombre,
    })

def span_tool(tracer, nombre, call_id):
    return _con_atributos(ctx, {
        "gen_ai.operation.name": "execute_tool",
        "gen_ai.tool.name": nombre,
        "gen_ai.tool.call.id": call_id,   # enlaza con lo que pidió el modelo
    })

def anotar_tokens(span, modelo, prompt, completion):
    span.set_attribute("gen_ai.usage.input_tokens", prompt)
    span.set_attribute("gen_ai.usage.output_tokens", completion)
```

### Lo que convierte tres trazas sueltas en una

```python
def inyectar(cabeceras):      # quien llama, mete su contexto
    inject(cabeceras)

def extraer(cabeceras):       # quien recibe, cuelga de él
    return extract(cabeceras)
```

**Qué decir:** esa cabecera `traceparent` es lo que hace que el salto lateral
aparezca **dentro** de la conversación del investigador, en vez de como una
traza aparte que nadie relaciona.

### Y el resultado, que es el argumento

Splunk Observability reconoce estos spans en su sección **Agent Observability**
sin configurar nada: las cifras de tokens, el anidamiento de agentes, todo.

**Porque los nombres son los del estándar.** Si se hubieran llamado `entrada` y
`salida`, habría habido que mapear cada uno a mano.

> Y de regalo: los spans `MCP send tools/call` **no los emite nuestro código**.
> Los emite el SDK de MCP, que se instrumenta solo.

---

## 6. Cilium: la política empieza por denegar

> **En Cilium, el momento en que escribes tu primera regla es el momento en que
> todo lo demás queda prohibido.**

`seguridad/cilium-l7.yaml`

```yaml
spec:
  endpointSelector:
    matchLabels:
      rol: agente          # <- a quién aplica
  egress:
    # DNS PRIMERO. Sin esto no se resuelve ningún nombre y todo lo demás
    # falla con errores que no apuntan a la política.
    - toEndpoints: [{matchLabels: {k8s-app: kube-dns}}]
      toPorts: [{ports: [{port: "53", protocol: UDP}]}]

    # La arista autorizada, con método y ruta
    - toEndpoints: [{matchLabels: {app: servidor-mcp}}]
      toPorts:
        - ports: [{port: "9000", protocol: TCP}]
          rules:
            http:
              - {method: "POST", path: "/mcp"}

  # NO hay regla hacia postgres. Esa omisión ES la política.
```

### Los cuatro puntos para la lámina

1. **Seleccionar es denegar.** Un pod al que ninguna política nombra está
   abierto. En cuanto una lo selecciona, todo lo que no esté escrito queda
   prohibido **en esa dirección**.
2. **El DNS va primero.** Es el error clásico: sin esa regla nada resuelve y los
   síntomas no apuntan a la red.
3. **La identidad son las etiquetas, no el nombre ni la IP.** `rol: agente` es lo
   que Cilium mira. Cambiarle una etiqueta a un pod lo convierte, para la red, en
   otra cosa — y eso se puede demostrar en vivo con el redactor.

   **Y se ve con un número.** Hubble muestra la identidad numérica de cada
   extremo. Antes de etiquetar es una; después, otra:

   ```
   antes:    identity = 61372   redactor   app=redactor
   después:  identity = <otra>  redactor   app=redactor, rol=agente
   ```

   Mismo pod, mismo nombre, misma imagen. **Otra identidad.** Es el insight #1
   llevado hasta la red: lo que distingue dos cargas de trabajo no es qué son,
   es cómo están etiquetadas.

   *Efecto de escenario:* durante unos minutos Hubble enseña las dos, porque su
   búfer guarda historia. No es un fallo — es la prueba de que cambió. Si
   prefieres una imagen limpia, filtra por `workload = redactor` (que sobrevive
   al cambio) y mira las filas por hora; el filtro por `identity` se queda
   obsoleto en cuanto etiquetas.
4. **Lo que no está escrito es tan política como lo que sí.** No hay regla
   agente→Postgres, y esa ausencia es lo que impide que un agente comprometido
   llegue a la base.

### Y el límite, que es lo más honesto de la sesión

```
POST /consulta_historial   →  Cilium lo ve, puede permitirlo
POST /dispone_caso         →  Cilium lo ve, puede denegarlo

POST /mcp                  →  las SEIS herramientas, indistinguibles
```

> Incluso la capa 7 se queda corta si el protocolo multiplexa.

---

## 7. Del Cilium de código abierto a la plataforma

> **Lo que el demo enseña cabe en un cluster. El problema real empieza en el
> cluster número veinte.**

### Lo que se demuestra y es verificable

El demo corre sobre **Cilium**: cuatro políticas, un cluster, y todo lo anterior
funciona. Eso es cierto y está medido.

### El argumento del uplift, en conceptos

Lo que cambia al pasar de un cluster a una organización **no es técnico, es
operativo**:

| En el demo | En producción |
|---|---|
| 4 políticas en un archivo | cientos, repartidas entre equipos |
| Un cluster | muchos, en varias nubes |
| Quien escribe la política la lee | quien la escribe y quien responde por ella son personas distintas |
| *"¿qué permite esta regla?"* se contesta leyendo | hay que poder contestarlo **sin** leer cada archivo |

**El punto conceptual que sí puedes defender sin material adicional:**

Cilium expresa la política por **identidad derivada de etiquetas**, no por
direcciones IP. Ésa es la misma idea que hay detrás de los **SGT (Security Group
Tags)** de Cisco TrustSec: la identidad viaja con la carga de trabajo, no con su
dirección. Son dos expresiones del mismo principio en dos capas distintas.

Y esa coincidencia conceptual es **la razón por la que estos dos mundos pueden
converger**: los dos ya piensan en "quién habla con quién", no en "qué IP habla
con qué IP".

### ⚠️ Lo que tienes que confirmar con material oficial

**No lo escribas en la slide hasta verificarlo.** La regla del proyecto es no
inventar nombres de producto ni capacidades:

- Qué añade exactamente **Isovalent Enterprise** sobre Cilium de código abierto
  en gestión de políticas multi-cluster, RBAC y datos históricos de Hubble
- Cómo se relacionan **Cisco Hypershield** y Cilium/eBPF en el mensaje actual
- Si existe hoy una integración **SGT ↔ identidades de Cilium**, y con qué alcance
- Qué papel juega **Cisco Cloud Control** en administrar estas políticas

Pídele a tu equipo de producto la lámina oficial. Lo de arriba te da el puente
conceptual; los detalles del producto tienen que venir de ellos.

> **Y un aviso para el escenario:** el demo NO enseña Hypershield ni SGT. Si lo
> mencionas, dilo como lo que es —hacia dónde va esto— y no como algo que
> acabas de demostrar. La sesión entera se apoya en que lo que se ve es real.

---

## Apéndice: los números medidos

Todos verificables en el repo, con fecha.

| | |
|---|---|
| Pesos del modelo | 18.01 GiB |
| Caché KV | 13.82 GiB |
| Concurrencia a 32k | 3.46x |
| Deliberación completa (2 rondas) | ~78 s |
| Spans por deliberación | ~47 (una ronda) |
| Herramientas | 6, todas tras `POST /mcp` |
| Políticas de red | 4 |
