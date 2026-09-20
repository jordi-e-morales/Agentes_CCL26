# Las capas de control: SLIM, Cilium y Tetragon

Cómo encajan las tres, y por qué **no se enciman**. Es el soporte técnico del
segmento 6 y de la frase que la sala tiene que llevarse: *ninguna capa sola
basta*.

## Primero, dos cosas llamadas "router"

Esta confusión cuesta media hora si no se aclara de entrada:

| | Qué es | Qué hace | Dónde vive |
|---|---|---|---|
| **Nodo SLIM** (*data plane*) | Infraestructura | Reenvía bytes por nombre. No sabe qué es un agente ni qué es una tarea | Un pod más, puerto 46357 |
| **Router por tarea** (`CLAUDE.md` §3) | **Un agente**, como los demás | Clasifica la tarea, consulta el Agent Directory, despacha al agente adecuado | Colgado del bus |

El router por tarea **no es el centro de la red**: es el centro de la *lógica*.
Está conectado al bus igual que cualquier otro agente.

Y una tercera pieza que conviene no mezclar: el **SLIM Controller** es el
*control plane*, una imagen aparte que configura las tablas de rutas y
suscripciones de los nodos. **No toca mensajes.**

## Qué ve cada capa

```
  CONTENIDO   ¿qué dice el mensaje?          AI Defense
              "esto es una inyección"
      ↓
  APLICACIÓN  ¿quién le habla a quién?       SLIM
              "agente-a abrió sesión con agente-b"
      ↓
  RED         ¿qué pod llama a qué ruta?     Cilium L7
              "este pod hizo POST /dispone_caso"
      ↓
  KERNEL      ¿qué proceso ejecuta qué?      Tetragon
              "alguien lanzó un binario no autorizado"
```

| Capa | Qué identifica | Qué controla | **De qué es ciega** |
|---|---|---|---|
| SLIM | Nombre de agente + credencial | Quién abre sesión con quién | Qué hace el agente *después* de recibir el mensaje |
| Cilium | Pod / workload (etiquetas) | Método y ruta HTTP | El contenido; y quién habla con quién *dentro* del bus |
| Tetragon | Proceso y syscall | Qué binario se ejecuta | La intención del mensaje |

## Por qué ninguna sola basta

Sigue el ataque del segmento 6 bajando por las capas. Esto es lo que hace
literalmente cierto el insight #3 — *no rompe el perímetro, abusa de una arista
que tú autorizaste*:

**SLIM no se entera de nada.** La credencial del agente comprometido **sigue
siendo válida**. No hay suplantación: es el agente legítimo, con su identidad
correcta, haciendo algo que no debería. SLIM transporta ese mensaje con total
normalidad, y hace bien — juzgar intenciones no es su trabajo.

**Cilium tampoco ve la inyección.** Ve que un pod hizo `POST /dispone_caso`. Si
ese pod no tiene permitido ese método y esa ruta, lo corta con un 403. Pero el
403 **no** es porque el mensaje fuera malicioso: es porque la petición no
estaba autorizada. Son cosas distintas y hay que decirlo así (`CLAUDE.md` §6:
*Cilium NO inspecciona prompts*).

**Tetragon no sabe qué es un agente.** Ve un proceso intentando ejecutar un
binario que no está en la lista. SIGKILL, y le da igual cómo llegó ahí.

Cada capa atrapa una **manifestación distinta del mismo ataque**. Esa es la
definición de defensa en profundidad.

## Dos consecuencias prácticas para el build

### 1. Cilium no puede vigilar agente↔agente

Todo el tráfico de SLIM es gRPC hacia el nodo, en el puerto 46357. Desde la
red, la malla entera se ve así:

```
agente-a ──┐
agente-b ──┼──► nodo SLIM :46357
router   ──┘
```

Cilium ve *"este pod se conecta al bus"*. **No ve** *"agente-a le habló a
agente-b"*. Es el mismo problema que con Kafka o NATS: la red observa
conexiones al broker, no el grafo lógico de quién publica a quién. Y con MLS
encendido, ni el propio nodo puede leer el contenido.

**El diseño ya lo tiene bien puesto.** El `CLAUDE.md` §4 dice *"qué agente
puede llamar qué tool = política L7 de Cilium sobre las rutas"*. Las llamadas a
las tools **no** van por SLIM: son HTTP del pod del agente al servicio de la
tool. Ahí Cilium sí ve método y ruta, y ahí el 403 significa algo.

Lo que sí puede hacer Cilium sobre SLIM es más burdo pero útil: **quién tiene
permitido siquiera conectarse al bus**.

### 2. Hubble va a mostrar una estrella, y eso puede contradecir el segmento 3

En el segmento 3 se dice *"esto es una malla, no una estrella"*. Dos segmentos
después se enseña Hubble, y Hubble muestra una estrella alrededor del nodo
SLIM. Alguien en la sala lo va a notar.

No es un error. Son dos topologías distintas y ambas son ciertas:

- **La de transporte** (lo que ve Hubble): una estrella alrededor del bus.
- **La de aplicación** (lo que ven las trazas): una malla, porque `agente-a`
  abrió su propia sesión con `agente-b`.

La documentación de SLIM da la frase exacta para sostener esto:

> *SLIM routing nodes only forward messages and don't participate in
> application sessions.*

El nodo **reenvía** pero **no participa**. Por eso se puede decir *"el router
por tarea no participa en esta conversación"* y **no** se puede decir *"el
tráfico no pasa por el centro"*.

**Y esto convierte el riesgo en el mejor argumento del segmento 5.** El
`CLAUDE.md` §5 exige Hubble como segunda fuente independiente. La razón ahora
es más fuerte que "por si el agente no emite un span": las dos fuentes **ven
topologías diferentes**, y el hueco entre ambas es donde se esconde un agente
comprometido.

Si el agente intenta una conexión fuera del pipeline, no irá por SLIM —sería
una conexión cruda— así que no habrá traza que la declare. Hubble la ve igual,
porque no depende de que nadie la confiese.

Poner las dos vistas lado a lado y decir *"la red ve esto, la aplicación ve
aquello, y la diferencia es la que te delata"* es mejor demo que cualquiera de
las dos por separado.

### Una salida si la estrella molesta mucho

SLIM se puede desplegar como **DaemonSet**: un nodo de data plane por nodo de
Kubernetes. Entonces Hubble vería `agente → nodo local → nodo remoto → agente`,
que se parece bastante más a lo que la aplicación afirma.

Con el cluster de kind actual (un control-plane y un worker) el efecto es
limitado, pero está documentado como opción y vale la pena tenerlo en el
bolsillo.

## Estado de este documento

Escrito el 2026-09-19 a partir de la documentación de SLIM y del código de
`agntcy/slim-bindings`. **La parte de SLIM no está verificada en ejecución**:
depende de que el spike corra. La de Cilium y Tetragon se apoya en la demo v1,
donde sí funcionaron.
