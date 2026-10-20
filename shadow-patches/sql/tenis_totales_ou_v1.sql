-- ============================================================================
-- Mercado Tenis OU (juegos totales) v1 — Supabase prod wpiztubmmmzclhlprgpd
-- Aplicado 2026-10-20 vía migraciones MCP. Este archivo es el registro reproducible.
-- Orden: backfill -> coeficientes -> vista de picks -> wiring (grade, snapshot,
-- mejores) -> fila de validación.
-- ============================================================================

-- 1) BACKFILL HISTÓRICO DE LINESCORES -----------------------------------------
create table if not exists public._carga_tenis_lshist (
  id bigint generated always as identity primary key,
  req_id bigint, tour text, ym text,
  procesado boolean not null default false,
  creado_at timestamptz not null default now()
);
create index if not exists ix_carga_tenis_lshist_pend
  on public._carga_tenis_lshist (procesado) where not procesado;

create or replace function public.tenis_ls_hist_pedir(p_desde date, p_hasta date)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare v_n int := 0; d date;
begin
  delete from _carga_tenis_lshist where creado_at < now() - interval '2 days';
  d := date_trunc('month', p_desde)::date;
  while d <= p_hasta loop
    insert into _carga_tenis_lshist (req_id, tour, ym)
    select net.http_get(
             'https://site.api.espn.com/apis/site/v2/sports/tennis/'||t||
             '/scoreboard?dates='||to_char(d,'YYYYMM')),
           t, to_char(d,'YYYYMM')
    from unnest(array['atp','wta']) t;
    v_n := v_n + 2;
    d := (d + interval '1 month')::date;
  end loop;
  return jsonb_build_object('peticiones', v_n, 'desde', p_desde, 'hasta', p_hasta);
end $fn$;

create or replace function public.tenis_ls_hist_parse(p_max int default 40)
returns jsonb language plpgsql security definer set search_path to 'public' as $fn$
declare r record; v_n int; v_filas int := 0; v_resp int := 0;
begin
  update _carga_tenis_lshist c set procesado = true
    from net._http_response resp
   where resp.id = c.req_id and not c.procesado and resp.status_code <> 200;
  for r in
    select c.id, resp.content as cuerpo
      from _carga_tenis_lshist c
      join net._http_response resp on resp.id = c.req_id
     where not c.procesado and resp.status_code = 200
     limit p_max
  loop
    begin
      insert into tenis_linescore (espn_event_id, competitor_id, orden, nombre,
                                   period, juegos, tiebreak)
      select comp->>'id', x->>'id', (x->>'order')::numeric::smallint,
             coalesce(x->'athlete'->>'displayName', x->'athlete'->>'fullName', x->>'name'),
             ord::smallint, (ls->>'value')::numeric::smallint,
             nullif(ls->>'tiebreak','')::numeric::smallint
      from jsonb_array_elements((r.cuerpo::jsonb)->'events') ev
      cross join lateral jsonb_array_elements(ev->'groupings') grp
      cross join lateral jsonb_array_elements(grp->'competitions') comp
      cross join lateral jsonb_array_elements(comp->'competitors') x
      cross join lateral jsonb_array_elements(x->'linescores') with ordinality as t(ls, ord)
      where (grp->'grouping'->>'slug') in ('mens-singles','womens-singles')
        and (comp->'status'->'type'->>'completed')::boolean is true
        and jsonb_array_length(comp->'competitors') = 2
        and x->>'id' is not null and ls->>'value' is not null
      on conflict (espn_event_id, competitor_id, period) do update
        set juegos = excluded.juegos, tiebreak = excluded.tiebreak,
            orden = excluded.orden, nombre = excluded.nombre, capturado_at = now();
      get diagnostics v_n = row_count; v_filas := v_filas + v_n;
    exception when others then
      raise warning 'ls_hist parse % : [%] %', r.id, sqlstate, sqlerrm;
    end;
    update _carga_tenis_lshist set procesado = true where id = r.id;
    v_resp := v_resp + 1;
  end loop;
  return jsonb_build_object('respuestas_leidas', v_resp, 'filas_guardadas', v_filas);
end $fn$;

-- Ejecución del backfill (una vez): por rondas para respetar pg_net/purga.
--   select tenis_ls_hist_pedir('2021-09-01','2022-12-01');  -- esperar ~30s
--   select tenis_ls_hist_parse(60);                          -- repetir por rango
--   ... 2023-01..2024-12 ... 2025-01..2026-10 ...

-- Respaldo diario (mes actual + anterior).
select cron.schedule('tenis-ls-hist-mensual', '50 6 * * *', $$
  select public.tenis_ls_hist_parse(60);
  select public.tenis_ls_hist_pedir((date_trunc('month', now()) - interval '1 month')::date, now()::date);
$$);

-- 2) COEFICIENTES DEL MODELO (logística cruda; z = w0 + sum(w_f*feature)) -------
create table if not exists public.tenis_totales_modelo_v1 (
  tour text primary key,
  w0 numeric not null, w_bo numeric not null, w_pfav numeric not null,
  w_gpssum numeric not null, w_gpsmin numeric not null, w_gpsmax numeric not null,
  w_totsum numeric not null,
  linea_bo3 numeric not null, linea_bo5 numeric,
  min_hist smallint not null default 5, n_fit integer, metodo text,
  actualizado timestamptz not null default now()
);
insert into public.tenis_totales_modelo_v1
  (tour,w0,w_bo,w_pfav,w_gpssum,w_gpsmin,w_gpsmax,w_totsum,linea_bo3,linea_bo5,min_hist,n_fit,metodo)
values
  ('atp', -5.628598, 0.032863, -0.381325, 0.074550, 0.139131, 0.079195, 0.043197, 22, 30, 5, 16679,
    'Logistica P(juegos>linea) ritmo rodante 20 + Elo + bo; linea mediana por bo; walk-forward 9 trimestres'),
  ('wta', -1.576837, 0.0, -1.739329, 0.042415, 0.184276, -0.071806, 0.022411, 20, null, 5, 22336,
    'Logistica P(juegos>linea) ritmo rodante 20 + Elo; linea mediana 20; walk-forward 9 trimestres')
on conflict (tour) do update set
  w0=excluded.w0,w_bo=excluded.w_bo,w_pfav=excluded.w_pfav,w_gpssum=excluded.w_gpssum,
  w_gpsmin=excluded.w_gpsmin,w_gpsmax=excluded.w_gpsmax,w_totsum=excluded.w_totsum,
  linea_bo3=excluded.linea_bo3,linea_bo5=excluded.linea_bo5,n_fit=excluded.n_fit,
  metodo=excluded.metodo,actualizado=now();

-- 3) VISTA DE PICKS OU PRÓXIMOS -----------------------------------------------
create or replace view public.v_reto_tenis_totales_v1 as
with mg as (
  select p.espn_match_id, p.tour, p.fecha, p.winner_id, p.loser_id,
         case when p.tour='atp'
               and lower(coalesce(p.torneo,'')) ~ '(australian open|roland garros|french open|wimbledon|us open)'
              then 5 else 3 end as bo,
         sum(lw.juegos + ll.juegos)::numeric as total_games, count(*)::int as n_sets
  from public.tenis_partidos_v1 p
  join public.tenis_linescore lw on lw.espn_event_id = p.espn_match_id and lw.competitor_id = p.winner_id
  join public.tenis_linescore ll on ll.espn_event_id = p.espn_match_id and ll.competitor_id = p.loser_id and ll.period = lw.period
  group by 1,2,3,4,5,6
  having count(*) >= 1 and sum(lw.juegos + ll.juegos) > 0
), pm as (
  select winner_id as pid, fecha, total_games/n_sets as gps, total_games from mg
  union all
  select loser_id as pid, fecha, total_games/n_sets as gps, total_games from mg
), pace as (
  select pid, avg(gps) as gps_avg, avg(total_games) as tot_avg, count(*) as n
  from (select pid, gps, total_games,
               row_number() over (partition by pid order by fecha desc) as rn from pm) z
  where rn <= 20 group by pid
), up as (
  select a.espn_match_id, a.tour, a.torneo, a.fecha as inicio, a.p1_name, a.p2_name, a.p1_id, a.p2_id,
         case when a.tour='atp'
               and lower(coalesce(a.torneo,'')) ~ '(australian open|roland garros|french open|wimbledon|us open)'
              then 5 else 3 end as bo,
         p1.gps_avg as gps1, p2.gps_avg as gps2, p1.tot_avg as tot1, p2.tot_avg as tot2,
         r1.rating as rt1, r2.rating as rt2
  from public.tenis_agenda_v1 a
  join pace p1 on p1.pid = a.p1_id
  join pace p2 on p2.pid = a.p2_id
  join public.tenis_elo_rating_prod r1 on r1.player_id = a.p1_id
  join public.tenis_elo_rating_prod r2 on r2.player_id = a.p2_id
  join public.tenis_totales_modelo_v1 m on m.tour = a.tour
  where a.fecha > now() and p1.n >= m.min_hist and p2.n >= m.min_hist
), calc as (
  select up.*, m.w0, m.w_bo, m.w_pfav, m.w_gpssum, m.w_gpsmin, m.w_gpsmax, m.w_totsum,
         case when up.bo = 5 then m.linea_bo5 else m.linea_bo3 end as linea,
         1.0/(1.0+power(10.0, -abs(up.rt1-up.rt2)/400.0)) as p_fav,
         (up.gps1 + up.gps2) as gps_sum, least(up.gps1, up.gps2) as gps_min,
         greatest(up.gps1, up.gps2) as gps_max, (up.tot1 + up.tot2) as tot_sum
  from up join public.tenis_totales_modelo_v1 m on m.tour = up.tour
), prob as (
  select calc.*, (w0 + w_bo*bo + w_pfav*p_fav + w_gpssum*gps_sum
                    + w_gpsmin*gps_min + w_gpsmax*gps_max + w_totsum*tot_sum) as z
  from calc
)
select espn_match_id as espn_event_id, tour, torneo, p1_name, p2_name, inicio as kickoff, linea,
       round((tot_sum/2.0), 1) as juegos_prom_reciente,
       round(100.0/(1.0+exp(-z)), 1) as over_pct,
       round(100.0 - 100.0/(1.0+exp(-z)), 1) as under_pct,
       case when 1.0/(1.0+exp(-z)) >= 0.5 then 'over' else 'under' end as lado,
       case when 1.0/(1.0+exp(-z)) >= 0.5 then 'Más de '||linea||' juegos' else 'Menos de '||linea||' juegos' end as pick_titulo,
       round(greatest(100.0/(1.0+exp(-z)), 100.0 - 100.0/(1.0+exp(-z))), 1) as pick_prob_pct
from prob order by inicio;

-- 4) WIRING: reto_snapshot_capturar_v1 (bloque OU tenis, piso >=60) ------------
--    v_reto_mejores_picks_v1 (bloque OU tenis, piso >=60)
--    v_reto_pick_grade_v1 (rama tenis OU, push=NULL)
--    Ver migraciones: snapshot_capturar_tenis_ou, mejores_picks_tenis_ou,
--    pick_grade_tenis_ou. (Bloques añadidos, resto preservado.)

-- 5) VALIDACIÓN ---------------------------------------------------------------
insert into public.reto_modelo_validacion_v1 (deporte, mercado, muestra_oos, accuracy_pct, brier, metodo, actualizado)
values
 ('tenis_atp','OU',494,66.2,null,'Juegos totales. Logistica P(juegos>linea) ritmo rodante 20 + Elo + bo; linea mediana por bo (22/30); walk-forward 9 trimestres; tramo >=60%. OJO: vence linea MEDIANA estatica, no linea real de casa de apuestas.',now()),
 ('tenis_wta','OU',523,65.2,null,'Juegos totales. Logistica P(juegos>linea) ritmo rodante 20 + Elo; linea mediana 20; walk-forward 9 trimestres; tramo >=60%. OJO: vence linea MEDIANA estatica, no linea real de casa de apuestas.',now())
on conflict do nothing;
