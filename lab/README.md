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
| `vllm-up.sh` | El modelo en la GPU: el segmento 1 | Independiente del cluster |
| `reparar-cluster.sh` | Rescate cuando el cluster queda colgado tras un reinicio | Solo cuando falla algo |

## Tres cosas que no son obvias

### Los drivers de la GPU no bastan

Son dos piezas distintas y se confunden siempre:

- El **driver NVIDIA** deja que el *host* vea la GPU. Se comprueba con `nvidia-smi`.
- El **`nvidia-container-toolkit`** deja que un *contenedor* la vea. Se comprueba
  con `docker run --gpus all`.

Tener lo primero no da lo segundo, y vLLM corre en contenedor. El bootstrap
verifica e instala lo que falte.

### vLLM vive fuera de Kubernetes

A propósito. Pasar la GPU hacia adentro de un nodo de kind (que ya es un
contenedor) es frágil y se rompe en cada reinicio. Además, el segmento 1 queda
más limpio sin Kubernetes de por medio: `nvidia-smi`, `docker ps`, un motor,
dos agentes encima.

Los agentes sí viven dentro de kind y alcanzan a vLLM por la IP del host en la
red de Docker. `vllm-up.sh` te la imprime al final; no es `localhost`, porque
dentro de un pod eso es el propio pod.

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
