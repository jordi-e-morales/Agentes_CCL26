# La evidencia: PostgreSQL

De aquí leen las herramientas del servidor MCP. Sustituye a los datos escritos a
mano del spike.

## Cómo levantarlo

```bash
./datos/postgres-up.sh
```

Necesita el cluster arriba (`./lab/cluster-up.sh`). Al final te imprime **la
misma consulta corriendo sobre los dos dominios**, que es la prueba de que el
esquema es neutral.

Otros usos:

```bash
./datos/postgres-up.sh --psql
```

```bash
./datos/postgres-up.sh --reset
```

## Tres decisiones que conviene entender

### No hay almacenamiento persistente, y es a propósito

`PGDATA` vive en un `emptyDir`, y el esquema con la semilla se montan en
`/docker-entrypoint-initdb.d/`. La imagen de Postgres ejecuta esos scripts
**solo cuando el directorio de datos está vacío** — o sea, en cada pod nuevo.

Consecuencias, todas buenas para este proyecto:

- La base **siempre nace igual**. El estado es determinista.
- "Reiniciar entre visitantes" es **borrar el pod**. Nada que respaldar, nada
  que limpiar, nada que se corrompa a media jornada de stand.
- Cambiar los `.sql` y volver a correr el script con `--reset` recarga todo. Sin
  migraciones.

### Es un pod aparte, no SQLite

SQLite sería un archivo dentro del pod: no hay arista, no hay nada que
gobernar. Un pod aparte es **una arista que Cilium puede gobernar**:

> El servidor MCP puede hablar con la base. **Los agentes no.**

Cuando el agente comprometido lo intente directo, Cilium lo corta y **Hubble lo
ve** — aunque el agente no emita ninguna traza confesándolo. Esa es la
*ausencia* de la que habla el `CLAUDE.md` §5.

### El pod lleva `rol: datos`, nunca `rol: agente`

La `TracingPolicy` de Tetragon mata cualquier `exec` desde pods con
`rol: agente`, y Postgres lanza procesos hijos constantemente. Con esa etiqueta
no arrancaría.

Que la política sea tan fácil de razonar —*los agentes no ejecutan binarios,
punto*— es justo lo que la hace defendible en vivo.

## Las tablas

| Tabla | Para qué |
|---|---|
| `sujetos` | Sobre quién o qué es la alerta. Lo del dominio vive en `atributos JSONB` |
| `alertas` | El caso |
| **`eventos`** | **La tabla clave.** Ver abajo |
| `listas` | Listas de control |
| `fragmentos` | Los textos libres, con `source_trust`. **Aquí vive el riesgo** |
| `disposiciones` | El resultado. La escribe `dispone_caso`. Empieza vacía |

### `eventos` es la que prueba la promesa difícil

El `CLAUDE.md` §7 promete que los casos de SOC cargan **sin cambiar código**.
Esta tabla lo vuelve demostrable:

| Dominio | Qué lleva `atributos` |
|---|---|
| Monitoreo transaccional | `canal`, `volumen`, `contraparte` |
| Alertas de SOC | `binario`, `usuario`, `destino`, `puerto` |

Misma tabla, misma consulta, misma herramienta. `postgres-up.sh` lo imprime al
terminar: dos bloques de filas que no se parecen en nada, salidos del mismo
`SELECT`.

**No existe una tabla `transacciones`.** En cuanto se escriba esa palabra, un
caso de SOC obliga a tocar código y la promesa se rompe.

### `fragmentos` es donde entra el ataque

`source_trust` declara quién escribió cada texto: `internal`, `external` o
`unknown`. **La inyección del segmento 6 vive siempre en un fragmento
`external`** — es una invariante del proyecto, no una casualidad de un caso.

`FRG-0004` es ese fragmento. En la interfaz se renderiza distinto, para que la
sala **vea** que el sistema sabía de dónde venía ese texto y aun así el modelo
le hizo caso. Si se viera igual que el resto, parecería un truco.

## Credenciales

`postgres-lab` es un Secret con la contraseña a la vista, a propósito. Datos
sintéticos, entorno desechable, nada real detrás. Está visible para que nadie la
confunda con una credencial de verdad ni la reutilice en otro sitio.
