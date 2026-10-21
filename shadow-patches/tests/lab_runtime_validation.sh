#!/usr/bin/env bash
# ============================================================================
# LAB RUNTIME VALIDATION — ISS-003/009 V2
# ============================================================================
# Valida V2 contra un clúster PostgreSQL LOCAL EFÍMERO con el schema de producción
# (solo estructura, SIN datos). NO toca producción en ningún momento.
#
# Requisitos: postgresql@17 instalado (keg-only, sin servicio).
# Uso:
#   bash shadow-patches/tests/lab_runtime_validation.sh <socket_dir> <db_template>
#
# El clúster se arranca SOLO con socket unix (listen_addresses=''), sin puerto TCP,
# y debe apagarse al terminar con:  pg_ctl -D <datadir> -m fast stop
#
# Cómo se construyó el template (referencia):
#   pg_dump "$DATABASE_URL" --schema-only --schema=public --no-owner --no-privileges
#   (lectura pura; sin datos sensibles). Luego se adapta search_path='' -> 'public'
#   y se crean stubs de roles Supabase, schemas auth/vault/storage/cron/net y
#   extensiones unaccent/pg_trgm/pgcrypto.
# ============================================================================
set -uo pipefail
SOCK="${1:?uso: $0 <socket_dir> <db_template>}"
TPL="${2:?uso: $0 <socket_dir> <db_template>}"
PG="${PG_BIN:-/opt/homebrew/opt/postgresql@17/bin}"
R="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0

clone() { $PG/psql -h "$SOCK" -U postgres -d postgres -X -q \
          -c "DROP DATABASE IF EXISTS $1;" -c "CREATE DATABASE $1 TEMPLATE $TPL;" >/dev/null 2>&1; }
q()     { $PG/psql -h "$SOCK" -U postgres -d "$1" -X -A -t -c "$2"; }
ok()    { echo "  $1 = PASS"; }
ko()    { echo "  $1 = FAIL — $2"; fails=$((fails+1)); }

echo "== T1: V1 (RETIRED) debe fallar por incompatibilidad ordinal =="
clone t1
o=$($PG/psql -h "$SOCK" -U postgres -d t1 -X -v ON_ERROR_STOP=1 -f "$R/shadow-patches/deploy/deploy_iss003_009.sql" 2>&1)
s=$(q t1 "SELECT (SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='v_pick_canonico')||'/'||(SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='v_mejores_picks_mlb');")
if echo "$o" | grep -q 'cannot change name of view column' && [ "$s" = "43/22" ]; then ok T1; else ko T1 "estado=$s"; fi

echo "== T2: V2 debe aplicar con asserts A-I =="
clone t2
o=$($PG/psql -h "$SOCK" -U postgres -d t2 -X -v ON_ERROR_STOP=1 -f "$R/shadow-patches/deploy/deploy_iss003_009_v2.sql" 2>&1)
if echo "$o" | grep -q '^COMMIT'; then ok T2; else ko T2 "$(echo "$o"|grep ERROR|head -1)"; fi
echo "$o" | grep -E 'PASS_EMPTY_COVERAGE|ATENCION' | sed 's/^.*NOTICE:  /  ⚠ /'

echo "== T3: compatibilidad ordinal runtime =="
n=$(q t2 "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='v_mejores_picks_mlb' AND ((ordinal_position=15 AND column_name='nivel') OR (ordinal_position=23 AND column_name='economically_eligible') OR (ordinal_position=24 AND column_name='reason_code'));")
v=$(q t2 "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='v_pick_canonico' AND ordinal_position=44 AND column_name='es_pick_reason';")
if [ "$n" = "3" ] && [ "$v" = "1" ]; then ok T3; else ko T3 "vmm=$n vpc44=$v"; fi

echo "== T5: rollback primario semántico =="
o=$($PG/psql -h "$SOCK" -U postgres -d t2 -X -v ON_ERROR_STOP=1 -f "$R/shadow-patches/rollback/iss003_009_semantic_rollback.sql" 2>&1)
k=$(q t2 "SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='public' AND p.proname='analisis_completo' AND pg_get_functiondef(p.oid) LIKE '%economically_eligible%';")
if echo "$o" | grep -q '^COMMIT' && [ "$k" = "0" ]; then ok T5; else ko T5 "ac_key=$k"; fi

echo "== T6: re-apply V2 tras rollback (idempotencia) =="
o=$($PG/psql -h "$SOCK" -U postgres -d t2 -X -v ON_ERROR_STOP=1 -f "$R/shadow-patches/deploy/deploy_iss003_009_v2.sql" 2>&1)
if echo "$o" | grep -q '^COMMIT'; then ok T6; else ko T6 "$(echo "$o"|grep ERROR|head -1)"; fi

echo "== T7: assert FAIL debe revertir TODO =="
clone t7
tmp=$(mktemp)
sed 's/IF vmm_ncol<>24 THEN/IF vmm_ncol<>999 THEN/' "$R/shadow-patches/deploy/deploy_iss003_009_v2.sql" > "$tmp"
sed -i '' "s#\\\\ir ../iss003_009_mlb_governance_v2.sql#\\\\ir $R/shadow-patches/iss003_009_mlb_governance_v2.sql#" "$tmp" 2>/dev/null || \
  sed -i "s#\\\\ir ../iss003_009_mlb_governance_v2.sql#\\\\ir $R/shadow-patches/iss003_009_mlb_governance_v2.sql#" "$tmp"
b=$(q t7 "SELECT (SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='v_pick_canonico')||'|'||md5(pg_get_viewdef('public.v_mejores_picks_mlb'::regclass,true))||'|'||md5(pg_get_functiondef('public.analisis_completo(text)'::regprocedure));")
$PG/psql -h "$SOCK" -U postgres -d t7 -X -v ON_ERROR_STOP=1 -f "$tmp" >/dev/null 2>&1
a=$(q t7 "SELECT (SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='v_pick_canonico')||'|'||md5(pg_get_viewdef('public.v_mejores_picks_mlb'::regclass,true))||'|'||md5(pg_get_functiondef('public.analisis_completo(text)'::regprocedure));")
rm -f "$tmp"
if [ "$b" = "$a" ]; then ok T7; else ko T7 "estado parcial persistió"; fi

echo
echo "FAILS=$fails"
exit $fails
