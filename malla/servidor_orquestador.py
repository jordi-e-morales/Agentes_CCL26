#!/usr/bin/env python3
"""El orquestador por tarea, como servicio. Corre en su propio pod.

POR QUE SALIO DE LA INTERFAZ
----------------------------
Hasta el 2026-09-23 el router vivia DENTRO del proceso de ui/servidor.py: la
interfaz importaba malla/flujo.py y llamaba a deliberar() en su propio proceso.
Funcionaba, y tenia un problema que solo se ve desde la red.

El CLAUDE.md §3 dice del router: "Es un agente mas, no el centro de la red: es
el centro de la logica". Dentro del proceso de la interfaz eso era cierto en la
logica y falso en la red: sus llamadas a los agentes salian del host, entraban
por el port-forward y Hubble no tenia a quien dibujar. El grafo de la malla
aparecia sin la flecha que la pone en marcha, y Cilium no podia gobernar
router -> agente porque ese trafico no atravesaba el cluster.

POR QUE LA INTERFAZ NO SE MOVIO CON EL
--------------------------------------
Porque son dos cosas distintas que compartian proceso por accidente:

  - El router es un AGENTE. Su sitio es la malla, y ahi tiene que ser visible.
  - La interfaz es la VENTANA DEL PRESENTADOR. Su sitio es el host, que es
    donde estan nvidia-smi, kubectl y hubble.

Meter la interfaz al cluster habria roto el panel de GPU (no hay nvidia-smi en
un pod) y habria exigido darle permiso para ejecutar comandos dentro de pods de
kube-system — en una sesion cuyo segmento 6 trata de minimo privilegio.

Asi que la interfaz se queda donde estaba y hace de proxy del SSE. La logica no
se duplico: flujo.py es el mismo archivo, solo cambio quien lo ejecuta.

Uso:
    python malla/servidor_orquestador.py            (puerto 7012)
"""

import argparse
import hashlib
import json
import pathlib
import sys

from starlette.applications import Starlette
from starlette.responses import JSONResponse, StreamingResponse
from starlette.routing import Route

RAIZ = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(RAIZ))
from malla import flujo  # noqa: E402


def version_del_codigo() -> str:
    """Huella de lo que ESTE proceso esta corriendo.

    Mismo mecanismo que en agente.py, y por el mismo motivo: un proceso viejo
    no da error, da resultados viejos. Ya nos mordio tres veces.

    Se mezclan los dos archivos porque los dos deciden el comportamiento: la
    logica esta en flujo.py y el transporte aqui. Cambiar cualquiera y no
    reconstruir la imagen produce el mismo sintoma.
    """
    h = hashlib.sha256()
    for f in ("malla/flujo.py", "malla/servidor_orquestador.py"):
        h.update((RAIZ / f).read_bytes())
    return h.hexdigest()[:12]


async def salud(_req):
    return JSONResponse({"ok": True, "rol": "orquestador",
                         "version_codigo": version_del_codigo()})


async def tarjeta(_req):
    """La Agent Card del router.

    El router tambien publica la suya, y eso no es simetria por gusto: es lo que
    hace verdad la frase "es un agente mas". Hasta hoy era el unico de los tres
    sin tarjeta.
    """
    return JSONResponse(json.loads(
        (RAIZ / "malla" / "tarjetas" / "orquestador.json").read_text(encoding="utf-8")))


async def agentes(_req):
    """El descubrimiento: lee las tarjetas de los demas. Es el segmento 2."""
    return JSONResponse(await flujo.descubrir())


async def deliberar(req):
    """La deliberacion entera, transmitida como SSE mientras ocurre.

    SE TRANSMITE, NO SE DEVUELVE AL FINAL. Una deliberacion tarda ~41 segundos,
    y el §12 dice que "la espera es la demo": la sala ve aparecer el
    descubrimiento, la eleccion, el sobre A2A, cada herramienta con su respuesta
    y el salto lateral. Devolver todo junto al terminar convertiria eso en 41
    segundos de pantalla quieta.
    """
    cuerpo = {}
    try:
        cuerpo = await req.json()
    except Exception:
        pass
    alerta = cuerpo.get("alerta") or req.query_params.get("alerta", "")
    sujeto = cuerpo.get("sujeto") or req.query_params.get("sujeto", "")
    busca = cuerpo.get("busca") or req.query_params.get("busca", "riesgo")

    async def eventos():
        try:
            async for evento in flujo.deliberar(alerta, sujeto, busca):
                yield f"data: {json.dumps(evento, ensure_ascii=False)}\n\n"
        except Exception as e:
            # El error viaja por el mismo canal. Si se dejara escapar, la
            # interfaz veria la conexion cortarse sin saber por que, y en
            # pantalla eso es indistinguible de "se quedo pensando".
            yield ("data: " + json.dumps(
                {"tipo": "error", "mensaje": f"{type(e).__name__}: {e}"},
                ensure_ascii=False) + "\n\n")

    return StreamingResponse(eventos(), media_type="text/event-stream", headers={
        "Cache-Control": "no-cache",
        # Sin esto un proxy intermedio puede acumular la respuesta y entregarla
        # de golpe al final, que es exactamente lo que se quiere evitar.
        "X-Accel-Buffering": "no",
    })


def construir():
    return Starlette(routes=[
        Route("/salud", salud),
        Route("/.well-known/agent-card.json", tarjeta),
        Route("/agentes", agentes),
        Route("/deliberar", deliberar, methods=["POST"]),
    ])


def main():
    p = argparse.ArgumentParser(description="El orquestador por tarea, como servicio")
    p.add_argument("--puerto", type=int, default=7012)
    a = p.parse_args()

    import uvicorn
    print(f"Orquestador en http://0.0.0.0:{a.puerto}  (codigo {version_del_codigo()})")
    print(f"  tarjeta:   /.well-known/agent-card.json")
    print(f"  descubrir: GET  /agentes")
    print(f"  deliberar: POST /deliberar   (SSE)")
    for nombre, base in flujo.AGENTES.items():
        print(f"  agente:    {nombre} en {base}")
    uvicorn.run(construir(), host="0.0.0.0", port=a.puerto, log_level="warning")


if __name__ == "__main__":
    main()
