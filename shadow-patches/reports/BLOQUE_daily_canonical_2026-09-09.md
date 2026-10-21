# DAILY PICK CANÓNICO — reemplazo staged de v_reto13m_daily (§24, STOP-SHIP 5606928639)

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON
artefacto: `shadow-patches/prepared/iss036_daily_canonical_selector.sql` · `STAGED_NOT_EXECUTED`

## Contaminación confirmada (pg_get_viewdef de public.v_reto13m_daily, 2026-09-09)
1. `btts_no := CASE WHEN btts_yes IS NOT NULL THEN 100 - btts_yes END` — **complemento
   derivado**, no del mismo snapshot conjunto. Viola §16/N.
2. Candidato `('Over 2.5 goles', (markets->>'over25'))` — etiqueta "Over 2.5" usando
   `markets.over25` **sin mirar la línea real del proveedor** → ofrece Over 2.5 cuando
   la línea real es 3.5 (prueba del auditor: Vancouver, Atlanta, Portland MLS hoy).
   Viola §15/§18. STOP-SHIP.
3. Set de candidatos + umbrales (`prob >= 45 and <= 83.3`) hardcodeados en la vista.

## Reemplazo staged (iss036)
`v2.v_soccer_daily_candidates` + `v2.v_soccer_daily_canonical` sobre la superficie
canónica `v2.soccer_prediction_v2_staged` (iss033):
- Candidatos: 1X2 (HOME/DRAW/AWAY), BTTS YES + **BTTS NO explícito del MISMO snapshot**
  (no `100-yes`), y O/U **sólo a la línea real** `over_line` (p_over/p_under de esa
  línea; si `over_line` es null no hay candidato O/U). La etiqueta lleva
  `canonical_line`, nunca "2.5" fijo.
- **NO recalcula probabilidad**: `canonical_probability` = valor canónico tal cual.
- Ranking: `row_number()` por probabilidad canónica (+ muestra, kickoff). Pick del Día =
  `rank_dia = 1`. Sólo eventos `model_status='READY_UNVALIDATED'` (fail-closed).
- Contrato de salida (§24): `canonical_event_id, canonical_market, canonical_side,
  canonical_line, canonical_probability, model_snapshot_id, rank_dia`.

## Invariante anti-regresión (a validar en branch)
`DAILY_NO_FIXED_LINE_GATE`: para toda fila O/U del daily, `canonical_line = over_line`
del proveedor para ese evento (no existe fila O/U con línea distinta a la real). Y no
existe fila BTTS NO cuyo valor sea `100 - btts_yes` reconstruido (proviene de la columna
`btts_no` del snapshot). STAGED — depende de deploy de iss033 + iss036 en branch.

## Estado
`DAILY_NO_FIXED_LINE_GATE = STAGED_ONLY` (reemplazo listo; prod sigue con v_reto13m_daily
contaminada hasta cutover). ChatGPT ya protege el frontend Remix para ignorar
v_reto13m_daily como autoridad. No prod mutation.
