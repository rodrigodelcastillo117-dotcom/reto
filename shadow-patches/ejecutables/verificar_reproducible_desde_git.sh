#!/usr/bin/env bash
# =====================================================================
# verificar_reproducible_desde_git.sh
#   Responde UNA pregunta: se puede reconstruir la ruta de decision
#   leyendo SOLO este repositorio, sin leer una definicion de produccion?
#
#   El dueno lo planteo asi, textual:
#     "No aceptare un clean bootstrap mientras para reconstruir el sistema
#      haga falta leer una definicion preexistente de produccion."
#
#   Este script NO se conecta a la base. Eso es a proposito: si necesitara
#   la base para responder, la respuesta ya seria no.
# =====================================================================
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

# Cierre transitivo de la ruta de decision, medido por pg_depend el 2026-09-12
# desde las raices v_pick_canonico, v_super_pick, v_reto13m_lo_mejor y
# v_reto13m_mejores. 14 vistas.
VISTAS=(
  calibracion_mercado
  picks_recomendados_hoy
  picks_recomendados_hoy_raw
  v_evento_hora
  v_mejor_pick_por_partido
  v_momios_confiables
  v_pick_canonico
  v_pick_momio_libro
  v_picks_futbol_calibrado
  v_picks_mlb_modelo
  v_radar_odds_fase
  v_reto13m_lo_mejor
  v_reto13m_mejores
  v_super_pick
)

falta=0; parche=0; completo=0
echo "=== REPRODUCIBLE_FROM_GIT: ruta de decision, 14 vistas ==="
for v in "${VISTAS[@]}"; do
  # Definicion COMPLETA: un create ... as ESTATICO en el archivo.
  #   Se excluyen a proposito las lineas donde el create vive DENTRO de una
  #   cadena que se concatena con una definicion leida de la base, del tipo
  #     execute 'create or replace view X as ' || replace(v, a, b)
  #   Eso no es una definicion: es un parche sobre produccion. La primera
  #   version de este script las contaba como completas y daba una respuesta
  #   falsamente generosa justo en v_super_pick.
  full=$(grep -rlE "^[[:space:]]*create (or replace )?(materialized )?view (public\.)?${v}\b[[:space:]]*as[[:space:]]*$" \
           --include="*.sql" . 2>/dev/null | grep -v '/\.git/' | head -3 | tr '\n' ' ')
  if [ -z "$full" ]; then
    # tambien vale si el create y el select abren en la misma linea, siempre
    # que la linea NO sea un execute ni una concatenacion de cadena
    full=$(grep -rlE "^[[:space:]]*create (or replace )?(materialized )?view (public\.)?${v}\b[[:space:]]*as[[:space:]]+(select|with|[(])" \
             --include="*.sql" . 2>/dev/null | grep -v '/\.git/' | head -3 | tr '\n' ' ')
  fi
  # Parche sobre produccion: arma el DDL leyendo pg_get_viewdef de la base.
  patch=$(grep -rlE "pg_get_viewdef\('?(public\.)?${v}'?" \
           --include="*.sql" . 2>/dev/null | grep -v '/\.git/' | head -3 | tr '\n' ' ')

  if [ -n "$full" ]; then
    if [ -n "$patch" ]; then
      echo "  PARCHE+BASE  $v"
      echo "               base:   $full"
      echo "               parche: $patch"
      parche=$((parche+1))
    else
      echo "  COMPLETO     $v   <- $full"
      completo=$((completo+1))
    fi
  else
    if [ -n "$patch" ]; then
      echo "  SOLO PARCHE  $v   <- $patch   (lee la definicion de PRODUCCION)"
    else
      echo "  FALTA        $v   (no existe en Git de ninguna forma)"
    fi
    falta=$((falta+1))
  fi
done

echo
echo "  definicion completa en Git .......... $completo"
echo "  completa pero ademas parchada ....... $parche"
echo "  sin definicion completa ............. $falta"
echo
if [ "$falta" -gt 0 ]; then
  echo "RESULTADO: REPRODUCIBLE_FROM_GIT = NO."
  echo "  Faltan $falta vistas del cierre de decision. El clean bootstrap NO se"
  echo "  puede declarar: reconstruir el sistema todavia exige leer produccion."
  exit 1
fi
if [ "$parche" -gt 0 ]; then
  echo "RESULTADO: REPRODUCIBLE_FROM_GIT = SI, CON ORDEN OBLIGATORIO."
  echo "  $parche vistas tienen base completa Y un parche que lee pg_get_viewdef."
  echo "  Eso funciona SOLO si el baseline corre antes que el parche: ahi el"
  echo "  parche lee una definicion que el propio bootstrap acaba de crear, no"
  echo "  una preexistente de produccion. El orden es parte del contrato."
  exit 0
fi
echo "RESULTADO: REPRODUCIBLE_FROM_GIT = SI, SIN PARCHES SOBRE PRODUCCION."
