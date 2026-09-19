# Proyecto: tutorial guiado de malla de agentes — Cisco Connect LATAM

Contexto permanente del proyecto. Léelo completo antes de proponer cambios.
Si algo aquí contradice lo que parece razonable, gana este archivo: las
decisiones ya se tomaron con motivo.

Documento de diseño completo (spec de la sesión):
https://claude.ai/artifact/GDx1dPcdCXQRVTYxp9Wfq5

---

## 1. Qué construimos

El soporte técnico de una sesión de 60 minutos en formato **tutorial guiado**.
No hay bloques de diapositivas separados de la demo: es una sola construcción
continua donde cada concepto se explica en una slide y acto seguido se muestra
funcionando.

**Audiencia:** arquitectos de IA e IT senior, **nuevos** en agentes, malla,
trazas distribuidas y seguridad cloud-native.

**North-star:** al salir, un arquitecto que hoy no conoce estos conceptos debe
poder imaginar —y confiar en— cómo funciona una malla de agentes real y cómo se
mantiene bajo control, porque vio cada pieza volverse real en vivo.

**Nada se despliega durante la sesión.** Todo está instalado y corriendo de
antemano; se muestra la parte relevante de cada pieza. El software tiene que
soportar ese modo: arrancar limpio, quedarse listo, y dejarse "enseñar" por
partes.

### Los tres insights que la sala debe recordar

1. **Un agente no es un modelo.** Dos agentes corren sobre los mismos pesos, en
   el mismo servidor. Lo que los hace distintos es prompt, identidad y permisos.
2. **En un sistema de agentes, la ejecución de código no está en el modelo,
   está en el ejecutor de herramientas.** Ahí es donde tiene que vivir el
   control.
3. **El ataque no rompe el perímetro, abusa de una arista que tú autorizaste.**
   Por eso la política tiene que ser sobre la intención del mensaje (capa 7), no
   solo sobre el par origen-destino (capa 4).

---

## 2. El arco: cada segmento termina con la pregunta que el siguiente responde

| Segmento | Capa del stack que resalta | Termina con |
|---|---|---|
| 1. Un agente no es un modelo | Cómputo acelerado | ¿Cómo se encuentran? |
| 2. Se descubren y se rutean | AGNTCY | ¿Cómo se hablan? |
| 3. La malla SLIM | AGNTCY + Kubernetes | ¿De dónde sacan los datos? |
| 4. Herramientas | Kubernetes | ¿Cómo sé qué pasó? |
| 5. Observabilidad | Splunk | ¿Y si alguien abusa de esto? |
| 6. Control | Seguridad | Cierre |

Esto no es adorno narrativo: define **qué tiene que ser mostrable por separado**.
Cada segmento necesita poder enseñarse solo, sin depender de que el anterior se
haya ejecutado en esa misma corrida.

---

## 3. Arquitectura

```
Tarea → Router por tarea → (consulta) Agent Directory (OASF)
                         → Agente A  <--SLIM-->  Agente B
                              ↓                      ↓
                          Tools (evidencia y acción)
                              ↓
                    OTLP → OTel Collector → Splunk APM

Gobernado por: Cilium (L7), Tetragon (kernel), AI Defense (contenido)
Observado también por: Hubble (segunda fuente independiente)
```

- **Router por tarea:** clasifica, consulta el Directory y despacha al agente
  adecuado.
- **Agent Directory (OASF):** registros de capacidades; es la fuente del ruteo.
- **Agentes** sobre vLLM en el L40S de dCloud.
- **SLIM:** el bus de mensajes de AGNTCY entre agentes. Reemplaza cualquier
  transporte HTTP casero. Debe existir al menos un **salto lateral** agente a
  agente sin pasar por el centro: sin eso la malla es una estrella.
- **Tools:** servicios invocados por function-calling.
- **OTel Collector → Splunk:** trazas distribuidas de agentes y tools.

---

## 4. Herramientas y la acción peligrosa

Las tools no son un extra: son la superficie donde aterriza la seguridad.

| Tool | Tipo | Para qué |
|---|---|---|
| `consulta_historial` | evidencia | alimenta el debate con datos |
| `lista_sancionados` | evidencia | idem |
| `perfil_sujeto` | evidencia | idem |
| `dispone_caso` | **acción peligrosa** | lo que el ataque intenta abusar |
| `exporta_evidencia` | **ejecuta un binario** | genera un PDF invocando un proceso |

`exporta_evidencia` existe por una razón concreta: si el agente ejecutara un
binario "porque sí", el SIGKILL parecería montado. Con ella, el ataque tiene una
vía estructural y creíble.

**Regla de diseño:** las tools de evidencia deben explicarse solas en tres
segundos, sin que nadie sepa del dominio. Nombres claros, salidas legibles.

### Consecuencia para la política

- *Qué agente puede llamar qué tool* = política L7 de Cilium sobre las rutas.
- *Qué binario puede ejecutar el ejecutor* = TracingPolicy de Tetragon con
  `matchActions: Sigkill`.

---

## 5. Observabilidad

- OTel SDK en los agentes. **Un span por mensaje SLIM y un span por tool call**,
  con `trace_id` propagado por toda la malla.
- Cada span lleva `tokens.prompt`, `tokens.completion` y `model`. Así la
  atribución de costos es una dimensión de la traza, no un contador con precios
  inventados. El abstract de la sesión promete atribución de costos: esto es lo
  que la cumple.
- Camino: agentes → OTLP → OpenTelemetry Collector → exportador de Splunk.

**Hubble es una segunda fuente obligatoria.** OTel es la autodeclaración de la
aplicación: si el agente comprometido intenta una conexión fuera del pipeline,
no va a emitir un span sobre ella. Sin Hubble no se puede mostrar una ausencia.
El segmento 6 necesita ambas fuentes visibles.

---

## 6. Seguridad

| Capa | Producto | Qué hace en el demo |
|---|---|---|
| Contenido | Cisco AI Defense | detecta la inyección y la bloquea |
| Red | Isovalent Enterprise Platform (Cilium) | 403 sobre arista autorizada con petición no autorizada |
| Kernel | Isovalent Enterprise Runtime Security (Tetragon) | SIGKILL al binario no autorizado |

**Orden del segmento 6:** AI Defense entra ganando (detecta y bloquea primero,
con su mapeo a OWASP LLM01 y MITRE ATLAS). Solo después la versión ofuscada
pasa, y entran red y kernel. El mensaje es "ninguna capa sola basta, ni siquiera
una buena", no "el guardrail tiene un hueco".

**Capa de traducción:** AI Defense todavía no detiene ataques en español, así
que el flujo traduce el prompt al inglés antes del análisis. Es un workaround
temporal (la versión en español está por liberarse) y en la sesión se menciona
en una frase. **No construir narrativa sobre esto.** Nota técnica: el traductor
procesa entrada no confiable, así que pertenece a la matriz de permisos como
cualquier otro componente.

### Reglas de honestidad, no negociables

- **Cilium NO inspecciona prompts.** Hace política L7 sobre método y ruta. La
  detección de inyección es análisis de contenido y es otra capa. Nunca
  mezclarlas.
- Lo sustituido se etiqueta en pantalla como sustituto.
- No afirmar que algo está verificado si no lo está.
- No inventar nombres de producto ni capacidades de Cisco.
- Datos sintéticos, etiquetados como tales, con nombres claramente ficticios.

---

## 7. El caso de uso es decorado

Triage de alertas de monitoreo transaccional (AML). Se explica en 30 segundos y
no se vuelve a tocar. Nada de marco regulatorio, tipologías ni umbrales: la
audiencia no es bancaria.

**El esquema debe ser neutral al dominio.** Habrá casos de reserva de triage de
alertas de SOC que usan el mismo esquema y los mismos agentes **sin cambios de
código**. Nunca uses vocabulario de AML en nombres de campos, clases o rutas
(nada de `cliente`, `monto`, `cuenta_origen`). Usa alerta, sujeto y evidencia.

El campo `source_trust` marca qué partes del contexto las escribió alguien de
fuera. La inyección vive siempre en un texto libre con `source_trust: external`,
y en la UI ese contenido se renderiza distinto.

---

## 8. Entorno

**Sin código de simulación.** Toda la inferencia y todos los eventos de
seguridad son reales. Si algo no se puede probar de verdad, se deja pendiente,
no se finge.

- **Desarrollo local:** Windows con VM Ubuntu 24.04 vía Multipass (WSL2 no
  sirve: su kernel no siempre expone BTF y Tetragon lo necesita). Dentro: kind
  con Cilium (sin CNI por defecto, sin kube-proxy), Tetragon, y Ollama con un
  modelo pequeño para desarrollar sin GPU.
- **dCloud:** un L40S de 48 GB, **solo por reservas cortas**. Restricción de
  diseño: todo lo que pueda desarrollarse sin GPU debe desarrollarse sin GPU.
  Las ventanas de dCloud se reservan para vLLM y para lo que solo existe ahí.
- `lab/bootstrap.sh` es el artefacto portable. La VM es desechable. Todo cambio
  de entorno se escribe ahí, nunca solo se teclea.

---

## 9. Fases de construcción

| Fase | Entregable que corre | Depende de |
|---|---|---|
| A | Malla mínima: router y dos agentes hablando por SLIM | vLLM listo |
| B | Agent Directory (OASF) y ruteo por capacidad | A |
| C | Tools, incluidas la acción peligrosa y la que ejecuta un binario | A |
| D | OTel a Splunk con tokens como atributo del span | A, C |
| E | Cilium L7 y Tetragon sobre agentes y tools | C |
| F | AI Defense con la capa de traducción, más pulido de narración | D, E |
| G | Presets del stand y subtítulos | F |

Cada fase deja algo demostrable. No saltar fases.

### El mínimo viable, decidido de antemano

Si dCloud se complica o SLIM resulta inmaduro, sobreviven los segmentos 1, 3, 4
y 6 (agente ≠ modelo, malla, herramientas, control). Directorio, ruteo y trazas
son amplificadores.

---

## 10. Modo stand

Mismo material, otro modo de reproducirlo. Un botón por preset que dispara la
secuencia con avance automático y subtítulos.

| Preset | Qué corre |
|---|---|
| Atracción | bucle de ~50s con el 403 y el SIGKILL, sin audio |
| Guiado corto | solo el segmento 6, ~3 min |
| Profundo | los seis segmentos, ~12 min |

Requisitos propios: reinicio en menos de 10 segundos entre visitantes; **el pod
tiene que volver después del SIGKILL** y quedar listo antes del siguiente;
subtítulos que expliquen cada paso sin narrador (un colega opera el stand);
tipografía legible a 4 metros; casos de SOC cargables sin cambiar código.

---

## 11. Cómo trabajar en este repo

- El usuario sabe poco de Kubernetes y está aprendiendo en el proceso.
  **Explica qué haces y por qué, en español, con comentarios en el código.**
  No entregues código sin contexto.
- Cambios pequeños y verificables sobre refactors grandes. Antes de cambiar algo
  existente, explica qué hace hoy.
- Antes de agregar dependencias, pregunta.
- Commits pequeños y frecuentes, en español, describiendo qué funciona ahora que
  antes no.
- Todo lo que haya que instalar en el entorno va a `lab/bootstrap.sh`.

### No objetivos

- No hay modo simulación.
- El repo anterior (`triage-multiagente`) se queda intacto como demo v1 y no se
  toca desde aquí.
- Las diapositivas se arman aparte.

---

## 12. Decisiones abiertas

- **SLIM:** qué runtime de AGNTCY y su madurez. Confirmar antes de la Fase A: es
  la dependencia más pesada del plan.
- **Modelo chico:** con la atribución de tokens, dos tiers vuelven a tener
  sentido. Sin ella, el ruteo por capacidad hacia el agente correcto basta.
- **Splunk:** Observability Cloud (mejor UI, requiere internet) contra
  Enterprise self-host (offline, UI de trazas más pobre).
- **El traductor:** ¿agente con Agent Card propia en el Directory, o sidecar del
  guardrail?
