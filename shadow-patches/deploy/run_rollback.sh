#!/usr/bin/env bash
# ============================================================================
# RUNNER TURNKEY — ROLLBACK ISS-003/009/009B (verifica SHA -> restaura defs PRE-DEPLOY)
# Uso (desde la raíz del repo, con DATABASE_URL exportado a PROD):
#   bash shadow-patches/deploy/run_rollback.sh
# Solo ante fallo crítico POST-COMMIT. Usa el artefacto de rollback congelado.
# ============================================================================
set -euo pipefail

ROLLBACK_SHA="32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530"
RB="shadow-patches/rollback/iss003_009_rollback.sql"

: "${DATABASE_URL:?ABORT: exporta DATABASE_URL (conexión a PROD) antes de correr}"
[ -f "$RB" ] || { echo "ABORT: falta $RB"; exit 1; }

cur="$(sha256sum "$RB" | awk '{print $1}')"
if [ "$cur" != "$ROLLBACK_SHA" ]; then
  echo "ROLLBACK SHA_DRIFT=YES  actual=$cur  esperado=$ROLLBACK_SHA"
  echo "ABORT: artefacto de rollback no verificable."; exit 2
fi
echo "ROLLBACK SHA OK. Restaurando defs PRE-DEPLOY (una transacción)..."

if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$RB"; then
  echo "ROLLBACK=APPLIED  (analisis_completo -> v_mejores_picks_mlb -> v_pick_canonico + subárbol + grants)"
  exit 0
else
  echo "ROLLBACK=FAILED  (revisa el error; producción puede requerir intervención manual)"
  exit 3
fi
