# Agentes_CCL26

Soporte técnico de la sesión de Cisco Connect LATAM: un tutorial guiado de 60
minutos donde una malla de agentes se construye en vivo y se pone bajo control.

El plan completo está en [`CLAUDE.md`](CLAUDE.md). Léelo antes de cambiar nada.

| Carpeta | Qué hay |
|---|---|
| [`lab/`](lab/) | Instalación reproducible del entorno: herramientas, cluster, kernel, GPU |
| [`esquema/`](esquema/) | El contrato de datos del que cuelgan las tools y la interfaz |
| [`spike-slim/`](spike-slim/) | Experimento que decide si SLIM entra al proyecto. Incluye [una explicación de SLIM desde cero](spike-slim/COMO-FUNCIONA-SLIM.md) |

## Levantar todo en un host limpio

Esta es la receta completa, y **tiene que seguir siendo esta receta**. Si
migrar a una instancia nueva necesita algo que no esté aquí, el bootstrap está
incompleto y hay que arreglarlo ese mismo día.

```bash
git clone https://github.com/jordi-e-morales/Agentes_CCL26.git
```

```bash
cd Agentes_CCL26 && ./lab/bootstrap.sh
```

```bash
./lab/cluster-up.sh && ./lab/tetragon-up.sh && ./lab/vllm-up.sh
```

Requisitos del host: Ubuntu con kernel que exponga BTF (lo verifica el
bootstrap) y, para la inferencia, una GPU NVIDIA con sus drivers.

## Dónde va el proyecto

Las fases están en `CLAUDE.md` §9. Estado:

| Fase | Entregable | Estado |
|---|---|---|
| — | Entorno, esquema de datos | Hecho |
| A | Malla mínima: router y dos agentes por SLIM | **Bloqueada:** SLIM sin validar |
| B | Agent Directory (OASF) y ruteo por capacidad | Pendiente |
| C | Tools, incluidas la acción peligrosa y la que ejecuta un binario | Pendiente |
| D | OTel a Splunk con tokens como atributo del span | Pendiente |
| E | Cilium L7 y Tetragon sobre agentes y tools | Pendiente |
| F | AI Defense con la capa de traducción | Pendiente |
| G | Presets del stand y subtítulos | Pendiente |

**Lo siguiente es el spike de SLIM**, no la Fase A. Es la dependencia más
pesada del plan y hoy no hay ni una línea de código que la valide: lo único que
existía en el repo anterior era un bus "estilo SLIM" simulado, y la simulación
está prohibida. El spike tiene criterio de corte: si no hay ping-pong entre dos
agentes **más un salto lateral** que no pase por el router, SLIM baja de
columna vertebral a amplificador y el transporte sustituto se etiqueta como tal
en pantalla.

## Reglas que no se negocian

Están en `CLAUDE.md` §6 y §8, pero estas tres se rompen por descuido:

- **Sin código de simulación.** Toda la inferencia y todos los eventos de
  seguridad son reales. Si algo no se puede probar de verdad, queda pendiente.
- **Cilium no inspecciona prompts.** Hace política L7 sobre método y ruta. La
  detección de inyección es análisis de contenido y es otra capa.
- **Todo cambio de entorno va a `lab/bootstrap.sh`**, nunca solo se teclea.
