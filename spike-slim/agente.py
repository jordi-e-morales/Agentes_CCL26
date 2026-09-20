#!/usr/bin/env python3
"""Los tres papeles del spike: router, agente-a y agente-b.

QUE TIENE QUE DEMOSTRAR ESTE SPIKE
----------------------------------
El CLAUDE.md dice que SLIM es la dependencia mas pesada del plan y que hay que
confirmarla ANTES de la Fase A. Tambien dice, en la seccion 3:

    "Debe existir al menos un SALTO LATERAL agente a agente sin pasar por el
     centro: sin eso la malla es una estrella."

Asi que el criterio de exito no es "se mandan mensajes". Es este flujo:

    router  --(1) tarea-->  agente-a
                            agente-a  --(2) consulta-->  agente-b     <-- SALTO LATERAL
                            agente-a  <--(3) respuesta--  agente-b
    router  <--(4) resultado--  agente-a

El paso 2 es el que importa. El router NO participa en esa conversacion: no la
media, no la ve, no la reenvia. agente-a abre su propia sesion con agente-b.

UNA PRECISION DE HONESTIDAD, IMPORTANTE PARA EL SEGMENTO 3
----------------------------------------------------------
"Sin pasar por el centro" es una afirmacion sobre la TOPOLOGIA DE LA
APLICACION, no sobre el camino de los paquetes.

En SLIM todos los mensajes atraviesan fisicamente el nodo, porque el nodo ES el
bus. Lo que el salto lateral demuestra es que agente-a y agente-b se hablan
como iguales, sin que el router orqueste la conversacion. Eso es lo que separa
una malla de una estrella, y es una propiedad real y valiosa.

Pero en la sesion NO se puede decir "el trafico no pasa por el centro", porque
si pasa. Se dice: "el router no participa en esta conversacion". La diferencia
importa y el CLAUDE.md seccion 6 es explicito sobre no afirmar de mas.

Uso (tres terminales, mas la del nodo):
    .venv/bin/python spike-slim/agente.py --rol b
    .venv/bin/python spike-slim/agente.py --rol a
    .venv/bin/python spike-slim/agente.py --rol router
"""

import argparse
import asyncio
import datetime
import sys

import slim_bindings

# Los nombres en SLIM tienen tres partes: organizacion/espacio/aplicacion.
# Eso encaja de una con la idea del proyecto: la identidad del agente es parte
# del sistema, no una etiqueta que le ponemos por fuera.
#
# OJO CON LA PALABRA "ROUTER": en este proyecto hay DOS cosas distintas.
#
#   nodo SLIM      = infraestructura. Reenvia bytes por nombre. Es el "data
#                    plane", puerto 46357. No sabe que es un agente.
#   router-tareas  = UN AGENTE MAS, colgado del bus igual que los otros.
#                    Clasifica la tarea y despacha. Es el "router por tarea"
#                    del CLAUDE.md seccion 3.
#
# El agente se llama aqui "router-tareas" y no "router" justamente para que
# nadie los confunda. No es el centro de la RED; es el centro de la LOGICA.
ORG = "ccl26"
ESPACIO = "malla"

ROUTER = f"{ORG}/{ESPACIO}/router-tareas"
AGENTE_A = f"{ORG}/{ESPACIO}/agente-a"
AGENTE_B = f"{ORG}/{ESPACIO}/agente-b"

# Secreto compartido. Vale para el spike y NO vale para nada mas: SLIM soporta
# JWT y SPIFFE/SPIRE, que es por donde hay que ir cuando la identidad de cada
# agente tenga que ser demostrable. Ver el README de esta carpeta.
SECRETO = "spike-ccl26-no-usar-en-serio"

ESPERA = datetime.timedelta(seconds=30)


def traza(quien: str, que: str):
    print(f"[{quien:>12}] {que}", flush=True)


async def conectar(nombre_local: str, nodo: str):
    """Arranca el servicio, se conecta al nodo y se da de alta con un nombre.

    Los cuatro pasos son siempre los mismos para cualquier agente:
      1. inicializar el runtime de SLIM
      2. conectarse al nodo (devuelve un id de conexion)
      3. crear la "app" con su identidad
      4. SUSCRIBIRSE al propio nombre: es como decir "si alguien busca a
         ccl26/malla/agente-b, soy yo". Sin esto nadie te encuentra.
    """
    slim_bindings.uniffi_set_event_loop(asyncio.get_running_loop())
    slim_bindings.initialize_with_defaults()
    service = slim_bindings.get_global_service()

    conn_id = await service.connect_async(slim_bindings.new_insecure_client_config(nodo))

    yo = slim_bindings.Name.from_string(nombre_local)
    app = service.create_app_with_secret(yo, SECRETO)
    await app.subscribe_async(yo, conn_id)

    traza(nombre_local.split("/")[-1], f"dado de alta en {nodo}")
    return app, conn_id


async def abrir_sesion(app, conn_id, destino: str):
    """Abre una sesion punto a punto hacia otro agente.

    set_route_async le dice a este agente por que conexion se llega al destino.
    create_session_async negocia la sesion; hay que ESPERAR a completion antes
    de publicar, o los primeros mensajes se pierden.
    """
    remoto = slim_bindings.Name.from_string(destino)
    await app.set_route_async(remoto, conn_id)

    config = slim_bindings.SessionConfig(
        session_type=slim_bindings.SessionType.POINT_TO_POINT,
        max_retries=5,
        interval=datetime.timedelta(seconds=5),
        metadata={},
        mls_settings=None,  # sin cifrado extremo a extremo en el spike
    )
    ctx = await app.create_session_async(config, remoto)
    await ctx.completion.wait_async()
    return ctx.session


# ---------------------------------------------------------------------------
# ROL: router. Manda la tarea a agente-a y espera el resultado.
# ---------------------------------------------------------------------------
async def rol_router(nodo: str):
    app, conn_id = await conectar(ROUTER, nodo)
    sesion = await abrir_sesion(app, conn_id, AGENTE_A)

    traza("router", f"-> agente-a: tarea ALR-FICTICIA-0001")
    await sesion.publish_async(b"tarea:ALR-FICTICIA-0001", None, None)

    msg = await sesion.get_message_async(timeout=ESPERA)
    traza("router", f"<- agente-a: {msg.payload.decode()}")

    print()
    print("=" * 66)
    print("SPIKE SUPERADO si arriba se ve que agente-a hablo con agente-b")
    print("sin que el router interviniera en esa conversacion.")
    print("=" * 66)


# ---------------------------------------------------------------------------
# ROL: agente-a. Recibe del router y hace EL SALTO LATERAL a agente-b.
# ---------------------------------------------------------------------------
async def rol_a(nodo: str):
    app, conn_id = await conectar(AGENTE_A, nodo)
    traza("agente-a", "esperando al router...")

    sesion_router = await app.listen_for_session_async(None)
    msg = await sesion_router.get_message_async(timeout=ESPERA)
    tarea = msg.payload.decode()
    traza("agente-a", f"<- router: {tarea}")

    # ---- EL SALTO LATERAL ----
    # agente-a abre SU PROPIA sesion con agente-b. El router no participa.
    traza("agente-a", "SALTO LATERAL: abriendo sesion propia con agente-b")
    sesion_b = await abrir_sesion(app, conn_id, AGENTE_B)

    await sesion_b.publish_async(f"consulta:{tarea}".encode(), None, None)
    traza("agente-a", "-> agente-b: consulta enviada (el router no la ve)")

    respuesta_b = await sesion_b.get_message_async(timeout=ESPERA)
    traza("agente-a", f"<- agente-b: {respuesta_b.payload.decode()}")
    # ---- fin del salto lateral ----

    await sesion_router.publish_async(
        f"resultado (con aporte de agente-b: {respuesta_b.payload.decode()})".encode(),
        None,
        None,
    )
    traza("agente-a", "-> router: resultado")


# ---------------------------------------------------------------------------
# ROL: agente-b. Solo escucha y contesta. Nunca habla con el router.
# ---------------------------------------------------------------------------
async def rol_b(nodo: str):
    app, _ = await conectar(AGENTE_B, nodo)
    traza("agente-b", "esperando a quien sea...")

    sesion = await app.listen_for_session_async(None)
    msg = await sesion.get_message_async(timeout=ESPERA)
    traza("agente-b", f"<- {msg.payload.decode()}  (viene de agente-a, no del router)")

    await sesion.publish_async(b"evidencia-b:sin-coincidencias", None, None)
    traza("agente-b", "-> respuesta enviada")


ROLES = {"router": rol_router, "a": rol_a, "b": rol_b}


def main():
    p = argparse.ArgumentParser(description="Spike de SLIM: ping-pong y salto lateral")
    p.add_argument("--rol", required=True, choices=sorted(ROLES), help="que papel hace este proceso")
    p.add_argument("--nodo", default="http://127.0.0.1:46357", help="URL del nodo SLIM")
    args = p.parse_args()

    try:
        asyncio.run(ROLES[args.rol](args.nodo))
    except KeyboardInterrupt:
        pass
    except Exception as e:
        print(f"\nFALLO ({args.rol}): {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
