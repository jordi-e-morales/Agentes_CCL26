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
| 2 | kind + Cilium **o Isovalent Enterprise** | Cluster | No |
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

### 2. El cluster y la red

**Hay que elegir aquí, y es excluyente.** Cilium tiene que ser el único CNI del
cluster, así que no se instala una versión y luego la otra encima. Los dos
caminos dan la misma demo; el empresarial además **demuestra** lo que la lámina
7 de `PUNTOS-CLAVE.md` hoy sólo afirma.

**Camino A — código abierto** (Cilium 1.20.1 + Tetragon 1.7.1)

```bash
./lab/cluster-up.sh && ./lab/tetragon-up.sh
```

**Camino B — Isovalent Enterprise** (Cilium 1.19.8 + Runtime Security 1.19.3)

El cluster se crea **sin red**, y la red la pone el instalador empresarial —que
trae Tetragon dentro, así que `tetragon-up.sh` no se corre:

```bash
./lab/cluster-up.sh --solo-kind
```

```bash
./lab/isovalent-up.sh
```

Pide tu CEC y el token de **acceso** de Artifactory por teclado (nunca por
argumento: los argumentos se ven en `ps` y quedan en el historial). Entre
`--solo-kind` y el instalador los nodos se quedan en `NotReady`: es lo
esperado, todavía no hay red.

**Antes del token hace falta el grupo**, y es lo que más cuesta descubrir: el
acceso de lectura a los artefactos de Isovalent va por pertenencia a
**`isovalent-artifactory-read-ext`** en MyID Groups, no por un ticket de
Artifactory. Sin esa membresía todo lo demás funciona y aun así falla — el
token se crea, autentica, ve 140 repositorios, y el de Isovalent da **403**.
Nada en ese 403 menciona un grupo.

El token son **dos pasos**: creas un *ID token* en la UI de Artifactory y lo
cambias por un *access token* contra `/access/api/v1/tokens`. Solo el segundo
sirve como password. El intercambio completo está escrito en la cabecera de
`lab/isovalent-up.sh`, junto con la comprobación previa que distingue el 401
(token mal) del 403 (falta el grupo). **Y si te acaban de aprobar el grupo y
sigue el 403, regenera el token**: pudo quedarse con el conjunto de grupos
anterior.

Si ya tienes el cluster con Cilium de código abierto, el instalador **se para y
te lo dice** en vez de intentar adoptarlo. Para cambiar de camino hay que
rehacer el cluster:

```bash
kind delete cluster --name agentes && ./lab/cluster-up.sh --solo-kind && ./lab/isovalent-up.sh
```

Rehacer el cluster se lleva Postgres, el servidor MCP, los agentes y el
Collector — todos vuelven con sus scripts, y el que tarda es
`./malla/agentes-up.sh` porque reconstruye la imagen. **vLLM no se toca:** corre
en el host, fuera de kind.

#### Lo que el instalador empresarial hace distinto de las instrucciones de Cisco

Las instrucciones oficiales traen **cuatro erratas**, y el script las corrige:
`set CEC=` es sintaxis de `cmd` y no de bash; `--docker-password=$ACCESS-TOKEN`
se parsea como `$ACCESS` seguido de `-TOKEN`; `--docker-username=<your=CEC>`
lleva un `=` de más; y `https://$CP\_IP:$CP\_PORT` mete barras literales que
dejan a Tetragon apuntando a un host que no existe.

Y preserva **cuatro ajustes que el `values` de ejemplo se llevaría por
delante**, los cuatro medidos, no preferencias:

| Ajuste | Si se pierde |
|---|---|
| `hubble.ui.enabled` | no hay grafo, y el grafo es la mitad del segmento 3 |
| `hubble.eventBufferCapacity=65535` | la historia baja de ~20 min a ~164 s: a los tres minutos los flujos que narras ya no existen |
| `envoy.streamIdleTimeoutDurationSeconds=1800` | vuelve a 300 s y corta una deliberación en CPU (medidos 345 s sin mandar un byte) |
| `tetragon.exportFilename=eventos.log` + `exportFilePerm=644` | el SIGKILL sigue funcionando y el panel *Lo que vio el kernel* se queda en blanco, **sin dar error** |

Ese último es el que más vale: `ui/servidor.py` y `seguridad/ver-eventos.sh`
leen esa ruta exacta, y el nombre por omisión (`tetragon.log`) se crea con
permiso 600 la primera vez — y un archivo que ya existe se queda en 600 para
siempre, así que cambiar el permiso después no arregla nada. El script
**comprueba el archivo al final** y avisa si el chart empresarial renombró la
clave, porque Helm acepta claves que no conoce y las ignora en silencio.

**Tetragon va a `kube-system`**, no al namespace `tetragon` que piden las
instrucciones, por la misma razón: las dos cosas que leen los eventos buscan
ahí. Se puede cambiar con `NS_TETRAGON=tetragon`, y entonces hay que ajustar
esas dos rutas.

**Timescape y L2 announcements quedan apagados.** Timescape necesita un backend
propio, y encenderlo contra uno que no existe puede dejar los pods de Cilium
exportando a la nada: `--con-timescape` cuando quieras probarlo, como segundo
paso. L2 anuncia IPs de LoadBalancer por ARP en una red física, y en kind no hay
tal red.

**Un efecto secundario bueno:** 1.19.8 arregla el desajuste de Hubble. La CLI va
por la 1.19.4 —la última que existe— contra un relay 1.20.1, con el aviso de
incompatibilidad que decidimos tolerar. En el camino B quedan en la misma línea.

**Y un riesgo con fecha: el token caduca a los 90 días.** Si caduca antes del
evento y hay que rehacer el cluster, no habría instalación posible. Por eso:

```bash
./lab/isovalent-up.sh --precargar
```

Guarda las imágenes dentro de kind con `kind load`. Una vez ahí el cluster se
rehace sin Artifactory y sin token — el mismo patrón que ya usamos para vLLM y
los agentes.

### 3. Las políticas

Son el **mismo CRD** en los dos caminos, así que se aplican igual:

```bash
kubectl apply -f seguridad/tetragon-herramientas-lista-blanca.yaml
```

```bash
kubectl apply -f seguridad/cilium-l7.yaml
```

En el camino B esto es lo primero que hay que verificar: la política L7 es lo
que más depende de Envoy, y Envoy es lo que más cambia entre versiones.

```bash
bash seguridad/probar-l7.sh && bash seguridad/probar-lista-blanca.sh
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
./observabilidad/splunk-up.sh https://ingest.us1.observability.splunkcloud.com
```

El argumento es el **Real-time Data Ingest Endpoint**, tal cual aparece en tu
página de perfil de Splunk Observability. Se pasa entero y no se deduce del
realm, porque hay **dos dominios en circulación** y no se puede adivinar cuál te
toca:

| | |
|---|---|
| `ingest.<realm>.observability.splunkcloud.com` | organizaciones nuevas |
| `ingest.<realm>.signalfx.com` | las antiguas |

Pide el token por teclado —nunca por argumento, que se ve en `ps`— lo guarda
como Secret, y no toca el archivo del repo.

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
| Un ConfigMap o un Secret | **`kubectl rollout restart` del pod que lo usa** | No se recargan solos: el proceso los leyó al arrancar |
| La etiqueta del redactor | **`./seguridad/redactor-limpio.sh`** antes de demostrar | Vive solo en el pod: un pod nuevo nace limpio por construcción |
| Quieres pasar a Isovalent Enterprise | `kind delete cluster --name agentes`, luego **`./lab/cluster-up.sh --solo-kind`** y **`./lab/isovalent-up.sh`** | Cilium tiene que ser el único CNI: no se instala uno sobre el otro |
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

El orden de arriba **es** el procedimiento. Dos cosas no se pueden dar por
hechas:

1. **La versión del driver NVIDIA.** Si la instancia nueva trae 580 o superior,
   se destraban el NIM y las imágenes modernas de vLLM (`CLAUDE.md` §8).
   Pregúntalo al pedirla.
2. **Qué red va a llevar** (paso 2). En la instancia final conviene el camino B
   con `--precargar`, para no depender de que el token siga vivo el día del
   evento.

Todo lo demás está en scripts idempotentes: `git clone` y la lista de arriba.
