-- iss056 — El número del modelo llega a la TARJETA, no sólo al dossier.
--
-- PROBLEMA QUE CIERRA
-- iss054 dejó el modelo NFL en `v2.nfl_decision_snapshot` y lo expuso en `public.nfl_dossier`,
-- que el frontend sólo pide al hacer clic en "VER ANÁLISIS". La lista de tarjetas lee
-- `public.nfl_tablero`, y esa vista únicamente tenía `prob_local`/`prob_visitante`, que son el
-- IMPLÍCITO SIN VIG DE LA CASA. Resultado: la tarjeta decía que no había porcentaje propio
-- aunque el snapshot ya existiera. Era una brecha de integración, no de datos.
--
-- LO QUE NO SE HACE
-- No se sustituye `prob_local`/`prob_visitante` por P_RETO. Siguen siendo mercado, con ese
-- nombre. El modelo llega en columnas NUEVAS y `prob_fuente` dice cuál trae la fila. Pisar
-- prob_local con el modelo habría hecho imposible distinguirlos después.
--
-- TRAMPA RESUELTA: `public.nfl_tablero` tiene `security_invoker=on`. Si hubiera leído v2
-- directamente, `anon` habría necesitado USAGE en el esquema v2 y SELECT en la tabla de
-- snapshots, y sin eso la vista COMPLETA falla — se habría caído toda la pantalla de NFL.
-- Por eso el puente `public.nfl_reto_modelo` va SIN security_invoker: corre con los privilegios
-- de su dueño, así que `anon` sólo necesita SELECT sobre el puente y v2 se queda cerrado.
-- Verificado con `set local role anon`: 31 filas visibles.
--
-- DOS BUGS PROPIOS CORREGIDOS ANTES DE DAR ESTO POR BUENO
--   1. El snapshot guarda PORCENTAJE (65.2), no fracción. El primer intento multiplicaba por
--      100 otra vez y la tarjeta mostraba 6520%. Medido contra los valores crudos.
--   2. `to_char(3.0,'FM9990.9')` devuelve "3." y sin signo: el spread salía "Detroit Lions 3."
--      en lugar de "+3". De ahí `v2.fn_fmt_spread`.

create or replace function v2.fn_fmt_spread(p numeric)
returns text language sql immutable as $$
  select case
           when p is null then null
           when p = 0 then 'PK'
           else (case when p > 0 then '+' else '-' end)
                || trim(trailing '.' from to_char(abs(p), 'FM9990.99'))
         end;
$$;

-- Puente público sobre v2: una fila por evento, el snapshot más reciente. Ver nota de privilegios.
create or replace view public.nfl_reto_modelo as
select distinct on (s.espn_event_id)
       s.espn_event_id, s.home_team, s.away_team,
       s.p_home_ml, s.p_away_ml, s.p_tie_regulation,
       s.p_home_cover, s.p_away_cover, s.p_spread_push,
       s.p_over, s.p_under, s.p_total_push,
       s.dk_spread_home, s.dk_total,
       s.exp_home, s.exp_away, s.exp_total, s.exp_margin,
       s.uncertainty, s.coverage,
       s.model_version, s.model_status, s.calibration_status,
       s.quality_status, s.suppression_reason, s.prob_source,
       s.decision_time, s.kickoff
  from v2.nfl_decision_snapshot s
 order by s.espn_event_id, s.decision_time desc, s.built_at desc;

grant select on public.nfl_reto_modelo to anon, authenticated, service_role;

-- nfl_tablero: TODAS las columnas viejas conservan nombre, tipo y posición (si no,
-- `create or replace view` lo rechaza, y de hecho lo rechazó cuando intenté insertar una
-- columna en medio). Las del modelo van al final.
-- La definición completa aplicada está en docs/master_v2/NFL_TABLERO_MODELO.md

-- Semana NFL vigente = la del próximo partido que todavía no termina. Cuando el último de la
-- semana 1 pasa, el próximo pendiente ya es de la semana 2 y la pantalla cambia sola.
create or replace view public.nfl_semana_actual as
with base as (
  select p.temporada, p.tipo_temporada, p.semana, p.fecha, p.estado
    from nfl_partidos p
   where p.tipo_temporada = 2
     and p.temporada = (select max(temporada) from nfl_partidos where tipo_temporada = 2)
),
proximo as (select semana, temporada from base where fecha + interval '4 hours' > now() order by fecha asc limit 1),
ultima  as (select semana, temporada from base order by fecha desc limit 1)
select coalesce((select semana from proximo), (select semana from ultima))       as semana,
       coalesce((select temporada from proximo), (select temporada from ultima)) as temporada,
       (select count(*) from base b where b.semana = coalesce((select semana from proximo), (select semana from ultima))) as partidos,
       (select count(*) from base b where b.semana = coalesce((select semana from proximo), (select semana from ultima)) and b.estado = 'final') as finalizados,
       exists (select 1 from proximo) as tiene_proximo;

grant select on public.nfl_semana_actual to anon, authenticated, service_role;

-- BUG PROPIO CORREGIDO: el primer intento unía por (semana, temporada) contra nfl_tablero, pero
-- ahí `temporada` es el TIPO ('regular'), no el año. La semana 1 existe en 2025 Y 2026, así que
-- devolvía 32 filas en lugar de 16. El filtro va por espn_event_id contra nfl_partidos.
drop view if exists public.nfl_tablero_semana;
create view public.nfl_tablero_semana as
with eventos as (
  select p.espn_event_id
    from nfl_partidos p
    join public.nfl_semana_actual sa on p.semana = sa.semana and p.temporada = sa.temporada
   where p.tipo_temporada = 2
)
select t.*,
       (t.estado = 'final') as terminado,
       case when t.estado = 'final' then 2 else 1 end as orden_grupo
  from public.nfl_tablero t
 where t.espn_event_id in (select espn_event_id from eventos)
 order by case when t.estado = 'final' then 2 else 1 end, t.fecha;

grant select on public.nfl_tablero_semana to anon, authenticated, service_role;

-- LOCK informativo de la semana. NO entra a reto_picks_hoy ni a Kelly:
-- `public.sin_modelo_independiente('NFL', ...)` sigue bloqueando NFL, y su criterio de reingreso
-- escrito (AUC >= 0.55 con n >= 250 en 2 temporadas, Y ganarle en LogLoss a la línea sin vig)
-- NO se cumple: el walk-forward 2025 tiene n=208 en UNA temporada y el mercado midió MEJOR
-- (Brier 0.21822 vs 0.22702). Dos de dos condiciones fallan. Por eso aquí no hay monto ni EV.
-- Definición completa aplicada en docs/master_v2/NFL_TABLERO_MODELO.md
