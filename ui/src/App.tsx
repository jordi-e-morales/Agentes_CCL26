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
  | { tipo: "argumento"; agente: string; texto: string }
  | { tipo: "consumo"; agente: string; tokens: Record<string, number> }
  | { tipo: "error"; mensaje: string }
  | { tipo: "fin" };

const CASOS = [
  { id: "ALR-FICTICIA-0001", sujeto: "SUJ-0001", etiqueta: "Monitoreo transaccional" },
  { id: "ALR-FICTICIA-0002", sujeto: "SUJ-0002", etiqueta: "Alertas de SOC" },
];

export default function App() {
  const [eventos, setEventos] = useState<Evento[]>([]);
  const [corriendo, setCorriendo] = useState(false);
  const [caso, setCaso] = useState(CASOS[0]);
  const fuente = useRef<EventSource | null>(null);

  function arrancar(c: typeof CASOS[0]) {
    fuente.current?.close();
    setCaso(c);
    setEventos([]);
    setCorriendo(true);
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
        <main>
        {/* Los dos dominios, lado a lado. Es la prueba de neutralidad: el mismo
            codigo, los mismos agentes, dos mundos que no se parecen. */}
        <div style={{ display: "flex", gap: 12, alignItems: "center", marginBottom: 8 }}>
          {CASOS.map((c) => (
            <button
              key={c.id}
              onClick={() => arrancar(c)}
              disabled={corriendo}
              style={{
                background: caso.id === c.id ? "var(--cisco-cian)" : "var(--panel-alto)",
                color: caso.id === c.id ? "var(--cisco-marino)" : "var(--texto)",
                border: "1px solid var(--borde)",
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
        </div>
        <p className="tenue" style={{ fontSize: "var(--texto-chico)", marginTop: 0 }}>
          Mismo código, mismos agentes, mismas cinco herramientas. Lo único que
          cambia es el caso.
        </p>

        {eventos.length === 0 && !corriendo && (
          <div className="panel" style={{ marginTop: 24 }}>
            <p style={{ margin: 0 }} className="suave">
              Elige un caso para ver la deliberación completa: cómo se descubren,
              qué evidencia consultan y qué se dicen entre ellos.
            </p>
          </div>
        )}

        {eventos.map((ev, i) => <Fila key={i} ev={ev} />)}
        </main>

        {/* El lateral no se mueve al hacer scroll: la GPU y los prompts son el
            contexto que da sentido a todo lo de la izquierda, y perderlos de
            vista obligaria a recordarlos. */}
        <aside className="lateral">
          <GPU activo={corriendo} />
          <Prompts />
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

  useEffect(() => {
    fetch("/api/prompts").then((r) => r.json()).then(setDatos).catch(() => {});
  }, []);

  return (
    <div className="panel" style={{ marginTop: 18 }}>
      <div style={{ fontWeight: 600 }}>
        Lo único que los hace distintos
        <Info>
          Los dos agentes corren sobre los mismos pesos, en el mismo proceso y
          en la misma GPU. No hay dos modelos. Lo que separa al que acusa del
          que defiende cabe en estos dos párrafos — y en su identidad y sus
          permisos, que gobiernan Cilium y Tetragon.
        </Info>
      </div>
      {datos.length === 0 && <p className="tenue" style={{ fontSize: 13 }}>cargando…</p>}
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
            </>
          )}
        </div>
      ))}
    </div>
  );
}

function GPU({ activo }: { activo: boolean }) {
  const [salida, setSalida] = useState("consultando…");

  useEffect(() => {
    let vivo = true;
    async function leer() {
      try {
        const r = await fetch("/api/gpu");
        const d = await r.json();
        if (vivo) setSalida(d.salida);
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
      <pre className="sobre mono" style={{ fontSize: 13, lineHeight: 1.35 }}>{salida}</pre>
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
          <div style={{ fontWeight: 600, marginBottom: 6 }}>{ev.agente}</div>
          <div>{ev.texto}</div>
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
