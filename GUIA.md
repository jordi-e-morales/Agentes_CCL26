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
| 7 | `port-forward` del MCP | Host | **Sí** |
| 8 | Agente investigador | Host | **Sí** |
| 9 | Agente defensor | Host | **Sí** |
| 10 | La interfaz | Host | **Sí** |

**Cuatro terminales** se quedan abiertas. Lo demás vive en el cluster o en
Docker y sobrevive a que cierres la sesión.

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

**El grafo de agentes se dibuja aquí, no en un editor visual** (§6): Hubble UI
pinta lo que de verdad pasó.

```bash
cilium hubble ui
```

Abre el navegador solo; si no, queda en `http://localhost:12000`. Hay que
elegir el namespace `agentes` en el desplegable de arriba: arranca vacío y sin
eso parece roto.

---

## Las cuatro terminales

Estas sí hay que dejarlas abiertas, cada una en su ventana.

**Terminal 1 — el puente a las herramientas**

```bash
kubectl -n agentes port-forward deploy/servidor-mcp 9000:9000
```

**Terminal 2 — el agente investigador**

```bash
.venv/bin/python malla/agente.py --rol investigador
```

**Terminal 3 — el agente defensor**

```bash
.venv/bin/python malla/agente.py --rol defensor --puerto 7011
```

**Terminal 4 — la interfaz**

```bash
.venv/bin/python ui/servidor.py
```

Queda en `http://<host>:8080`.

Si quieres trazas hacia el Collector, arranca los agentes con la variable
puesta:

```bash
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4318 .venv/bin/python malla/agente.py --rol investigador
```

Y entonces hace falta una quinta terminal con el `port-forward` del Collector.
Sin esa variable los agentes corren igual y no exportan nada.

---

## Qué reiniciar cuando cambia algo

| Cambió | Qué hacer |
|---|---|
| `malla/agente.py` | Reiniciar las dos terminales de agentes |
| `malla/flujo.py`, `ui/servidor.py` | **Reiniciar la terminal de la interfaz.** Importa el flujo al arrancar; sin reiniciar, los pasos nuevos no salen y no da ningún error |
| `ui/src/**` | `cd ui && npm run build`, y recargar el navegador |
| `ui/package.json` | `npm install` antes del build |
| `herramientas/servidor_mcp.py` | `./herramientas/servidor-up.sh` |
| Los `.sql` de `datos/` | `./datos/postgres-up.sh --reset` |
| Políticas de `seguridad/` | `kubectl apply -f ...` |

**Si vas a iterar sobre el frontend**, no compiles cada vez:

```bash
cd ui && npm run dev
```

Vite queda en el `5173` con recarga automática y manda `/api` al backend del
`8080`. Eso **sí** es un servidor: Ctrl-C cuando termines.

---

## Comprobar que todo está

```bash
bash lab/estado.sh
```

Y las pruebas de cada capa, que además son demostrables por separado:

```bash
.venv/bin/python malla/router.py --solo-descubrir
```

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
