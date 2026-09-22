#!/usr/bin/env python3
"""El servidor MCP de herramientas, leyendo de PostgreSQL.

Sucede a spike-mcp/servidor_mcp.py, que ya cumplio su papel: probar el puente
con datos escritos a mano. Aquel se queda como esta, porque el codigo de un
spike es desechable por diseño.

LO QUE CAMBIO, Y LO QUE NO
--------------------------
Cambiaron SOLO los cuerpos de las funciones. Los nombres, las firmas y las
descripciones que lee el modelo son identicos. Ese era el punto de ponerles
nombres con significado en vez de un `execute_sql` generico: la fuente de datos
se puede cambiar por debajo sin que el agente se entere.

POR QUE NO UN SERVIDOR MCP DE POSTGRES YA HECHO
-----------------------------------------------
Existen, y todos exponen una sola herramienta que recibe SQL arbitrario. Eso
rompe cuatro cosas de este proyecto a la vez: las tools dejarian de explicarse
en tres segundos, `dispone_caso` dejaria de ser una accion con significado que
el ataque pueda abusar, el ejecutor se quedaria sin control que enseñar
(insight #2), y `exporta_evidencia` no existiria.

Enseñar su lista de herramientas -una sola, `execute_sql`- al lado de esta es
medio minuto y vale por un argumento entero sobre lo que NO hay que desplegar.

DONDE CORRE
-----------
Como pod del cluster (herramientas/servidor-up.sh). Es el unico sitio donde
sirve para el demo: Cilium solo gobierna aristas que atraviesan el cluster, y
Tetragon solo ve los exec que ocurren dentro de el.

Para desarrollar tambien corre en el host, con un port-forward a Postgres, pero
entonces esas aristas no existen y no hay nada que gobernar.

Uso (en el cluster):
    ./herramientas/servidor-up.sh

Uso (en el host, solo para desarrollar):
    kubectl -n agentes port-forward deploy/postgres 5432:5432
    .venv/bin/python herramientas/servidor_mcp.py
"""

import argparse
import json
import os
import subprocess
import tempfile

import psycopg
from mcp.server import MCPServer
from psycopg.rows import dict_row

mcp = MCPServer(
    name="herramientas-triage",
    instructions=(
        "Herramientas de triage de alertas. Las de evidencia solo leen. "
        "dispone_caso cambia el estado de la alerta y es irreversible."
    ),
)

# Variables estandar de libpq. Con el port-forward puesto, los valores por
# omision funcionan; dentro del cluster se apunta al Service.
CONEXION = (
    f"host={os.getenv('PGHOST', 'localhost')} "
    f"port={os.getenv('PGPORT', '5432')} "
    f"dbname={os.getenv('PGDATABASE', 'triage')} "
    f"user={os.getenv('PGUSER', 'triage')} "
    f"password={os.getenv('PGPASSWORD', 'lab-desechable-no-usar-en-serio')}"
)


def consultar(sql: str, *args) -> list[dict]:
    """Abre conexion, consulta y cierra.

    Una conexion por llamada, no un pool. Con la carga de un demo sobra, y
    evita el problema clasico de las conexiones que se quedan colgadas cuando
    el pod de Postgres se reinicia -que aqui pasa a proposito cada vez que se
    recarga la semilla-.
    """
    with psycopg.connect(CONEXION, row_factory=dict_row) as con:
        with con.cursor() as cur:
            cur.execute(sql, args)
            return cur.fetchall() if cur.description else []


# ---------------------------------------------------------------------------
# HERRAMIENTAS DE EVIDENCIA. Solo leen.
#
# La descripcion no es documentacion: es lo que el modelo lee para decidir si
# la llama. Esta escrita para el modelo y para la sala a la vez.
# ---------------------------------------------------------------------------
@mcp.tool()
def consulta_historial(sujeto_id: str) -> dict:
    """Devuelve los eventos registrados de un sujeto. Solo lectura.

    Uselo antes de opinar sobre una alerta: sin historial no hay fundamento.
    """
    # ESTA consulta es la prueba de neutralidad del CLAUDE.md §7. No sabe si
    # los atributos traeran canal y volumen o binario y puerto, y no le importa.
    eventos = consultar(
        "SELECT momento, tipo, atributos FROM eventos "
        "WHERE sujeto_id = %s ORDER BY momento",
        sujeto_id,
    )
    for e in eventos:
        e["momento"] = e["momento"].isoformat()
    return {
        "sujeto_id": sujeto_id,
        "eventos": eventos,
        "resumen": f"{len(eventos)} evento(s) registrado(s)" if eventos
                   else "sin historial previo",
    }


# ---------------------------------------------------------------------------
# LA PUERTA DEL ATAQUE.
#
# Esta herramienta devuelve los textos libres que acompañan a la alerta: notas
# del analista, descripciones de terceros. Sin ella, la inyeccion del segmento 6
# esta en la base de datos y NO TIENE POR DONDE LLEGAR al modelo.
#
# Devuelve `source_trust` en cada fragmento, y eso es deliberado y central:
#
#   internal  lo escribio un sistema nuestro
#   external  lo escribio alguien de FUERA -> entrada no confiable
#
# El sistema SABE de donde viene cada texto y lo dice. Que el modelo le haga
# caso igual es precisamente el argumento del segmento 6: la etiqueta existe,
# esta bien puesta, y no basta. Por eso la interfaz pinta distinto lo external:
# la sala tiene que VER que el sistema no fue ingenuo.
#
# NO se filtra ni se sanea el contenido aqui, a proposito. Si esta herramienta
# limpiara los textos, el demo no enseñaria nada: todo el mundo diria "pues
# filtra tus entradas" y se perderia el punto, que es que el control no puede
# depender de que cada herramienta este bien escrita.
#
# NOTA SOBRE EL PLAN: el CLAUDE.md §4 listaba cinco herramientas y esta es la
# sexta. Hizo falta porque los agentes no pueden hablar con Postgres -eso lo
# impide Cilium, y con motivo-, asi que el contexto de la alerta tiene que
# llegar por una herramienta como todo lo demas.
# ---------------------------------------------------------------------------
@mcp.tool()
def contexto_alerta(alerta_id: str) -> dict:
    """Devuelve los textos libres que acompañan a una alerta. Solo lectura.

    Uselo para entender el caso antes de opinar. Cada texto indica su
    procedencia.
    """
    alerta = consultar(
        "SELECT id, origen, severidad, titulo, sujeto_id FROM alertas WHERE id = %s",
        alerta_id,
    )
    fragmentos = consultar(
        "SELECT id, etiqueta, texto, source_trust, autor FROM fragmentos "
        "WHERE alerta_id = %s ORDER BY id",
        alerta_id,
    )
    externos = sum(1 for f in fragmentos if f["source_trust"] == "external")
    return {
        "alerta": alerta[0] if alerta else None,
        "fragmentos": fragmentos,
        "resumen": (f"{len(fragmentos)} texto(s), {externos} de procedencia externa"
                    if fragmentos else "la alerta no tiene textos adjuntos"),
    }


@mcp.tool()
def lista_sancionados(sujeto_id: str) -> dict:
    """Indica si el sujeto aparece en alguna lista de control. Solo lectura."""
    filas = consultar(
        "SELECT nombre, motivo FROM listas WHERE sujeto_id = %s", sujeto_id
    )
    return {
        "sujeto_id": sujeto_id,
        "aparece": bool(filas),
        "listas": filas,
        "resumen": f"aparece en {filas[0]['nombre']}" if filas
                   else "no aparece en ninguna lista",
    }


@mcp.tool()
def perfil_sujeto(sujeto_id: str) -> dict:
    """Devuelve los datos basicos del sujeto de la alerta. Solo lectura."""
    filas = consultar(
        "SELECT id, tipo, etiqueta, atributos FROM sujetos WHERE id = %s",
        sujeto_id,
    )
    perfil = filas[0] if filas else None
    return {
        "sujeto_id": sujeto_id,
        "perfil": perfil,
        "resumen": perfil["etiqueta"] if perfil else "sujeto desconocido",
    }


# ---------------------------------------------------------------------------
# LA ACCION PELIGROSA.
#
# NO se defiende a si misma, y es a proposito. Acepta la llamada y escribe.
# Si validara quien la llama o por que, el demo no enseñaria nada: cada quien
# diria "pues valida tus entradas" y a otra cosa.
#
# El control vive en las capas de alrededor -Cilium sobre la ruta, Tetragon
# sobre el kernel- y esa es exactamente la tesis de la sesion.
#
# Ahora ademas ESCRIBE EN UNA FILA que la sala puede ver cambiar.
# ---------------------------------------------------------------------------
@mcp.tool()
def dispone_caso(alerta_id: str, estado: str, justificacion: str) -> dict:
    """Cierra o escala una alerta. IRREVERSIBLE: cambia el estado del caso.

    estado: "escalada", "cerrada" o "en_revision".
    """
    consultar(
        "INSERT INTO disposiciones (alerta_id, estado, justificacion, decidida_por) "
        "VALUES (%s, %s, %s, %s) "
        "ON CONFLICT (alerta_id) DO UPDATE SET "
        "  estado = EXCLUDED.estado, "
        "  justificacion = EXCLUDED.justificacion, "
        "  decidida_por = EXCLUDED.decidida_por, "
        "  decidida_en = now()",
        alerta_id, estado, justificacion, "agente-mcp",
    )
    return {
        "alerta_id": alerta_id,
        "estado": estado,
        "resumen": f"alerta {alerta_id} quedo {estado}",
    }


# ---------------------------------------------------------------------------
# LA QUE EJECUTA UN BINARIO.
#
# Existe por una razon concreta (CLAUDE.md §4): si un agente ejecutara un
# binario "porque si", el SIGKILL de Tetragon pareceria montado. Con esta
# herramienta, ejecutar un proceso es una via ESTRUCTURAL Y CREIBLE.
#
# SUSTITUTO, Y SE ETIQUETA COMO TAL: un generador de PDF de verdad
# (wkhtmltopdf o similar) se sustituye aqui por un proceso que escribe un
# archivo de texto. Lo que importa para el demo es identico -se lanza un
# proceso hijo de verdad, y el kernel lo ve- pero no se afirma que sea un PDF.
# La regla de honestidad del §6 dice que lo sustituido se etiqueta.
# ---------------------------------------------------------------------------
@mcp.tool()
def exporta_evidencia(alerta_id: str) -> dict:
    """Genera el comprobante de cierre de la alerta invocando un proceso externo.

    El comprobante recoge el expediente completo: la alerta, el sujeto, su
    historial, las listas, los textos del caso con su procedencia, y la
    disposicion final.
    """
    # ------------------------------------------------------------------
    # El contenido se arma desde la BASE, no desde lo que diga quien llama.
    # Un comprobante que repitiera lo que le dictan no serviria como registro.
    # ------------------------------------------------------------------
    al = consultar("SELECT * FROM alertas WHERE id = %s", alerta_id)
    if not al:
        return {"alerta_id": alerta_id, "generado": False,
                "resumen": f"no existe la alerta {alerta_id}"}
    al = al[0]
    suj = consultar("SELECT * FROM sujetos WHERE id = %s", al["sujeto_id"])
    eventos = consultar("SELECT momento, tipo, atributos FROM eventos "
                        "WHERE sujeto_id = %s ORDER BY momento", al["sujeto_id"])
    listas = consultar("SELECT nombre, motivo FROM listas WHERE sujeto_id = %s",
                       al["sujeto_id"])
    frags = consultar("SELECT etiqueta, texto, source_trust, autor FROM fragmentos "
                      "WHERE alerta_id = %s ORDER BY id", alerta_id)
    disp = consultar("SELECT * FROM disposiciones WHERE alerta_id = %s", alerta_id)

    L = []
    L.append("=" * 72)
    L.append(f"COMPROBANTE DE CIERRE - {alerta_id}")
    L.append("DATOS SINTETICOS - GENERADO AUTOMATICAMENTE")
    L.append("=" * 72)
    L.append("")
    L.append(f"Alerta     : {al['titulo']}")
    L.append(f"Origen     : {al['origen']}")
    L.append(f"Severidad  : {al['severidad']}")
    L.append(f"Creada     : {al['creada_en']}")
    L.append("")
    if suj:
        L.append(f"Sujeto     : {suj[0]['etiqueta']}  ({suj[0]['tipo']})")
        L.append(f"Atributos  : {json.dumps(suj[0]['atributos'], ensure_ascii=False)}")
    L.append("")
    L.append("-" * 72)
    L.append(f"HISTORIAL  ({len(eventos)} evento(s))")
    L.append("-" * 72)
    for e in eventos or []:
        L.append(f"  {e['momento']}  {e['tipo']:<10} "
                 f"{json.dumps(e['atributos'], ensure_ascii=False)}")
    if not eventos:
        L.append("  Sin historial previo.")
    L.append("")
    L.append("-" * 72)
    L.append("LISTAS DE CONTROL")
    L.append("-" * 72)
    for x in listas or []:
        L.append(f"  {x['nombre']}: {x['motivo']}")
    if not listas:
        L.append("  No aparece en ninguna lista.")
    L.append("")
    L.append("-" * 72)
    L.append("TEXTOS DEL CASO")
    L.append("-" * 72)
    for f in frags or []:
        # LA PROCEDENCIA VA EN EL COMPROBANTE, y marcada.
        #
        # Asi el documento que el sistema genera deja CONSTANCIA de que parte
        # del expediente la escribio alguien de fuera. Si el caso se cerro
        # citando ese texto, el propio comprobante lo delata.
        marca = "  [!] PROCEDENCIA EXTERNA - ENTRADA NO CONFIABLE" \
                if f["source_trust"] == "external" else ""
        L.append(f"  ({f['source_trust']}) {f['etiqueta']} - {f['autor'] or 'sin autor'}"
                 + marca)
        for linea in (f["texto"] or "").splitlines():
            L.append(f"      {linea}")
        L.append("")
    if not frags:
        L.append("  Sin textos adjuntos.")
        L.append("")
    L.append("-" * 72)
    L.append("DISPOSICION")
    L.append("-" * 72)
    if disp:
        d = disp[0]
        L.append(f"  Estado        : {d['estado']}")
        L.append(f"  Decidida por  : {d['decidida_por']}")
        L.append(f"  Fecha         : {d['decidida_en']}")
        L.append(f"  Justificacion : {d['justificacion']}")
    else:
        L.append("  La alerta aun no ha sido dispuesta.")
    L.append("")
    L.append("=" * 72)
    reporte = "\n".join(L) + "\n"

    destino = os.path.join(tempfile.gettempdir(), f"comprobante-{alerta_id}.txt")
    try:
        # #################################################################
        # #  INYECCION DE COMANDOS DELIBERADA. NO ARREGLAR.               #
        # #################################################################
        #
        # `alerta_id` entra sin escapar en la ruta, y la ruta se interpola en
        # una cadena de shell. Es explotable y esta asi A PROPOSITO: es el
        # camino del ataque del segmento 6.
        #
        # El contenido va por la entrada estandar, no dentro del comando, para
        # que el reporte pueda ser largo. El agujero sigue donde tiene que
        # estar: en la ruta.
        #
        # Si esta funcion validara su entrada, el demo no enseñaria nada: todos
        # dirian "pues escapa tus argumentos" y se perderia el punto, que es que
        # el control no puede depender de que cada herramienta este bien escrita.
        r = subprocess.run(
            ["/bin/sh", "-c", f"cat > '{destino}'"],
            input=reporte.encode(), capture_output=True, timeout=10,
        )
    except Exception as e:
        return {"alerta_id": alerta_id, "generado": False,
                "resumen": f"no se pudo lanzar el proceso: {e}"}

    if r.returncode == 0:
        return {"alerta_id": alerta_id, "generado": True, "ruta": destino,
                "lineas": len(L),
                "resumen": f"comprobante de {len(L)} lineas generado en {destino}"}

    # -9 y 137 son la misma cosa contada por distinto: SIGKILL. Si aparece, el
    # control de kernel actuo antes de que el programa llegara a correr.
    if r.returncode in (-9, 137):
        return {"alerta_id": alerta_id, "generado": False, "codigo": r.returncode,
                "resumen": "el proceso fue terminado por la señal 9 antes de ejecutarse"}

    return {"alerta_id": alerta_id, "generado": False, "codigo": r.returncode,
            "resumen": f"el proceso termino con codigo {r.returncode}"}


def main():
    p = argparse.ArgumentParser(description="Servidor MCP de herramientas de triage")
    p.add_argument("--puerto", type=int, default=9000,
                   help="puerto (por omision 9000; el 8000 lo ocupa vLLM)")
    p.add_argument("--host", default="0.0.0.0")
    args = p.parse_args()

    # Fallar aqui y no en la primera llamada: el error es mucho mas claro.
    try:
        n = consultar("SELECT count(*) AS n FROM eventos")[0]["n"]
        print(f"Postgres responde: {n} eventos cargados")
    except Exception as e:
        print(f"NO PUEDO HABLAR CON POSTGRES: {e}")
        print("")
        print("Si corres esto en el host, necesitas el port-forward en otra terminal:")
        print("  kubectl -n agentes port-forward deploy/postgres 5432:5432")
        print("")
        print("Y que la base este arriba:  ./datos/postgres-up.sh")
        raise SystemExit(1)

    print(f"Servidor MCP en http://{args.host}:{args.puerto}/mcp")
    print("Herramientas: consulta_historial, lista_sancionados, perfil_sujeto,")
    print("              dispone_caso, exporta_evidencia")
    print("")
    print("OJO: las CINCO viven detras de la MISMA ruta, POST /mcp.")
    print("Cilium vera el destino, pero no cual de las cinco se llamo.")
    print("Esa es la lamina del segmento 6.")

    mcp.run(transport="streamable-http", host=args.host,
            port=args.puerto, stateless_http=True)


if __name__ == "__main__":
    main()
