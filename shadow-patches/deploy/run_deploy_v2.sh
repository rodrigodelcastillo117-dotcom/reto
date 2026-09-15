#!/usr/bin/env bash
# ============================================================================
# RUNNER TURNKEY V2 — DEPLOY ISS-003/009/009B
# Sustituye a run_deploy.sh (V1 RETIRED por defecto posicional).
# Uso (desde la raíz del repo, con DATABASE_URL exportado a PROD):
#   bash shadow-patches/deploy/run_deploy_v2.sh
# NO toca producción si SHA_DRIFT. Asserts A-I; FAIL -> ROLLBACK total.
# ============================================================================
set -euo pipefail

REVIEWED_SHA="15642eb149c065fb4cbd21c9c918cbe145f90064ee5975b4721ca38eaeb4be52"
ROLLBACK_SEMANTIC_SHA="ef3de33f42258fbf0b63074418f2a5560006352e3a58db6cc6089166052fac0b"
ROLLBACK_STRUCTURAL_SHA="32656fb3560261c6f2eae1bf5a25e5bd2eb4b34e93844d82531f978ff0aa3530"
ART="shadow-patches/iss003_009_mlb_governance_v2.sql"
RB_SEM="shadow-patches/rollback/iss003_009_semantic_rollback.sql"
RB_STR="shadow-patches/rollback/iss003_009_rollback.sql"
DEPLOY="shadow-patches/deploy/deploy_iss003_009_v2.sql"

# sha256 portable (Linux: sha256sum; macOS sin coreutils: shasum -a 256)
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

: "${DATABASE_URL:?ABORT: exporta DATABASE_URL (conexión a PROD) antes de correr}"
for f in "$ART" "$RB_SEM" "$RB_STR" "$DEPLOY"; do
  [ -f "$f" ] || { echo "ABORT: falta $f"; exit 1; }
done

cur_art="$(sha256 "$ART")"
cur_sem="$(sha256 "$RB_SEM")"
cur_str="$(sha256 "$RB_STR")"

if [ "$cur_art" != "$REVIEWED_SHA" ]; then
  echo "SHA_DRIFT=YES  artefacto=$cur_art  esperado=$REVIEWED_SHA"
  echo "ABORT: no se toca producción."; exit 2
fi
if [ "$cur_sem" != "$ROLLBACK_SEMANTIC_SHA" ]; then
  echo "SHA_DRIFT=YES  rollback_semantico=$cur_sem  esperado=$ROLLBACK_SEMANTIC_SHA"
  echo "ABORT: rollback PRIMARIO no verificable, no se despliega."; exit 2
fi
if [ "$cur_str" != "$ROLLBACK_STRUCTURAL_SHA" ]; then
  echo "SHA_DRIFT=YES  rollback_estructural=$cur_str  esperado=$ROLLBACK_STRUCTURAL_SHA"
  echo "ABORT: rollback secundario no verificable, no se despliega."; exit 2
fi
echo "SHA_DRIFT=NO  (artefacto V2 + ambos rollbacks congelados OK)"

# PREFLIGHT read-only con guard EXPLICITO (el pooler de Supabase ignora PGOPTIONS)
echo "Preflight read-only (BEGIN READ ONLY con guard verificado)..."
guard="$(psql "$DATABASE_URL" -X -q -A -t -v ON_ERROR_STOP=1 \
  -c "BEGIN READ ONLY; SELECT current_setting('transaction_read_only');" 2>&1 | tail -1)"
if [ "$guard" != "on" ]; then
  echo "ABORT: guard read-only no verificable (transaction_read_only=$guard)"; exit 4
fi
echo "PROD_READONLY_GUARD=on"

echo "Aplicando deploy atómico V2 (una transacción; FAIL -> ROLLBACK)..."
if psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f "$DEPLOY"; then
  echo "DEPLOY=APPLIED  (asserts A-I PASS; COMMIT hecho)"
  echo "Revisa arriba si algun assert quedo como PASS_EMPTY_COVERAGE."
  echo "Siguiente: psql \"\$DATABASE_URL\" -f shadow-patches/deploy/smoke_post_commit.sql"
  exit 0
else
  echo "DEPLOY=ABORTED  (algun assert FAIL -> ROLLBACK automatico; nada quedo aplicado)"
  echo "Rollback primario (solo si hiciera falta): shadow-patches/rollback/iss003_009_semantic_rollback.sql"
  exit 3
fi
