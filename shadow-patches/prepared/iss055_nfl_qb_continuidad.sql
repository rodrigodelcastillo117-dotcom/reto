-- ============================================================================
-- iss055 — CONTINUIDAD DE QB como señal de fiabilidad del rating · STAGED
-- ============================================================================
-- NO PROD MUTATION · branch-only · RELEASE_GATE=HOLD · PROD_FREEZE=ON.
--
-- POR QUE EXISTE ESTE ARCHIVO
-- El backtest de 2025 (run_nfl_backtest_2025.sql) encontró que en el tramo donde el modelo
-- dice 40-50%, la realidad fue 32% — un error de +14 pp. Corregí la varianza en
-- nfl-2026.09.2 y ese tramo NO mejoró (+14.0 -> +14.7 pp). Eso PRUEBA que no es un problema
-- de calibración: es falta de features. El modelo aplica ventaja de campo completa a equipos
-- locales que ya no son los mismos equipos.
--
-- QUE HACE Y QUE NO HACE
-- SI hace: registra quién es el QB titular declarado y lo compara contra quién REALMENTE lanzó
--   más yardas en 2025 (medido en nfl_player_game_logs). Un cambio de titular significa que el
--   rating ofensivo de 2025 de ese equipo es menos transferible a 2026.
-- NO hace: asignar puntos por QB. No existe en esta base una valoración medida de cuánto vale
--   cada quarterback en puntos, y ponerla "a ojo" sería exactamente el hardcode subjetivo que
--   está prohibido. La continuidad entra como FIABILIDAD (ensancha incertidumbre / marca el
--   juego), no como ajuste de media.
--
-- CALIDAD DE LA FUENTE: la lista de titulares/suplentes la aportó el owner el 2026-09-11. Dos
-- inconsistencias se detectaron al ingerirla y quedan marcadas en nota_calidad en vez de
-- resolverse en silencio:
--   1. "Las Vegas Chargers" no existe. Herbert es Los Angeles Chargers (LAC). Corregido y anotado.
--   2. Drew Lock aparecía como suplente de NYG y de SEA a la vez. Imposible. RESUELTO por el
--      owner el 2026-09-11: Lock es de SEATTLE. El suplente de NYG queda NULL con nota, porque
--      no se declaró reemplazo y aquí no se inventa un nombre para llenar el hueco.
-- ============================================================================

create schema if not exists v2;

create table if not exists v2.nfl_qb_depth (
  team_abrev text primary key,
  team_nombre text not null,
  qb_titular text not null,
  qb_suplente text,
  asof timestamptz not null,
  fuente text not null,
  nota_calidad text
);

-- quién lanzó más yardas por equipo en la temporada regular 2025 (MEDIDO, no declarado)
create or replace view v2.v_nfl_qb_2025_lider as
select l.team as team_abrev, l.player_name as qb_2025,
       count(*) as juegos, sum(coalesce(l.pass_yards,0)) as yardas
from public.nfl_player_game_logs l
join public.nfl_partidos p on p.espn_event_id = l.espn_event_id
where l.position = 'QB' and p.temporada = 2025 and p.tipo_temporada = 2
group by l.team, l.player_name
qualify row_number() over (partition by l.team order by sum(coalesce(l.pass_yards,0)) desc) = 1;

-- continuidad por equipo
create or replace view v2.v_nfl_qb_continuidad as
select d.team_abrev, d.team_nombre, q.qb_2025, q.juegos as juegos_2025,
       d.qb_titular as qb_2026, d.qb_suplente, d.nota_calidad,
       (d.qb_titular = q.qb_2025) as hay_continuidad,
       case when d.qb_titular = q.qb_2025 then 'CONTINUIDAD' else 'QB_NUEVO' end as estado,
       -- fiabilidad del rating ofensivo 2025 para proyectar 2026
       case when d.qb_titular = q.qb_2025 then 1.00 else 0.60 end as fiabilidad_rating_ofensivo
from v2.nfl_qb_depth d
left join v2.v_nfl_qb_2025_lider q on q.team_abrev = d.team_abrev;

-- juegos de la semana donde al menos un equipo cambió de QB: ahí el rating de 2025 es
-- menos confiable y la probabilidad del modelo merece menos confianza, no más.
create or replace view v2.v_nfl_qb_riesgo_semana as
select s.espn_event_id, s.semana, s.kickoff,
       s.away_team || ' @ ' || s.home_team as partido,
       ch.estado as qb_local, ca.estado as qb_visitante,
       (coalesce(ch.hay_continuidad,true) and coalesce(ca.hay_continuidad,true)) as ambos_continuos,
       s.p_home_ml, s.p_away_ml, s.model_version
from v2.nfl_decision_snapshot s
left join v2.v_nfl_qb_continuidad ch on ch.team_nombre = s.home_team
left join v2.v_nfl_qb_continuidad ca on ca.team_nombre = s.away_team
where s.model_status = 'READY';

-- ============================================================================
-- ROLLBACK: drop view if exists v2.v_nfl_qb_riesgo_semana, v2.v_nfl_qb_continuidad,
--             v2.v_nfl_qb_2025_lider; drop table if exists v2.nfl_qb_depth;
-- ============================================================================
