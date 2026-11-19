import { useState, useRef, useEffect } from "react";
import "./estilo/cisco.css";

/* La deliberacion, dibujada segun ocurre.
 *
 * REGLA QUE MANDA EN ESTE ARCHIVO (CLAUDE.md, reglas de interfaz):
 * cada cosa en pantalla tiene que poder explicarse en UNA FRASE. Por eso cada
 * paso lleva su explicacion escrita al lado en vez de confiar en que quien
 * presenta se acuerde.
 *
 * Y todo lo que se ve viene de la malla de verdad: los sobres A2A son los que
 * viajaron, y los resultados de las herramientas son las filas de Postgres.
 * Aqui no se fabrica nada.
 */

type Evento =
  | { tipo: "paso"; n: number; nombre: string; explicacion: string }
  | { tipo: "agente"; clave: string; url: string; peticion: string;
      tarjeta?: any; vivo: boolean; error?: string }
  | { tipo: "eleccion"; agente: string; skill: string; tags: string[] }
  | { tipo: "sobre"; de: string; a: string; cuerpo: any }
  | { tipo: "esperando"; agente: string; explicacion: string }
  | { tipo: "herramienta"; agente: string; nombre: string; args: any;
      resultado?: string; endpoint?: string; metodo?: string }
  | { tipo: "salto"; de: string; a: string; sobre: any }
  | { tipo: "argumento"; agente: string; texto: string; ronda?: number }
  | { tipo: "sintesis"; texto: string }
  | { tipo: "sin_herramientas"; agente: string }
  | { tipo: "consumo"; agente: string; tokens: Record<string, number> }
  | { tipo: "error"; mensaje: string }
  | { tipo: "fin" };

const CASOS = [
  { id: "ALR-FICTICIA-0001", sujeto: "SUJ-0001", etiqueta: "Monitoreo transaccional" },
  { id: "ALR-FICTICIA-0002", sujeto: "SUJ-0002", etiqueta: "Alertas de SOC" },
  // El tercero trae la inyeccion, en un fragmento con source_trust=external.
  // Se marca en rojo porque no es un caso mas: es el del segmento 6.
  { id: "ALR-FICTICIA-0003", sujeto: "SUJ-0003", etiqueta: "Con texto externo",
    peligroso: true },
];

/* LOS SEIS SEGMENTOS DE LA SESION.
 *
 * POR QUE LA INTERFAZ SE NAVEGA ASI Y NO POR LA CORRIDA
 * -----------------------------------------------------
 * Hasta el 2026-09-23 esta pantalla contaba UNA DELIBERACION, de arriba abajo.
 * Eso esta bien para leerla y mal para presentarla: quien narra necesita contar
 * UNA SESION, que tiene seis partes y se cuentan en orden pero se enseñan
 * sueltas.
 *
 * El §2 del CLAUDE.md lo pide explicitamente: "cada segmento necesita poder
 * enseñarse solo, sin depender de que el anterior se haya ejecutado en esa
 * misma corrida". Con una sola columna lineal eso obligaba a buscar con scroll
 * en medio de la charla.
 *
 * `ve` dice que eventos de la deliberacion pertenecen a cada segmento. Filtrar
 * no es solo comodidad: el segmento 4 enseñando SOLO las llamadas a
 * herramientas es mucho mas claro que el mismo dato perdido en la cronologia.
 */
const SEGMENTOS = [
  {
    n: 1, titulo: "Un agente no es un modelo",
    // `cierra` no se pinta: es el guion del arco (§2), aqui por referencia.
    cierra: "¿Cómo se encuentran?",
    ve: [] as string[],
  },
  {
    n: 2, titulo: "Se descubren",
    cierra: "¿Cómo se hablan?",
    ve: ["agente", "eleccion"],
  },
  {
    n: 3, titulo: "Se hablan",
    cierra: "¿De dónde sacan los datos?",
    // Incluye `agente` y `eleccion` aunque el 2 tambien los tenga, y no es
    // duplicado por descuido: el 3 cuenta la secuencia ENTERA -descubrir,
    // elegir, despachar, hablarse- y sin los dos primeros los pasos 1 y 2
    // aparecian como titulos vacios. El 2 es el primer plano; el 3, la pelicula.
    ve: ["agente", "eleccion", "paso", "sobre", "salto", "argumento",
         "esperando", "sintesis", "error"],
  },
  {
    n: 4, titulo: "Herramientas por MCP",
    cierra: "¿Cómo sé qué pasó?",
    ve: ["herramienta", "sin_herramientas"],
  },
  {
    n: 5, titulo: "Observabilidad",
    cierra: "¿Y si alguien abusa de esto?",
    ve: ["consumo"],
  },
  {
    n: 6, titulo: "Seguridad y Control",
    cierra: "Cierre",
    ve: [],
  },
];

export default function App() {
  const [eventos, setEventos] = useState<Evento[]>([]);
  const [corriendo, setCorriendo] = useState(false);
  const [caso, setCaso] = useState(CASOS[0]);
  const [hora, setHora] = useState<string | null>(null);
  // Sube en cada arranque. El panel del kernel lo usa para saber que muertes
  // ya existian antes y no mezclarlas con las de ahora.
  const [corridaId, setCorridaId] = useState(0);
  // 0 = "Todo", la vista lineal de siempre. Se conserva como red de seguridad:
  // si en vivo algo no aparece donde deberia, ahi esta la corrida entera.
  const [segmento, setSegmento] = useState(1);
  const fuente = useRef<EventSource | null>(null);

  function arrancar(c: typeof CASOS[0]) {
    fuente.current?.close();
    setCaso(c);
    setEventos([]);
    // En vivo, confundir un resultado de hace media hora con el de ahora es de
    // los errores mas incomodos que hay. La pantalla ya se vacia al arrancar;
    // la hora deja claro ademas CUANDO fue lo que se esta viendo.
    setHora(new Date().toLocaleTimeString("es"));
    setCorridaId((n) => n + 1);
    setCorriendo(true);
    // Si estas en un segmento que no mira la deliberacion, arrancarla y no ver
    // nada parece que fallo. Se salta al 3, que es donde empieza a pasar.
    if (segmento === 1 || segmento === 6) setSegmento(3);
    const es = new EventSource(`/api/deliberar?alerta=${c.id}&sujeto=${c.sujeto}`);
    fuente.current = es;
    es.onmessage = (m) => {
      const ev: Evento = JSON.parse(m.data);
      setEventos((prev) => [...prev, ev]);
      if (ev.tipo === "fin" || ev.tipo === "error") {
        es.close();
        setCorriendo(false);
      }
    };
    es.onerror = () => { es.close(); setCorriendo(false); };
  }

  return (
    <>
      <header className="cabecera">
        <h1>Demo Multi-Agentes en Secure AI Factory de Cisco</h1>
        <span className="sub">Triage de alertas · datos sintéticos</span>
      </header>

      <div className="columnas">
        {/* EL RAIL: la sesion, no la corrida.
            Se queda fijo. Quien presenta tiene que poder saltar al segmento 6
            sin buscar, y volver al 1 si alguien pregunta algo de atras. */}
        <nav className="rail">
          {SEGMENTOS.map((sg) => (
            <button
              key={sg.n}
              onClick={() => setSegmento(sg.n)}
              className={segmento === sg.n ? "rail-activo" : ""}
            >
              <span className="rail-n">{sg.n}</span>
              <span className="rail-t">{sg.titulo}</span>
            </button>
          ))}
          <button
            onClick={() => setSegmento(0)}
            className={segmento === 0 ? "rail-activo" : ""}
            style={{ marginTop: 10, opacity: 0.75 }}
          >
            <span className="rail-n">·</span>
            <span className="rail-t">Todo</span>
          </button>
        </nav>

        <main>
        {/* Arrancar una deliberacion se puede desde cualquier segmento. En vivo
            hace falta poder relanzar sin navegar a otro sitio primero. */}
        <div style={{ display: "flex", gap: 12, alignItems: "center", marginBottom: 8 }}>
          {CASOS.map((c) => (
            <button
              key={c.id}
              onClick={() => arrancar(c)}
              disabled={corriendo}
              style={{
                background: caso.id === c.id
                  ? ((c as any).peligroso ? "var(--bloqueo)" : "var(--cisco-cian)")
                  : "var(--panel-alto)",
                color: caso.id === c.id
                  ? ((c as any).peligroso ? "#fff" : "var(--cisco-marino)")
                  : "var(--texto)",
                border: `1px solid ${(c as any).peligroso ? "var(--bloqueo)" : "var(--borde)"}`,
                borderRadius: "var(--radio)",
                padding: "12px 20px",
                fontSize: "var(--texto-base)",
                fontWeight: 600,
                fontFamily: "var(--fuente)",
                cursor: corriendo ? "wait" : "pointer",
              }}
            >
              {c.etiqueta}
            </button>
          ))}
          {corriendo && <span className="suave">deliberando…</span>}
          {hora && !corriendo && (
            <span className="tenue" style={{ fontSize: 13 }}>corrida de las {hora}</span>
          )}
        </div>

        {/* EL TITULO DEL SEGMENTO, y nada mas.
            Aqui estuvo la pregunta con la que cierra cada segmento, y se quito:
            eso es guion del presentador, no contenido para la sala. Lo que se
            proyecta es lo que el publico necesita ver. */}
        {segmento > 0 && (() => {
          const sg = SEGMENTOS.find((x) => x.n === segmento)!;
          return (
            <h2 style={{ margin: "18px 0 14px", fontSize: 22 }}>
              <span className="tenue" style={{ marginRight: 10 }}>{sg.n}</span>
              {sg.titulo}
            </h2>
          );
        })()}

        {/* Segmento 1: no necesita corrida.
            LA GPU SE QUEDA EN EL LATERAL, y no es por espacio. El segmento
            defiende que los dos agentes son el mismo modelo en el mismo
            hardware, y que lo unico que los separa es el prompt. Con el
            hardware a la derecha, fijo, y las dos identidades a la izquierda,
            la pantalla dice eso sola antes de que nadie lo explique. */}
        {segmento === 1 && (
          <>
            {/* EL MODELO PRIMERO, LOS AGENTES DEBAJO. El orden es el argumento:
                una cosa arriba, tres debajo, y las tres salen de la de arriba. */}
            <Modelo />
            <Prompts />
          </>
        )}

        {/* Segmento 6: tampoco necesita corrida, y ese es el punto. */}
        {segmento === 6 && (
          <>
            {/* El agente nuevo va PRIMERO: es lo unico del segmento que se
                opera en vivo. Los dos paneles de abajo son observacion. */}
            <Redactor />
            <Kernel activo={corriendo} corridaId={corridaId} />
            <Red activo={corriendo} corridaId={corridaId} />
          </>
        )}

        {/* Los segmentos 2 a 5 se alimentan de la deliberacion. Cada uno ve
            solo sus eventos: el 4 enseñando UNICAMENTE las herramientas es mas
            claro que el mismo dato perdido en la cronologia completa. */}
        {(segmento === 0 || (segmento >= 2 && segmento <= 5)) && (() => {
          const sg = SEGMENTOS.find((x) => x.n === segmento);
          const visibles = segmento === 0
            ? eventos
            : eventos.filter((e) => sg!.ve.includes(e.tipo));

          if (eventos.length === 0 && !corriendo) {
            return (
              <div className="panel" style={{ marginTop: 12 }}>
                <p style={{ margin: 0 }} className="suave">
                  Elige un caso arriba para ver la deliberación.
                </p>
              </div>
            );
          }
          if (visibles.length === 0) {
            return (
              <div className="panel" style={{ marginTop: 12 }}>
                <p style={{ margin: 0 }} className="suave">
                  {corriendo
                    ? "Todavía no ha pasado nada de este segmento en esta corrida."
                    : "Esta corrida no produjo nada de este segmento."}
                </p>
              </div>
            );
          }
          return (
            <>
              {visibles.map((ev, i) => <Fila key={i} ev={ev} />)}
              {/* La cascada es del 5: es la traza de la corrida entera. */}
              {(segmento === 5 || segmento === 0) &&
                eventos.some((e) => e.tipo === "fin") &&
                <Cascada corridaId={corridaId} />}
            </>
          );
        })()}
        </main>

        {/* El lateral se queda con lo que es CONTEXTO en todo momento. Lo que
            pertenece a un segmento concreto se mudo a su segmento. */}
        <aside className="lateral">
          {/* La GPU esta SIEMPRE. Es el contexto que sostiene toda la sesion:
              todo lo que pasa a la izquierda corre en ese aparato. */}
          <GPU activo={corriendo} />
          {segmento === 0 && <Prompts />}
          {segmento === 0 && <Kernel activo={corriendo} corridaId={corridaId} />}
          {segmento === 0 && <Red activo={corriendo} corridaId={corridaId} />}
        </aside>
      </div>
    </>
  );
}

/* La tarjeta de un agente.
 *
 * Se dibuja con tipografia de terminal a proposito. Descubrir un agente es
 * literalmente un GET a una ruta conocida, y enseñar el comando quita la
 * magia: la sala ve que no hay nada escondido, solo un archivo servido en un
 * sitio acordado.
 *
 * Debajo, la tarjeta CRUDA. Es lo que de verdad viaja; el resumen de arriba es
 * una comodidad, no la fuente.
 */
/* La (i) de informacion.
 *
 * Aqui va lo SECUNDARIO. La explicacion de una frase de cada paso se queda
 * siempre visible -regla de interfaz numero 1-, porque quien presenta no
 * deberia depender de acordarse. Esto es para el contexto que enriquece pero
 * no hace falta para seguir el hilo.
 */
function Info({ children }: { children: React.ReactNode }) {
  return (
    <span className="info">i<span className="nota">{children}</span></span>
  );
}

function Tarjeta({ ev }: { ev: Extract<Evento, { tipo: "agente" }> }) {
  const [cruda, setCruda] = useState(false);

  return (
    <div className="panel" style={{ marginTop: 10 }}>
      <div className="mono tenue" style={{ fontSize: "var(--texto-chico)" }}>
        $ curl {ev.url}
      </div>

      {!ev.vivo ? (
        <div style={{ marginTop: 10 }}>
          <strong>{ev.clave}</strong> <span className="chip bloqueo">no responde</span>
        </div>
      ) : (
        <>
          <pre className="sobre mono" style={{ marginTop: 10 }}>
{`nombre     : ${ev.tarjeta.name}
sabe hacer : ${ev.tarjeta.skills?.[0]?.name ?? "-"}
tags       : ${(ev.tarjeta.skills?.[0]?.tags ?? []).join(", ")}
ruta       : ${ev.tarjeta.supportedInterfaces?.[0]?.url ?? "-"}`}
          </pre>

          <button
            onClick={() => setCruda(!cruda)}
            style={{
              marginTop: 10, background: "transparent",
              border: "1px solid var(--borde)", borderRadius: 6,
              color: "var(--cisco-cian)", padding: "4px 12px",
              fontSize: 13, fontFamily: "var(--fuente)", cursor: "pointer",
            }}
          >
            {cruda ? "ocultar" : "ver la tarjeta cruda"}
          </button>
          {cruda && <pre className="sobre">{JSON.stringify(ev.tarjeta, null, 2)}</pre>}
        </>
      )}
    </div>
  );
}

/* Una llamada a herramienta por MCP.
 *
 * Mismo tratamiento que la tarjeta del agente: el destino y el metodo arriba en
 * monoespaciada, y la respuesta CRUDA desplegable.
 *
 * La respuesta importa tanto como la pregunta. Si solo se viera lo que se pidio,
 * no habria forma de saber si la evidencia existe o si el modelo la relleno. No
 * es teorico: paso dos veces, y las dos los agentes razonaron con elegancia
 * sobre datos vacios sin que nada pareciera roto.
 */
function Herramienta({ ev }: { ev: Extract<Evento, { tipo: "herramienta" }> }) {
  const [cruda, setCruda] = useState(false);

  /* El `resumen` que devuelve cada herramienta, en español.
   *
   * Existe por la regla del CLAUDE.md §4: las tools de evidencia tienen que
   * explicarse solas en tres segundos. La interfaz no lo usaba, y eso causo
   * una confusion real: ver `listas: []` en crudo parece que la herramienta
   * fallo, cuando lo que dice es "este sujeto no esta en ninguna lista".
   *
   * Un resultado VACIO y un resultado ROTO se ven igual en JSON crudo. Aqui
   * no: el resumen dice lo que paso, y el crudo queda detras del boton para
   * quien quiera comprobarlo. */
  let resumen: string | null = null;
  let fragmentos: any[] = [];
  try {
    const d = ev.resultado ? JSON.parse(ev.resultado) : null;
    resumen = d?.resumen ?? null;
    fragmentos = d?.fragmentos ?? [];
  } catch { resumen = null; }
  return (
    <div className="panel" style={{ marginTop: 10 }}>
      {/* Si falta el endpoint, se DICE. Antes simplemente no se dibujaba nada,
          y una ausencia silenciosa es indistinguible de "aqui no habia nada
          que enseñar". La causa casi siempre es la misma: los agentes corriendo
          codigo anterior al ultimo git pull. */}
      {ev.endpoint ? (
        <div className="mono tenue" style={{ fontSize: "var(--texto-chico)" }}>
          $ POST {ev.endpoint}  ·  {ev.metodo}
        </div>
      ) : (
        <div className="mono" style={{ fontSize: 13, color: "var(--aviso)" }}>
          el agente no reportó el destino — ¿reiniciaste sus terminales tras el
          último <code>git pull</code>?
        </div>
      )}
      <div className="mono" style={{ marginTop: 6 }}>
        <span className="chip">{ev.agente}</span>{" "}
        <span style={{ color: "var(--cisco-cian)" }}>{ev.nombre}</span>
        <span className="tenue">({JSON.stringify(ev.args)})</span>
      </div>
      {resumen && (
        <div style={{ marginTop: 8 }}>
          <span className="tenue" style={{ fontSize: 13 }}>devolvió:</span>{" "}
          <strong>{resumen}</strong>
        </div>
      )}

      {/* Los textos del caso, con su procedencia a la vista.
       *
       * El CLAUDE.md §7 lo exige: el contenido `external` se renderiza
       * distinto. La razon es narrativa y hay que tenerla clara — la sala
       * tiene que VER que el sistema sabia de donde venia ese texto, y que
       * aun asi el modelo le hizo caso. Si se viera igual que el resto,
       * pareceria un truco. */}
      {fragmentos.map((f) => (
        <div key={f.id} className={f.source_trust === "external" ? "externo" : "interno"}>
          <div style={{ fontSize: 13, marginBottom: 4 }}>
            <span className={f.source_trust === "external" ? "chip bloqueo" : "chip"}>
              {f.source_trust}
            </span>{" "}
            <span className="tenue">{f.etiqueta} · {f.autor}</span>
          </div>
          <div style={{ fontSize: "var(--texto-chico)" }}>{f.texto}</div>
          {f.source_trust === "external" && (
            <div style={{ fontSize: 13, marginTop: 6, color: "var(--bloqueo)" }}>
              Lo escribió alguien de fuera. El sistema lo sabe y lo dice.
            </div>
          )}
        </div>
      ))}
      {!ev.resultado && (
        <div className="mono" style={{ fontSize: 13, color: "var(--aviso)", marginTop: 8 }}>
          sin respuesta capturada — misma causa probable
        </div>
      )}
      {ev.resultado && (
        <>
          <button
            onClick={() => setCruda(!cruda)}
            style={{
              marginTop: 10, background: "transparent",
              border: "1px solid var(--borde)", borderRadius: 6,
              color: "var(--cisco-cian)", padding: "4px 12px",
              fontSize: 13, fontFamily: "var(--fuente)", cursor: "pointer",
            }}
          >
            {cruda ? "ocultar la respuesta" : "ver la respuesta cruda"}
          </button>
          {cruda && <pre className="sobre">{ev.resultado}</pre>}
        </>
      )}
    </div>
  );
}

/* El panel de la GPU.
 *
 * ESTO VALE MAS DE LO QUE PARECE. Mientras los dos agentes deliberan, en la
 * tabla se ve UN SOLO proceso de Python ocupando la tarjeta. No dos.
 *
 * Ahi esta el insight #1 sin tener que explicarlo: los agentes no son modelos.
 * Son dos prompts y dos identidades sobre los mismos pesos, en el mismo
 * proceso, en la misma GPU. Y lo dice una tabla que no dibujamos nosotros.
 */
/* Los prompts, en el lateral.
 *
 * Parecen campos de texto editables y NO lo son. Que lo parezcan es
 * deliberado: invita a preguntar "¿y si lo cambio?", que es exactamente la
 * pregunta que abre el insight #1.
 *
 * Se leen del codigo por la API, no de una copia escrita aqui. Si alguien
 * cambia un prompt y esta pantalla no lo refleja, estaria mintiendo sobre lo
 * unico que la sesion afirma que importa.
 */
function Prompts() {
  const [datos, setDatos] = useState<any[]>([]);
  const [abierto, setAbierto] = useState<string | null>(null);

  // EL CATCH VACIO ERA UNA TRAMPA.
  //
  // Antes esto era `.catch(() => {})`, asi que si el endpoint reventaba el panel
  // se quedaba en "cargando…" para siempre. Y "cargando…" eterno no distingue
  // "va lento" de "reventó": mandaba a esperar en vez de a mirar el error.
  const [fallo, setFallo] = useState<string | null>(null);
  useEffect(() => {
    fetch("/api/prompts")
      .then(async (r) => {
        if (!r.ok) throw new Error(`el backend respondió ${r.status}`);
        return r.json();
      })
      .then(setDatos)
      .catch((e) => setFallo(String(e.message || e)));
  }, []);

  return (
    <div className="panel" style={{ marginTop: 18 }}>
      <div style={{ fontWeight: 600 }}>
        Identidad de los Agentes
        <Info>
          Los tres corren sobre los mismos pesos, en la misma GPU, y salen de
          la misma imagen. No hay tres modelos. Lo que los separa cabe en su
          prompt y en lo que pueden tocar: el orquestador resume y no llega a
          ninguna herramienta; los otros dos llegan a las seis.
        </Info>
      </div>
      {fallo && (
        <p style={{
          fontSize: 13, color: "var(--aviso)", fontFamily: "var(--fuente-mono)",
          margin: "8px 0 0",
        }}>
          {fallo} — mira la terminal de ui/servidor.py
        </p>
      )}
      {!fallo && datos.length === 0 &&
        <p className="tenue" style={{ fontSize: 13 }}>cargando…</p>}
      {datos.map((d) => (
        <div key={d.rol} style={{ marginTop: 10 }}>
          <button
            onClick={() => setAbierto(abierto === d.rol ? null : d.rol)}
            style={{
              width: "100%", textAlign: "left", cursor: "pointer",
              background: abierto === d.rol ? "var(--panel-alto)" : "transparent",
              border: "1px solid var(--borde)", borderRadius: 6,
              color: "var(--texto)", padding: "8px 12px",
              fontSize: "var(--texto-chico)", fontFamily: "var(--fuente)",
            }}
          >
            {abierto === d.rol ? "▾" : "▸"} {d.rol}
          </button>
          {abierto === d.rol && (
            <>
              <textarea className="prompt" rows={9} value={d.prompt} readOnly
                        style={{ marginTop: 8 }} />
              <p className="tenue" style={{ fontSize: 12, margin: "4px 0 0" }}>
                solo lectura
              </p>

              {/* LAS HERRAMIENTAS A LAS QUE LLEGA.
                  Es la otra mitad de "que hace distinto a un agente": no solo
                  el prompt, tambien lo que puede tocar. El orquestador corre
                  sobre el mismo modelo y esta lista le sale vacia. */}
              <div style={{ marginTop: 10 }}>
                <div className="tenue" style={{ fontSize: 12, marginBottom: 4 }}>
                  herramientas a las que llega
                </div>

                {d.nota && (
                  <p className="suave" style={{
                    fontSize: "var(--texto-chico)", margin: "0 0 6px",
                    borderLeft: "3px solid var(--cisco-cian)", paddingLeft: 10,
                  }}>
                    {d.nota}
                  </p>
                )}

                {/* TRES ESTADOS, NO DOS. El tercero costo un rato:
                    si el backend es viejo no manda `herramientas` NI
                    `herramientas_fallo`, asi que el panel se quedaba mudo y
                    parecia que la funcion no existia. Un hueco en blanco es el
                    peor mensaje de error posible. */}
                {d.herramientas_fallo && (
                  <p className="tenue" style={{ fontSize: 12, margin: 0 }}>
                    {d.herramientas_fallo}
                  </p>
                )}
                {!d.herramientas && !d.herramientas_fallo && !d.nota && (
                  <p style={{
                    fontSize: 12, margin: 0, color: "var(--aviso)",
                    fontFamily: "var(--fuente-mono)",
                  }}>
                    el backend no mandó la lista — ¿reiniciaste ui/servidor.py?
                  </p>
                )}

                <div style={{ display: "flex", flexWrap: "wrap", gap: 5 }}>
                  {(d.herramientas ?? []).map((h: any) => (
                    <span
                      key={h.nombre}
                      title={h.descripcion}
                      style={{
                        fontFamily: "var(--fuente-mono)", fontSize: 12,
                        padding: "3px 8px", borderRadius: 5,
                        // Las dos que ACTUAN se marcan solas. Regla 3: la
                        // diferencia se resalta, no se deja buscar.
                        background: h.actua ? "#2A0F12" : "var(--fondo)",
                        border: `1px solid ${h.actua ? "var(--bloqueo)" : "var(--borde)"}`,
                        color: h.actua ? "var(--bloqueo)" : "var(--texto-suave)",
                        fontWeight: h.actua ? 700 : 400,
                      }}
                    >
                      {h.nombre}
                    </span>
                  ))}
                </div>

                {(d.herramientas ?? []).some((h: any) => h.actua) && (
                  <p className="tenue" style={{ fontSize: 12, margin: "8px 0 0" }}>
                    En rojo, las que <strong>actúan</strong>: una cierra el caso,
                    la otra ejecuta un proceso. La política de red no puede
                    concederle unas y negarle otras — las seis viajan por
                    el mismo <code>POST /mcp</code>.
                  </p>
                )}
              </div>
            </>
          )}
        </div>
      ))}
    </div>
  );
}

function GPU({ activo }: { activo: boolean }) {
  const [salida, setSalida] = useState("consultando…");
  const [cifras, setCifras] = useState<any>(null);

  useEffect(() => {
    let vivo = true;
    async function leer() {
      try {
        const r = await fetch("/api/gpu");
        const d = await r.json();
        if (vivo) { setSalida(d.salida); setCifras(d.cifras ?? null); }
      } catch {
        if (vivo) setSalida("no se pudo consultar la GPU");
      }
    }
    leer();
    // Mas rapido mientras se delibera: ahi es cuando la memoria se mueve y
    // cuando merece la pena estar mirando.
    const t = setInterval(leer, activo ? 1500 : 6000);
    return () => { vivo = false; clearInterval(t); };
  }, [activo]);

  return (
    <div className="panel" style={{ marginTop: 18 }}>
      <div style={{ fontWeight: 600 }}>
        La GPU, en vivo
        <Info>
          Mientras los dos agentes deliberan, aquí se ve <strong>un solo
          proceso</strong> de Python ocupando la tarjeta. No dos. Lo que los
          hace distintos no está en la GPU: está en su prompt y en su identidad.
          Y esta tabla no la dibujamos nosotros.
        </Info>
      </div>
      {/* Las cifras, en grande. La tabla cruda debajo es la prueba -nadie
          sospecha de nvidia-smi- pero proyectada obliga a buscar el dato entre
          marcos ascii. Lo importante se lee de lejos; lo que lo respalda, si
          alguien quiere, esta justo debajo. */}
      {cifras && (
        <div style={{ display: "flex", gap: 18, marginTop: 10, flexWrap: "wrap" }}>
          <Cifra valor={`${cifras.util}%`} etiqueta="utilización" />
          <Cifra valor={`${Math.round(cifras.usada / 1024)} GB`}
                 etiqueta={`de ${Math.round(cifras.total / 1024)} GB`} />
          <Cifra valor={cifras.procesos} etiqueta="proceso(s)"
                 resalta={cifras.procesos === 1} />
        </div>
      )}
      <pre className="sobre mono gpu-tabla">{salida}</pre>
    </div>
  );
}

function Cifra({ valor, etiqueta, resalta }: {
  valor: any; etiqueta: string; resalta?: boolean;
}) {
  return (
    <div>
      <div style={{
        fontSize: 26, fontWeight: 700, lineHeight: 1.1,
        color: resalta ? "var(--cisco-cian)" : "var(--texto)",
      }}>{valor}</div>
      <div className="tenue" style={{ fontSize: 12 }}>{etiqueta}</div>
    </div>
  );
}

/* Lo que vio el kernel, en vivo.
 *
 * El segmento 6 en la interfaz. Cada fila es un proceso que Tetragon mato
 * ANTES de que llegara a ejecutarse: quien lo intentaba, que quiso correr, y
 * que politica actuo.
 *
 * Esta en el lateral, junto a la GPU, porque igual que ella es contexto que
 * tiene sentido tener a la vista todo el rato y no solo en su momento.
 */
/* LA CASCADA. El segmento 5.
 *
 * Cada barra es un span: donde empezo y cuanto duro. La sangria es la jerarquia
 * -quien llamo a quien- y ahi se ve de un vistazo lo que costo explicar con
 * cuatro terminales: el salto lateral ocurre DENTRO de la conversacion del
 * investigador.
 *
 * Se dibuja desde el archivo del Collector, no desde Splunk. Asi no depende de
 * la red del recinto, que el §12 lista como riesgo. Splunk es la validacion
 * externa, no el unico sitio donde mirar.
 */
function Cascada({ corridaId }: { corridaId: number }) {
  const [datos, setDatos] = useState<any>(null);

  useEffect(() => {
    let vivo = true;
    async function leer() {
      try {
        const r = await fetch("/api/trazas");
        if (vivo) setDatos(await r.json());
      } catch { /* se queda como estaba */ }
    }
    // Un poco despues de terminar: el Collector agrupa antes de exportar.
    const t = setTimeout(leer, 3000);
    return () => { vivo = false; clearTimeout(t); };
  }, [corridaId]);

  if (!datos) return null;

  return (
    <div className="panel" style={{ marginTop: 20 }}>
      <div style={{ fontWeight: 600 }}>
        La cascada
        <Info>
          Cada barra es un span: dónde empezó y cuánto duró. La sangría es quién
          llamó a quién. El salto lateral aparece <strong>dentro</strong> de la
          conversación del investigador — el ping-pong de las cuatro terminales,
          en una imagen.
        </Info>
      </div>
      {!datos.hay && (
        <p className="tenue" style={{ fontSize: 13, margin: "6px 0 0" }}>
          {datos.motivo}
        </p>
      )}
      {datos.hay && (
        <>
          <p className="tenue mono" style={{ fontSize: 12, margin: "4px 0 12px" }}>
            trace {datos.trace} · {datos.total_ms} ms · {datos.spans.length} spans
          </p>
          {datos.spans.map((sp: any, i: number) => (
            <Barra key={i} sp={sp} spans={datos.spans} />
          ))}
        </>
      )}
    </div>
  );
}

function Barra({ sp, spans }: { sp: any; spans: any[] }) {
  // La profundidad sale de seguir la cadena de padres. Es lo que convierte una
  // lista plana de spans en un arbol legible.
  let nivel = 0, actual = sp;
  const porId = new Map(spans.map((x) => [x.id, x]));
  while (actual?.padre && porId.has(actual.padre) && nivel < 8) {
    actual = porId.get(actual.padre);
    nivel++;
  }
  const color = sp.operacion === "execute_tool" ? "var(--aviso)"
              : sp.operacion === "chat" ? "var(--cisco-cian)"
              : "var(--ok)";
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 3 }}>
      <div className="mono" style={{
        width: 300, paddingLeft: nivel * 16, fontSize: 12,
        whiteSpace: "nowrap", overflow: "hidden", textOverflow: "ellipsis",
      }}>
        <span style={{ color }}>{sp.herramienta ?? sp.nombre}</span>
      </div>
      <div style={{ flex: 1, position: "relative", height: 20,
                    background: "#05101F", borderRadius: 3 }}>
        <div style={{
          position: "absolute", left: `${sp.desde_pct}%`,
          width: `max(${sp.ancho_pct}%, 3px)`, top: 3, height: 14,
          background: color, borderRadius: 3,
        }} />
      </div>
      <div className="tenue mono" style={{ width: 92, fontSize: 12, textAlign: "right" }}>
        {sp.ms} ms
        {sp.salida ? <span style={{ color: "var(--texto-suave)" }}> · {sp.salida}t</span> : null}
      </div>
    </div>
  );
}

function Kernel({ activo, corridaId }: { activo: boolean; corridaId: number }) {
  const [datos, setDatos] = useState<any>(null);
  // Las muertes que YA existian cuando empezo esta corrida.
  //
  // El archivo de exportacion de Tetragon acumula desde que arranco, asi que
  // incluye las pruebas de la lista blanca y cualquier bloqueo anterior. Sin
  // esto, la demo empieza con SIGKILLs en pantalla y cuando llega el de verdad
  // no se distingue cual es.
  //
  // Se marcan por contenido y no por hora: los relojes del navegador y del
  // nodo no tienen por que coincidir, y una comparacion de fechas fallaria de
  // forma silenciosa.
  const previas = useRef<Set<string>>(new Set());
  const [verAnteriores, setVerAnteriores] = useState(false);

  const clave = (m: any) => `${m.hora}|${m.ejecutaba}|${m.quiso_correr}`;

  useEffect(() => {
    let vivo = true;
    async function leer() {
      try {
        const r = await fetch("/api/eventos-kernel");
        const d = await r.json();
        if (vivo) setDatos(d);
        return d;
      } catch { return null; }
    }
    // Al empezar una corrida, se apunta lo que ya habia.
    (async () => {
      const d = await leer();
      if (d?.muertes) previas.current = new Set(d.muertes.map(clave));
    })();
    const t = setInterval(leer, activo ? 2000 : 10000);
    return () => { vivo = false; clearInterval(t); };
  }, [activo, corridaId]);

  const todas = datos?.muertes ?? [];
  const deAhora = todas.filter((m: any) => !previas.current.has(clave(m)));
  const aPintar = verAnteriores ? todas : deAhora;
  const ocultas = todas.length - deAhora.length;

  return (
    <div className="panel" style={{ marginTop: 18 }}>
      <div style={{ fontWeight: 600 }}>
        Lo que vio el kernel
        <Info>
          Cada fila es un proceso que Tetragon mató <strong>antes</strong> de
          que llegara a ejecutarse. No adivina intenciones: aplica una regla
          sobre qué binarios puede lanzar el ejecutor de herramientas. Por eso
          no falla cuando el análisis de contenido sí falla.
        </Info>
      </div>
      {!datos?.hay && (
        <p className="tenue" style={{ fontSize: 13, margin: "6px 0 0" }}>
          {datos?.motivo ?? "consultando…"}
        </p>
      )}
      {datos?.hay && aPintar.length === 0 && (
        <p className="suave" style={{ fontSize: "var(--texto-chico)", margin: "6px 0 0" }}>
          Nada bloqueado en esta corrida.
        </p>
      )}
      {datos?.hay && ocultas > 0 && (
        <button
          onClick={() => setVerAnteriores(!verAnteriores)}
          style={{
            marginTop: 8, background: "transparent",
            border: "1px solid var(--borde)", borderRadius: 6,
            color: "var(--texto-suave)", padding: "3px 10px",
            fontSize: 12, fontFamily: "var(--fuente)", cursor: "pointer",
          }}
        >
          {verAnteriores ? "ocultar" : `${ocultas} de antes de esta corrida`}
        </button>
      )}
      {aPintar.map((m: any, i: number) => (
        <div key={i} style={{
          marginTop: 8, padding: "8px 10px", borderRadius: 6,
          background: "#2A0F12", border: "1px solid var(--bloqueo)",
          fontFamily: "var(--fuente-mono)", fontSize: 12,
        }}>
          <div style={{ color: "var(--bloqueo)", fontWeight: 700 }}>SIGKILL</div>
          <div className="suave">{m.ejecutaba}</div>
          <div>quiso correr: <strong>{m.quiso_correr}</strong></div>
          <div className="tenue">{m.politica}</div>
        </div>
      ))}
    </div>
  );
}

function Fila({ ev }: { ev: Evento }) {
  switch (ev.tipo) {
    case "paso":
      return (
        <div className="paso">
          <div className="n">{ev.n}</div>
          <div>
            <h2>{ev.nombre}</h2>
            <p className="explicacion">{ev.explicacion}</p>
          </div>
        </div>
      );

    case "agente":
      return <Tarjeta ev={ev} />;

    case "eleccion":
      return (
        <div className="panel" style={{ marginTop: 10, borderColor: "var(--cisco-cian)" }}>
          <span className="chip ok">elegido</span>{" "}
          <strong>{ev.agente}</strong>
          <div className="suave" style={{ fontSize: "var(--texto-chico)", marginTop: 4 }}>
            Declara «{ev.skill}», y sus tags incluyen lo que la tarea pedía.
          </div>
        </div>
      );

    case "sobre":
      return (
        <div style={{ marginTop: 10 }}>
          <div className="suave" style={{ fontSize: "var(--texto-chico)" }}>
            Sobre A2A · {ev.de} → {ev.a}
          </div>
          <pre className="sobre">{JSON.stringify(ev.cuerpo, null, 2)}</pre>
        </div>
      );

    case "esperando":
      return (
        <p className="suave" style={{ marginTop: 10 }}>
          Esperando a <strong>{ev.agente}</strong>. {ev.explicacion}
        </p>
      );

    case "herramienta":
      return <Herramienta ev={ev} />;

    case "salto":
      return (
        <div className="panel" style={{ marginTop: 10, borderColor: "var(--cisco-cian)" }}>
          <div style={{ fontWeight: 600, color: "var(--cisco-cian)" }}>
            {ev.de} → {ev.a}
          </div>
          <div className="suave" style={{ fontSize: "var(--texto-chico)" }}>
            Esta conversación la abrió el agente. El router no la creó, no la ve
            y no la reenvía.
          </div>
          {ev.sobre && <pre className="sobre">{JSON.stringify(ev.sobre, null, 2)}</pre>}
        </div>
      );

    case "argumento":
      return (
        <div className="panel" style={{ marginTop: 10, borderLeft: "3px solid var(--cisco-cian)" }}>
          <div style={{ fontWeight: 600, marginBottom: 6 }}>
            {ev.agente}
            {/* La ronda importa: con una sola, el defensor objeta y nadie le
                responde. Ver el numero deja claro que hay replica. */}
            {ev.ronda ? <span className="chip" style={{ marginLeft: 8 }}>
              ronda {ev.ronda}
            </span> : null}
          </div>
          <div>{ev.texto}</div>
        </div>
      );

    case "sin_herramientas":
      /* Opinar sin mirar evidencia no es un hueco de la interfaz: es un hecho
         del caso, y de los que la sala tiene que notar. */
      return (
        <div className="panel" style={{ marginTop: 10, borderColor: "var(--aviso)" }}>
          <span className="chip" style={{ color: "var(--aviso)", borderColor: "var(--aviso)" }}>
            {ev.agente}
          </span>{" "}
          <strong>no consultó ninguna herramienta</strong>
          <div className="suave" style={{ fontSize: "var(--texto-chico)", marginTop: 4 }}>
            Opinó sin recoger evidencia.
          </div>
        </div>
      );

    case "sintesis":
      /* El cierre del orquestador. Se destaca porque es lo que alguien leeria
         si solo tuviera diez segundos, y porque es la unica voz que no toma
         partido. */
      return (
        <div className="panel" style={{
          marginTop: 14, borderColor: "var(--cisco-cian)",
          borderLeft: "4px solid var(--cisco-cian)",
        }}>
          <div style={{ fontWeight: 600, marginBottom: 6 }}>
            orquestador
            <Info>
              No opina sobre el caso ni puede actuar sobre él: no tiene
              herramientas. Su único poder es resumir lo que los dos agentes
              sostuvieron. Quien decide es quien recogió la evidencia.
            </Info>
          </div>
          <div style={{ fontSize: "var(--texto-grande)", lineHeight: 1.5 }}>
            {ev.texto}
          </div>
        </div>
      );

    case "consumo":
      return (
        <p className="tenue" style={{ fontSize: "var(--texto-chico)", marginTop: 8 }}>
          {ev.agente} — {ev.tokens["tokens.prompt"]} tokens de entrada,{" "}
          {ev.tokens["tokens.completion"]} de salida
        </p>
      );

    case "error":
      return (
        <div className="panel" style={{ marginTop: 10, borderColor: "var(--bloqueo)" }}>
          <span className="chip bloqueo">error</span> {ev.mensaje}
        </div>
      );

    default:
      return null;
  }
}

/* Lo que vio la RED. La segunda fuente obligatoria del CLAUDE.md §5.
 *
 * POR QUE ESTE PANEL NO SOBRA AL LADO DE LA CASCADA
 * -------------------------------------------------
 * La cascada la escribe la aplicacion: es lo que los agentes DECLARAN haber
 * hecho. Esto lo escribe Hubble mirando los paquetes, sin preguntarle a nadie.
 * Dos cosas que solo se pueden enseñar aqui:
 *
 *   1. Una AUSENCIA. Si un agente intenta una conexion fuera del pipeline, no
 *      va a emitir un span confesandola. La red la registra igual.
 *   2. Que POST /mcp se repite IDENTICO para herramientas distintas. La
 *      aplicacion sabe que llamo a `dispone_caso`; la red vio la misma linea
 *      que cuando consulto el historial.
 *
 * Lo segundo es la lamina del segmento 6: la arista estaba autorizada y la
 * intencion no se veia. No hace falta adornarlo — la repeticion de POST /mcp
 * se ve porque esta repetida, y quien narra dice la frase. Un contador
 * "xN identicas" estuvo aqui y se quito: el numero dependia de cuantos flujos
 * cupieran en la ventana, asi que no significaba nada y obligaba a buscarle un
 * sentido. Regla 1 de la interfaz.
 */
function Red({ activo, corridaId }: { activo: boolean; corridaId: number }) {
  const [datos, setDatos] = useState<any>(null);

  useEffect(() => {
    let vivo = true;
    async function leer() {
      try {
        const r = await fetch("/api/hubble");
        const d = await r.json();
        if (vivo) setDatos(d);
      } catch { /* la red es contexto, no puede tumbar la demo */ }
    }
    leer();
    const t = setInterval(leer, activo ? 3000 : 12000);
    return () => { vivo = false; clearInterval(t); };
  }, [activo, corridaId]);

  const flujos: any[] = datos?.flujos ?? [];

  return (
    <div className="panel" style={{ marginTop: 18 }}>
      <div style={{ fontWeight: 600 }}>
        Lo que vio la red
        <Info>
          Esto lo escribe Hubble mirando los paquetes, no la aplicación
          contando lo que hizo. Por eso puede mostrar algo que la cascada
          nunca mostrará: un intento que <strong>ningún span declara</strong>.
          Y enseña el límite de la capa 7: varias herramientas distintas
          viajan todas como el mismo <code>POST /mcp</code>.
        </Info>
      </div>

      {!datos?.hay && (
        <p className="tenue" style={{ fontSize: 13, margin: "6px 0 0" }}>
          {datos?.motivo ?? "consultando…"}
        </p>
      )}

      {datos?.hay && flujos.length === 0 && (
        <p className="suave" style={{ fontSize: "var(--texto-chico)", margin: "6px 0 0" }}>
          Sin tráfico de capa 7 todavía.
        </p>
      )}

      {flujos.map((f, i) => {
        const bloqueado = f.veredicto === "DROPPED" || f.veredicto === "DENIED";
        return (
          <div key={i} style={{
            marginTop: 6, padding: "6px 9px", borderRadius: 6,
            fontFamily: "var(--fuente-mono)", fontSize: 12,
            background: bloqueado ? "#2A0F12" : "var(--fondo)",
            border: `1px solid ${bloqueado ? "var(--bloqueo)" : "var(--borde)"}`,
          }}>
            <div style={{ display: "flex", gap: 6, alignItems: "baseline", flexWrap: "wrap" }}>
              {bloqueado && (
                <span style={{ color: "var(--bloqueo)", fontWeight: 700 }}>
                  {f.veredicto}
                </span>
              )}
              <strong>{f.metodo}</strong>
              <span>{f.ruta}</span>
            </div>
            <div className="tenue">{f.de} → {f.a}</div>
          </div>
        );
      })}
    </div>
  );
}

/* EL MODELO. La mitad que le faltaba al segmento 1.
 *
 * El segmento afirma que un agente no es un modelo, y hasta el 2026-09-23
 * enseñaba los agentes y del modelo no decia nada: la afirmacion se quedaba en
 * palabra del presentador.
 *
 * Aqui esta el otro lado, y todo leido del proceso que esta corriendo: lo que
 * el motor dice de si mismo, los argumentos con los que arranco de verdad, y lo
 * que midio al cargar los pesos. Si alguien relanza vLLM con otra
 * cuantizacion, este panel lo dice sin que nadie toque la interfaz.
 */
function Modelo() {
  const [d, setD] = useState<any>(null);

  useEffect(() => {
    fetch("/api/modelo").then((r) => r.json()).then(setD)
      .catch((e) => setD({ hay: false, motivo: String(e) }));
  }, []);

  return (
    <div className="panel">
      <div style={{ fontWeight: 600 }}>
        El modelo
        <Info>
          Uno solo, en un servidor, con unos pesos cargados. Los tres agentes de
          abajo corren sobre esto. Nada de lo que se ve aquí está escrito en la
          interfaz: sale de preguntarle al motor y de mirar con qué argumentos
          arrancó.
        </Info>
      </div>

      {!d && <p className="tenue" style={{ fontSize: 13, margin: "6px 0 0" }}>consultando…</p>}
      {d && !d.hay && (
        <p className="tenue" style={{ fontSize: 13, margin: "6px 0 0" }}>
          {d.motivo ?? "no se pudo consultar el motor"}
        </p>
      )}

      {d?.hay && (
        <>
          {/* Lo que se lee a cuatro metros. */}
          <div style={{ display: "flex", gap: 18, marginTop: 10,
                        flexWrap: "wrap", alignItems: "baseline" }}>
            <div style={{
              fontFamily: "var(--fuente-mono)", fontSize: 20, fontWeight: 700,
              color: "var(--cisco-cian)",
            }}>
              {d.id}
            </div>
            {d.ventana && (
              <Cifra valor={(d.ventana / 1024).toFixed(0) + "k"}
                     etiqueta="ventana de contexto" />
            )}
          </div>

          {/* Los argumentos REALES. Esto es lo que nadie espera ver, y es lo
              que hace creible todo lo demas: no es un diagrama, es la linea de
              comandos del proceso que esta sirviendo las respuestas. */}
          {d.opciones?.length > 0 && (
            <div style={{ marginTop: 12 }}>
              <div className="tenue" style={{ fontSize: 12, marginBottom: 5 }}>
                cómo se desplegó · <code>docker inspect vllm</code>
              </div>
              <div style={{ display: "flex", flexWrap: "wrap", gap: 5 }}>
                {d.opciones.map((o: any) => (
                  <span key={o.flag} style={{
                    fontFamily: "var(--fuente-mono)", fontSize: 12,
                    padding: "3px 8px", borderRadius: 5,
                    background: "var(--fondo)",
                    border: "1px solid var(--borde)",
                    color: "var(--texto-suave)",
                  }}>
                    {o.flag}
                    {o.valor && (
                      <strong style={{ color: "var(--texto)" }}> {o.valor}</strong>
                    )}
                  </span>
                ))}
              </div>
            </div>
          )}

          {/* Lo que MIDIO al arrancar. Estas lineas explican por que no caben
              dos modelos en esta GPU, que es una pregunta que la sala hace. */}
          {d.medidas?.length > 0 && (
            <div style={{ marginTop: 12 }}>
              <div className="tenue" style={{ fontSize: 12, marginBottom: 5 }}>
                lo que midió al cargar · <code>docker logs vllm</code>
              </div>
              <pre className="sobre mono" style={{ fontSize: 11, marginTop: 0 }}>
{d.medidas.join("\n")}
              </pre>
            </div>
          )}
        </>
      )}
    </div>
  );
}

/* EL AGENTE NUEVO. El momento en vivo del segmento 6.
 *
 * "Queremos que un agente redacte el resumen del caso para el analista." Es la
 * peticion mas inocente que existe. El redactor solo necesita LEER la alerta, y
 * no puede — porque no lleva la etiqueta `rol: agente`, y el servidor de
 * herramientas solo acepta entrada de quien la lleva.
 *
 * Le pones la etiqueta, lee. Y de paso puede cerrar casos, porque las seis
 * herramientas viajan por la misma ruta y la red no sabe distinguirlas.
 *
 * Cada boton enseña el kubectl que ejecuta: regla 2, la interfaz hace visible
 * el mecanismo. Un boton que hace magia seria mas bonito y contrario al
 * proposito.
 */
function Redactor() {
  const [estado, setEstado] = useState<any>(null);
  const [salida, setSalida] = useState<any>(null);
  const [ocupado, setOcupado] = useState<string | null>(null);

  async function leerEstado() {
    try {
      const r = await fetch("/api/redactor?accion=estado");
      setEstado(await r.json());
    } catch { setEstado({ existe: false }); }
  }
  useEffect(() => { leerEstado(); }, []);

  async function accionar(accion: string, etiqueta: string) {
    setOcupado(etiqueta);
    setSalida(null);
    try {
      const r = await fetch(`/api/redactor?accion=${accion}`);
      const d = await r.json();
      setSalida(d);
      await leerEstado();
    } catch (e) {
      setSalida({ salida: String(e) });
    } finally {
      setOcupado(null);
    }
  }

  const boton = (accion: string, texto: string, destacado = false) => (
    <button
      onClick={() => accionar(accion, texto)}
      disabled={ocupado !== null || !estado?.existe}
      style={{
        background: destacado ? "var(--cisco-cian)" : "var(--panel-alto)",
        color: destacado ? "var(--cisco-marino)" : "var(--texto)",
        border: "1px solid var(--borde)", borderRadius: "var(--radio)",
        padding: "10px 16px", fontSize: "var(--texto-chico)", fontWeight: 600,
        fontFamily: "var(--fuente)",
        cursor: ocupado ? "wait" : "pointer",
        opacity: ocupado && ocupado !== texto ? 0.5 : 1,
      }}
    >
      {ocupado === texto ? "…" : texto}
    </button>
  );

  return (
    <div className="panel">
      <div style={{ fontWeight: 600 }}>
        Un agente nuevo entra a la malla
        <Info>
          El redactor sale de la <strong>misma imagen</strong> que los otros
          tres y sólo quiere leer la alerta para resumirla. Lo único que le
          falta es la etiqueta <code>rol: agente</code> — y el servidor de
          herramientas sólo acepta entrada de quien la lleva. La protección está
          en el recurso, no en quien llama.
        </Info>
      </div>

      {!estado && (
        <p className="tenue" style={{ fontSize: 13, margin: "6px 0 0" }}>consultando…</p>
      )}
      {estado && !estado.existe && (
        <p className="tenue" style={{ fontSize: 13, margin: "6px 0 0" }}>
          el redactor no está desplegado — <code>./malla/agentes-up.sh</code>
        </p>
      )}

      {estado?.existe && (
        <>
          {/* El estado actual, grande. Es lo que hay que mirar antes y despues
              de cada boton. */}
          <div style={{
            marginTop: 10, padding: "10px 14px", borderRadius: 6,
            background: estado.etiquetado ? "#10331A" : "var(--fondo)",
            border: `1px solid ${estado.etiquetado ? "var(--ok)" : "var(--borde)"}`,
            fontFamily: "var(--fuente-mono)", fontSize: 13,
          }}>
            {estado.pod}{"  "}
            <strong style={{ color: estado.etiquetado ? "var(--ok)" : "var(--texto-tenue)" }}>
              {estado.etiquetado ? "rol=agente" : "sin rol"}
            </strong>
          </div>

          <div style={{ display: "flex", gap: 10, marginTop: 12, flexWrap: "wrap" }}>
            {boton("intenta", "Intentar leer la alerta", true)}
            {estado.etiquetado
              ? boton("desetiqueta", "Quitarle la etiqueta")
              : boton("etiqueta", "Ponerle rol=agente")}
          </div>

          {salida && (
            <>
              {salida.comando && (
                <div className="tenue" style={{
                  fontSize: 12, marginTop: 12, fontFamily: "var(--fuente-mono)",
                }}>
                  $ {salida.comando}
                </div>
              )}
              <pre className="sobre mono" style={{
                fontSize: 12,
                borderLeftColor: salida.logro === false ? "var(--bloqueo)"
                               : salida.logro === true ? "var(--ok)"
                               : "var(--cisco-cian)",
              }}>{salida.salida || "(sin salida)"}</pre>
            </>
          )}

        </>
      )}
    </div>
  );
}
