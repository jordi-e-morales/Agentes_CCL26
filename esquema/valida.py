#!/usr/bin/env python3
"""Valida los casos de ejemplo contra el esquema.

Sirve para dos cosas:

1. Comprobar que un caso nuevo esta bien escrito antes de cargarlo.
2. Probar que el esquema SIGUE siendo neutral al dominio. Los ejemplos son de
   dominios que no se parecen (transaccional y SOC) y validan contra el mismo
   esquema. Si alguien agrega un campo con nombre de dominio, esto no lo
   detecta solo, pero el ejemplo del otro dominio se vuelve invalido en cuanto
   ese campo sea obligatorio.

Uso:  .venv/bin/python esquema/valida.py
"""
import glob
import json
import pathlib
import sys

from jsonschema import Draft202012Validator

RAIZ = pathlib.Path(__file__).parent
esquema = json.loads((RAIZ / "alerta.schema.json").read_text(encoding="utf-8"))

# Primero: que el esquema en si sea un esquema valido. Un error de sintaxis
# aqui haria que todos los casos "pasaran" sin que nada se comprobara.
Draft202012Validator.check_schema(esquema)
validador = Draft202012Validator(esquema)

fallos = 0
for ruta in sorted(glob.glob(str(RAIZ / "ejemplos" / "*.json"))):
    caso = json.loads(pathlib.Path(ruta).read_text(encoding="utf-8"))
    errores = sorted(validador.iter_errors(caso), key=lambda e: list(e.path))
    nombre = pathlib.Path(ruta).name
    if errores:
        fallos += 1
        print(f"  FALLA  {nombre}")
        for e in errores:
            donde = "/".join(map(str, e.path)) or "(raiz)"
            print(f"         {donde}: {e.message}")
    else:
        print(f"  ok     {nombre}")

if fallos:
    print(f"\n{fallos} caso(s) invalido(s).")
    sys.exit(1)
print("\nTodos los casos validan contra el esquema.")
