# La interfaz

**Demo Multi-Agentes en Secure AI Factory de Cisco**

React + Vite delante, Python detrás. Dibuja la deliberación **según ocurre**,
con datos de la malla de verdad.

## Cómo correrla

```bash
cd ui && npm install && npm run build
```

```bash
.venv/bin/python ui/servidor.py
```

Queda en `http://localhost:8080`. Necesita los dos agentes levantados
(`malla/README.md`) y el servidor MCP alcanzable.

Para desarrollar el frontend con recarga automática:

```bash
cd ui && npm run dev
```

Eso levanta Vite en el 5173 y manda `/api` al backend del 8080.

## Los colores están en un solo archivo

[`src/estilo/cisco.css`](src/estilo/cisco.css). **Ningún componente escribe un
color a mano**, todos usan las variables de ahí. Cambiar la identidad visual es
editar ese archivo y nada más.

Si la paleta de tu plantilla de Cisco Live no es esta, se corrige en un minuto.

Dos decisiones heredadas de la v1 que vale la pena conservar:

- **Sin `@import` de Google Fonts.** El día del evento nada depende de internet.
  Si Inter está instalada se usa; si no, la del sistema.
- **Base de 17px, no 14.** El `CLAUDE.md` §10 pide tipografía legible a cuatro
  metros: esto se proyecta, no se lee en un portátil.

## Por qué el backend es Python

El repo del que viene el diseño visual (`agntcy-mortgage-demo`) era Node de
punta a punta. Aquí no: ya hay Python que sabe hablar A2A, MCP y Postgres, y
`starlette` viene gratis con `mcp`. Reescribir esa capa sería duplicarla, y una
cosa más que instalar en la instancia del día 4.

React y Vite se quedan donde importan: el control visual.

Node hace falta **solo para compilar**. Una vez compilada, quien sirve la página
es Python; el día del evento Node no interviene.

## Lo que NO hace, y es lo importante

**No fabrica datos.** Los sobres A2A que ves son los que viajaron. Los
resultados de las herramientas son las filas de Postgres.

Esa distinción no es purismo. El `agntcy-mortgage-demo` dibujaba una cascada de
OpenTelemetry preciosa que la propia aplicación se inventaba — su README lo dice
con precisión: *"modelled as a full SLIM envelope"*.

Aquí eso rompería el argumento central del segmento 5, que dice que **OTel es la
autodeclaración de la aplicación** y que por eso hace falta Hubble como fuente
independiente. Si la cascada la dibuja la misma aplicación con datos que ella
inventó, no hay dos fuentes: hay una aplicación calificando su propio examen.

## Las reglas que sigue

Del `CLAUDE.md`, reglas de interfaz:

1. **Cada paso lleva su explicación en una frase**, escrita al lado. No se
   confía en que quien presenta se acuerde.
2. **Se ve el mecanismo:** el sobre A2A entero, la llamada a la herramienta
   *con su resultado*, y quién habló con quién.
3. **Lo importante se marca solo.** El salto lateral sale resaltado; no hay que
   buscarlo.

### Por qué la herramienta muestra también el resultado

Si solo se viera la pregunta, no habría forma de saber si la evidencia existe o
si el modelo la rellenó. Esa no es una hipótesis: pasó, y las dos veces los
agentes deliberaron con elegancia sobre datos vacíos sin que nada pareciera
roto.
