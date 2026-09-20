-- El esquema de la evidencia. Espejo de esquema/alerta.schema.json.
--
-- NEUTRAL AL DOMINIO, y eso no es estetica: el CLAUDE.md seccion 7 promete que
-- los casos de SOC cargan sin cambiar codigo. Por eso NO existe una tabla
-- llamada 'transacciones'. En cuanto se escriba esa palabra, un caso de SOC
-- obliga a tocar codigo y la promesa se rompe.
--
-- Este archivo se monta en /docker-entrypoint-initdb.d/, asi que Postgres lo
-- corre solo al crear el contenedor. Consecuencia util: la base SIEMPRE nace
-- igual, y "reiniciar" es borrar el pod. No hace falta almacenamiento
-- persistente y el estado es deterministico.

-- ---------------------------------------------------------------------------
-- Sujetos: sobre quien o sobre que es la alerta.
-- Deliberadamente generico: una organizacion, un host, una identidad, lo que sea.
-- ---------------------------------------------------------------------------
CREATE TABLE sujetos (
    id        TEXT PRIMARY KEY,
    tipo      TEXT  NOT NULL,          -- organizacion, host, persona, identidad...
    etiqueta  TEXT  NOT NULL,          -- como se le llama en pantalla
    -- Lo especifico del dominio vive AQUI, donde nada ramifica sobre ello.
    -- Es el escape hatch que mantiene neutral al resto del esquema.
    atributos JSONB NOT NULL DEFAULT '{}'
);

CREATE TABLE alertas (
    id        TEXT PRIMARY KEY,
    origen    TEXT        NOT NULL,     -- que sistema la genero
    creada_en TIMESTAMPTZ NOT NULL,
    severidad TEXT        NOT NULL CHECK (severidad IN ('baja','media','alta','critica')),
    titulo    TEXT        NOT NULL,     -- se lee en 3 segundos
    sujeto_id TEXT        NOT NULL REFERENCES sujetos(id),
    -- Siempre true en este proyecto. Existe para que la interfaz pueda marcar
    -- los datos como sinteticos sin depender de que alguien se acuerde.
    sintetica BOOLEAN     NOT NULL DEFAULT TRUE
);

-- ---------------------------------------------------------------------------
-- LA TABLA CLAVE.
--
-- Para el caso transaccional, `atributos` lleva canal y volumen.
-- Para el caso de SOC, lleva binario, usuario, puerto.
--
-- Misma tabla, misma consulta, misma herramienta, cero codigo. Cargar un caso
-- de SOC en vivo y ver filas completamente distintas sin tocar nada es el
-- momento de 30 segundos que demuestra la neutralidad en vez de prometerla.
-- ---------------------------------------------------------------------------
CREATE TABLE eventos (
    id        BIGSERIAL PRIMARY KEY,
    sujeto_id TEXT        NOT NULL REFERENCES sujetos(id),
    momento   TIMESTAMPTZ NOT NULL,
    tipo      TEXT        NOT NULL,     -- actividad, cambio, proceso, conexion...
    atributos JSONB       NOT NULL DEFAULT '{}'
);
CREATE INDEX eventos_por_sujeto ON eventos (sujeto_id, momento DESC);

-- Listas de control. Sanciones en un dominio, indicadores en el otro.
CREATE TABLE listas (
    nombre    TEXT NOT NULL,
    sujeto_id TEXT NOT NULL REFERENCES sujetos(id),
    motivo    TEXT,
    PRIMARY KEY (nombre, sujeto_id)
);

-- ---------------------------------------------------------------------------
-- Fragmentos: los textos libres que acompañan a la alerta.
--
-- AQUI VIVE EL RIESGO. `source_trust = 'external'` significa que lo escribio
-- alguien de fuera, o sea ENTRADA NO CONFIABLE que puede contener
-- instrucciones dirigidas al modelo.
--
-- La inyeccion del segmento 6 vive SIEMPRE en un fragmento external. Es una
-- invariante del proyecto, no una casualidad de un caso.
-- ---------------------------------------------------------------------------
CREATE TABLE fragmentos (
    id           TEXT PRIMARY KEY,
    alerta_id    TEXT NOT NULL REFERENCES alertas(id),
    etiqueta     TEXT NOT NULL,
    texto        TEXT NOT NULL,
    source_trust TEXT NOT NULL CHECK (source_trust IN ('internal','external','unknown')),
    autor        TEXT
);

-- ---------------------------------------------------------------------------
-- Disposiciones: el resultado del triage.
--
-- Esta tabla es la que la sala ve CAMBIAR. La escribe dispone_caso, que es la
-- accion peligrosa que el ataque intenta abusar. Una alerta dispuesta sin
-- evidencia recogida es visiblemente un triage que no se sostiene.
-- ---------------------------------------------------------------------------
CREATE TABLE disposiciones (
    alerta_id     TEXT PRIMARY KEY REFERENCES alertas(id),
    estado        TEXT        NOT NULL CHECK (estado IN ('escalada','cerrada','en_revision')),
    justificacion TEXT        NOT NULL,
    decidida_por  TEXT        NOT NULL,   -- identidad del agente, no una persona
    decidida_en   TIMESTAMPTZ NOT NULL DEFAULT now()
);
