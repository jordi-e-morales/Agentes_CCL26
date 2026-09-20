#!/usr/bin/env python3
"""El servidor MCP: donde viven las herramientas de los agentes.

POR QUE ESCRIBIMOS EL NUESTRO Y NO USAMOS UNO DE POSTGRES YA HECHO
------------------------------------------------------------------
Existen servidores MCP para Postgres (el oficial fue archivado en 2025; el
sucesor es Postgres MCP Pro). Todos exponen UNA herramienta: `query` o
`execute_sql`, que recibe SQL arbitrario. Para este demo eso seria un error:

  1. El CLAUDE.md seccion 4 exige que las tools se expliquen solas en tres
     segundos sin saber del dominio. La sala veria SQL crudo.
  2. `dispone_caso` es la accion peligrosa que el ataque abusa. Con SQL
     arbitrario el ataque pasa a ser "ejecuta este SELECT", que es una demo de
     inyeccion SQL, no de autorizacion de agentes.
  3. El insight #2 dice que el control vive en el EJECUTOR de herramientas. Si
     el ejecutor es un paso directo a SQL, no hay control que enseñar. El
     argumento central de la sesion se cae.
  4. `exporta_evidencia` tiene que ejecutar un binario. Ningun servidor de
     Postgres hace eso.

Eso si: enseñar la lista de herramientas de un Postgres MCP generico -una sola,
`execute_sql`- al lado de esta, es medio minuto y vale por un argumento entero
sobre lo que NO hay que desplegar.

QUE HAY AQUI Y QUE NO
---------------------
Este es el spike. Los datos son de mentira y estan escritos a mano, con los
mismos casos que esquema/ejemplos/. Postgres entra despues, y cuando entre
SOLO cambian los cuerpos de las funciones: los nombres, las firmas y lo que ve
el modelo se quedan igual. Ese es el punto de tener nombres con significado.

Uso:
    .venv/bin/python spike-mcp/servidor_mcp.py
    .venv/bin/python spike-mcp/servidor_mcp.py --puerto 9000
"""

import argparse

from mcp.server import MCPServer

mcp = MCPServer(
    name="herramientas-triage",
    instructions=(
        "Herramientas de triage de alertas. Las de evidencia solo leen. "
        "dispone_caso cambia el estado de la alerta y es irreversible."
    ),
)

# ---------------------------------------------------------------------------
# Datos sinteticos. Nombres claramente ficticios, como exige el CLAUDE.md §6.
# Neutrales al dominio: aqui no hay 'cliente' ni 'monto', hay sujetos y eventos.
# ---------------------------------------------------------------------------
EVENTOS = {
    "SUJ-0001": [
        {"momento": "2026-08-14", "tipo": "actividad", "atributos": {"canal": "digital", "volumen": "alto"}},
        {"momento": "2026-08-29", "tipo": "actividad", "atributos": {"canal": "digital", "volumen": "alto"}},
        {"momento": "2026-09-02", "tipo": "cambio", "atributos": {"campo": "representante_legal"}},
    ],
    "SUJ-0002": [
        {"momento": "2026-09-16", "tipo": "proceso", "atributos": {"binario": "/tmp/ficticio", "usuario": "svc-app"}},
        {"momento": "2026-09-16", "tipo": "conexion", "atributos": {"destino": "203.0.113.9", "puerto": 8443}},
    ],
    "SUJ-0003": [],
}

LISTAS = {"SUJ-0007": "lista-ficticia-A"}

PERFILES = {
    "SUJ-0001": {"tipo": "organizacion", "etiqueta": "Distribuidora Quetzal Ficticia, S.A.",
                 "jurisdiccion": "PAIS-FICTICIO-A", "antiguedad_meses": 7},
    "SUJ-0002": {"tipo": "host", "etiqueta": "srv-ficticio-app-07",
                 "segmento": "produccion", "expuesto_a_internet": False},
    "SUJ-0003": {"tipo": "organizacion", "etiqueta": "Comercializadora Jacaranda Ficticia, S. de R.L.",
                 "jurisdiccion": "PAIS-FICTICIO-B", "antiguedad_meses": 3},
}

# Lo que dispone_caso va escribiendo. En el spike vive en memoria; con Postgres
# sera una fila que la sala ve cambiar en pantalla.
DISPOSICIONES: dict[str, dict] = {}


# ---------------------------------------------------------------------------
# HERRAMIENTAS DE EVIDENCIA. Solo leen.
#
# La descripcion de cada una NO es documentacion: es lo que el modelo lee para
# decidir si la llama. Esta escrita para el modelo y para la sala a la vez.
# ---------------------------------------------------------------------------
@mcp.tool()
def consulta_historial(sujeto_id: str) -> dict:
    """Devuelve los eventos registrados de un sujeto. Solo lectura.

    Uselo antes de opinar sobre una alerta: sin historial no hay fundamento.
    """
    eventos = EVENTOS.get(sujeto_id, [])
    return {
        "sujeto_id": sujeto_id,
        "eventos": eventos,
        "resumen": f"{len(eventos)} evento(s) registrado(s)" if eventos
                   else "sin historial previo",
    }


@mcp.tool()
def lista_sancionados(sujeto_id: str) -> dict:
    """Indica si el sujeto aparece en alguna lista de control. Solo lectura."""
    lista = LISTAS.get(sujeto_id)
    return {
        "sujeto_id": sujeto_id,
        "aparece": lista is not None,
        "resumen": f"aparece en {lista}" if lista else "no aparece en ninguna lista",
    }


@mcp.tool()
def perfil_sujeto(sujeto_id: str) -> dict:
    """Devuelve los datos basicos del sujeto de la alerta. Solo lectura."""
    perfil = PERFILES.get(sujeto_id)
    return {
        "sujeto_id": sujeto_id,
        "perfil": perfil,
        "resumen": perfil["etiqueta"] if perfil else "sujeto desconocido",
    }


# ---------------------------------------------------------------------------
# LA ACCION PELIGROSA.
#
# Es lo que el ataque del segmento 6 intenta abusar, y por eso existe. Fijate
# en que NO se defiende sola: acepta la llamada y la ejecuta. El control no
# vive aqui dentro, vive en las capas de alrededor (Cilium sobre la ruta,
# Tetragon sobre el kernel). Esa es exactamente la tesis de la sesion.
#
# Si esta funcion se protegiera a si misma, el demo no enseñaria nada: cada
# quien diria "pues valida tus entradas" y a otra cosa.
# ---------------------------------------------------------------------------
@mcp.tool()
def dispone_caso(alerta_id: str, estado: str, justificacion: str) -> dict:
    """Cierra o escala una alerta. IRREVERSIBLE: cambia el estado del caso.

    estado: "escalada", "cerrada" o "en_revision".
    """
    DISPOSICIONES[alerta_id] = {"estado": estado, "justificacion": justificacion}
    return {
        "alerta_id": alerta_id,
        "estado": estado,
        "resumen": f"alerta {alerta_id} quedo {estado}",
    }


def main():
    p = argparse.ArgumentParser(description="Servidor MCP de herramientas de triage")
    p.add_argument("--puerto", type=int, default=9000,
                   help="puerto (por omision 9000; el 8000 lo ocupa vLLM)")
    p.add_argument("--host", default="0.0.0.0",
                   help="0.0.0.0 para que lo alcancen otros pods")
    args = p.parse_args()

    print(f"Servidor MCP en http://{args.host}:{args.puerto}/mcp")
    print("Herramientas: consulta_historial, lista_sancionados, perfil_sujeto, dispone_caso")
    print("")
    print("OJO: las cuatro viven detras de la MISMA ruta, POST /mcp.")
    print("Cilium vera el destino, pero no cual de las cuatro se llamo.")
    print("Esa es la lamina del segmento 6.")

    # stateless_http=True a proposito: sin estado de sesion, cada llamada es un
    # POST /mcp independiente. Eso simplifica el reinicio (modo stand) y hace
    # que lo que ve la red sea exactamente lo que contamos que ve.
    mcp.run(
        transport="streamable-http",
        host=args.host,
        port=args.puerto,
        stateless_http=True,
    )


if __name__ == "__main__":
    main()
