# PASS 6 — Performance / read-path de artefactos SOCCER (§33) · recomendaciones STAGED

repo: `reto` · branch: `claude/reto-13m-espn-matches-3uknie` · PROD_FREEZE=ON
**No se crean índices en prod** (§33). Sólo recomendaciones.

## Índices existentes relevantes (verificado)
`historico_partidos_espn`: pk(espn_event_id); (home_espn_id,fecha[/DESC]); (away_espn_id,fecha[/DESC]);
(espn_endpoint,fecha); parciales MLB. `agenda_espn`: pk; (home,away,fecha); (fecha).

## Análisis del builder as-of (iss033) e daily (iss036)
- `fn_soccer_features_asof`: filtra `home_espn_id=? AND liga_id=? AND fecha<? AND fecha>=?`.
  Usa `idx_hpe_home (home_espn_id, fecha)`; `liga_id` queda como recheck. Selectividad de
  un equipo es alta → **adecuado** (no N+1: es lateral set-based sobre la agenda).
- League means / base-rates: filtran `liga_id=? AND fecha<?`. **No hay índice (liga_id,fecha)**
  → agregado por liga puede recorrer más filas de lo necesario. Con 241 eventos × 3 subqueries
  de liga es el mayor costo del walk-forward/builder.
- `iss036` daily: `cross join lateral (7 valores)` por evento + 2 window functions
  (best_per_event, rank_dia). Barato; sin cartesian, sin N+1.

## Recomendaciones (STAGED, aplicar en branch/cutover con autorización)
```sql
-- Acelera league means / base-rates AS-OF (builder + BLOQUE 2b):
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_hpe_liga_fecha
  ON public.historico_partidos_espn (liga_id, fecha) WHERE home_score IS NOT NULL;
-- (opcional) composite exacto del split as-of home/away:
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_hpe_home_liga_fecha
  ON public.historico_partidos_espn (home_espn_id, liga_id, fecha) WHERE home_score IS NOT NULL;
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_hpe_away_liga_fecha
  ON public.historico_partidos_espn (away_espn_id, liga_id, fecha) WHERE home_score IS NOT NULL;
```
`CONCURRENTLY` = sin lock de escritura; `IF NOT EXISTS` idempotente. Coste: 3 índices
parciales sobre 42.5k filas (bajo). No cambian correctness; sólo velocidad.

## Nota
El mayor gasto de read-path histórico NO es el builder as-of sino el re-join del agregado
móvil en `v_futpro_v2` (que iss033 elimina). El proyecto global de Disk IO NO se abre ahora (§33/§52).
`READ_PATH_GATE = recomendaciones STAGED` (no bloquea correctness).
