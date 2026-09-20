#!/usr/bin/env python3
"""Comprueba que las Agent Cards son A2A valido de verdad.

POR QUE LAS TARJETAS SON JSON A MANO Y NO GENERADAS
----------------------------------------------------
El SDK de A2A puede construirlas, pero sus tipos son protobuf y el resultado no
se parece a lo que uno escribiria. Y estas tarjetas SE ENSEÑAN EN PANTALLA: son
el segmento 2 entero. Tienen que leerse de un vistazo.

Asi que se escriben como JSON legible y se VALIDAN con el SDK. De ese modo:

  - lo que la sala ve es exactamente lo que hay
  - y no se afirma "esto es A2A" sin que nadie lo haya comprobado

Es la misma regla de honestidad del CLAUDE.md §6, aplicada a un formato.

Uso:  .venv/bin/python malla/valida_tarjetas.py
"""

import glob
import json
import pathlib
import sys

try:
    from a2a.types import AgentCard
    from google.protobuf.json_format import ParseDict
except ImportError:
    print("Falta el SDK de A2A:  .venv/bin/pip install a2a-sdk")
    raise SystemExit(1)

RAIZ = pathlib.Path(__file__).parent

# El SDK usa nombres protobuf (snake_case) y el JSON del protocolo usa
# camelCase. ParseDict traduce entre los dos.
#
# DISCREPANCIA ANOTADA: la especificacion JSON de A2A 0.3.x muestra los campos
# `protocolVersion` y `preferredTransport`, pero el esquema protobuf del SDK
# (lf.a2a.v1.AgentCard) NO los tiene. Aqui se valida contra el SDK, asi que las
# tarjetas no los llevan.
#
# Se deja dicho por dos razones: para que nadie los "arregle" agregandolos, y
# porque si alguien en la sala compara con la spec publicada, la diferencia
# tiene explicacion en vez de parecer un descuido.
fallas = 0
for ruta in sorted(glob.glob(str(RAIZ / "tarjetas" / "*.json"))):
    nombre = pathlib.Path(ruta).name
    datos = json.loads(pathlib.Path(ruta).read_text(encoding="utf-8"))
    try:
        # ignore_unknown_fields=False a proposito: si escribo un campo que el
        # protocolo no tiene, quiero enterarme aqui y no en el escenario.
        ParseDict(datos, AgentCard(), ignore_unknown_fields=False)
        print(f"  ok     {nombre}")
    except Exception as e:
        fallas += 1
        print(f"  FALLA  {nombre}: {e}")

print()
if fallas:
    print(f"{fallas} tarjeta(s) invalida(s).")
    sys.exit(1)
print("Las tarjetas son A2A valido.")
