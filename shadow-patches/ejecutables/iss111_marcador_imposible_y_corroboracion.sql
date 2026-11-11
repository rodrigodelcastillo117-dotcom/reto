-- =====================================================================
-- ISS111  UN MARCADOR IMPOSIBLE NO ES UN CONFLICTO: ES UN DATO FALSO
-- =====================================================================
-- EL CASO, CON SUS TRES FUENTES
--   Evento 401874394, Tennessee Titans vs Chicago Bears, 2026-08-29.
--
--   live_scores              status=final, 0 - 0
--                            status_detail='FT (recuperado del historico ESPN)'
--                            updated_at 2026-09-03 19:32  (EL MAS NUEVO)
--   historico_partidos_espn  15 - 24
--                            cargado_at 2026-08-30 17:01
--   nfl_player_game_logs     CHI 1 rush + 2 rec = 3 TD reales (16 registros)
--                            TEN 1 rush + 0 rec = 1 TD real  (16 registros)
--                            pass_tds=2 en CHI duplica los mismos TD de
--                            recepcion; el total de equipo es rush+rec.
--
--   nfl_reconciliar_resultado() lo marca "bloqueado por conflicto" y no lo
--   toca. Esa fue la decision correcta mientras no hubiera prueba.
--
-- POR QUE YA NO ES UN CONFLICTO
--   Un touchdown vale 6 puntos como MINIMO. Si los game logs registran 3 TD
--   de Chicago, el marcador de Chicago no puede ser menor que 18. Si
--   registran 1 TD de Tennessee, el de Tennessee no puede ser menor que 6.
--   El 15-24 del historico cumple las dos cotas (24>=18, 15>=6).
--   El 0-0 de live_scores viola las dos.
--
--   Eso no es opinion ni reconstruccion del marcador: es una cota inferior
--   aritmetica. No se inventa nada. No hay dos verdades en disputa: hay una
--   fuente corrompida contra dos que se corroboran.
--
-- POR QUE NO SE ARREGLA A MANO
--   El dueno prohibio el arreglo manual de calificacion como solucion. Aqui
--   no se escribe "15-24" a mano en ningun lado: se ADOPTA el valor de la
--   autoridad ya declarada (historico_partidos_espn, precedencia de
--   v_nfl_resultado_autoritativo) y solo cuando los game logs la corroboran.
--   Si manana los logs no corroboran, la funcion no toca nada.
--
-- LA CAUSA RAIZ, QUE ES LO QUE DE VERDAD HAY QUE CERRAR
--   Los tres escritores NFL de live_scores sobreescriben el marcador SIN
--   GUARDA:
--     espejar_nfl_a_live()   on conflict do update set home_score = EXCLUDED.home_score
--     sync_nfl_cdn_tick()    on conflict do update set home_score = excluded.home_score
--     sync_nfl_desde_cdn()   on conflict do update set home_score = excluded.home_score
--   El patron correcto YA EXISTE en este mismo esquema:
--     upsert_live_scores_guarded()
--       home_score = coalesce(excluded.home_score, live_scores.home_score)
--   Es decir: el codigo sabia como hacerlo bien y tres funciones no lo hacen.
--   Cualquier lectura del feed que venga sin marcador destruye un marcador
--   conocido. Que escritura exacta produjo el 0-0 el 3-sep no lo puedo
--   probar: no hay bitacora de escrituras. Lo que si esta probado es la
--   clase de defecto y que las tres puertas siguen abiertas.
--
-- BUG ADICIONAL EN completar_metadatos_live()
--   Sus CTE 'rec' y 'u' son hermanos del MISMO statement y comparten el
--   WHERE (status='scheduled' AND game_date < now()-2d); 'u' solo le quita
--   la condicion de que exista historico. Los efectos de un CTE que modifica
--   datos NO son visibles para sus hermanos, asi que una fila recuperada por
--   'rec' tambien es blanco de 'u', y cual gana no lo decide el autor.
--   Es el MISMO error que yo cometi hoy midiendo idempotencia con CTEs
--   hermanos. Se corrige excluyendo en 'u' lo que 'rec' ya resolvio.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) LA COTA: cuantos puntos como minimo anoto un equipo
-- ---------------------------------------------------------------------
create or replace function public.nfl_puntos_minimos_por_tds(p_event_id text, p_team text)
returns int language sql stable as $fn$
  -- IDENTIDAD EXACTA, SIN ADIVINAR.
  --   live_scores guarda 'Tennessee Titans'; nfl_player_game_logs guarda 'TEN'.
  --   Mi primera version comparaba g.team = p_team directo y devolvia 0 para
  --   TODOS los equipos, lo que hacia que ningun marcador fuera imposible: el
  --   gate habria dado verde con el 0-0 intacto. Lo atrapo la prueba negativa.
  --   Se resuelve por nfl_equipo_abrev, que es un mapa declarado de 32 filas y
  --   cubre 32 de los 32 nombres distintos de live_scores NFL. Si un nombre no
  --   resuelve, no hay sustitucion difusa: la cota queda NULL y
  --   nfl_marcador_imposible no afirma nada.
  --
  -- rush_tds + rec_tds es el total real del equipo. pass_tds duplica los
  -- mismos touchdowns de recepcion y sumarlo contaria cada TD dos veces.
  select case
    when not exists (select 1 from public.nfl_equipo_abrev a
                     where a.nombre = p_team or a.abrev = p_team)
      then null
    else coalesce((
      select (sum(g.rush_tds) + sum(g.rec_tds)) * 6
      from public.nfl_player_game_logs g
      where g.espn_event_id = p_event_id
        and g.team = coalesce(
              (select a.abrev from public.nfl_equipo_abrev a where a.nombre = p_team),
              p_team)
    ), 0)
  end;
$fn$;

comment on function public.nfl_puntos_minimos_por_tds(text,text) is
'ISS111. Cota INFERIOR de puntos de un equipo segun sus touchdowns registrados: un TD vale 6 como minimo. No reconstruye el marcador (faltan FG, XP y 2pt): solo dice por debajo de que numero el marcador es imposible.';

create or replace function public.nfl_marcador_imposible(
  p_event_id text, p_home_team text, p_away_team text,
  p_home_score int, p_away_score int)
returns boolean language sql stable as $fn$
  select case
    when p_home_score is null or p_away_score is null then false
    -- sin game logs no hay prueba: no se afirma imposibilidad
    when not exists (select 1 from public.nfl_player_game_logs g
                     where g.espn_event_id = p_event_id) then false
    -- si un nombre de equipo no resuelve a abreviatura, la cota es NULL y no
    -- se afirma imposibilidad: falta de prueba no es prueba
    else coalesce(p_home_score < public.nfl_puntos_minimos_por_tds(p_event_id, p_home_team), false)
      or coalesce(p_away_score < public.nfl_puntos_minimos_por_tds(p_event_id, p_away_team), false)
  end;
$fn$;

comment on function public.nfl_marcador_imposible(text,text,text,int,int) is
'ISS111. true solo cuando el marcador declarado queda por DEBAJO de la cota que imponen los touchdowns registrados. Sin game logs devuelve false: falta de prueba no es prueba.';

-- ---------------------------------------------------------------------
-- 2) BITACORA: lo que se rechazo, con su evidencia
-- ---------------------------------------------------------------------
create table if not exists public.marcador_degradacion_rechazada (
  id              bigserial primary key,
  espn_event_id   text        not null,
  score_rechazado text        not null,
  score_conservado text       not null,
  evidencia       jsonb       not null,
  rechazado_at    timestamptz not null default now()
);

comment on table public.marcador_degradacion_rechazada is
'ISS111. Cada intento de escribir un marcador imposible sobre uno valido, con su evidencia. Si esta tabla crece, el escritor que la llena es el que hay que arreglar.';

-- ---------------------------------------------------------------------
-- 3) LA GUARDA CENTRAL
--    Un solo disparador protege a los TRES escritores sin editarlos. No
--    levanta excepcion a proposito: si abortara, tumbaria la corrida de
--    cron completa. Conserva el valor bueno y deja registro.
-- ---------------------------------------------------------------------
create or replace function public.tg_no_degradar_marcador_nfl()
returns trigger language plpgsql as $fn$
declare v_min_h int; v_min_a int;
begin
  -- solo NFL, solo cuando YA habia un marcador no nulo
  if coalesce(NEW.liga,'') <> 'NFL' then return NEW; end if;
  if OLD.home_score is null or OLD.away_score is null then return NEW; end if;
  if NEW.home_score is not distinct from OLD.home_score
     and NEW.away_score is not distinct from OLD.away_score then return NEW; end if;

  if public.nfl_marcador_imposible(NEW.espn_event_id, NEW.home_team, NEW.away_team,
                                   NEW.home_score, NEW.away_score)
     and not public.nfl_marcador_imposible(NEW.espn_event_id, OLD.home_team, OLD.away_team,
                                           OLD.home_score, OLD.away_score)
  then
    v_min_h := public.nfl_puntos_minimos_por_tds(NEW.espn_event_id, NEW.home_team);
    v_min_a := public.nfl_puntos_minimos_por_tds(NEW.espn_event_id, NEW.away_team);

    insert into public.marcador_degradacion_rechazada
      (espn_event_id, score_rechazado, score_conservado, evidencia)
    values (NEW.espn_event_id,
            NEW.home_score || '-' || NEW.away_score,
            OLD.home_score || '-' || OLD.away_score,
            jsonb_build_object(
              'minimo_por_tds_home', v_min_h,
              'minimo_por_tds_away', v_min_a,
              'home_team', NEW.home_team, 'away_team', NEW.away_team,
              'status_entrante', NEW.status,
              'detalle_entrante', NEW.status_detail));

    -- se conserva el marcador que SI es posible
    NEW.home_score := OLD.home_score;
    NEW.away_score := OLD.away_score;
  end if;

  return NEW;
end;
$fn$;

comment on function public.tg_no_degradar_marcador_nfl() is
'ISS111. Impide que un marcador imposible (por debajo de la cota de touchdowns) reemplace a uno posible. Protege de una vez a espejar_nfl_a_live, sync_nfl_cdn_tick y sync_nfl_desde_cdn, que escriben EXCLUDED.home_score sin guarda. No levanta excepcion: abortar tumbaria la corrida de cron.';

drop trigger if exists zz_no_degradar_marcador_nfl on public.live_scores;
create trigger zz_no_degradar_marcador_nfl
  before update on public.live_scores
  for each row execute function public.tg_no_degradar_marcador_nfl();

-- ---------------------------------------------------------------------
-- 4) RESOLVER EL CONFLICTO POR CORROBORACION, NO A MANO
-- ---------------------------------------------------------------------
create or replace function public.nfl_resolver_conflicto_corroborado(p_dry_run boolean default true)
returns table(accion text, evento text, de text, a text, evidencia jsonb)
language plpgsql as $fn$
begin
  create temp table if not exists _cand on commit drop as
  select ls.espn_event_id, ls.home_team, ls.away_team,
         ls.home_score ls_h, ls.away_score ls_a,
         h.home_score hi_h, h.away_score hi_a,
         public.nfl_puntos_minimos_por_tds(ls.espn_event_id, ls.home_team) min_h,
         public.nfl_puntos_minimos_por_tds(ls.espn_event_id, ls.away_team) min_a
  from public.live_scores ls
  join public.historico_partidos_espn h on h.espn_event_id = ls.espn_event_id
  where ls.liga = 'NFL'
    and h.home_score is not null and h.away_score is not null
    -- live_scores contradice al historico
    and (ls.home_score, ls.away_score) is distinct from (h.home_score, h.away_score)
    -- y el de live_scores es IMPOSIBLE mientras el del historico SI es posible
    and public.nfl_marcador_imposible(ls.espn_event_id, ls.home_team, ls.away_team,
                                      ls.home_score, ls.away_score)
    and not public.nfl_marcador_imposible(ls.espn_event_id, ls.home_team, ls.away_team,
                                          h.home_score, h.away_score);

  if p_dry_run then
    return query
      select 'SE_ADOPTARIA_EL_HISTORICO'::text, c.espn_event_id,
             c.ls_h||'-'||c.ls_a, c.hi_h||'-'||c.hi_a,
             jsonb_build_object('minimo_por_tds_home', c.min_h,
                                'minimo_por_tds_away', c.min_a,
                                'por_que', 'el marcador de live_scores queda por debajo de la cota de touchdowns y el del historico no')
      from _cand c;
    return;
  end if;

  -- idempotente: solo escribe donde sigue habiendo diferencia
  return query
    with up as (
      update public.live_scores ls
         set home_score = c.hi_h, away_score = c.hi_a,
             status_detail = 'FT (adoptado del historico, corroborado por game logs)',
             updated_at = now()
        from _cand c
       where c.espn_event_id = ls.espn_event_id
         and (ls.home_score, ls.away_score) is distinct from (c.hi_h, c.hi_a)
      returning ls.espn_event_id, c.ls_h, c.ls_a, c.hi_h, c.hi_a, c.min_h, c.min_a
    )
    select 'HISTORICO_ADOPTADO'::text, up.espn_event_id,
           up.ls_h||'-'||up.ls_a, up.hi_h||'-'||up.hi_a,
           jsonb_build_object('minimo_por_tds_home', up.min_h,
                              'minimo_por_tds_away', up.min_a)
    from up;
end;
$fn$;

comment on function public.nfl_resolver_conflicto_corroborado(boolean) is
'ISS111. Adopta el marcador del historico SOLO cuando el de live_scores es imposible segun los touchdowns registrados y el del historico no lo es. No escribe ningun numero a mano: adopta el de la autoridad ya declarada. Si los game logs no corroboran, no toca nada. Idempotente.';

-- ---------------------------------------------------------------------
-- 5) GATE
-- ---------------------------------------------------------------------
create or replace function public.gate_marcador_posible_nfl()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  select 'MARCADOR_NFL_IMPOSIBLE'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(ls.espn_event_id||': '||ls.home_score||'-'||ls.away_score
                    ||' pero los TD exigen >= '
                    ||coalesce(public.nfl_puntos_minimos_por_tds(ls.espn_event_id, ls.home_team)::text,'?')
                    ||'-'||coalesce(public.nfl_puntos_minimos_por_tds(ls.espn_event_id, ls.away_team)::text,'?'),
                  ' | '), 'ninguno')
  from public.live_scores ls
  where ls.liga = 'NFL'
    and public.nfl_marcador_imposible(ls.espn_event_id, ls.home_team, ls.away_team,
                                      ls.home_score, ls.away_score)
  union all
  select 'ESCRITOR_NFL_SIN_GUARDA_DE_MARCADOR'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(p.proname, ', ' order by p.proname), 'ninguno')
           || '. El patron correcto ya existe en upsert_live_scores_guarded: '
           || 'home_score = coalesce(excluded.home_score, live_scores.home_score). '
           || 'Mientras no se corrijan, los protege el disparador zz_no_degradar_marcador_nfl.'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace and n.nspname='public'
  where p.prosrc ~* 'on conflict'
    and p.prosrc ~* 'live_scores'
    and p.prosrc ~* '(home_score|away_score)\s*=\s*(excluded|EXCLUDED)\.'
    and p.prosrc !~* 'coalesce\s*\(\s*(excluded|EXCLUDED)\.(home_score|away_score)'
  union all
  select 'GUARDA_DE_MARCADOR_INSTALADA'::text,
         case when count(*) = 1 then 'PASS' else 'FAIL' end, count(*),
         'disparador zz_no_degradar_marcador_nfl en live_scores'
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  where c.relname = 'live_scores' and t.tgname = 'zz_no_degradar_marcador_nfl' and not t.tgisinternal
  union all
  select 'DEGRADACIONES_RECHAZADAS'::text, 'INFO', count(*),
         'intentos de escribir un marcador imposible que la guarda rechazo'
  from public.marcador_degradacion_rechazada;
$fn$;

comment on function public.gate_marcador_posible_nfl() is
'ISS111. Ningun marcador de NFL puede quedar por debajo de la cota que imponen sus touchdowns, y ningun escritor de live_scores debe sobreescribir el marcador sin guarda.';

grant execute on function public.nfl_puntos_minimos_por_tds(text,text)              to anon, authenticated, service_role;
grant execute on function public.nfl_marcador_imposible(text,text,text,int,int)     to anon, authenticated, service_role;
grant execute on function public.gate_marcador_posible_nfl()                        to anon, authenticated, service_role;
grant execute on function public.nfl_resolver_conflicto_corroborado(boolean)        to service_role;
grant select on public.marcador_degradacion_rechazada to anon, authenticated, service_role;
revoke insert, update, delete, truncate on public.marcador_degradacion_rechazada from anon, authenticated;

-- =====================================================================
-- RESULTADO Y PRUEBAS
-- =====================================================================
--   Cota y predicado: 10/10 pruebas PASS, entre ellas
--     el 0-0 es imposible                        true
--     el 15-24 del historico es posible          false
--     justo en la cota (6 y 18) es posible       false
--     un punto abajo de la cota es imposible     true
--     la abreviatura TEN/CHI tambien resuelve    true
--     sin game logs no se afirma nada            false
--     los DOS nombres sin resolver: no se adivina false
--
--   UN BUG QUE ATRAPO MI PROPIA PRUEBA NEGATIVA
--     La primera version comparaba g.team = p_team directo. live_scores
--     guarda 'Tennessee Titans' y nfl_player_game_logs guarda 'TEN', asi que
--     la cota salia 0 para TODOS los equipos y NINGUN marcador resultaba
--     imposible: el gate habria dado VERDE con el 0-0 intacto. Se resolvio
--     por nfl_equipo_abrev, mapa declarado de 32 filas que cubre 32 de 32
--     nombres de live_scores NFL. Si un nombre no resuelve, la cota es NULL y
--     no se afirma nada: no hay sustitucion difusa.
--
--   Prueba adversarial de la guarda, con control positivo:
--     paso 0  marcador corroborado 15-24
--     paso 1  ATAQUE: update a 0-0 como lo hace un sync sin guarda
--             -> RECHAZADO, se conserva 15-24, 1 rechazo con evidencia
--                (minimo_por_tds_away=18, minimo_por_tds_home=6)
--     paso 2  CONTROL POSITIVO: correccion legitima a 16-24 -> ACEPTADA
--             (la guarda no bloquea correcciones reales)
--
--   Conflicto cerrado:
--     nfl_reconciliar_resultado antes  bloqueadas_por_conflicto = 1
--     nfl_reconciliar_resultado ahora  conflictos = [], 
--       run1 filas_actualizadas=1, run2 filas_actualizadas=0  (idempotente)
--       desalineados_restantes = 0
--     gate MARCADOR_NFL_IMPOSIBLE = PASS 0
--
--   La plata NO se movio: 0 parlays contienen este evento.
--     huella economica de parlays 93b6a364879a960c4f6d969e68cf60eb, 68 filas.
--
--   La etiqueta de procedencia se corrigio: la fila decia
--   'FT (recuperado del historico ESPN)' mientras tenia 0-0, o sea afirmaba
--   una procedencia falsa. Ahora dice
--   'FT (adoptado del historico, corroborado por game logs: CHI>=18, TEN>=6)'.
--
-- LO QUE QUEDA ABIERTO Y NO VOY A ESCONDER
--   1. CINCO escritores de live_scores siguen sin guarda, dos mas de los tres
--      que habia identificado: archivar_marcadores,
--      espejar_apifootball_a_live_scores, espejar_nfl_a_live,
--      sync_nfl_cdn_tick, sync_nfl_desde_cdn. El disparador los contiene, pero
--      contener no es corregir: hay que ponerles
--      coalesce(excluded.home_score, live_scores.home_score).
--   2. El bug de CTEs hermanos en completar_metadatos_live() sigue ahi.
--      NO lo toque en esta pasada: es una funcion de cron y cambiarla sin
--      reproducir su corrida completa es arriesgar el pipeline de resultados.
--   3. oraculo_picks_tracking tiene 3 filas de este evento en
--      resultado='pendiente' pese a que el partido termino el 29-ago y su
--      marcador ya es autoritativo. Queda para el frente de calificacion.
--   4. parlays tiene 1 fila con manual_override = true. No es mia y no la
--      toque. Merece auditoria aparte: un override manual es exactamente lo
--      que el dueno prohibio como solucion.
