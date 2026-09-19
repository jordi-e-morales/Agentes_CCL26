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
| `vllm-up.sh` | Motor de inferencia con vLLM | Independiente del cluster |
| `nim-up.sh` | Motor de inferencia con un NVIDIA NIM | Alternativa a `vllm-up.sh` |
| `reparar-cluster.sh` | Rescate cuando el cluster queda colgado tras un reinicio | Solo cuando falla algo |

## Dos motores, un contrato

`vllm-up.sh` y `nim-up.sh` son hermanos, no alternativas excluyentes de diseño.
Los dos exponen la API de OpenAI en el puerto 8000 y los dos escriben
`endpoint.env`:

```
MOTOR=nim
MODEL=nvidia/nemotron-3-nano
TOOL_CALL_PARSER=qwen3_coder
OPENAI_BASE_URL=http://172.18.0.1:8000/v1
```

**Los agentes leen ese archivo y nunca hablan con algo específico de un motor.**
Esa es toda la regla, y es la que mantiene barata la decisión: cambiar de vLLM
a NIM es bajar uno y subir el otro.

Cada script se niega a arrancar si el otro tiene el puerto tomado. Con los dos
arriba, los agentes hablarían con el que ganó la carrera — el peor tipo de
error, el que no se nota hasta que las mediciones ya no significan nada. Para
compararlos a la vez: `PUERTO=8001 ./nim-up.sh`.

| | `vllm-up.sh` | `nim-up.sh` |
|---|---|---|
| Modelo por omisión | Qwen2.5-7B-Instruct | Nemotron 3 Nano 30B A3B |
| Parser de tools | `hermes` | `qwen3_coder` |
| Razonamiento | No | **Sí, por omisión** |
| Credenciales | Ninguna | Clave de NGC |
| Descarga | Varios GB | Decenas de GB |

### El razonamiento no es una bandera del servidor

Es un parámetro **por petición**, así que `nim-up.sh` no puede encenderlo ni
apagarlo. Lo deciden los agentes en cada llamada:

```json
{"chat_template_kwargs": {"enable_thinking": false}}
```

Omitirlo lo deja encendido. Esto conviene tenerlo claro al construir los
agentes, porque el intercambio es real: el razonamiento mejora el tool-calling
y engorda `tokens.completion` —lo que hace visible la atribución de costos del
segmento 5— pero sube la latencia, y la regla de abandono del guion es de 60
segundos.

### El NIM en esta GPU: resuelto, y con un hallazgo

Las fuentes no coincidian —el model card del FP8 solo listaba H100 y A100, la
matriz de soporte de NIM si incluia L40S— asi que se le pregunto al contenedor:

```bash
./lab/nim-up.sh --profiles
```

**El L40S esta soportado.** Y el reporte trajo algo que no se veia en ninguna
documentacion: todos los perfiles ejecutables aqui empiezan con `vllm-`, y
ninguno es compilable a TensorRT-LLM. **En esta GPU el NIM corre vLLM por
dentro.**

Eso no lo invalida, pero recalibra que se esta comprando: no es un motor mas
rapido, es el mismo motor empaquetado, licenciado bajo NVIDIA AI Enterprise y
con los perfiles ya elegidos. La ganancia es de narrativa y de
reproducibilidad. Conviene tenerlo claro antes de contarlo en la sesion.

| Perfil | Pide | En 46 GB |
|---|---|---|
| `vllm-fp8-tp1-pp1-34.0` | ≥34 GB | Sí, deja ~12 GB de KV cache |
| `vllm-nvidia-h200-fp8-tp1-pp1-42.0` | ≥42 GB | Apenas, deja ~4 GB |
| `vllm-bf16-tp1-pp1-80.0` | ≥63 GB | No cabe |

`nim-up.sh` **fija** el primero con `NIM_MODEL_PROFILE`. NIM elige perfil solo
en cada arranque, y si un dia eligiera el de 42 GB el sintoma seria un demo
lentisimo sin causa visible — la peor forma de fallar en vivo.

El hash del perfil pertenece a esa version de la imagen. Si cambias el tag,
vuelve a correr `--profiles` y actualiza el valor en el script.

Consecuencia para el `CLAUDE.md` §12: con 34 GB ocupados por un solo modelo,
**no caben dos tiers en esta GPU**. Esa decision abierta la cierra el hardware.

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
