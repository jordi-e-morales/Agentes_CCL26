import { useState, useRef } from "react";
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
  | { tipo: "herramienta"; agente: string; nombre: string; args: any; resultado?: string }
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

      <main style={{ maxWidth: 1080, margin: "0 auto", padding: "24px 28px 80px" }}>
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
      /* La pregunta Y la respuesta. Si solo se viera la pregunta, no habria
         forma de saber si la evidencia existe o si el modelo la invento. */
      return (
        <div className="panel" style={{ marginTop: 10 }}>
          <div>
            <span className="chip">{ev.agente}</span>{" "}
            <code style={{ color: "var(--cisco-cian)" }}>{ev.nombre}</code>
            <code className="tenue">({JSON.stringify(ev.args)})</code>
          </div>
          {ev.resultado && <pre className="sobre">{ev.resultado}</pre>}
        </div>
      );

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
