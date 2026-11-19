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

Cilium ve *"este pod se conecta a un nodo SLIM"*. **No ve** *"agente-a le habló
a agente-b"*. Y con MLS encendido, ni el propio nodo puede leer el contenido.

El problema se parece al de Kafka o NATS —la red observa conexiones a la
infraestructura, no el grafo lógico de quién habla con quién— pero **la analogía
no debe llevarse más lejos**, por lo que se explica en el apartado siguiente.

**El diseño ya lo tiene bien puesto.** El `CLAUDE.md` §4 dice *"qué agente
puede llamar qué tool = política L7 de Cilium sobre las rutas"*. Las llamadas a
las tools **no** van por SLIM: son HTTP del pod del agente al servicio de la
tool. Ahí Cilium sí ve método y ruta, y ahí el 403 significa algo.

Lo que sí puede hacer Cilium sobre SLIM es más burdo pero útil: **quién tiene
permitido siquiera conectarse al bus**.

### 2. SLIM no es un broker central, y eso cambia lo que verá Hubble

La documentación de SLIM dice, comparándose con Kafka, NATS y RabbitMQ:

> **No central broker** — Peer-to-peer architecture; no single point of failure
> or trust

Eso es cierto, y conviene entender bien en qué sentido, porque es fácil sacar
la conclusión equivocada en las dos direcciones.

**SLIM no es un broker: es una red de enrutamiento.** El data plane no es un
proceso central sino un conjunto de nodos organizados en **dominios**, con
**links** entre ellos, **gateways** con relevo automático si uno cae, y ruteo
multi-salto por árbol de caminos mínimos. Las topologías configurables incluyen
malla completa, estrella, cadena y pares explícitos.

La analogía correcta es **internet**, no Kafka. Internet es peer-to-peer y no
tiene servidor central, y aun así **cada paquete atraviesa routers**. SLIM es
igual: no hay broker que sea dueño de los mensajes, pero sí hay nodos que los
reenvían.

Las dos afirmaciones conviven sin contradicción:

| Afirmación | Por qué es cierta |
|---|---|
| *No central broker* | No hay un punto único del que todos dependan. Los nodos forman una red con topología configurable y relevo de gateway |
| *Los mensajes atraviesan nodos* | El data plane es *"the core routing engine"*. No existe conexión directa entre dos apps |
| *Ningún nodo tiene que ser de confianza* | Con MLS el contenido va cifrado extremo a extremo. El nodo reenvía sin poder leer |

**La estrella que mencionaba este documento era un artefacto de nuestro
despliegue, no de SLIM.** El spike levanta *un* nodo en localhost, así que
todo converge ahí. Eso es una decisión de desarrollo.

### Consecuencia: desplegar SLIM como DaemonSet

Con un nodo de data plane por nodo de Kubernetes, lo que Hubble ve es:

```
Nodo A                          Nodo B
┌─────────────────────┐         ┌─────────────────────┐
│  Pod del agente     │         │  Pod del agente     │
│     ↓ (ClusterIP)   │         │     ↓ (ClusterIP)   │
│  Pod SLIM (local)   │ ──────▶ │  Pod SLIM (local)   │
└─────────────────────┘         └─────────────────────┘
        internalTrafficPolicy: Local en el Service
```

Eso ya **no es una estrella**: es una red de enrutamiento, que es justo lo que
la sesión afirma en el segmento 3. El chart de Helm lo soporta con
`slim.deploymentMode: DaemonSet`, y el `internalTrafficPolicy: Local` hace que
cada pod use el nodo SLIM de su propia máquina sin configurar nada en la
aplicación.

Con el cluster de kind actual (un control-plane y un worker) el efecto es
modesto —dos nodos SLIM— pero suficiente para que la vista de Hubble sea
coherente con el relato, en vez de contradecirlo.

**Recomendación: desplegar SLIM como DaemonSet en la Fase A**, no como
Deployment de una réplica. No cuesta más y evita tener que explicar en vivo por
qué la pantalla contradice la lámina.

### Lo que sigue siendo cierto sobre las trazas

Aun con DaemonSet, Hubble ve **el camino del transporte**, no el grafo lógico:
verá `agente → nodo local → nodo remoto → agente`, sin saber que esa
conversación era `agente-a` hablándole a `agente-b`.

Ese grafo solo aparece en las trazas de la aplicación. Así que el argumento del
`CLAUDE.md` §5 se mantiene intacto y sigue siendo el mejor del segmento 5: las
dos fuentes **ven cosas distintas**, y el hueco entre ambas es donde se esconde
un agente comprometido.

Si el agente intenta una conexión fuera del pipeline, no irá por SLIM —sería
una conexión cruda— así que no habrá traza que la declare. Hubble la ve igual,
porque no depende de que nadie la confiese.

## Hay una cuarta superficie de control: la topología de SLIM

Esto no estaba en la tabla de arriba y merece estar.

SLIM trae su propio control de quién puede alcanzar a quién, independiente de
Cilium:

- **Dominios** — conjuntos de nodos bajo una misma administración. Dentro de un
  dominio los nodos se descubren solos y rutean entre sí *sin intervención del
  Controller*.
- **Topología** — qué dominios pueden enlazarse: malla completa, estrella,
  cadena o pares explícitos.
- **Segmentos** — aislamiento multi-inquilino. La documentación es tajante:
  *"nodes in one segment are completely invisible to nodes in other
  segments"*.

Un segmento no es una política de red: es que la ruta **no existe**. Cilium
bloquea un paquete que se envió; un segmento hace que nunca haya un camino por
donde enviarlo.

Para el demo eso da una lámina adicional si hiciera falta: aislamiento por
diseño en la capa de mensajería, más política L7 en la red, más control en el
kernel. Tres formas distintas de decir "no", en tres sitios distintos.

## Estado de este documento

Escrito el 2026-09-19 a partir de la documentación de SLIM
(`docs/content/slim/architecture/routing.md` y `deploy/daemonset.md` del
repositorio `agntcy/slim`, leídos directamente) y del código de
`agntcy/slim-bindings`.

**La parte de SLIM no está verificada en ejecución**: depende de que el spike
corra. La de Cilium y Tetragon se apoya en la demo v1, donde sí funcionaron.

Una corrección quedó incorporada: la primera versión de este documento decía
que Hubble vería una estrella y comparaba SLIM con Kafka. Ambas cosas eran
engañosas. La estrella era un artefacto de levantar un solo nodo en el spike, y
SLIM no es un broker sino una red de enrutamiento con topología configurable.
