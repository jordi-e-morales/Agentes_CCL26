# El laboratorio

Todo lo que instala el entorno. La máquina es desechable; **estos scripts son
lo que viaja.**

Eso no es una frase bonita: la reserva actual del host termina el 2026-09-23 y
después hay que migrar a la instancia que llega al día del evento. Esa
migración es la prueba real de este directorio.

## El orden

Los cuatro primeros son idempotentes: puedes correrlos de nuevo sin romper nada.

| Script | Qué hace | Cuándo |
|---|---|---|
| `bootstrap.sh` | Herramientas: Docker, kubectl, kind, Cilium, Hubble, Helm, GPU en contenedores, venv | Una vez por host |
| `cluster-up.sh` | Crea el cluster de kind y le pone Cilium como red | Después del bootstrap |
| `tetragon-up.sh` | Control de kernel: el SIGKILL del segmento 6 | Después del cluster |
| `vllm-up.sh` | **El motor de inferencia.** Qwen2.5-32B-AWQ | Independiente del cluster |
| `nim-up.sh` | NVIDIA NIM. **No sirve en este host** (driver 555) | Solo con driver ≥ 580 |
| `reparar-cluster.sh` | Rescate cuando el cluster queda colgado tras un reinicio | Solo cuando falla algo |

## El motor: vLLM, y el driver manda

El motor en uso es **`vllm-up.sh`** con Qwen2.5-32B-Instruct-AWQ.
`nim-up.sh` **no funciona en este host** y está marcado como tal.

### El techo es el driver, no el software

El host tiene driver **555.42.06**, que expone **CUDA 12.5**. Las imágenes
modernas —el NIM de NVIDIA y `vllm/vllm-openai:latest`— se compilan sobre
**CUDA 13**, que exige driver **≥ 580**. Fallan con:

```
CUDA driver ... too old (found version 12050)
```

Y no hay atajo por compatibilidad hacia adelante: las librerías de CUDA 13
están hechas para las ramas **R535 y R570**. El 555 cae justo en el hueco.

Actualizar el driver resolvería las dos cosas, pero **no hay reinicio
disponible en este host**. Así que la imagen queda anclada a
`vllm/vllm-openai:v0.6.6.post1`, que está sobre CUDA 12.x y ya funcionó en
dCloud durante la demo v1.

Es una versión vieja a propósito. El límite no lo pone vLLM, lo pone el driver.

### Lo que se hereda de la demo v1

Varios valores de `vllm-up.sh` no se dedujeron, se **midieron** en dCloud
durante `triage-multiagente`. Cada uno lleva su motivo al lado en el script:

| Ajuste | Por qué |
|---|---|
| AWQ y no FP8 | AWQ carga ya cuantizado (~19 GB); el FP8 dinámico obliga a cargar el bf16 entero antes de comprimir |
| `--kv-cache-dtype fp8` | Reduce la caché KV a la mitad |
| `--enable-prefix-caching` | Los agentes comparten prefijo de prompt |
| Sin `--restart` | Un arranque fallido en bucle vuelve a pedir VRAM y enturbia el diagnóstico |
| Barrido del contenedor antes de arrancar | Un contenedor muerto puede seguir reteniendo VRAM, y el error culpa a la caché en vez del cadáver |

**La IP del host se filtra a IPv4.** La red de kind es dual-stack: si tomas el
primer gateway a ciegas te puede tocar el IPv6, y el motor se publica en IPv4,
así que los pods apuntarían a una dirección inalcanzable.

Un cambio respecto de v1: allí corrían dos instancias sobre el mismo L40S y al
32B se le daba `0.68` de la GPU. Aquí corre una sola, así que sube a `0.90`.
Si algún día vuelven dos modelos, eso baja.

### Lo medido en este host (2026-09-19)

Con `UTIL=0.90` y `CTX=32768`, el motor arranca en 27 segundos y reparte así:

| | GiB |
|---|---|
| GPU total (como la ve vLLM) | 44.43 |
| × 0.90 de utilización | 39.99 |
| − pesos del 32B AWQ | 18.01 |
| − pico de activaciones | 8.02 |
| − non_torch | 0.13 |
| **= caché KV** | **13.82** |

Y de ahí sale **el número que condiciona el diseño**:

```
Maximum concurrency for 32768 tokens per request: 3.46x
```

Solo caben ~3.5 peticiones en vuelo. Con router, dos agentes y el traductor del
guardrail, cuatro llamadas concurrentes con contexto largo ya se encolan — y
eso se ve como latencia, con la regla de abandono de 60 segundos encima.

**Bajar `CTX` es la optimización más barata del proyecto**, porque el pico de
activaciones también baja: a 16k la concurrencia pasa de ~3.5 a ~7.

```bash
CTX=16384 ./lab/vllm-up.sh
```

Queda en 32k solo hasta saber cuánto contexto necesita de verdad cada agente.

El tool-calling está confirmado en esta versión: el log dice
`"auto" tool choice has been enabled`.

### El contrato: endpoint.env

Los dos scripts de motor escriben `lab/endpoint.env`:

```
MOTOR=vllm
MODEL=Qwen/Qwen2.5-32B-Instruct-AWQ
TOOL_CALL_PARSER=hermes
OPENAI_BASE_URL=http://172.18.0.1:8000/v1
```

**Los agentes leen ese archivo y nunca hablan con algo específico de un motor.**
Esa es toda la regla, y es lo que mantuvo barata esta decisión: cuando el NIM
falló, lo que se perdió fue una tarde, no un refactor.

### Qué queda del intento con NIM

`nim-up.sh` se queda en el repo. En un host con driver ≥ 580 funciona tal cual,
y el trabajo de averiguación sirve:

- **El L40S sí está soportado** por el NIM de Nemotron 3 Nano. El model card del
  FP8 solo listaba H100 y A100; la matriz de soporte de NIM tenía razón.
- **Todos los perfiles ejecutables ahí son `vllm-`**, ninguno compilable a
  TensorRT-LLM. En esta GPU el NIM habría corrido vLLM por dentro: lo que
  aporta es empaquetado, licencia y perfiles elegidos, no un motor más rápido.
- El perfil correcto sería `vllm-fp8-tp1-pp1-34.0`, fijado con
  `NIM_MODEL_PROFILE` para que no lo elija el contenedor cada mañana.

Para recuperar el disco que gastó el intento —la imagen y los pesos están en
sitios distintos, que es lo que hace que uno se olvide de uno de los dos—:

```bash
./lab/nim-up.sh --purge
```

Nunca `docker system prune -a` para esto: se llevaría por delante la imagen de
vLLM y las de los nodos de kind.

Consecuencia para el `CLAUDE.md` §12: con un 32B AWQ a `0.90` de la GPU, **no
caben dos tiers de modelo**. Esa decisión abierta la cierra el hardware.

## Tres cosas que no son obvias

### Los drivers de la GPU no bastan

Son dos piezas distintas y se confunden siempre:

- El **driver NVIDIA** deja que el *host* vea la GPU. Se comprueba con `nvidia-smi`.
- El **`nvidia-container-toolkit`** deja que un *contenedor* la vea. Se comprueba
  con `docker run --gpus all`.

Tener lo primero no da lo segundo, y vLLM corre en contenedor. El bootstrap
verifica e instala lo que falte.

### El motor de inferencia vive fuera de Kubernetes

A propósito. Pasar la GPU hacia adentro de un nodo de kind (que ya es un
contenedor) es frágil y se rompe en cada reinicio. Además, el segmento 1 queda
más limpio sin Kubernetes de por medio: `nvidia-smi`, `docker ps`, un motor,
dos agentes encima.

Los agentes sí viven dentro de kind y alcanzan al motor por la IP del host en
la red de Docker. Eso es lo que va en `OPENAI_BASE_URL` de `endpoint.env`; no
es `localhost`, porque dentro de un pod eso es el propio pod.

### kind intercambia las IPs de sus nodos al reiniciar

Este es el que más tiempo cuesta si no lo sabes. Cuando el host reinicia,
Docker puede darles a los contenedores-nodo IPs distintas. Cilium tiene la del
apiserver fija en una variable de entorno, así que deja de encontrarlo, y sin
Cilium no hay red para ningún pod. El síntoma es pods en `Unknown` o
`ContainerCreating` que no se recuperan solos.

`reparar-cluster.sh` detecta la IP real, corrige Cilium y fuerza la recreación
de los pods colgados.

Esto importa más allá de un reinicio accidental: el modo stand pide reinicio en
menos de 10 segundos entre visitantes, y el pod tiene que volver después del
SIGKILL. Cualquier diseño que dependa de IPs estables de kind va a fallar ahí.

## Versiones fijas

Tetragon está anclado en 1.7.1 y Helm en v4.3.0, con la suma de verificación
comprobada. El día del evento tiene que correr lo mismo que se ensayó.

**Pendiente:** la imagen de vLLM todavía usa `latest`, que es una mina para el
día del evento. Hay que fijarla al digest exacto en cuanto la primera corrida
funcione. Está anotado dentro de `vllm-up.sh`, con el motivo extra de este lab:
el driver es 555 (CUDA 12.5), así que una imagen sobre CUDA 13 podría no
arrancar.
