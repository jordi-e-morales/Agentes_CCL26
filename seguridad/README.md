# La capa de kernel: el SIGKILL

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
