-- ============================================================================
-- RÉCORD PÚBLICO — vistas read-only para la pantalla de transparencia
-- ✅ APLICADAS A PROD el 2026-10-14 (migración record_publico_views_v1) tras
--    autorización explícita del usuario ("Todo: prod + Lovable"). Grants a
--    anon/authenticated incluidos. Money sigue apagado.
-- ----------------------------------------------------------------------------
-- Son 100% ADITIVAS y de SOLO LECTURA: crean vistas nuevas, nada depende de
-- ellas, no modifican ni una tabla, función, vista o dato existente. No tocan
-- ningún gate ni money_authorized. Riesgo operativo: mínimo. Se dejan staged
-- solo por disciplina de freeze.
--
-- Fuentes: evidencia_modelo_forward (registro forward calificado, model-vs-market),
--          v2.soccer_publication_market_evidence_v1 (CLV soccer).
-- Validadas read-only el 2026-10-14 contra prod wpiztubmmmzclhlprgpd; los números
-- coinciden con el prototipo record-verificado.html.
-- ============================================================================

-- 1) Marcador agregado por deporte ------------------------------------------
create or replace view public.v_reto_track_record_v1 as
select
  deporte,
  count(*) filter (where resultado is not null) as picks_calificados,
  round(avg((acerto)::int) filter (where resultado is not null)*100, 1) as acierto_pct,
  round(avg(case when acerto then momio_mercado-1 else -1 end)
        filter (where resultado is not null and momio_mercado > 1)*100, 1) as roi_flat_pct,
  round(avg(momio_mercado) filter (where resultado is not null and momio_mercado > 1), 2) as momio_prom,
  round(avg(brier_modelo)  filter (where resultado is not null), 4) as brier_modelo,
  round(avg(brier_mercado) filter (where resultado is not null), 4) as brier_mercado,
  (avg(brier_modelo)  filter (where resultado is not null)
     < avg(brier_mercado) filter (where resultado is not null)) as le_gana_al_mercado,
  min(kickoff) filter (where resultado is not null)::date as desde,
  max(kickoff) filter (where resultado is not null)::date as hasta
from public.evidencia_modelo_forward
group by deporte
having count(*) filter (where resultado is not null) > 0;

-- 2) Curva de calibración por deporte y banda de probabilidad ---------------
--    (solo bandas con n>=10 para no mostrar ruido)
create or replace view public.v_reto_calibration_curve_v1 as
select
  deporte,
  (floor(prob_modelo/10)*10)::int      as banda_min,
  (floor(prob_modelo/10)*10 + 10)::int as banda_max,
  count(*)                             as n,
  round(avg(prob_modelo), 1)           as prob_dicha,
  round(avg((acerto)::int)*100, 1)     as acierto_real
from public.evidencia_modelo_forward
where resultado is not null and prob_modelo is not null
group by deporte, floor(prob_modelo/10)
having count(*) >= 10;

-- 3) CLV de soccer (valor de línea de cierre) -------------------------------
create or replace view public.v_reto_clv_v1 as
select
  'soccer'::text as deporte,
  count(*) filter (where closing_valid)                                      as picks_con_cierre,
  count(*) filter (where closing_odds is not null and decision_odds is not null) as con_ambos_precios,
  round(avg(market_drift_samebook_pp) filter (where closing_valid), 2)       as drift_promedio_pp,
  round(avg((market_drift_samebook_pp > 0)::int) filter (where closing_valid)*100, 1) as pct_clv_positivo,
  min(kickoff)::date as desde,
  max(kickoff)::date as hasta
from v2.soccer_publication_market_evidence_v1;

-- 4) Historial pick por pick (últimos calificados) --------------------------
create or replace view public.v_reto_recent_picks_v1 as
select
  deporte, liga, partido, pick_desc,
  round(prob_modelo, 1)        as prob_modelo,
  round(prob_mercado_novig, 1) as prob_mercado,
  momio_mercado,
  acerto,
  kickoff::date as fecha,
  kickoff
from public.evidencia_modelo_forward
where resultado is not null
order by kickoff desc;

-- ============================================================================
-- Permisos sugeridos (revisar con la postura RLS pendiente antes de exponer a anon):
--   grant select on public.v_reto_track_record_v1,
--                   public.v_reto_calibration_curve_v1,
--                   public.v_reto_clv_v1,
--                   public.v_reto_recent_picks_v1 to anon, authenticated;
-- NOTA: estas vistas NO exponen internals del modelo (pesos, features, lambdas):
-- solo probabilidad dicha, prob de mercado, momio y resultado — datos que de todos
-- modos se muestran al usuario. Son seguras de publicar aun bajo la deuda de RLS.
-- ============================================================================
