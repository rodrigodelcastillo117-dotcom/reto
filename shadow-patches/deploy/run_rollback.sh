#!/usr/bin/env bash
# ============================================================================
# RUNNER TURNKEY — ROLLBACK ISS-003/009/009B
# PRIMARIO  : SEMANTIC (NO CASCADE) — restaura comportamiento, preserva disponibilidad.
# SECUNDARIO: STRUCTURAL (DROP CASCADE) — solo offline, con --structural. Cascade auditado
#             exhaustivo: CASCADE_DROPPED_SET == ROLLBACK_RECREATED_SET (3 vistas), FULL_STRUCTURAL_ROLLBACK=SAFE.
# Uso (desde la raíz del repo, con DATABASE_URL a PROD):
#   bash shadow-patches/deploy/run_rollback.sh              # semantic (recomendado)
#   bash shadow-patches/deploy/run_rollback.sh --structural # structural cascade (offline)
# Solo ante fallo crítico POST-COMMIT. Un fallo DENTRO del deploy ya revierte solo.
# ============================================================================
set -euo pipefail

SEMANTIC_SHA="ef3de33f42258fbf0b63074418f2a5560006352e3a58db6cc6089166052fac0b"
STRUCTURAL_SHA="32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530"
SEMANTIC="shadow-patches/rollback/iss003_009_semantic_rollback.sql"
STRUCTURAL="shadow-patches/rollback/iss003_009_rollback.sql"

MODE="semantic"; FILE="$SEMANTIC"; EXPECT="$SEMANTIC_SHA"
if [ "${1:-}" = "--structural" ]; then MODE="structural"; FILE="$STRUCTURAL"; EXPECT="$STRUCTURAL_SHA"; fi

: "${DATABASE_URL:?ABORT: exporta DATABASE_URL (conexión a PROD) antes de correr}"
[ -f "$FILE" ] || { echo "ABORT: falta $FILE"; exit 1; }

cur="$(sha256sum "$FILE" | awk '{print $1}')"
if [ "$cur" != "$EXPECT" ]; then
  echo "ROLLBACK SHA_DRIFT=YES  ($MODE) actual=$cur esperado=$EXPECT"
  echo "ABORT: artefacto de rollback no verificable."; exit 2
fi
echo "ROLLBACK MODE=$MODE  SHA OK. Restaurando (una transacción)..."

if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$FILE"; then
  echo "ROLLBACK=APPLIED  mode=$MODE"
  [ "$MODE" = "semantic" ] && echo "  (comportamiento previo restaurado; cols aditivas quedan inertes; sin DROP/CASCADE; disponibilidad preservada)"
  exit 0
else
  echo "ROLLBACK=FAILED  mode=$MODE  (revisa el error; puede requerir intervención manual)"
  exit 3
fi
