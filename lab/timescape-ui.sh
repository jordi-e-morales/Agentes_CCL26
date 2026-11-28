#!/usr/bin/env bash
#
# Abre la UI de Hubble Timescape para verla DESDE OTRA MAQUINA.
#
# QUE ES, Y EN QUE SE DIFERENCIA DE HUBBLE UI
# --------------------------------------------
# Hubble UI enseña lo que esta pasando AHORA: si nadie habla, no hay nada.
# Timescape guarda esos mismos flujos y deja preguntarle al PASADO.
#
# Eso cambia como se narra el segmento 3. Hoy, si la sala pregunta "¿y lo de
# hace cinco minutos?", la respuesta es volver a lanzar una deliberacion.
# Con Timescape se consulta.
#
# Es ademas lo que convierte el primer ⚠️ de PUNTOS-CLAVE.md §7 -lo que
# Isovalent añade sobre el Cilium de codigo abierto- de afirmacion en algo que
# se enseña.
#
# OJO CON LA VENTANA DE HISTORIA
# -------------------------------
# Esta montado SIN persistencia, porque la sesion son dos horas en tandas de
# 15 minutos. Dos consecuencias que hay que saber antes de prometer nada en
# vivo:
#
#   - La historia dura lo que diga el TTL (2h por omision en este repo).
#   - Si el pod se reinicia, se pierde TODA. No es un fallo: es la decision.
#
# Para que sobreviva a reinicios:
#   TS_PERSISTENCIA=si ./lab/isovalent-up.sh --con-timescape
#
# Uso:  ./lab/timescape-ui.sh       (se queda corriendo; Ctrl+C lo cierra)

set -uo pipefail

PUERTO=${PUERTO:-12002}
NS=${NS:-kube-system}

# NO HAY SERVICE DE UI APARTE, Y ESA ERA MI SUPOSICION EQUIVOCADA.
#
# Timescape expone TODO desde un solo Service, con los puertos nombrados:
#
#   push  4260    stream 4261   grpc 443
#   ui    8080    metrics 9090  ch-metrics 8001
#
# Y el pod lleva dos contenedores, clickhouse y timescape. Asi que buscar un
# servicio con "ui" en el NOMBRE no encuentra nada; hay que buscar el que
# tenga un PUERTO llamado "ui". Visto el 2026-11-27.
SVC=$(kubectl -n "$NS" get svc \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{range .spec.ports[*]}{.name}{" "}{end}{"\n"}{end}' \
  2>/dev/null | grep -i timescape | grep -w ui | awk '{print $1}' | head -1)

if [ -z "$SVC" ]; then
  echo ""
  echo "No encuentro un Service de Timescape con un puerto llamado 'ui' en $NS."
  echo ""
  echo "Lo que hay con 'timescape' en el nombre:"
  kubectl -n "$NS" get svc --no-headers 2>/dev/null | grep -i timescape | sed 's/^/  /' \
    || echo "  (nada: Timescape no esta instalado)"
  echo ""
  echo "Se instala con:  ./lab/isovalent-up.sh --con-timescape"
  echo ""
  exit 1
fi

# El puerto, por su nombre y no por su posicion: el orden puede cambiar entre
# versiones y acabarias con el puerto de metricas en el navegador.
PUERTO_SVC=$(kubectl -n "$NS" get svc "$SVC" \
  -o jsonpath='{.spec.ports[?(@.name=="ui")].port}' 2>/dev/null)
[ -z "$PUERTO_SVC" ] && PUERTO_SVC=8080

IP=$(hostname -I 2>/dev/null | awk '{print $1}')
TTL=$(kubectl -n "$NS" get cm cilium-config -o jsonpath='{.data.hubble-timescape-ttl}' 2>/dev/null)

echo ""
echo "=== Hubble Timescape: $NS/$SVC"
echo ""
echo "    Desde tu navegador:   http://${IP:-<ip-del-host>}:$PUERTO"
echo ""
echo "    Guarda la historia de flujos ${TTL:+durante $TTL}. A diferencia de"
echo "    Hubble UI, aqui se puede preguntar por lo que paso ANTES."
echo ""
echo "    SIN PERSISTENCIA: si el pod se reinicia, la historia se va entera."
echo "    Es la decision tomada para una sesion de dos horas, no un fallo."
echo ""
echo "    Si sale vacia y ya hubo trafico, mira el destino del exportador:"
echo "      kubectl -n $NS get cm cilium-config \\"
echo "        -o jsonpath='{.data.hubble-export-timescape-targets}'"
echo "      (verificado el 2026-11-27: hubble-timescape.kube-system.svc:4261)"
echo ""
echo "    Ctrl+C para cerrarlo."
echo ""

exec kubectl -n "$NS" port-forward --address 0.0.0.0 "svc/$SVC" "$PUERTO:$PUERTO_SVC"
