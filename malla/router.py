#!/usr/bin/env python3
"""El router por tarea: descubre quien puede hacer el trabajo y se lo manda.

NO ES EL CENTRO DE LA RED, ES EL CENTRO DE LA LOGICA
-----------------------------------------------------
Es un agente mas. No hay bus, no hay nodo central, no hay nada en medio: le
habla directamente al agente que eligio, por HTTP.

QUE HACE, EN TRES PASOS QUE SE VEN
-----------------------------------
  1. DESCUBRE  lee las Agent Cards de /.well-known/agent-card.json
  2. ELIGE     compara lo que pide la tarea con los `tags` de cada skill
  3. DESPACHA  manda un message/send de A2A al elegido

El paso 1 es el segmento 2 entero, y es lo contrario de tener URLs escritas a
mano en un archivo de configuracion: si mañana aparece un agente nuevo, el
router lo encuentra sin que nadie lo reprograme.

Uso:
    .venv/bin/python malla/router.py
    .venv/bin/python malla/router.py --alerta ALR-FICTICIA-0002 --sujeto SUJ-0002
"""

import argparse
import json
import os
import sys
import urllib.request

# Donde BUSCAR agentes. Ojo con la distincion, que es el punto del segmento 2:
# esto es una lista de DONDE PREGUNTAR, no de quien hace que. Lo que cada agente
# sabe hacer sale de su tarjeta, no de aqui.
#
# En el cluster son nombres de Service; en el host, localhost. Por eso se leen
# del entorno y no estan escritos a fuego.
AGENTES = {
    "investigador": os.getenv("URL_INVESTIGADOR", "http://localhost:7010"),
    "defensor": os.getenv("URL_DEFENSOR", "http://localhost:7011"),
}


def traer(url: str, cuerpo: dict | None = None, espera: int = 300) -> dict:
    datos = json.dumps(cuerpo).encode() if cuerpo else None
    req = urllib.request.Request(
        url, data=datos, method="POST" if cuerpo else "GET",
        headers={"Content-Type": "application/json"} if cuerpo else {},
    )
    with urllib.request.urlopen(req, timeout=espera) as r:
        return json.loads(r.read())


def main():
    p = argparse.ArgumentParser(description="Router por tarea")
    p.add_argument("--alerta", default="ALR-FICTICIA-0001")
    p.add_argument("--sujeto", default="SUJ-0001")
    p.add_argument("--busca", default="riesgo",
                   help="la capacidad que la tarea necesita (se compara con los tags)")
    # El segmento 2 tiene que poder enseñarse SOLO, sin depender de que el
    # modelo este levantado (CLAUDE.md §2). Con esto, descubrir y elegir son
    # una demo de diez segundos que no toca la GPU.
    p.add_argument("--solo-descubrir", action="store_true",
                   help="descubre y elige, pero no despacha (util para el segmento 2)")
    a = p.parse_args()

    # ---- 1. DESCUBRIR -----------------------------------------------------
    print("=" * 66)
    print("1. DESCUBRIR  — leyendo las Agent Cards")
    print("=" * 66)
    catalogo = {}
    for nombre, base in AGENTES.items():
        try:
            tarjeta = traer(f"{base}/.well-known/agent-card.json", espera=10)
        except Exception as e:
            print(f"  {nombre}: no responde ({type(e).__name__})")
            continue
        catalogo[nombre] = tarjeta
        for skill in tarjeta.get("skills", []):
            print(f"  {tarjeta['name']}")
            print(f"    sabe hacer : {skill['name']}")
            print(f"    tags       : {', '.join(skill.get('tags', []))}")
            print(f"    ruta       : {tarjeta['supportedInterfaces'][0]['url']}")

    if not catalogo:
        print("\nNingun agente responde. Levantalos primero (ver malla/README.md).")
        sys.exit(1)

    # ---- 2. ELEGIR --------------------------------------------------------
    print()
    print("=" * 66)
    print(f"2. ELEGIR  — la tarea necesita: '{a.busca}'")
    print("=" * 66)
    elegido = None
    for nombre, tarjeta in catalogo.items():
        for skill in tarjeta.get("skills", []):
            if a.busca in skill.get("tags", []):
                elegido = nombre
                print(f"  '{a.busca}' esta en los tags de {tarjeta['name']}  ->  elegido")
                break
        if elegido:
            break
    if not elegido:
        print(f"  Ningun agente declara '{a.busca}'. Nadie puede hacer esta tarea.")
        sys.exit(1)

    if a.solo_descubrir:
        print()
        print("=" * 66)
        print("Hasta aqui el segmento 2: nadie tenia la direccion de nadie.")
        print("El router la leyo de la tarjeta y eligio por capacidad.")
        print("=" * 66)
        return

    # ---- 3. DESPACHAR -----------------------------------------------------
    print()
    print("=" * 66)
    print(f"3. DESPACHAR  — A2A hacia {elegido}")
    print("=" * 66)
    tarea = (f"Revisa la alerta {a.alerta}, cuyo sujeto es {a.sujeto}. "
             f"Recoge evidencia y da tu postura.")
    peticion = {
        "jsonrpc": "2.0", "id": "router-1", "method": "message/send",
        "params": {"message": {"kind": "message", "role": "user",
                               "messageId": "m-router-1",
                               "parts": [{"kind": "text", "text": tarea}]}},
    }
    print(json.dumps(peticion, ensure_ascii=False, indent=2))
    print("\n  (esperando; el agente va a recoger evidencia y a consultar a su vecino)\n")

    respuesta = traer(f"{AGENTES[elegido]}/a2a", peticion)

    # ---- El resultado -----------------------------------------------------
    r = respuesta.get("result", {})
    texto = next((p["text"] for p in r.get("parts", []) if p.get("kind") == "text"), "")
    meta = r.get("metadata", {})

    print("=" * 66)
    print("LA DELIBERACION")
    print("=" * 66)
    print(texto)
    print()
    if meta.get("herramientas_usadas"):
        print("Evidencia que recogio el primer agente:")
        for h in meta["herramientas_usadas"]:
            print(f"  - {h['tool']}({h['args']})")
    if meta.get("consumo"):
        print()
        print("Consumo del primer agente:")
        for k, v in meta["consumo"].items():
            print(f"  {k:<20} {v}")
    print()
    print("=" * 66)
    print("El router eligio por CAPACIDAD, no por una URL escrita a mano.")
    print("Y los dos agentes hablaron entre ellos sin que el router mediara.")
    print("=" * 66)


if __name__ == "__main__":
    main()
