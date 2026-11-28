"""
Entrena el modelo de riesgo. scikit-learn de verdad, no un if disfrazado.

QUE ES Y QUE NO ES
------------------
Es una regresion logistica sobre siete variables neutrales al dominio
(modelo/variables.py), entrenada con datos SINTETICOS etiquetados por
construccion. El §8 del CLAUDE.md prohibe el codigo de simulacion: aqui no se
simula nada, se entrena de verdad y se mide de verdad. Lo sintetico son los
datos, y eso se dice en pantalla -igual que el resto de la evidencia del
proyecto-.

POR QUE REGRESION LOGISTICA Y NO ALGO MAS POTENTE
--------------------------------------------------
Porque la sesion trata de explicabilidad, y aqui la explicacion es EXACTA, no
aproximada: la contribucion de cada variable es su coeficiente por su valor
estandarizado. Sumadas dan el log-odds. No hace falta SHAP ni ninguna
aproximacion posterior, que es justo lo que uno tiene que anadir cuando eligio
un modelo que no se puede leer.

Un bosque aleatorio daria quiza mejor AUC sobre estos datos y una explicacion
peor. Para lo que tiene que demostrar esta sesion, eso es el intercambio
equivocado.

Y conecta con el meta-argumento del §6: cada capa de abstraccion que agregas
te quita visibilidad. Tambien vale para los modelos.

LAS METRICAS VAN A SPLUNK COMO TRAZA, Y HAY QUE DECIR POR QUE
--------------------------------------------------------------
Splunk Observability no tiene un registro de experimentos tipo MLflow. Asi que
el entrenamiento se emite como una traza: un span raiz con las metricas como
atributos. No es un sustituto de MLflow y no se va a presentar como tal; es
lo que de verdad se puede hacer, que es la regla del §6.

Uso:
  python modelo/entrena.py
  python modelo/entrena.py --n 8000 --semilla 7
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import (average_precision_score, confusion_matrix,
                             f1_score, precision_score, recall_score,
                             roc_auc_score)
from sklearn.model_selection import train_test_split
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import StandardScaler

AQUI = Path(__file__).resolve().parent
sys.path.insert(0, str(AQUI))
import variables as V  # noqa: E402

DESTINO = AQUI / "riesgo.joblib"
VERSION = "1.0.0"


# ---------------------------------------------------------------------------
# Los datos.
#
# Se generan como EVIDENCIA -alertas, eventos, listas- y despues se pasan por
# el MISMO extractor que usa el agente en vivo. Es deliberado: si generase
# vectores de variables directamente, el entrenamiento y la inferencia
# podrian divergir sin que nada avisara. Ver la cabecera de variables.py.
# ---------------------------------------------------------------------------
def _caso(rng: np.random.Generator, r: float) -> tuple[dict, list, list, dict]:
    """
    Genera la evidencia de un caso a partir de un RIESGO LATENTE r en [0,1].

    POR QUE ASI Y NO CON DOS POBLACIONES SEPARADAS
    ----------------------------------------------
    La primera version generaba "riesgosos" y "normales" como dos grupos
    distintos. El modelo sacaba AUC 0.9998, y eso es un problema disfrazado
    de exito por dos motivos:

      1. Cualquiera en la sala que sepa de ML ve un 0.9998 sobre datos
         sinteticos y concluye, con razon, que el problema estaba amañado.
      2. Rompe la demo. Si el modelo acierta siempre, no hay nada que
         discutir entre el numero y la explicacion del defensor -que es
         justo el debate que queremos enseñar-.

    Ahora hay UN riesgo latente, y las siete variables son indicadores
    RUIDOSOS de el. La etiqueta la decide el latente, no las variables. Eso
    deja un error de Bayes mayor que cero: ni el mejor modelo posible puede
    acertar siempre, que es como son los problemas de verdad.

    `dias_alta` se genera a proposito SIN relacion con r. Es una variable
    inutil metida adrede: el modelo tiene que aprender a ignorarla, y que su
    coeficiente salga casi cero es una comprobacion de que el entrenamiento
    hace lo que decimos que hace.
    """
    ahora = datetime.now(timezone.utc)

    # Cuantos eventos: mas riesgo, mas actividad, pero con cola larga.
    n = int(np.clip(rng.poisson(2.5 + 7.5 * r), 1, 14))

    # Lo observado contra el umbral. El ruido es grande a proposito: un caso
    # normal puede rozar el umbral y uno riesgoso quedarse corto.
    razon = float(np.clip(rng.normal(0.38 + 0.62 * r, 0.24), 0.0, 1.9))

    # Ritmo. Mas riesgo = intervalos mas cortos y mas parejos.
    hueco_dias = max(0.3, float(rng.normal(10.0 - 7.0 * r, 3.4)))
    dispersion = float(abs(rng.normal(0.85 - 0.65 * r, 0.32)))

    # Tipo de evento: mas riesgo, mas monotono.
    p_dominante = float(np.clip(0.45 + 0.5 * r, 0.3, 0.98))
    tipos = ["actividad" if rng.random() < p_dominante
             else str(rng.choice(["cambio", "contacto"])) for _ in range(n)]

    sev = rng.choice(["baja", "media", "alta", "critica"],
                     p=np.array([0.40 - 0.30 * r, 0.35, 0.18 + 0.19 * r,
                                 0.07 + 0.11 * r]).clip(0.01, None)
                       / np.array([0.40 - 0.30 * r, 0.35, 0.18 + 0.19 * r,
                                   0.07 + 0.11 * r]).clip(0.01, None).sum())
    en_lista = rng.random() < (0.03 + 0.18 * r)

    # SIN relacion con r. Ver la nota de arriba.
    dias_alta = int(rng.integers(1, 1500))

    momento = ahora
    eventos = []
    for t in tipos:
        salto = max(0.05, hueco_dias * (1.0 + rng.normal(0, dispersion)))
        momento = momento - timedelta(days=salto)
        eventos.append({"momento": momento.isoformat(), "tipo": t})

    limite = 90000.0
    alerta = {
        "severidad": str(sev),
        "deteccion": {
            "umbral":    {"acumulado": limite},
            "observado": {"acumulado": round(razon * limite, 2)},
        },
    }
    listas = [{"nombre": "control"}] if en_lista else []
    sujeto = {"atributos": {"alta": (ahora - timedelta(days=dias_alta)).isoformat()}}
    return alerta, eventos, listas, sujeto


def construir(n: int, semilla: int) -> tuple[np.ndarray, np.ndarray]:
    rng = np.random.default_rng(semilla)
    X, y = [], []
    for _ in range(n):
        # El riesgo latente, sesgado hacia abajo: la mayoria de las alertas
        # no son nada, como en la realidad. Beta(2,4) deja ~20% por encima
        # del corte, asi que el conjunto queda desbalanceado sin tener que
        # forzarlo con una proporcion fija.
        r = float(rng.beta(2.0, 4.0))
        X.append(V.como_vector(V.extraer(*_caso(rng, r))))
        # La etiqueta la decide el LATENTE, no las variables observadas. De
        # ahi sale el solapamiento: dos casos con variables parecidas pueden
        # tener etiquetas distintas, y ningun modelo puede separarlos.
        y.append(1 if r > 0.52 else 0)
    return np.asarray(X, dtype=float), np.asarray(y, dtype=int)


def _traza(metricas: dict, coef: dict, n: int) -> None:
    """
    Emite el entrenamiento como una traza. Best effort: si no hay Collector,
    no pasa nada y no se interrumpe el entrenamiento por observabilidad.
    """
    if not os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
        print("  (sin OTEL_EXPORTER_OTLP_ENDPOINT: no se emite traza)")
        return
    try:
        sys.path.insert(0, str(AQUI.parent))
        from observabilidad import trazas  # noqa
        tr = trazas.tracer("entrenamiento-riesgo")
        with tr.start_as_current_span("train_model modelo_riesgo") as s:
            s.set_attribute("ml.model.name", "riesgo")
            s.set_attribute("ml.model.version", VERSION)
            s.set_attribute("ml.model.algorithm", "logistic_regression")
            s.set_attribute("ml.dataset.size", n)
            for k, v in metricas.items():
                s.set_attribute(f"ml.metric.{k}", float(v))
            for k, v in coef.items():
                s.set_attribute(f"ml.coef.{k}", float(v))
        print("  traza emitida")
    except Exception as e:
        print(f"  (no se pudo emitir la traza: {type(e).__name__}: {e})")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=4000)
    ap.add_argument("--semilla", type=int, default=20261127)
    args = ap.parse_args()

    print(f"\n=== Datos sinteticos: {args.n} casos, semilla {args.semilla}")
    X, y = construir(args.n, args.semilla)
    print(f"  positivos: {int(y.sum())} ({y.mean():.1%})")

    X_tr, X_te, y_tr, y_te = train_test_split(
        X, y, test_size=0.25, random_state=args.semilla, stratify=y)

    print("\n=== Entrenando")
    modelo = Pipeline([
        ("escala", StandardScaler()),
        # class_weight balanced: con 22% de positivos, sin esto el modelo
        # aprende que decir "no" casi siempre ya acierta el 78% de las veces.
        ("lr", LogisticRegression(max_iter=1000, class_weight="balanced")),
    ])
    modelo.fit(X_tr, y_tr)

    p = modelo.predict_proba(X_te)[:, 1]
    pred = (p >= 0.5).astype(int)
    metricas = {
        "auc":       roc_auc_score(y_te, p),
        "pr_auc":    average_precision_score(y_te, p),
        "precision": precision_score(y_te, pred, zero_division=0),
        "recall":    recall_score(y_te, pred, zero_division=0),
        "f1":        f1_score(y_te, pred, zero_division=0),
    }
    tn, fp, fn, tp = confusion_matrix(y_te, pred).ravel()

    print(f"\n=== Metricas (sobre {len(y_te)} casos que NO vio)")
    for k, v in metricas.items():
        print(f"  {k:<10} {v:.4f}")
    print(f"  aciertos  {tp} de {tp+fn} riesgosos, {tn} de {tn+fp} normales")
    print(f"  falsos    {fp} positivos, {fn} negativos")

    lr = modelo.named_steps["lr"]
    coef = {n: float(c) for n, c in zip(V.NOMBRES, lr.coef_[0])}
    print("\n=== Lo que aprendio (coeficiente estandarizado)")
    for n, c in sorted(coef.items(), key=lambda kv: -abs(kv[1])):
        print(f"  {c:+.4f}  {n:<16} {V.EXPLICACION[n]}")

    import joblib
    joblib.dump({
        "modelo":    modelo,
        "version":   VERSION,
        "nombres":   V.NOMBRES,
        "metricas":  metricas,
        "coef":      coef,
        "entrenado": datetime.now(timezone.utc).isoformat(),
        "n":         args.n,
        "semilla":   args.semilla,
        "sintetico": True,
    }, DESTINO)
    print(f"\n=== Guardado en {DESTINO}")

    print("\n=== Traza")
    _traza(metricas, coef, args.n)

    print(json.dumps({"version": VERSION, **{k: round(v, 4) for k, v in metricas.items()}}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
