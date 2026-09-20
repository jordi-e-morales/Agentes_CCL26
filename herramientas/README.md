# El servidor MCP de herramientas

Las cinco tools del `CLAUDE.md` §4, leyendo y escribiendo en PostgreSQL.

Sucede a `spike-mcp/servidor_mcp.py`, que ya cumplió su papel —probar el puente
con datos escritos a mano— y se queda intacto, porque el código de un spike es
desechable por diseño.

## Lo que cambió del spike, y lo que no

**Cambiaron solo los cuerpos de las funciones.** Los nombres, las firmas y las
descripciones que lee el modelo son idénticas.

Ese era el punto de ponerles nombres con significado en vez de un
`execute_sql`: la fuente de datos se cambia por debajo y el agente no se entera.

## Cómo correrlo

Terminal 1 — el puente a la base (mientras el servidor corra en el host):

```bash
kubectl -n agentes port-forward deploy/postgres 5432:5432
```

Terminal 2 — el servidor:

```bash
.venv/bin/pip install "psycopg[binary]"
```

```bash
.venv/bin/python herramientas/servidor_mcp.py
```

Terminal 3 — el agente:

```bash
.venv/bin/python spike-mcp/agente.py
```

Comprueba la conexión al arrancar, no en la primera llamada: si Postgres no
está, el error te lo dice con el comando que falta.

## Las cinco herramientas

| Tool | Tipo | Qué hace |
|---|---|---|
| `consulta_historial` | evidencia | `SELECT` sobre `eventos` |
| `lista_sancionados` | evidencia | `SELECT` sobre `listas` |
| `perfil_sujeto` | evidencia | `SELECT` sobre `sujetos` |
| `dispone_caso` | **acción peligrosa** | **`INSERT`** sobre `disposiciones` |
| `exporta_evidencia` | **ejecuta un binario** | Lanza un proceso hijo |

### `dispone_caso` no se defiende a sí misma

A propósito. Acepta la llamada y escribe. Si validara quién la llama o por qué,
el demo no enseñaría nada: cada quien diría *"pues valida tus entradas"* y a
otra cosa.

El control vive en las capas de alrededor —Cilium sobre la ruta, Tetragon sobre
el kernel— y esa es la tesis de la sesión.

Ahora además **escribe en una fila que la sala puede ver cambiar**:

```bash
./datos/postgres-up.sh --psql
```
```sql
SELECT * FROM disposiciones;
```

### `exporta_evidencia` es un sustituto, y se etiqueta

Un generador de PDF real se sustituye aquí por un proceso que escribe un
archivo de texto. Lo que importa para el demo es idéntico —**se lanza un
proceso hijo de verdad y el kernel lo ve**— pero no se afirma que sea un PDF.
Regla de honestidad del §6: lo sustituido se etiqueta.

Si Tetragon está activo y esto corre desde un pod con `rol: agente`, devuelve
código `-9`: el proceso murió por SIGKILL **antes de ejecutarse**.

## Dónde corre hoy, y dónde tiene que correr

Hoy en el host, alcanzando Postgres por `port-forward`. Para el demo tiene que
ser **un pod del cluster**: solo así Cilium puede gobernar las dos aristas que
importan.

```
agente  ──►  servidor MCP  ──►  postgres
        ▲                  ▲
        │                  └── esta arista Cilium la permite
        └── y esta la ve, pero no distingue cuál de las cinco tools
```

## Por qué no un servidor MCP de Postgres ya hecho

Existen, y todos exponen **una** herramienta con SQL arbitrario. Eso rompería
cuatro cosas a la vez: las tools dejarían de explicarse en tres segundos,
`dispone_caso` dejaría de ser una acción con significado que el ataque pueda
abusar, el ejecutor se quedaría sin control que enseñar (insight #2), y
`exporta_evidencia` no existiría.

Enseñar su lista de herramientas al lado de esta es medio minuto y vale por un
argumento entero sobre lo que **no** hay que desplegar.
