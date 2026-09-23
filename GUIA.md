# Cómo levantar todo

Orden completo, de abajo arriba. Sirve para tres cosas: montar el laboratorio
desde cero, migrar a una instancia nueva, y la lista de verificación del día del
evento.

```bash
bash lab/estado.sh
```

Eso dice qué falta en cualquier momento. Si algo va mal, empieza por ahí.

---

## Lo que corre, y dónde

| | Qué | Dónde | ¿Terminal propia? |
|---|---|---|---|
| 1 | vLLM + Qwen2.5-32B | Contenedor en el host | No, va en segundo plano |
| 2 | kind + Cilium | Cluster | No |
| 3 | Tetragon + políticas | Cluster | No |
| 4 | PostgreSQL | Pod | No |
| 5 | Servidor MCP | Pod | No |
| 6 | Collector de OTel | Pod | No |
| 7 | **Orquestador por tarea** | **Pod** | No |
| 8 | **Agente investigador** | **Pod** | No |
| 9 | **Agente defensor** | **Pod** | No |
| 10 | Los dos `port-forward` | Host | **Sí** |
| 11 | Relay de Hubble | Host | **Sí** |
| 12 | La interfaz | Host | **Sí** |

**Tres terminales** se quedan abiertas. Lo demás vive en el cluster o en Docker
y sobrevive a que cierres la sesión.

Los agentes y el orquestador pasaron de host a pods el 2026-09-23, y es el cambio que
hace enseñables los segmentos 3 y 6: sólo como pods sus aristas existen para
Cilium y para Hubble.

**La interfaz se queda en el host, y es una decisión, no un pendiente.** Depende
de `nvidia-smi` para el panel de GPU y de `kubectl` contra Tetragon y el
Collector para los de kernel y cascada. Moverla al cluster rompería el primero y
exigiría darle permiso para ejecutar comandos dentro de `kube-system`, en una
sesión cuyo segmento 6 trata de mínimo privilegio. El reparto que queda es el
que el §3 ya describía: **el orquestador es un agente** y su sitio es la malla; **la
interfaz es la ventana del presentador** y su sitio es el host.

---

## Una vez por máquina

```bash
./lab/bootstrap.sh
```

Instala todo: Docker, kubectl, kind, Cilium, Hubble, Helm, el toolkit de GPU,
Node y el venv de Python. Es idempotente.

```bash
.venv/bin/pip install -r requirements.txt
```

```bash
cd ui && npm install && npm run build && cd ..
```

`npm run build` **termina solo**: no es un servidor, no hay que dejarlo abierto.

---

## Las capas de abajo (sobreviven a cerrar la terminal)

### 1. El modelo

```bash
./lab/vllm-up.sh
```

Tarda: la primera vez descarga ~19 GB. Escribe `lab/endpoint.env`, que es de
donde los agentes sacan la URL del motor.

### 2. El cluster

```bash
./lab/cluster-up.sh
```

### 3. El control de kernel

```bash
./lab/tetragon-up.sh
```

```bash
kubectl apply -f seguridad/tetragon-herramientas-lista-blanca.yaml
```

```bash
kubectl apply -f seguridad/cilium-l7.yaml
```

### 4. La evidencia

```bash
./datos/postgres-up.sh
```

### 5. Las herramientas

```bash
./herramientas/servidor-up.sh
```

Compila la imagen, la mete al cluster con `kind load` y despliega.

### 6. Las trazas

```bash
./observabilidad/collector-up.sh
```

### 7. Hubble, la segunda fuente

Las trazas son lo que la aplicación **declara**. Hubble es lo que la red
**vio**. El §5 pide las dos porque una ausencia solo se puede enseñar con la
segunda: si un agente intenta una conexión fuera del pipeline, no va a emitir
un span sobre ella.

El relay necesita un port-forward, y se queda corriendo:

```bash
cilium hubble port-forward &
```

Con eso funcionan `hubble observe`, el panel *Lo que vio la red* de la interfaz
y los dos scripts de seguridad. Comprobar:

```bash
hubble status
```

Ese port-forward del relay sí puede quedarse en `localhost`: quien lo consulta
—`hubble observe` y el servidor de la interfaz— corre en el mismo host.

**El grafo de agentes se dibuja aquí, no en un editor visual** (§6): Hubble UI
pinta lo que de verdad pasó.

```bash
./lab/hubble-ui.sh
```

Se queda corriendo e imprime la URL con la IP del host.

**No usar `cilium hubble ui`.** Hace el port-forward contra `127.0.0.1` e
intenta abrir un navegador: en un host sin escritorio las dos cosas fallan, y
desde tu máquina el puerto simplemente no existe. El script lo expone en
`0.0.0.0`, igual que `ui/servidor.py`, así que se alcanza con la misma IP que ya
usas para la interfaz.

Dos cosas que hacen parecer que está roto y no lo está:

1. **Arranca vacío.** Hay que elegir el namespace `agentes` en el desplegable de
   arriba a la izquierda.
2. **Dibuja tráfico, no diseño.** Si nadie está hablando no hay nada que pintar.
   Lanza una deliberación y el grafo aparece.

---

## El orquestador y los agentes son pods

**Esto cambió el 2026-09-23 y es importante.** Antes los agentes corrían como
procesos en el host con `python malla/agente.py`, y el orquestador vivía *dentro* del
proceso de la interfaz. Ya no: son tres Deployments que salen de **una sola
imagen**.

La razón está en `malla/Dockerfile`, y no es despliegue por gusto. Con los
agentes en el host, el salto lateral `investigador → defensor` era
`localhost:7010 → localhost:7011` y **nunca tocaba la red del cluster**: Cilium
no tenía nada que gobernar, Hubble nada que dibujar, y las políticas que
seleccionan `rol: agente` no aplicaban a nadie real. La v1 los tenía como pods;
esto lo recupera.

```bash
./malla/agentes-up.sh
```

Compila la imagen, la carga en kind, despliega los tres, y publica vLLM dentro
del cluster. Idempotente: se puede repetir.

Los tres salen de la misma imagen y sólo cambia el argumento — que es el
insight #1 de la sesión hecho despliegue: mismos pesos, mismo código, identidades
y permisos distintos.

Cada cambio en `malla/agente.py` pide volver a correrlo. Si sólo cambias una
variable del ConfigMap (`RONDAS_DEBATE`, por ejemplo), basta:

```bash
kubectl apply -f malla/00-agentes.yaml && kubectl -n agentes rollout restart deploy/orquestador deploy/investigador deploy/defensor
```

---

## Las tres terminales

Estas sí hay que dejarlas abiertas, cada una en su ventana.

**Terminal 1 — los puentes**

La interfaz corre en el host y ahora **sólo habla con el orquestador**. A los agentes
les habla el orquestador, desde dentro del cluster:

```bash
kubectl -n agentes port-forward deploy/orquestador 7012:7012 & kubectl -n agentes port-forward deploy/servidor-mcp 9000:9000
```

El del servidor MCP se queda para poder probar herramientas a mano desde el
host; la deliberación ya no lo usa.

**Los `port-forward` de investigador y defensor ya no hacen falta.** Si los dejas
puestos no estorban, pero tampoco sirven — y conviene quitarlos, porque tenerlos
invita a pensar que la interfaz les habla.

**Terminal 2 — el relay de Hubble**

```bash
cilium hubble port-forward
```

**Terminal 3 — la interfaz**

```bash
.venv/bin/python ui/servidor.py
```

Queda en `http://<host>:8080`.

### Las trazas ya no piden variable

Con los agentes en el host había que arrancarlos con
`OTEL_EXPORTER_OTLP_ENDPOINT=...` y acordarse cada vez. Ahora la variable está
en el ConfigMap `endpoints` apuntando a `http://otel-collector:4318`, que es DNS
del cluster: **los pods exportan solos y sin port-forward.**

### Ver lo que dice un agente, o el orquestador

Los sobres A2A se siguen imprimiendo; ahora salen por los logs del pod:

```bash
./malla/agentes-up.sh --logs investigador
```

```bash
./malla/agentes-up.sh --logs orquestador
```

### Comprobar que la imagen no se quedó atrás

```bash
curl -s http://localhost:8080/api/salud
```

Devuelve `version_flujo` (lo que hay en disco) y `version_orquestador` (lo que el pod
está corriendo). **Si `al_dia` es `false`, la imagen es vieja:**
`./malla/agentes-up.sh`. Este desfase ya mordió tres veces y nunca da un error —
da resultados viejos, que es peor.

### 8. Splunk Observability (opcional)

```bash
./observabilidad/splunk-up.sh us1
```

El argumento es tu *realm* — el que sale en la URL de tu Splunk
(`https://app.**us1**.signalfx.com`). Pide el token por teclado, lo guarda como
Secret, y no toca el archivo del repo.

**No puede romper nada.** El exportador `file` se queda puesto, así que la
cascada del segmento 5 se dibuja igual sin internet y sin credenciales. Splunk
es validación externa, no el único sitio donde mirar.

Para quitarlo: `./observabilidad/splunk-up.sh --down`

En Splunk los servicios aparecen como `orquestador`, `agente-investigador` y
`agente-defensor`. Los spans llevan los atributos `gen_ai.*`, así que deberían
reconocerse como de GenAI sin configurar nada.

---

## Qué reiniciar cuando cambia algo

**La respuesta corta, y sirve siempre:**

```bash
./lab/reiniciar.sh
```

Reconstruye la imagen, relanza los tres pods, aplica las políticas, rehace los
puentes y compila la interfaz. Al final te dice lo único que no puede hacer solo:
reiniciar tu terminal de `ui/servidor.py`.

Con `--rapido` se salta la imagen, que es lo que tarda.

---

### Y la tabla, para cuando quieras hacerlo a mano

**Cada pieza se reinicia distinto, y ninguna avisa cuando corre código viejo.**
Ése es el problema de fondo: un pod con la imagen vieja no falla, sirve lo de
antes. Ya mordió cinco veces.

| Cambiaste | Qué hay que hacer | Por qué |
|---|---|---|
| `malla/*.py` (agentes, flujo, orquestador) | `./malla/agentes-up.sh` | El código va **dentro de la imagen**. Sin reconstruir, los pods siguen con el anterior |
| `herramientas/servidor_mcp.py` | `./herramientas/servidor-up.sh` | Igual: otra imagen |
| `ui/servidor.py` | **Ctrl+C y relanzar esa terminal** | Python no recarga módulos solos |
| `ui/src/**` | `cd ui && npm run build` + recargar navegador | Son estáticos, no tocan el backend |
| `seguridad/*.yaml` | `kubectl apply -f ...` | En caliente, no reinicia nada |
| `datos/*.sql` | `./datos/postgres-up.sh --reset` | |
| Se reinició un pod | rehacer su `port-forward` | Los puentes mueren con el pod, **y no avisan** |
| Se recreó el cluster | `./lab/publica-vllm.sh` | La IP del host cambió |

### Las tres trampas que ya nos costaron tiempo

1. **Un `port-forward` muerto parece un fallo de la aplicación.** La interfaz
   dice *"no alcanzo al orquestador"* y el orquestador está perfecto.
2. **Una política sin aplicar parece que los agentes están caídos.** El error es
   *"ningún agente responde"* y lo que pasa es que la red corta la petición.
3. **Una imagen vieja no da error.** Da resultados viejos. Por eso los pods
   publican la huella de su código en `/salud` y `lab/diagnostico.sh` la compara.

Cuando algo no cuadre y no sepas qué es:

```bash
bash lab/diagnostico.sh
```

---

## Comprobar que todo está

```bash
bash lab/estado.sh
```

Y las pruebas de cada capa, que además son demostrables por separado:

```bash
curl -s http://localhost:7012/agentes | jq '.[] | {clave, vivo, peticion}'
```

Ése es el descubrimiento **de verdad**: lo hace el orquestador, desde dentro del
cluster, leyendo las Agent Cards por HTTP. Es exactamente lo que alimenta el
segmento 2 de la interfaz.

*(`malla/router.py` es un CLI anterior que habla a `localhost:7010`. Desde que
los agentes son pods ya no alcanza nada sin puentes que hoy no levantamos. Se
conserva por si hiciera falta depurar el descubrimiento fuera del cluster.)*

```bash
bash seguridad/probar-lista-blanca.sh
```

```bash
bash seguridad/probar-l7.sh
```

---

## Para la migración a la instancia final

El orden de arriba **es** el procedimiento. Lo único que no se puede dar por
hecho es la versión del driver NVIDIA: si la instancia nueva trae 580 o
superior, se destraban el NIM y las imágenes modernas de vLLM
(`CLAUDE.md` §8). Pregúntalo al pedirla.

Todo lo demás está en scripts idempotentes: `git clone` y la lista de arriba.
