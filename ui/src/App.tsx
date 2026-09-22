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

export default function App() {
  const [eventos, setEventos] = useState<Evento[]>([]);
  const [corriendo, setCorriendo] = useState(false);
  const [caso, setCaso] = useState(CASOS[0]);
  const [hora, setHora] = useState<string | null>(null);
  // Sube en cada arranque. El panel del kernel lo usa para saber que muertes
  // ya existian antes y no mezclarlas con las de ahora.
  const [corridaId, setCorridaId] = useState(0);
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
          <Kernel activo={corriendo} corridaId={corridaId} />
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

  useEffect(() => {
    fetch("/api/prompts").then((r) => r.json()).then(setDatos).catch(() => {});
  }, []);

  return (
    <div className="panel" style={{ marginTop: 18 }}>
      <div style={{ fontWeight: 600 }}>
        Identidad de los Agentes
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
          <div style={{ fontWeight: 600, marginBottom: 6 }}>{ev.agente}</div>
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
