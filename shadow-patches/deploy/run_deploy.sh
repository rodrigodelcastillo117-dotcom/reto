#!/usr/bin/env bash
# ============================================================================
# RUNNER TURNKEY — DEPLOY ISS-003/009/009B (verifica SHA -> aborta drift -> deploy atómico)
# Uso (desde la raíz del repo, con DATABASE_URL exportado a PROD):
#   export DATABASE_URL="postgresql://...@db.<ref>.supabase.co:5432/postgres"
#   bash shadow-patches/deploy/run_deploy.sh
# NO toca producción si SHA_DRIFT. Corre asserts A-G (PASS por invariante); FAIL -> ROLLBACK total.
# ============================================================================
set -euo pipefail

REVIEWED_SHA="57b7a4077247e5e814aa9e4ce7e0ad369dc11975a8bff7ea28083c3ffedd4cad"
ROLLBACK_SHA="32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530"
ART="shadow-patches/iss003_009_mlb_governance.sql"
RB="shadow-patches/rollback/iss003_009_rollback.sql"
DEPLOY="shadow-patches/deploy/deploy_iss003_009.sql"

: "${DATABASE_URL:?ABORT: exporta DATABASE_URL (conexión a PROD) antes de correr}"
for f in "$ART" "$RB" "$DEPLOY"; do [ -f "$f" ] || { echo "ABORT: falta $f"; exit 1; }; done

cur_art="$(sha256sum "$ART" | awk '{print $1}')"
cur_rb="$(sha256sum "$RB"  | awk '{print $1}')"

if [ "$cur_art" != "$REVIEWED_SHA" ]; then
  echo "SHA_DRIFT=YES  artefacto=$cur_art  esperado=$REVIEWED_SHA"
  echo "ABORT: no se toca producción."; exit 2
fi
if [ "$cur_rb" != "$ROLLBACK_SHA" ]; then
  echo "SHA_DRIFT=YES  rollback=$cur_rb  esperado=$ROLLBACK_SHA"
  echo "ABORT: rollback no verificable, no se despliega."; exit 2
fi
echo "SHA_DRIFT=NO  (artefacto y rollback congelados OK)"
echo "Aplicando deploy atómico (una transacción; PASS por invariante; FAIL -> ROLLBACK)..."

if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$DEPLOY"; then
  echo "DEPLOY=APPLIED  (todos los asserts PASS; COMMIT hecho)"
  echo "Siguiente: psql \"\$DATABASE_URL\" -f shadow-patches/deploy/smoke_post_commit.sql"
  exit 0
else
  echo "DEPLOY=ABORTED  (algún assert FAIL -> ROLLBACK automático; nada quedó aplicado)"
  echo "Revisa el 'FAIL ...' arriba. Producción quedó en su estado previo."
  exit 3
fi
