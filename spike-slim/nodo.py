#!/usr/bin/env python3
"""El nodo SLIM: el bus por el que se hablan los agentes.

Esto es el "data plane" de SLIM. Piensalo como una centralita: los agentes se
conectan a el, se dan de alta con un nombre, y a partir de ahi pueden abrir
sesiones entre ellos.

SORPRESA AGRADABLE: no hace falta contenedor. El propio paquete de Python
(slim-bindings) trae el nodo embebido, escrito en Rust. Un proceso de Python
levanta un bus completo. Eso hace que este spike se pueda probar en cualquier
maquina, sin GPU, sin Kubernetes y sin descargar nada grande.

Uso:
    .venv/bin/python -m spike_slim.nodo
    .venv/bin/python spike-slim/nodo.py --direccion 127.0.0.1:46357
"""

import argparse
import asyncio
from signal import SIGINT

import slim_bindings


async def amain(direccion: str):
    # slim_bindings esta escrito en Rust y expuesto a Python con uniffi. Hay
    # que decirle cual es el bucle de eventos de asyncio para que las llamadas
    # asincronas del lado Rust sepan donde devolver el control.
    slim_bindings.uniffi_set_event_loop(asyncio.get_running_loop())

    # Inicializa el estado global (trazas, runtime, servicio) con los valores
    # por omision. Para el spike sobra; cuando toque OpenTelemetry habra que
    # pasar configuracion explicita.
    slim_bindings.initialize_with_defaults()
    service = slim_bindings.get_global_service()

    # "insecure" = sin TLS. Es un valor de desarrollo, y esta bien en el lab,
    # pero OJO: si esto llega al demo hay que decir en pantalla que el
    # transporte va en claro. No afirmar que algo esta cifrado si no lo esta.
    server_config = slim_bindings.new_insecure_server_config(direccion)
    await service.run_server_async(server_config)

    print(f"Nodo SLIM escuchando en {direccion}")
    print("Ctrl+C para pararlo")

    parar = asyncio.Event()
    asyncio.get_running_loop().add_signal_handler(SIGINT, parar.set)
    await parar.wait()

    print("\nParando el nodo...")
    await service.shutdown_async()


def main():
    p = argparse.ArgumentParser(description="Nodo SLIM para el spike")
    p.add_argument(
        "--direccion",
        default="127.0.0.1:46357",
        help="host:puerto donde escucha el nodo (por omision 127.0.0.1:46357)",
    )
    args = p.parse_args()
    try:
        asyncio.run(amain(args.direccion))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
