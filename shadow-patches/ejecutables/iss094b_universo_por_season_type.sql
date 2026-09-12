-- iss094b — RECONSTRUIR EL UNIVERSO DEL BACKTEST CON season_type  [EJECUTABLE]
--
-- Sustituye el filtro de MLB por el ENTERO REAL de ESPN (season_type in (2,3))
-- en vez de la etiqueta de texto. NFL sigue por etiqueta porque su season_type
-- NO se ha recuperado todavia: ese es un defecto gemelo ABIERTO y esta
-- declarado como tal en la assertion 4c de este archivo.
--
-- Se ejecuta DESPUES de iss094. Es idempotente: trunca y reconstruye.

-- ===========================================================================
-- 1) LAMBDA — rama BASEBALL: ventana de equipo 24 meses, liga 30 dias
-- ===========================================================================
truncate public.calib_lambda;

insert into public.calib_lambda
  (deporte, espn_event_id, fecha, total, lam, muestra, tipo_temporada,
   asof_home, asof_away, asof_league, vent_equipo, vent_liga)
with j as (
  select espn_event_id, fecha, home_espn_id, away_espn_id,
         home_score, away_score, (home_score+away_score)::int total
  from public.historico_partidos_espn
  where espn_endpoint ilike '%baseball%'
    and season_type in (2,3)                 -- EL ENTERO REAL, no la etiqueta
    and home_score is not null and away_score is not null
    and home_espn_id is not null and away_espn_id is not null
),
pl as (select espn_event_id, avg(home_score) over w gf, avg(away_score) over w gc,
              count(*) over w pj, max(fecha) over w asof
       from j window w as (partition by home_espn_id order by fecha
            range between interval '24 months' preceding and interval '1 day' preceding)),
pv as (select espn_event_id, avg(away_score) over w gf, avg(home_score) over w gc,
              count(*) over w pj, max(fecha) over w asof
       from j window w as (partition by away_espn_id order by fecha
            range between interval '24 months' preceding and interval '1 day' preceding)),
bs as (select espn_event_id, avg(home_score) over w bl, avg(away_score) over w bv,
              count(*) over w pj, max(fecha) over w asof
       from j window w as (order by fecha
            range between interval '30 days' preceding and interval '1 day' preceding))
select 'baseball', j.espn_event_id, j.fecha, j.total,
  (least(greatest(bs.bl*(1+(pl.pj/(pl.pj+20.0))*((pl.gf/bs.bl)-1))
                      *(1+(pv.pj/(pv.pj+20.0))*((pv.gc/bs.bl)-1)), 1.5), 9.0)
 + least(greatest(bs.bv*(1+(pv.pj/(pv.pj+20.0))*((pv.gf/bs.bv)-1))
                      *(1+(pl.pj/(pl.pj+20.0))*((pl.gc/bs.bv)-1)), 1.5), 9.0))::double precision,
  least(pl.pj, pv.pj)::int, 'regular_o_playoffs',
  pl.asof, pv.asof, bs.asof, '24 months', '30 days'
from j
join pl on pl.espn_event_id=j.espn_event_id
join pv on pv.espn_event_id=j.espn_event_id
join bs on bs.espn_event_id=j.espn_event_id
where pl.pj >= 20 and pv.pj >= 20 and bs.pj >= 100;

-- ===========================================================================
-- 2) LAMBDA — rama FOOTBALL: 36 meses / 120 dias. Ramas SEPARADAS a proposito:
--    un marco RANGE no se puede parametrizar, y ese fue el bug de iss087.
-- ===========================================================================
insert into public.calib_lambda
  (deporte, espn_event_id, fecha, total, lam, muestra, tipo_temporada,
   asof_home, asof_away, asof_league, vent_equipo, vent_liga)
with j as (
  select espn_event_id, fecha, home_espn_id, away_espn_id,
         home_score, away_score, (home_score+away_score)::int total
  from public.historico_partidos_espn
  where espn_endpoint ilike '%football%'
    and tipo_temporada = 'regular_o_playoffs'   -- DEFECTO ABIERTO: sin season_type
    and home_score is not null and away_score is not null
    and home_espn_id is not null and away_espn_id is not null
),
pl as (select espn_event_id, avg(home_score) over w gf, avg(away_score) over w gc,
              count(*) over w pj, max(fecha) over w asof
       from j window w as (partition by home_espn_id order by fecha
            range between interval '36 months' preceding and interval '1 day' preceding)),
pv as (select espn_event_id, avg(away_score) over w gf, avg(home_score) over w gc,
              count(*) over w pj, max(fecha) over w asof
       from j window w as (partition by away_espn_id order by fecha
            range between interval '36 months' preceding and interval '1 day' preceding)),
bs as (select espn_event_id, avg(home_score) over w bl, avg(away_score) over w bv,
              count(*) over w pj, max(fecha) over w asof
       from j window w as (order by fecha
            range between interval '120 days' preceding and interval '1 day' preceding))
select 'football', j.espn_event_id, j.fecha, j.total,
  (least(greatest(bs.bl*(1+(pl.pj/(pl.pj+8.0))*((pl.gf/bs.bl)-1))
                      *(1+(pv.pj/(pv.pj+8.0))*((pv.gc/bs.bl)-1)), 8.0), 40.0)
 + least(greatest(bs.bv*(1+(pv.pj/(pv.pj+8.0))*((pv.gf/bs.bv)-1))
                      *(1+(pl.pj/(pl.pj+8.0))*((pl.gc/bs.bv)-1)), 8.0), 40.0))::double precision,
  least(pl.pj, pv.pj)::int, 'regular_o_playoffs',
  pl.asof, pv.asof, bs.asof, '36 months', '120 days'
from j
join pl on pl.espn_event_id=j.espn_event_id
join pv on pv.espn_event_id=j.espn_event_id
join bs on bs.espn_event_id=j.espn_event_id
where pl.pj >= 8 and pv.pj >= 8 and bs.pj >= 40;

-- ===========================================================================
-- 3) SIGMA rodante y causal + linaje consolidado por feature
-- ===========================================================================
update public.calib_lambda c
   set sd_rodante = r.sd, n_resid = r.n, asof_dispersion = r.asof
from (select deporte, espn_event_id,
             stddev_pop(total - lam) over w sd, count(*) over w n, max(fecha) over w asof
      from public.calib_lambda
      window w as (partition by deporte order by fecha
                   range between interval '24 months' preceding and interval '1 day' preceding)) r
where r.deporte=c.deporte and r.espn_event_id=c.espn_event_id;

update public.calib_lambda
   set data_asof_real = greatest(asof_home, asof_away, asof_league, asof_dispersion);

-- ===========================================================================
-- 4) EVENTOS: uno por (partido, linea). Linea entera puede empujar; .5 NUNCA.
--    linea_entera es GENERADA: no se inserta.
-- ===========================================================================
delete from public.calib_eventos
 where model_version in ('mlb_totales_normal_v1','nfl_totales_normal_v1');

insert into public.calib_eventos
  (model_version, deporte, mercado, espn_event_id, fecha_partido, feature_cutoff,
   linea, p_raw, p_win_uncond, p_push, p_loss_uncond, resultado,
   n_muestra_modelo, data_asof_real)
select
  case when c.deporte='baseball' then 'mlb_totales_normal_v1' else 'nfl_totales_normal_v1' end,
  c.deporte, 'Over/Under', c.espn_event_id, c.fecha, c.data_asof_real, q.linea,
  round(greatest(0.0001, least(0.9999, q.pw / nullif(q.pw + q.pl, 0)))::numeric, 6),
  round(q.pw::numeric,6), round(greatest(0, 1-q.pw-q.pl)::numeric,6), round(q.pl::numeric,6),
  case when c.total > q.linea then 'WIN' when c.total = q.linea then 'PUSH' else 'LOSS' end,
  c.muestra, c.data_asof_real
from public.calib_lambda c
cross join lateral (
  select ln.linea,
    case when ln.linea = trunc(ln.linea)
         then 1 - public.normal_cdf(((ln.linea + 0.5 - c.lam)/c.sd_rodante)::double precision)
         else 1 - public.normal_cdf(((ln.linea       - c.lam)/c.sd_rodante)::double precision) end pw,
    case when ln.linea = trunc(ln.linea)
         then public.normal_cdf(((ln.linea - 0.5 - c.lam)/c.sd_rodante)::double precision)
         else public.normal_cdf(((ln.linea       - c.lam)/c.sd_rodante)::double precision) end pl
  from unnest(case when c.deporte='baseball'
                   then array[7,7.5,8,8.5,9,9.5,10,10.5]::numeric[]
                   else array[37,37.5,40,40.5,43,43.5,46,46.5,49,49.5]::numeric[] end) ln(linea)
) q
where c.sd_rodante is not null and c.sd_rodante > 0 and c.n_resid >= 200
  and c.data_asof_real is not null and q.pw + q.pl > 0;

-- ===========================================================================
-- 5) ASSERTIONS
-- ===========================================================================
do $$
declare v_n int;
begin
  -- 5a) ninguna pretemporada dentro del universo
  select count(*) into v_n from public.calib_lambda cl
   join public.historico_partidos_espn h on h.espn_event_id = cl.espn_event_id
   where cl.deporte='baseball' and h.season_type = 1;
  if v_n > 0 then raise exception 'PRETEMPORADA DENTRO DEL BACKTEST: % partidos', v_n; end if;

  -- 5b) linaje: ningun feature mira el dia del partido ni despues
  select count(*) into v_n from public.calib_lambda
   where greatest(asof_home, asof_away, asof_league, asof_dispersion) >= fecha;
  if v_n > 0 then raise exception 'FUGA TEMPORAL: % filas', v_n; end if;

  -- 5c) ventanas correctas por deporte (el bug de iss087)
  select count(*) into v_n from public.calib_lambda
   where (deporte='baseball' and (vent_equipo <> '24 months' or vent_liga <> '30 days'))
      or (deporte='football' and (vent_equipo <> '36 months' or vent_liga <> '120 days'));
  if v_n > 0 then raise exception 'VENTANAS MAL APLICADAS: % filas', v_n; end if;

  -- 5d) una linea .5 no puede empujar nunca
  select count(*) into v_n from public.calib_eventos
   where not linea_entera and (resultado='PUSH' or p_push > 0.0001);
  if v_n > 0 then raise exception 'PUSH FANTASMA: % eventos', v_n; end if;

  -- 5e) DEFECTO ABIERTO DECLARADO: NFL sin season_type. Esta assertion NO falla
  --     a proposito; deja el hueco VISIBLE en cada corrida.
  select count(*) into v_n from public.historico_partidos_espn
   where espn_endpoint ilike '%football%' and season_type is null;
  if v_n > 0 then
    raise warning 'DEFECTO ABIERTO: % filas de NFL sin season_type. Sus metricas NO son confiables hasta recuperarlo.', v_n;
  end if;

  raise notice 'iss094b OK: universo por season_type, linaje limpio, ventanas por deporte';
end $$;

-- FIN iss094b.
