# Cómo funciona SLIM

Explicación desde cero, para quien mira este código por primera vez. Se
entiende mucho mejor si primero ves qué problema resuelve.

## Por qué no basta con HTTP

Imagina que haces la malla a mano: cada agente es un servidor web y se llaman
entre ellos con HTTP. Enseguida aparecen los problemas.

- **Direcciones.** Agente A necesita la URL de agente B. La pones en un archivo
  de configuración. Ahora agregas un agente y tienes que tocar la configuración
  de todos los demás.
- **Cada agente es servidor y cliente a la vez.** Tiene que escuchar en un
  puerto, y ese puerto tiene que ser alcanzable desde donde esté el otro.
- **HTTP es pregunta-respuesta.** Uno pide, el otro contesta, y el que pidió se
  queda esperando. Una conversación entre agentes no siempre es así: a veces
  hay ida y vuelta, a veces le hablas a un grupo, a veces mandas algo sin
  esperar nada.

SLIM cambia el modelo. En vez de *"llamo al teléfono 10.0.3.7 puerto 8080"*, es
*"mando un mensaje a `ccl26/malla/agente-b`"*, y el bus se encarga de
encontrarlo. Como el correo electrónico: le escribes a una dirección, no a un
servidor.

## Las cuatro piezas

```
                    ┌──────────────────────┐
                    │      NODO SLIM       │   el bus, la centralita
                    │   127.0.0.1:46357    │   todos se conectan aquí
                    └──────────────────────┘
                       ▲       ▲       ▲
                       │       │       │      conexiones
                ┌──────┘       │       └──────┐
          ┌─────┴────┐   ┌─────┴────┐   ┌─────┴────┐
          │   APP    │   │   APP    │   │   APP    │   cada agente
          │  router  │   │ agente-a │   │ agente-b │
          └──────────┘   └──────────┘   └──────────┘
             nombre: ccl26/malla/router, etc.
```

**El nodo** es el bus. Un solo proceso al que todos se conectan. Reenvía
mensajes *por nombre*. En [`nodo.py`](nodo.py) son tres líneas, porque
`slim-bindings` lo trae embebido en Rust.

**La app** es tu agente visto desde SLIM. Un proceso de Python puede tener
varias apps; en el ejemplo oficial de AGNTCY crean dos en el mismo programa.

**El nombre** tiene tres partes: `organización/espacio/aplicación`. En este
spike, `ccl26/malla/agente-a`. **No es una IP ni un puerto**, y ahí está la
gracia: el agente se mueve de máquina, de pod o de nodo, y sigue siendo el
mismo nombre. Nadie tiene que actualizar nada.

**La sesión** es una conversación establecida entre dos apps. No es una
conexión TCP: va por encima y sobrevive a reintentos. Por eso el `SessionConfig`
del código lleva `max_retries=5`.

## El código, paso a paso

Estas son las seis llamadas del spike y qué hace cada una:

```python
conn_id = await service.connect_async(...)        # 1. me conecto al bus
app = service.create_app_with_secret(yo, SECRETO) # 2. esta es mi identidad
await app.subscribe_async(yo, conn_id)            # 3. "si buscan este nombre, soy yo"
await app.set_route_async(remoto, conn_id)        # 4. "para llegar a ese, por aquí"
ctx = await app.create_session_async(...)         # 5. abro conversación
await ctx.completion.wait_async()                 #    ...y espero a que se establezca
await sesion.publish_async(b"hola", None, None)   # 6. hablo
```

El par que más cuesta entender es el 3 y el 4, y son simétricos:

- **`subscribe`** va *hacia adentro*: te haces encontrable. Sin esto nadie
  puede mandarte nada.
- **`set_route`** va *hacia afuera*: le dices a tu propia app por qué conexión
  se llega a otro nombre.

Y el `completion.wait_async()` del paso 5 no es decorativo: si publicas antes de
que la sesión esté establecida, los primeros mensajes se pierden. Es el tipo de
detalle que cuesta una tarde si no lo sabes.

## La identidad

Fíjate en el paso 2: **crear la app y darle identidad son el mismo acto**. No
es que primero exista el agente y luego le cuelgues una credencial.

Hay tres modos:

| Modo | Qué es | Cuándo |
|---|---|---|
| Secreto compartido | Una contraseña que todos conocen | Desarrollo. Es lo que usa este spike |
| JWT + JWKS | Un token firmado, verificable con clave pública | Producción sencilla |
| SPIFFE / SPIRE | Identidad de carga de trabajo, emitida y rotada automáticamente | Lo serio |

El `CLAUDE.md` dice que el insight #1 de la sesión es *"lo que hace distintos a
dos agentes es prompt, identidad y permisos"*. Con SLIM la identidad deja de
ser una metáfora: son dos credenciales criptográficamente distintas sobre los
mismos pesos, en el mismo servidor. Eso se puede **enseñar**, no solo contar.

## Estrella contra malla

Esto es de lo que va el segmento 3, y es lo que el spike tiene que demostrar.

**Estrella** — el router media todo. Los agentes no se conocen entre sí:

```
        agente-a ──┐         ┌── agente-c
                   ├─ router ┤
        agente-b ──┘         └── agente-d
```

**Malla** — los agentes se hablan como iguales:

```
        agente-a ─────────── agente-b
            │   ╲         ╱   │
            │     router      │
            │   ╱         ╲   │
        agente-c ─────────── agente-d
```

La diferencia no es estética. En la estrella el router es cuello de botella,
punto único de fallo, y tiene que entender cada conversación. En la malla,
`agente-a` puede consultarle algo a `agente-b` sin que nadie más se entere.

En [`agente.py`](agente.py) eso es exactamente el bloque marcado
`EL SALTO LATERAL`: cuando `agente-a` recibe la tarea del router, **abre su
propia sesión** con `agente-b`. El router no la crea, no la ve y no la reenvía.

## La parte incómoda

Los mensajes del salto lateral **sí pasan físicamente por el nodo**, porque el
nodo *es* el bus. Todo pasa por ahí.

Entonces, ¿qué demuestra el salto lateral? Que la **topología de la aplicación**
es una malla: dos agentes conversan como iguales sin que el router orqueste.
Eso es real y es la propiedad que importa.

Pero en la sesión no se puede decir *"el tráfico no pasa por el centro"*. Hay
que decir *"el router no participa en esta conversación"*. El `CLAUDE.md` §6 es
explícito sobre no afirmar de más, y esta es justo la clase de frase que un
arquitecto de red en la sala detectaría al vuelo.

## Qué NO es SLIM

Para cerrar el mapa mental:

- **No es un framework de agentes.** No sabe qué es un agente, ni un prompt, ni
  una herramienta. Mueve bytes entre nombres.
- **No ejecuta modelos.** Eso es vLLM, y son mundos separados.
- **No decide quién habla con quién.** Esa lógica —el ruteo por capacidad, el
  Agent Directory— se escribe encima.

SLIM es plomería con identidad. Buena plomería, pero plomería.
