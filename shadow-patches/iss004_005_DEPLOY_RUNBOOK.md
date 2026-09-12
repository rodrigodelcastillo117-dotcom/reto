# RUNBOOK DEPLOY — ISS-004/005 CADENA ECONÓMICA ÚNICA (SQL)

**Estado:** `PREDEPLOY_ISS004_005_GATE = PASS` · `DEPLOY_AUTHORIZATION = PENDING` (a la espera de GO explícito).
**NO EJECUTAR** hasta GO y en una ventana en que el usuario NO esté usando la app.
Parche fuente: `shadow-patches/iss004_005_cadena_economica_unica.sql`.
Frontend bypass: ya CERRADO fuera de este runbook (Lovable commit `5e814916`, build OK) — precondición, no se re-verifica en SQL.

Objetos que toca (5): `decision_pick_v1` (NUEVO), `kelly_fraccion_pct` (reescribe),
`v_pick_canonico` (replace ev_pct→EV_DECISION), `mejor_oportunidad_hoy` (reescribe),
`favoritos_bien_pagados` (reescribe), `v_super_pick` (replace kelly_pct_sugerido).
`v_pick_canonico` y `v_super_pick` son vistas MUY leídas → riesgo de lock. Por eso lock_timeout bajo + abortar rápido, sin reintentos ciegos.

---

## PASO 0 — SNAPSHOT ROLLBACK (read-only, sin locks; ANTES del deploy)

Capturar def viva + md5 de los 5 objetos a `shadow-patches/iss004_005_rollback_snapshot.sql`
(mismo patrón que ISS-006.2). Read-only, no toma locks de escritura:

```sql
SELECT 'FUNC '||p.proname AS obj, md5(pg_get_functiondef(p.oid)) AS fp, pg_get_functiondef(p.oid) AS def
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public' AND p.proname IN ('kelly_fraccion_pct','mejor_oportunidad_hoy','favoritos_bien_pagados')
UNION ALL
SELECT 'VIEW '||c.relname, md5(pg_get_viewdef(c.oid,true)), pg_get_viewdef(c.oid,true)
FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
WHERE n.nspname='public' AND c.relname IN ('v_pick_canonico','v_super_pick');
```

Guardar cada `def` como un `CREATE OR REPLACE ...` para poder revertir. `decision_pick_v1`
es NUEVO → su rollback es `DROP FUNCTION public.decision_pick_v1(text,text,text,text,numeric,numeric,numeric,numeric,jsonb);`.

**Drift check:** confirmar que los `needle` de los replace() siguen presentes en la def viva
(los DO-block ya abortan con `SUBSTR_NOT_FOUND` si no). Si algún md5 cambió respecto al dry-run,
RE-DERIVAR el needle antes de continuar.

---

## PASO 1 — DEPLOY ATÓMICO (una sola transacción)

Un solo `BEGIN … COMMIT`. `lock_timeout` bajo para **abortar rápido** si las vistas están
ocupadas; `statement_timeout` razonable. **Sin reintentos ciegos.** El contenido exacto
(Partes 1–6) es el de `iss004_005_cadena_economica_unica.sql`, precedido por:

```sql
BEGIN;
SET LOCAL lock_timeout      = '3s';   -- si no consigue el lock en 3s -> error -> ROLLBACK
SET LOCAL statement_timeout = '45s';  -- techo razonable por sentencia

--  … Parte 1: CREATE OR REPLACE FUNCTION decision_pick_v1(...) + REVOKE/GRANT
--  … Parte 2: CREATE OR REPLACE FUNCTION kelly_fraccion_pct(...)  (5 args)
--  … Parte 3: DO $vpc$  replace ev_pct→EV_DECISION en v_pick_canonico  (aborta si SUBSTR_NOT_FOUND)
--  … Parte 4: CREATE OR REPLACE FUNCTION mejor_oportunidad_hoy(...)
--  … Parte 5: CREATE OR REPLACE FUNCTION favoritos_bien_pagados(...)
--  … Parte 6: DO $sp$   replace kelly_pct_sugerido en v_super_pick  (aborta si SUBSTR_NOT_FOUND)

--  PASO 2 (POST-VERIFY) va aquí, ANTES del COMMIT.
COMMIT;
```

**Regla de lock contention:** si una sentencia falla con `55P03 lock_not_available`,
la transacción aborta sola (ROLLBACK). **No reintentar en automático.** Esperar a una
ventana más tranquila y re-ejecutar manualmente. Cero `COMMIT` parcial (todo en una txn).

---

## PASO 2 — POST-VERIFY (dentro de la misma transacción, antes del COMMIT)

Bloque `DO` que hace `RAISE EXCEPTION` (→ ROLLBACK total) si cualquier invariante falla.
Solo si todo pasa, el flujo llega al `COMMIT`:

```sql
DO $verify$
DECLARE
  v_bad int; v_auth int; v_espick int; v_apto int; v_fbp int;
  v_surf numeric; v_eng numeric;
BEGIN
  -- I1  EV_UI == EV_DECISION en TODAS las filas con precio (|dif| <= 0.1pp)
  SELECT count(*) INTO v_bad
    FROM public.v_pick_canonico v
   WHERE v.momio_mercado IS NOT NULL AND v.probabilidad_pct IS NOT NULL
     AND abs(v.ev_pct - (decision_economica_v1(v.probabilidad_pct, v.momio_mercado, v.mercado)->>'ev_pct')::numeric) > 0.1;
  IF v_bad > 0 THEN RAISE EXCEPTION 'POSTVERIFY_FAIL EV_UI<>EV_DECISION en % filas', v_bad; END IF;

  -- I2  P_DECISION única: la vista y el núcleo coinciden (muestra 1 fila)
  SELECT v.ev_pct, (decision_economica_v1(v.probabilidad_pct, v.momio_mercado, v.mercado)->>'ev_pct')::numeric
    INTO v_surf, v_eng
    FROM public.v_pick_canonico v
   WHERE v.momio_mercado IS NOT NULL AND v.probabilidad_pct IS NOT NULL LIMIT 1;
  IF v_surf IS DISTINCT FROM v_eng THEN RAISE EXCEPTION 'POSTVERIFY_FAIL P/EV no única'; END IF;

  -- I3  CURRENT_AUTHORIZED_MODELS = NONE
  SELECT count(*) INTO v_auth FROM public.economic_model_authority WHERE economic_authorized;
  IF v_auth <> 0 THEN RAISE EXCEPTION 'POSTVERIFY_FAIL authorized_models=%', v_auth; END IF;

  -- I4  economic picks siguen 0 en todas las superficies
  SELECT count(*) INTO v_espick FROM public.v_pick_canonico WHERE es_pick;
  SELECT count(*) INTO v_apto   FROM public.v_super_pick    WHERE apto_para_mostrar;
  SELECT count(*) INTO v_fbp    FROM public.favoritos_bien_pagados() WHERE fraccion > 0;
  IF v_espick <> 0 OR v_apto <> 0 OR v_fbp <> 0 THEN
    RAISE EXCEPTION 'POSTVERIFY_FAIL economic picks es_pick=% apto=% fbp=%', v_espick, v_apto, v_fbp;
  END IF;

  -- I5  frontend sin Kelly automático: precondición verificada fuera de banda
  --     (Lovable commit 5e814916, build OK). No verificable en SQL; se deja asentado aquí.
  RAISE NOTICE 'POSTVERIFY OK — listo para COMMIT';
END $verify$;
```

Nota sobre I1/I2 al desplegar: dentro de la txn ya está la vista nueva (ev_pct=EV_DECISION),
así que la comparación contra `decision_economica_v1` debe dar diferencia 0 salvo redondeo (≤0.1pp).

---

## PASO 3 — SMOKE POST-COMMIT (read-only)

- `authorized_models=0`, `es_pick=0`, `apto_para_mostrar=0`, `favoritos fraccion>0 = 0`.
- `decision_pick_v1` responde y su `ev_decision` == `decision_economica_v1.ev_pct` para inputs de prueba.
- Confirmar en la app (tú, navegador) que las tarjetas muestran EV coherente y `$0`/razón donde aplica.

## ROLLBACK (si POST-VERIFY falla o smoke sale mal)

1. Si el POST-VERIFY hizo `RAISE`, la txn ya revirtió: nada persistió. Diagnosticar y re-derivar.
2. Si ya se hizo COMMIT y algo sale mal después: aplicar `iss004_005_rollback_snapshot.sql`
   (CREATE OR REPLACE de las 5 defs previas) + `DROP FUNCTION decision_pick_v1(...)`, también
   en una sola transacción con lock_timeout bajo. Como `CURRENT_AUTHORIZED_MODELS=NONE`, el peor
   caso es cosmético (EV/fracción), nunca dinero movido.

---

## CHECKLIST DE CONDICIONES (todas cumplidas por este runbook)

- [x] una sola transacción
- [x] `lock_timeout` bajo (3s)
- [x] `statement_timeout` razonable (45s)
- [x] abortar si no consigue locks rápido (55P03 → ROLLBACK)
- [x] cero reintentos ciegos (esperar ventana, re-ejecutar manual)
- [x] snapshot rollback de todas las funciones/vistas (Paso 0)
- [x] POST-VERIFY: EV_UI==EV_DECISION · P_DECISION única · authorized=NONE · economic picks=0 · frontend sin Kelly (out-of-band)
- [x] lock contention → ROLLBACK y esperar, no insistir

`DEPLOY_AUTHORIZATION = PENDING` — no ejecutar sin nuevo GO.
