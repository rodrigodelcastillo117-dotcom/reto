-- ============================================================================
-- run_nfl_backtest_2025.sql — backtest WALK-FORWARD del cerebro NFL sobre 2025
-- ============================================================================
-- Responde una sola pregunta: ¿los porcentajes son reales?
--
-- Honestidad del procedimiento: para cada fecha de juego los ratings se ajustan SÓLO con
-- juegos estrictamente anteriores (`fecha < v_asof` dentro de fn_nfl_fit_ratings). No hay
-- forma de que el modelo vea el resultado que intenta predecir. Se exigen >= 64 juegos de
-- entrenamiento antes de la primera predicción.
--
-- IMPORTANTE — aquí NO se aplica early_season_sd_inflation: dentro de 2025 sí hay datos de la
-- misma temporada, así que inflar la varianza sería inventar incertidumbre que no existe. La
-- inflación sólo aplica a Week 1, donde los ratings vienen de la temporada anterior.
-- ============================================================================

create table if not exists v2.nfl_backtest_2025 (
  espn_event_id text primary key, fecha timestamptz,
  juegos_entrenamiento int, mu_home numeric, mu_away numeric,
  p_home_ml numeric, p_home_cover numeric, p_over numeric,
  mercado_p_home numeric, dk_spread numeric, dk_total numeric,
  gano_home int, cubrio_home int, fue_over int, push_spread int, push_total int,
  exp_margin numeric, margen_real int, exp_total numeric, total_real int
);
truncate v2.nfl_backtest_2025;

do $bt$
declare d date; cfg record; g record; rh record; ra record; mk record;
  v_mu_h numeric; v_mu_a numeric; v_sd numeric; n_train int; v_asof timestamptz;
begin
  select * into cfg from v2.nfl_model_config where model_version='nfl-2026.09.1';
  v_sd := cfg.sd_team_points;   -- sin inflación: ver nota del encabezado

  for d in
    select distinct fecha::date f from public.nfl_partidos
    where temporada=2025 and tipo_temporada=2 and pts_home is not null order by 1
  loop
    v_asof := d::timestamptz;   -- v_asof y no `asof`: el nombre pelado colisiona con la columna
    select count(*) into n_train from public.nfl_partidos
     where tipo_temporada=2 and pts_home is not null and fecha < v_asof;
    if n_train < 64 then continue; end if;

    perform v2.fn_nfl_fit_ratings(v_asof, 'nfl-2026.09.1');

    for g in
      select p.* from public.nfl_partidos p
      where p.temporada=2025 and p.tipo_temporada=2 and p.pts_home is not null
        and p.fecha::date = d and p.spread is not null and p.total_linea is not null
    loop
      select * into rh from v2.nfl_team_rating r
       where r.asof=v_asof and r.team_id=g.home_id and r.model_version='nfl-2026.09.1';
      select * into ra from v2.nfl_team_rating r
       where r.asof=v_asof and r.team_id=g.away_id and r.model_version='nfl-2026.09.1';
      if rh.team_id is null or ra.team_id is null then continue; end if;

      v_mu_h := cfg.league_mean_points + rh.off_rating + ra.def_rating + cfg.hfa_points/2.0;
      v_mu_a := cfg.league_mean_points + ra.off_rating + rh.def_rating - cfg.hfa_points/2.0;
      select * into mk from v2.fn_nfl_markets_from_pmf(
        v2.fn_nfl_points_pmf(round(v_mu_h,3), v_sd),
        v2.fn_nfl_points_pmf(round(v_mu_a,3), v_sd), g.spread, g.total_linea);
      if mk.p_home_ml is null then continue; end if;

      insert into v2.nfl_backtest_2025 values (
        g.espn_event_id, g.fecha, n_train, round(v_mu_h,3), round(v_mu_a,3),
        mk.p_home_ml, mk.p_home_cover, mk.p_over,
        case when g.p_home is not null then round(100*g.p_home,1) end,
        g.spread, g.total_linea,
        case when g.pts_home > g.pts_away then 1 when g.pts_home < g.pts_away then 0 end,
        case when (g.pts_home-g.pts_away) + g.spread > 0 then 1
             when (g.pts_home-g.pts_away) + g.spread < 0 then 0 end,
        case when (g.pts_home+g.pts_away) > g.total_linea then 1
             when (g.pts_home+g.pts_away) < g.total_linea then 0 end,
        case when (g.pts_home-g.pts_away) + g.spread = 0 then 1 else 0 end,
        case when (g.pts_home+g.pts_away) = g.total_linea then 1 else 0 end,
        mk.exp_margin, g.pts_home-g.pts_away, mk.exp_total, g.pts_home+g.pts_away
      ) on conflict (espn_event_id) do nothing;
    end loop;
  end loop;
end $bt$;

-- ── 1) MONEYLINE: modelo vs volado vs mercado, con t pareada ────────────────
with d as (
  select *, p_home_ml/100.0 p, mercado_p_home/100.0 q, gano_home::numeric y
  from v2.nfl_backtest_2025 where gano_home is not null
), pair as (select *, case when q is not null then power(q-y,2)-power(p-y,2) end gain from d)
select 'MONEYLINE' bloque, count(*) n,
       round(avg(power(p-y,2))::numeric,5) brier_modelo,
       round(avg(power(0.5-y,2))::numeric,5) brier_volado,
       round((1-avg(power(p-y,2))/avg(power(0.5-y,2)))::numeric,5) skill_vs_volado,
       count(gain) n_mercado,
       round(avg(power(q-y,2)) filter (where q is not null)::numeric,5) brier_mercado,
       round(avg(gain)::numeric,5) ganancia_vs_mercado,
       round((stddev_samp(gain)/sqrt(count(gain)))::numeric,5) se,
       round((avg(gain)/(stddev_samp(gain)/sqrt(count(gain))))::numeric,3) t_stat
from pair;

-- ── 2) SPREAD y TOTAL: sesgo y Brier contra el volado ──────────────────────
select 'SPREAD cover' mercado, count(*) n,
       round(avg(p_home_cover)::numeric,2) modelo_pct, round(100.0*avg(cubrio_home)::numeric,2) real_pct,
       round(avg(power(p_home_cover/100.0 - cubrio_home,2))::numeric,5) brier,
       round(avg(power(0.5 - cubrio_home,2))::numeric,5) brier_volado
from v2.nfl_backtest_2025 where cubrio_home is not null
union all
select 'TOTAL over', count(*),
       round(avg(p_over)::numeric,2), round(100.0*avg(fue_over)::numeric,2),
       round(avg(power(p_over/100.0 - fue_over,2))::numeric,5),
       round(avg(power(0.5 - fue_over,2))::numeric,5)
from v2.nfl_backtest_2025 where fue_over is not null;

-- ── 3) precisión en PUNTOS contra la línea de DK ───────────────────────────
select count(*) n,
       round(avg(abs(exp_margin - margen_real))::numeric,3) mae_margen_modelo,
       round(avg(abs(-dk_spread - margen_real))::numeric,3) mae_margen_dk,
       round(sqrt(avg(power(exp_margin - margen_real,2)))::numeric,3) rmse_margen_modelo,
       round(sqrt(avg(power(-dk_spread - margen_real,2)))::numeric,3) rmse_margen_dk,
       round(avg(abs(exp_total - total_real))::numeric,3) mae_total_modelo,
       round(avg(abs(dk_total - total_real))::numeric,3) mae_total_dk,
       round(avg(exp_margin - margen_real)::numeric,3) sesgo_margen,
       round(avg(exp_total - total_real)::numeric,3) sesgo_total
from v2.nfl_backtest_2025 where margen_real is not null;

-- ── 4) CALIBRACIÓN por tramos — el diagnóstico que importa ─────────────────
-- Si el modelo está sub-confiado en los extremos, su distribución es demasiado ANCHA y la sd
-- usada es mayor que la residual real. Eso es medible aquí y fue exactamente lo que pasó.
with b as (
  select case when p_home_ml < 40 then '1. <40' when p_home_ml < 50 then '2. 40-50'
              when p_home_ml < 60 then '3. 50-60' when p_home_ml < 70 then '4. 60-70'
              else '5. 70+' end bucket, p_home_ml, gano_home
  from v2.nfl_backtest_2025 where gano_home is not null
)
select bucket, count(*) n, round(avg(p_home_ml)::numeric,1) modelo_dice_pct,
       round(100.0*avg(gano_home)::numeric,1) real_pct,
       round((avg(p_home_ml) - 100.0*avg(gano_home))::numeric,1) error_pp
from b group by bucket order by bucket;
