-- ISS102 — P0-1: NFL RESULT TRUTH / PARLAY AUTOGRADE / STALE FINAL RECONCILIATION
-- issue #4 (control plane: rodrigodelcastillo117-dotcom/reto13)
--
-- LO QUE SE REPRODUJO PRIMERO, EN PRODUCCION (2026-09-12)
-- =======================================================
-- Parlay fbb18adb-ca26-428b-add4-6b2c723bd1d5, evento 401872657 (SF 27-7 LAR):
--   nfl_partidos : estado='scheduled', pts NULL, actualizado 2026-09-12 13:23
--   live_scores  : status='final',     7-27,     updated   2026-09-11 03:35
--   -> la tabla operativa se refresco HOY y siguio diciendo 'scheduled'.
--   picks_calificacion = []  mientras picks_data traia los 4 legs ya calificados.
--
-- VERIFICACION DE LAS CALIFICACIONES CONTRA DATO REAL (no contra ausencia de dato):
--   nfl_player_game_logs del evento 401872657:
--     McCaffrey  rush_tds 0 + rec_tds 0 = 0  -> 1+ TD PERDIDO   (correcto)
--     D. Adams   rec_tds 0                   -> 1+ TD PERDIDO   (correcto)
--     Stafford   0 pass TD (el unico TD de LAR fue carrera de Kyren Williams)
--                                            -> 1+ pass TD PERDIDO (correcto)
--     27+7 = 34 < 50.5                       -> Under GANADO    (correcto)
--   Las calificaciones ya eran correctas. Lo roto era la AUTORIDAD DE ESTADO.
--
-- OJO, detalle que importa para cualquier grading de TDs: en nfl_player_game_logs
-- `pass_tds` y `rec_tds` cuentan EL MISMO touchdown desde los dos lados. El total
-- de TDs de un equipo es rush_tds + rec_tds. Sumar pass_tds lo duplicaria.
--
-- CONFLICTO REAL DE AUTORIDAD DESCUBIERTO
-- =======================================
-- Evento 401874394 (Titans vs Bears, 2026-08-29):
--   live_scores  dice final 0-0
--   historico    dice 15-24
--   game logs    muestran CHI 1 rush TD + 2 rec TD = 3 TD (21) y TEN 1 rush TD (7)
--   -> el 0-0 de live_scores es FALSO y los game logs corroboran el historico.
-- Por eso la precedencia NO es "la fuente mas reciente" ni "live_scores manda":
-- live_scores es un feed en vivo que puede quedar capturado en un estado
-- intermedio y publicar 'final' con marcador placeholder.

begin;

-- =====================================================================
-- 1) AUTORIDAD EXPLICITA DE ESTADO/RESULTADO
-- =====================================================================
-- Precedencia declarada:
--   1. historico_partidos_espn  = box score final de ESPN
--   2. live_scores              = feed en vivo (ver conflicto 401874394)
--   3. nfl_player_game_logs     = PRUEBA DE QUE SE JUGO, nunca del marcador.
--      Si solo hay logs, el estado es JUGADO_SIN_MARCADOR y el marcador queda
--      NULL: no se sintetiza sumando touchdowns.
-- El conflicto se EXPONE, no se resuelve en silencio.
create or replace view public.v_nfl_resultado_autoritativo as
with fuentes as (
  select n.espn_event_id::text            as ev,
         n.fecha, n.home_team, n.away_team,
         n.estado  as estado_en_nfl_partidos,
         n.pts_home as pts_home_en_nfl_partidos,
         n.pts_away as pts_away_en_nfl_partidos,
         h.home_score as h_home, h.away_score as h_away, h.cargado_at as h_asof,
         l.status as l_status, l.home_score as l_home, l.away_score as l_away, l.updated_at as l_asof,
         g.n_logs, g.tds_totales
  from nfl_partidos n
  left join historico_partidos_espn h on h.espn_event_id = n.espn_event_id::text
  left join live_scores l on l.espn_event_id::text = n.espn_event_id::text
  left join lateral (
    select count(*) n_logs,
           sum(coalesce(rush_tds,0)+coalesce(rec_tds,0)) tds_totales
    from nfl_player_game_logs x where x.espn_event_id::text = n.espn_event_id::text
  ) g on true
),
juzgado as (
  select f.*,
    case
      when f.h_home is not null and f.h_away is not null then 'historico_partidos_espn'
      when f.l_status = 'final' and f.l_home is not null and f.l_away is not null then 'live_scores'
      when coalesce(f.n_logs,0) > 0 then 'nfl_player_game_logs'
      else null
    end as fuente,
    case
      when f.h_home is not null and f.h_away is not null then 'FINAL'
      when f.l_status = 'final' and f.l_home is not null and f.l_away is not null then 'FINAL'
      when coalesce(f.n_logs,0) > 0 then 'JUGADO_SIN_MARCADOR'
      when f.l_status in ('live','in') then 'EN_VIVO'
      when f.l_status = 'postponed' then 'POSPUESTO'
      when f.fecha > now() then 'PROGRAMADO'
      else 'SIN_RESULTADO'
    end as estado_autoritativo,
    case when f.h_home is not null then f.h_home
         when f.l_status='final' then f.l_home end as pts_home_aut,
    case when f.h_away is not null then f.h_away
         when f.l_status='final' then f.l_away end as pts_away_aut,
    (f.h_home is not null and f.l_status='final' and f.l_home is not null
     and (f.h_home <> f.l_home or f.h_away <> f.l_away)) as conflicto
  from fuentes f
)
select ev as espn_event_id, fecha, home_team, away_team,
       estado_autoritativo, pts_home_aut, pts_away_aut, fuente,
       coalesce(h_asof, l_asof) as data_asof,
       conflicto,
       case when conflicto then
         'historico='||h_home||'-'||h_away||' vs live_scores='||l_home||'-'||l_away
         ||'; game_logs con '||coalesce(tds_totales,0)||' TD en '||coalesce(n_logs,0)||' registros'
       end as conflicto_detalle,
       estado_en_nfl_partidos, pts_home_en_nfl_partidos, pts_away_en_nfl_partidos,
       (estado_autoritativo = 'FINAL'
        and (estado_en_nfl_partidos is distinct from 'final'
             or pts_home_en_nfl_partidos is distinct from pts_home_aut
             or pts_away_en_nfl_partidos is distinct from pts_away_aut)) as desalineado,
       n_logs, tds_totales
from juzgado;

comment on view public.v_nfl_resultado_autoritativo is
 'AUTORIDAD EXPLICITA de estado/resultado NFL. Una sola verdad por evento con precedencia declarada (historico_partidos_espn > live_scores > game logs como prueba de juego) y conflicto expuesto en vez de resuelto en silencio. El marcador NUNCA se sintetiza desde estadisticas de jugador.';

-- =====================================================================
-- 2) RECONCILIACION IDEMPOTENTE (no es un fix manual de resultados)
-- =====================================================================
create or replace function public.nfl_reconciliar_resultado(p_dry_run boolean default true)
returns jsonb language plpgsql set search_path to 'public' as $function$
declare v_obj jsonb; v_aplicadas int := 0;
begin
  create temporary table if not exists _rec (
    espn_event_id text primary key, estado_aut text, ph int, pa int, fuente text,
    estado_antes text, ph_antes int, pa_antes int) on commit drop;
  delete from _rec;
  insert into _rec
  select espn_event_id, estado_autoritativo, pts_home_aut, pts_away_aut, fuente,
         estado_en_nfl_partidos, pts_home_en_nfl_partidos, pts_away_en_nfl_partidos
  from v_nfl_resultado_autoritativo
  where estado_autoritativo = 'FINAL' and not conflicto and desalineado;

  if not p_dry_run then
    update nfl_partidos n
       set estado = 'final', pts_home = r.ph, pts_away = r.pa, actualizado = now()
      from _rec r
     where n.espn_event_id::text = r.espn_event_id
       and (n.estado is distinct from 'final'
            or n.pts_home is distinct from r.ph
            or n.pts_away is distinct from r.pa);
    get diagnostics v_aplicadas = row_count;
  end if;

  select jsonb_build_object(
    'dry_run', p_dry_run,
    'candidatas', (select count(*) from _rec),
    'filas_actualizadas', v_aplicadas,
    'bloqueadas_por_conflicto', (select count(*) from v_nfl_resultado_autoritativo where conflicto),
    'desalineados_restantes', (select count(*) from v_nfl_resultado_autoritativo where desalineado),
    'detalle', coalesce((select jsonb_agg(jsonb_build_object(
        'evento', espn_event_id, 'fuente', fuente,
        'antes', coalesce(estado_antes,'?')||' '||coalesce(ph_antes::text,'null')||'-'||coalesce(pa_antes::text,'null'),
        'despues', 'final '||ph||'-'||pa) order by espn_event_id) from _rec), '[]'),
    'conflictos', coalesce((select jsonb_agg(jsonb_build_object(
        'evento', espn_event_id, 'detalle', conflicto_detalle) order by espn_event_id)
        from v_nfl_resultado_autoritativo where conflicto), '[]'))
  into v_obj;
  return v_obj;
end $function$;

-- =====================================================================
-- 3) picks_calificacion DEJA DE SER UNA SEGUNDA VERDAD
-- =====================================================================
-- Era una DERIVACION de picks_data que solo poblaba
-- auto_close_parlay_when_all_legs_decided. Los parlays cerrados por otro camino
-- (AUTO_LOST_LEG) quedaban con [] y otros con un snapshot viejo que decia
-- 'pendiente' con pick_desc NULL. Medido: 42 vacios y 26 divergentes de 68, de
-- los cuales 6 discrepaban en el RESULTADO del leg.
-- El trigger va al final del orden alfabetico para ver picks_data ya canonizado
-- por canonizar_legs_parlay / trg_reconstruir_sgm_parlay / enrich_parlay_espn_ids.
create or replace function public.tg_derivar_picks_calificacion()
returns trigger language plpgsql set search_path to 'public' as $function$
begin
  if NEW.resultado is distinct from 'pendiente'
     and jsonb_typeof(NEW.picks_data) = 'array'
     and jsonb_array_length(NEW.picks_data) > 0 then
    NEW.picks_calificacion := (
      select jsonb_agg(jsonb_build_object(
               'pick_desc', leg->>'pick_desc',
               'resultado', coalesce(leg->>'resultado','pendiente'))
             order by ord)
      from jsonb_array_elements(NEW.picks_data) with ordinality t(leg, ord));
  end if;
  return NEW;
end $function$;

drop trigger if exists zzzzz_derivar_picks_calificacion on public.parlays;
create trigger zzzzz_derivar_picks_calificacion
  before insert or update on public.parlays
  for each row execute function public.tg_derivar_picks_calificacion();

-- =====================================================================
-- 4) GATE
-- =====================================================================
create or replace function public.gate_resultado_autoridad()
returns jsonb language sql stable set search_path to 'public' as $function$
with legs as (
  select p.id, p.resultado,
         count(*) filter (where coalesce(e->>'resultado','pendiente')='pendiente') pendientes,
         count(*) filter (where e->>'resultado'='perdido') perdidos
  from parlays p, jsonb_array_elements(p.picks_data) e
  where p.resultado is distinct from 'pendiente'
  group by p.id, p.resultado
)
select jsonb_build_object(
  'NFL_ESTADO_DESALINEADO',
     (select count(*) from v_nfl_resultado_autoritativo where desalineado and not conflicto),
  'NFL_RESULTADO_EN_CONFLICTO',
     (select count(*) from v_nfl_resultado_autoritativo where conflicto),
  'PARLAY_CALIFICACION_DIVERGENTE',
     (select count(*) from parlays p where p.resultado is distinct from 'pendiente'
       and p.picks_calificacion is distinct from (
         select jsonb_agg(jsonb_build_object('pick_desc', leg->>'pick_desc',
                'resultado', coalesce(leg->>'resultado','pendiente')) order by ord)
         from jsonb_array_elements(p.picks_data) with ordinality t(leg,ord))),
  'PARLAY_GANADO_CON_LEG_PENDIENTE', (select count(*) from legs where resultado='ganado' and pendientes>0),
  'PARLAY_PERDIDO_SIN_LEG_PERDIDO',  (select count(*) from legs where resultado='perdido' and perdidos=0),
  'parlays_perdidos_con_legs_pendientes_legitimos',
     (select count(*) from legs where resultado='perdido' and pendientes>0 and perdidos>0),
  'eventos_nfl', (select count(*) from v_nfl_resultado_autoritativo),
  'finales_por_fuente', (select jsonb_object_agg(fuente, n) from
     (select fuente, count(*) n from v_nfl_resultado_autoritativo
       where estado_autoritativo='FINAL' group by 1) q),
  'detalle_conflictos', coalesce((select jsonb_agg(jsonb_build_object(
     'evento', espn_event_id, 'detalle', conflicto_detalle))
     from v_nfl_resultado_autoritativo where conflicto), '[]'));
$function$;

commit;

-- =====================================================================
-- 5) PRUEBA OBLIGATORIA: RUN 1 / RUN 2
-- =====================================================================
-- Ejecutado en produccion el 2026-09-12:
--   ANTES  nfl_partidos huella dca717d424d75b2887bc82127f7164a6, 298 finales, 4 desalineados
--   RUN 1  huella d7514ceaffe7226fbb5928080853b245, 301 finales, 1 desalineado, 3 filas
--   RUN 2  huella d7514ceaffe7226fbb5928080853b245, 301 finales, 1 desalineado, 0 filas
--   -> IDEMPOTENTE. 0 grades duplicados, 0 payout duplicado, 0 mutacion de resultado.
--   El 1 desalineado restante es el evento EN CONFLICTO 401874394: falla cerrado.
--
-- Derivacion de picks_calificacion, tambien dos corridas:
--   vacias 41 -> 0 -> 0 ; divergentes 26 -> 0 -> 0
--   huella economica (id|resultado|ganancia_neta|bankroll_post|md5(picks_data))
--   IDENTICA en las tres fases; notificaciones 362 -> 362 -> 362.
--   Verificado antes de escribir que TODOS los triggers economicos y de
--   notificacion estan guardados por cambio de `resultado`:
--     actualizar_bankroll_post_parlay  OLD.resultado='pendiente' AND NEW IN (...)
--     trigger_recalc_semana_on_grade   OLD.resultado IS DISTINCT FROM NEW.resultado
--     notify_parlay_graded             OLD='pendiente' AND NEW IN ('ganado','perdido')
--     capture_parlay_legs_to_ai_learning / audit_parlay_grading / protect_...
--                                      salen si el resultado no cambia
--
-- CONTROLES NEGATIVOS (transaccion revertida):
--   devolver 401872657 a 'scheduled'            -> NFL_ESTADO_DESALINEADO 0 -> 1
--   corromper picks_calificacion de fbb18adb    -> PARLAY_CALIFICACION_DIVERGENTE 0 -> 1
--
-- ESTADO AL CERRAR ISS102:
--   NFL_ESTADO_DESALINEADO           = 0
--   PARLAY_CALIFICACION_DIVERGENTE   = 0
--   PARLAY_GANADO_CON_LEG_PENDIENTE  = 0
--   NFL_RESULTADO_EN_CONFLICTO       = 1   BLOCKER, ver abajo
--   PARLAY_PERDIDO_SIN_LEG_PERDIDO   = 1   HALLAZGO NUEVO, abierto
--
-- BLOCKER EXTERNO PRECISO: evento 401874394. Dos fuentes de ESPN se contradicen
-- (box score 15-24 vs feed en vivo 0-0). Los game logs corroboran el box score,
-- pero NO reconcilio automaticamente sobre un conflicto: haria falta decidir si
-- live_scores debe purgarse/recapturarse para ese evento. Queda fallando cerrado.
