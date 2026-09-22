# Las dos capas de control: red y kernel

Hay **dos políticas**, y la diferencia entre ellas es el argumento del
segmento 6.

| Política | Sobre quién | Regla | Estado |
|---|---|---|---|
| `agentes-sin-exec` | `rol: agente` | **Prohibición total.** Un agente no ejecuta binarios, punto | Portada de v1, probada allí |
| `herramientas-lista-blanca` | `rol: herramientas` | **Lista blanca.** El ejecutor corre el shell del generador y nada más | Nueva, sin correr |

### Por qué dos y no una

El servidor MCP **sí necesita** ejecutar un proceso: eso es exactamente
`exporta_evidencia`. Prohibirle todo lo dejaría sin funcionar.

Y ahí está la vía del ataque del segmento 6, que es la que pide el
`CLAUDE.md` §4 — *qué binario puede ejecutar el ejecutor*:

| | La cadena |
|---|---|
| 1 | La inyección llega en un fragmento `source_trust: external` |
| 2 | El agente llama `exporta_evidencia` con un `alerta_id` manipulado |
| 3 | El shell ejecuta un binario que nadie autorizó |
| 4 | **Tetragon lo mata:** la lista blanca solo permite el del comprobante |

La inyección de comandos de `exporta_evidencia` **es deliberada y está
etiquetada como tal** en el código. Si esa función validara su entrada, el demo
no enseñaría nada: todo el mundo diría *"pues escapa tus argumentos"* y se
perdería el punto — que el control no puede depender de que cada herramienta
esté bien escrita.

```bash
bash seguridad/probar-lista-blanca.sh
```

### La lista blanca bloqueó a su propio equipo

Pasó el 2026-09-21 y merece contarse en la sesión.

`exporta_evidencia` escribía una sola línea con `printf`, que es **interno de
dash**: no hay `exec`, no hay nada que matar. Cuando el comprobante pasó a ser
un expediente completo, la escritura cambió a `cat > ruta` — y `cat` **sí** es
un binario.

Tetragon lo mató. El archivo quedó **vacío**, porque la redirección `>` crea el
fichero antes del `exec`.

Nadie había tocado la política. Un cambio legítimo en la herramienta chocó con
la lista blanca, exactamente como debe ser. **Eso demuestra que está viva y no
es decorativa**, que es justo lo que alguien en la sala va a sospechar cuando
vea el SIGKILL del ataque.

El arreglo es añadir `cat`, no ensanchar la regla: la lista dice exactamente
qué necesita el generador de comprobantes.

### Las dos formas de fallar en silencio

Esta política puede romperse sin avisar, en dos direcciones opuestas:

- **La ruta del shell no está en la lista blanca** → mata también lo legítimo, y
  `exporta_evidencia` deja de funcionar.
- **El intérprete no está en `matchBinaries`** → **no dispara nada**, y parece
  que todo está protegido cuando no hay nada aplicándose. Esta es la peligrosa.

`linux_binprm` reporta rutas **resueltas**, y en Debian `/bin/sh` es un enlace a
dash. Por eso `probar-lista-blanca.sh` comprueba las rutas reales dentro del pod
**antes** de sacar ninguna conclusión.

Nota de operadores: para `linux_binprm` valen `Equal`, `NotEqual`, `Prefix`,
`Postfix` y `SubString`. **`NotIn` no está soportado** — si se usa, la política
no dispara y no avisa.

## Ver lo que vio el kernel

```bash
bash seguridad/ver-eventos.sh
```

```bash
bash seguridad/ver-eventos.sh --seguir
```

**`tetra getevents` a secas no sirve**, y cuesta un rato entender por qué:

1. **Transmite en vivo**, no consulta el pasado. Un `| grep | tail` se queda
   esperando para siempre y no imprime nada. Lo ya ocurrido está en el archivo
   de exportación, no en el flujo.
2. **Tetragon es un DaemonSet**: un pod por nodo, y cada uno solo ve lo de su
   máquina. `ds/tetragon` elige uno cualquiera, que puede no ser donde corre el
   pod que te interesa.

El script resuelve las dos: busca el nodo donde vive el servidor de
herramientas, le pregunta al Tetragon de *ese* nodo, y lee el histórico.

## Ver lo que vio la red, y lo que la aplicación calló

```bash
cilium hubble port-forward &          # una vez, se queda corriendo
bash seguridad/probar-hubble.sh
```

Esto no repite lo que hace `probar-l7.sh`. Ese comprueba que la política
funciona; este enseña **por qué hacen falta dos fuentes de observabilidad** y no
una.

| Fuente | Qué es | Qué puede enseñar |
|---|---|---|
| La cascada de trazas | Lo que la aplicación **declara** haber hecho | Todo el detalle de lo que salió bien |
| Hubble | Lo que la red **vio**, sin preguntar a nadie | Un intento que **ningún span menciona** |

El script provoca que un pod con `rol: agente` intente ir directo a Postgres y
después mira las dos fuentes: Hubble tiene el tráfico, el archivo del Collector
tiene **cero** spans que mencionen el puerto 5432. No es un fallo de
instrumentación — nadie instrumenta el camino que no existe.

> Un panel de observabilidad alimentado solo por la aplicación no puede mostrar
> una ausencia.

El cliente es `agente-demo`, **sustituto** del agente real (que hoy corre en el
host). La política mira la etiqueta del pod, así que para la red son lo mismo;
pero la regla de honestidad del §6 pide etiquetar lo sustituido, y el script lo
imprime en pantalla.

En la interfaz esto mismo vive en el panel **Lo que vio la red**, al lado de
*Lo que vio el kernel*. Ahí las líneas `POST /mcp` llevan una marca `×N
idénticas`: es el límite de la capa 7 señalándose solo, sin obligar a nadie a
comparar dos columnas.

Y el grafo de agentes se dibuja con Hubble UI (`cilium hubble ui`, namespace
`agentes`), que pinta lo que de verdad pasó — no un editor visual, que pinta lo
que alguien diseñó.

## Lo que se ve cuando funciona (medido el 2026-09-20)

Salida real de `probar-l7.sh`, recortada. **Estas tres líneas son el segmento 6
entero**, y no hay que editarlas para ponerlas en pantalla:

```
http-request DROPPED   (HTTP/1.1 GET  http://servidor-mcp...:9000/)
http-request FORWARDED (HTTP/1.1 POST http://servidor-mcp...:9000/mcp)
http-request FORWARDED (HTTP/1.1 POST http://servidor-mcp...:9000/mcp)
```

**La primera demuestra la capacidad.** Misma IP de origen, mismo puerto, mismo
pod de destino — y se corta por la ruta. Eso es capa 7 de verdad, no filtrado
de capa 4 disfrazado. Si alguien en la sala sospecha que es un truco, esa línea
lo contesta.

**Las otras dos demuestran el límite.** Son idénticas. La primera fue
`consulta_historial`, que lee evidencia. La segunda fue `dispone_caso`, que
**cierra el caso**. Para la red son la misma petición.

En una sola pantalla está lo que la red puede hacer y lo que no.

Y del lado del kernel, los dos eventos que cierran el argumento:

```json
{"ejecutaba":"/bin/sh",               "quiso_correr":"/usr/bin/id", "politica":"herramientas-lista-blanca"}
{"ejecutaba":"/usr/local/bin/python3","quiso_correr":"/usr/bin/id", "politica":"herramientas-lista-blanca"}
```

La red autorizó la arista. El kernel atrapó lo que la red no podía ver.
**Ninguna capa sola bastaba** — que es la frase con la que la sala se va.

---

## El SIGKILL, en detalle

Control de ejecución con Tetragon. Es el final del segmento 6 y lo único del
demo que **mata procesos de verdad**.

## Lo que hay que entender antes de correrlo

La política no mira qué agente eres, ni qué hace tu código, ni qué binario
quieres lanzar. Mira **dos cosas**:

1. ¿Tu pod lleva la etiqueta `rol: agente`?
2. ¿Quien intenta ejecutar un programa es el intérprete de Python?

Si las dos son sí, Tetragon manda **SIGKILL antes de que el programa nuevo
corra**. Se engancha en `security_bprm_creds_for_exec`, el punto del kernel
donde se autoriza un `exec`.

**Se filtra por quién ejecuta, no por qué se ejecuta.** Eso es lo que la hace
honesta: no hay lista negra de binarios peligrosos que mantener, ni que
esquivar usando otro binario. Por eso la prueba intenta dos programas
distintos: para que se vea que mueren los dos.

Y no adivina intenciones. Aplica una regla. Por eso no falla cuando el
clasificador de contenido sí falla — que es el argumento entero del segmento 6.

## Cómo correrlo

```bash
./lab/cluster-up.sh && ./lab/tetragon-up.sh
```

```bash
kubectl apply -f seguridad/00-pods-de-prueba.yaml
```

```bash
kubectl apply -f seguridad/tetragon-agentes-sin-exec.yaml
```

```bash
bash seguridad/probar-sigkill.sh
```

## Por qué dos pods pelados

`agente-demo` y `servicio-demo` son idénticos salvo por una etiqueta. Corren
`sleep infinity` y no hacen nada.

Eso basta para demostrar el mecanismo completo **antes de que exista un solo
agente**, que es lo que pide el `CLAUDE.md` §2: cada segmento tiene que poder
enseñarse solo, sin depender de que el anterior se haya ejecutado.

Y el contraste es el demo: la misma orden en los dos pods, dos resultados
distintos, y la única diferencia es una palabra en una etiqueta.

## Qué se ve cuando funciona

El hijo muere con `-9` y **el servicio sigue vivo, sin reinicios**. Con
`subprocess`, Python primero se clona y el clon intenta el `exec`. Tetragon
mata al clon: el agente sigue respondiendo y la herramienta recibe *"terminado
por la señal 9"*.

Eso importa para el guión: el pod tiene que volver a estar listo para el
siguiente visitante, y aquí ni siquiera se cae.

## Procedencia

Portado de la demo v1 (`triage-multiagente`,
`deploy/k8s/politicas/tetragon-agentes-sin-exec.yaml` y
`herramientas/probar_tetragon.sh`). Resultó ser neutral al dominio por suerte:
no menciona AML ni triage por ningún lado.

La ruta del intérprete (`/usr/local/bin/python3.13`) depende de la imagen. Si
la cambias:

```bash
kubectl -n agentes exec agente-demo -- readlink -f $(which python3)
```
