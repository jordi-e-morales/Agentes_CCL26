# El esquema

Este es el contrato del que cuelga todo lo demás: las cinco tools, la interfaz,
el punto donde aterriza la inyección y los casos de reserva de SOC.

Está primero en el repo a propósito. Es lo más barato de escribir hoy y lo más
caro de cambiar después: si se define en la Fase C, ya hay cinco tools escritas
contra la forma equivocada.

## La regla que lo explica todo

**El esquema es neutral al dominio.** No hay campos `cliente`, `monto` ni
`cuenta_origen`. Solo hay **alerta**, **sujeto** y **evidencia**.

El motivo es concreto y está en el `CLAUDE.md` §7: habrá casos de reserva de
triage de alertas de SOC que usan los mismos agentes **sin cambios de código**.
Si el esquema habla de dinero, cargar un caso de SOC obliga a tocar código, y
eso no se puede hacer entre dos sesiones de un stand.

Lo específico del dominio vive en `sujeto.atributos`, un mapa libre clave-valor
sobre el que **nada ramifica**. Ese es el escape hatch que mantiene neutral al
resto.

### La prueba de que funciona

En `ejemplos/` hay dos casos de dominios que no se parecen en nada:

| Archivo | Dominio | `sujeto.tipo` |
|---|---|---|
| `transaccional-0001.json` | Monitoreo transaccional | `organizacion` |
| `soc-0001.json` | Alertas de SOC | `host` |

Validan contra el mismo esquema, sin un campo opcional de por medio. Esa es la
prueba, y es reproducible:

```bash
.venv/bin/python esquema/valida.py
```

Si algún día un caso nuevo obliga a agregar un campo con nombre de dominio, el
esquema se rompió y hay que discutirlo, no parchearlo.

## `source_trust`: dónde vive el riesgo

Cada texto libre declara quién lo escribió:

| Valor | Qué significa |
|---|---|
| `internal` | Lo produjo un sistema nuestro |
| `external` | Lo escribió alguien de fuera: **entrada no confiable** |
| `unknown` | No se sabe, y se trata como `external` |

**La inyección del segmento 6 vive siempre en un fragmento `external`.** No hay
ningún caso donde llegue por otra vía, y eso es una invariante del proyecto, no
una casualidad del ejemplo. `ejemplos/transaccional-0003-inyectada.json` es el
caso que la lleva: el texto del reportante externo intenta que el agente cierre
la alerta sin recoger evidencia y que ejecute la exportación.

En la interfaz, un fragmento `external` se renderiza distinto. La razón es
narrativa y vale la pena tenerla clara al construir la UI: la sala tiene que
poder **ver** que el sistema sabía que ese texto venía de fuera, y aun así el
modelo le hizo caso. Eso es lo que hace convincente al segmento 6. Si el texto
malicioso se ve igual que el resto, parece un truco.

## Lo que el esquema deja ver de la seguridad

- `evidencia[]` se llena durante el triage, no viene en el caso. Cada entrada
  dice qué tool la produjo, y cada tool call es un span en la traza.
- `disposicion` es nula hasta que alguien decide. La escribe `dispone_caso`,
  que es **la acción peligrosa** del demo: es lo que el ataque intenta abusar.
- `disposicion.justificacion` es donde se ve el daño. Una alerta dispuesta con
  `evidencia` vacía es visiblemente un triage que no se sostiene, sin que nadie
  tenga que explicar por qué.

## Datos sintéticos

`sintetica` es `const: true`. No es decorativo: el `CLAUDE.md` §6 exige datos
sintéticos etiquetados como tales, y este campo permite que la interfaz lo
muestre sin depender de que alguien se acuerde. Todos los nombres son
claramente ficticios.
