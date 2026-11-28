"""
Las variables del modelo de riesgo, y UN SOLO sitio donde se calculan.

POR QUE ESTE ARCHIVO EXISTE APARTE
----------------------------------
Es el fallo mas comun de un sistema de ML en produccion: el entrenamiento
calcula una variable de una forma y la inferencia de otra. El modelo entonces
acierta en las pruebas y falla en vivo, y no hay nada en los logs que lo
confiese. Se llama training/serving skew.

Aqui no puede pasar porque hay una sola funcion, y la usan los dos:
`modelo/entrena.py` sobre datos sinteticos, y el agente de scoring sobre la
evidencia real que devuelven las herramientas.

LAS VARIABLES SON NEUTRALES AL DOMINIO, Y ESO NO ES ESTETICA
------------------------------------------------------------
El §7 del CLAUDE.md promete que un caso de SOC carga sin tocar codigo. En el
momento en que una variable se llame `monto` o `contraparte`, esa promesa se
rompe: un caso de SOC no tiene montos.

Por eso todas miden FORMA, no contenido:

  razon_umbral     lo observado dividido por el umbral de la regla. Para AML
                   es dinero contra un limite; para SOC, intentos contra un
                   limite. La razon significa lo mismo en los dos.
  eventos_ventana  cuantos eventos cayeron dentro de la ventana de la regla.
  regularidad      que tan parejos son los intervalos entre eventos. Un
                   proceso automatico es regular; una persona no. Sirve igual
                   para pagos que para conexiones.
  concentracion    que fraccion de los eventos es del tipo dominante.
  en_listas        aparece en alguna lista de control. 0 o 1.
  severidad_ord    la severidad que trae la alerta, como numero.
  antiguedad       dias desde que el sujeto existe, normalizado.

Ninguna menciona el dominio. Las mismas siete describen un lavado de dinero y
un movimiento lateral en una red.
"""

from __future__ import annotations

import statistics
from datetime import datetime, timezone

# El ORDEN IMPORTA y por eso esta escrito una sola vez: es el orden de las
# columnas con el que se entrena, y tiene que ser el mismo con el que se
# predice. Un modelo al que le cambias el orden de las columnas no falla: da
# numeros distintos, que es peor.
NOMBRES = [
    "razon_umbral",
    "eventos_ventana",
    "regularidad",
    "concentracion",
    "en_listas",
    "severidad_ord",
    "antiguedad",
]

# Como se le explica cada una a alguien que no sabe del dominio. Viaja con la
# respuesta del agente, para que la interfaz no tenga que saber de modelos.
EXPLICACION = {
    "razon_umbral":    "que tan cerca del umbral de la regla esta lo observado",
    "eventos_ventana": "cuantos eventos cayeron dentro de la ventana",
    "regularidad":     "que tan parejos son los intervalos entre eventos",
    "concentracion":   "que fraccion de los eventos es del tipo dominante",
    "en_listas":       "si el sujeto aparece en alguna lista de control",
    "severidad_ord":   "la severidad que trae la alerta",
    "antiguedad":      "que tan reciente es el sujeto",
}

SEVERIDADES = {"baja": 0.0, "media": 1.0, "alta": 2.0, "critica": 3.0}


def _momento(valor) -> datetime | None:
    """Acepta lo que devuelven las herramientas: texto ISO o datetime."""
    if isinstance(valor, datetime):
        return valor if valor.tzinfo else valor.replace(tzinfo=timezone.utc)
    if isinstance(valor, str):
        try:
            return datetime.fromisoformat(valor.replace("Z", "+00:00"))
        except ValueError:
            return None
    return None


def _regularidad(eventos: list[dict]) -> float:
    """
    0 = intervalos completamente irregulares, 1 = reloj suizo.

    Se mide con el coeficiente de variacion de los intervalos: desviacion
    dividida por media. Un proceso automatizado da un numero cercano a 0; la
    actividad humana, disperso. Se invierte y se acota para que "mas alto =
    mas sospechoso de automatizacion".

    Con menos de tres eventos no hay intervalos suficientes para decir nada,
    y devolver 0 seria afirmar "es irregular" sin saberlo. Se devuelve 0.5,
    que es la postura honesta: no se.
    """
    momentos = sorted(m for m in (_momento(e.get("momento")) for e in eventos) if m)
    if len(momentos) < 3:
        return 0.5
    huecos = [(b - a).total_seconds() for a, b in zip(momentos, momentos[1:])]
    huecos = [h for h in huecos if h > 0]
    if len(huecos) < 2:
        return 0.5
    media = statistics.fmean(huecos)
    if media <= 0:
        return 0.5
    cv = statistics.pstdev(huecos) / media
    return max(0.0, min(1.0, 1.0 - cv))


def _concentracion(eventos: list[dict]) -> float:
    if not eventos:
        return 0.0
    tipos: dict[str, int] = {}
    for e in eventos:
        t = str(e.get("tipo", "?"))
        tipos[t] = tipos.get(t, 0) + 1
    return max(tipos.values()) / len(eventos)


def extraer(alerta: dict, eventos: list[dict], listas: list,
            sujeto: dict | None = None) -> dict[str, float]:
    """
    De la evidencia a las siete variables.

    Los argumentos tienen la forma EXACTA que devuelven las herramientas MCP
    (`contexto_alerta`, `consulta_historial`, `lista_sancionados`,
    `perfil_sujeto`), para que el agente de scoring no tenga que traducir
    nada y la traduccion no pueda divergir.

    Todo lo que falte se trata como ausencia explicita, no como cero: un cero
    silencioso es una afirmacion que nadie hizo.
    """
    deteccion = alerta.get("deteccion") or alerta.get("atributos") or {}
    umbral   = deteccion.get("umbral") or {}
    observado = deteccion.get("observado") or {}

    # La razon se calcula sobre las claves que EXISTAN en los dos lados. Asi
    # un caso de SOC con {intentos: N} funciona igual que uno con otra clave,
    # sin que este archivo sepa como se llaman.
    razones = []
    for clave, lim in umbral.items():
        obs = observado.get(clave)
        try:
            lim_f, obs_f = float(lim), float(obs)
            if lim_f > 0:
                razones.append(obs_f / lim_f)
        except (TypeError, ValueError):
            continue
    razon = max(razones) if razones else 0.0

    sev = SEVERIDADES.get(str(alerta.get("severidad", "")).lower(), 1.0) / 3.0

    antiguedad = 0.5
    if sujeto:
        alta = _momento((sujeto.get("atributos") or {}).get("alta"))
        if alta:
            dias = (datetime.now(timezone.utc) - alta).days
            # Normalizado a dos años: mas alla de eso, "antiguo" es antiguo.
            antiguedad = max(0.0, min(1.0, dias / 730.0))

    return {
        "razon_umbral":    round(min(razon, 2.0), 4),
        "eventos_ventana": float(len(eventos)),
        "regularidad":     round(_regularidad(eventos), 4),
        "concentracion":   round(_concentracion(eventos), 4),
        "en_listas":       1.0 if listas else 0.0,
        "severidad_ord":   sev,
        "antiguedad":      round(antiguedad, 4),
    }


def como_vector(variables: dict[str, float]) -> list[float]:
    """En el orden de NOMBRES, siempre. Ver el comentario de NOMBRES."""
    return [float(variables.get(n, 0.0)) for n in NOMBRES]
