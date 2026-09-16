-- =====================================================================
-- ISS139 -- LAS COMPETENCIAS NO ESTABAN BLOQUEADAS POR LA POLITICA
--
-- El dueno pidio "hacer todo de una vez": Libertadores, AFC, EFL Cup, Copa
-- del Rey, Coppa Italia y las copas europeas. Yo llevaba dos issues
-- diciendo que el bloqueo era la politica de competiciones. ESTABA MAL, y
-- lo mido aqui.
--
-- ============ LO QUE DE VERDAD BLOQUEABA ============
--
-- Corri el predictor canonico sobre los 69 eventos bloqueados, pasandoles
-- una competencia YA APROBADA para saltarme la politica y ver que pasaba:
--
--   Taca de Portugal  39 eventos -> 0 saldrian. HOME_DOMESTIC_SAMPLE_BELOW_15
--   KNVB Beker        20 eventos -> 0 saldrian. HOME_DOMESTIC_SAMPLE_BELOW_15
--   EFL Cup            5 eventos -> 2 saldrian. 3 por phi
--   Libertadores       3 eventos -> 0 saldrian. 2 muestra, 1 phi
--   Sudamericana       2 eventos -> el dueno dijo NO
--
-- O sea: aprobar la politica destraba 2 partidos. Los otros 67 estan
-- bloqueados por DATOS, no por permisos.
--
-- PRIMER ERROR MIO EN ESTA MEDICION: mi primer conteo dijo "39 de 39
-- funcionarian". Era falso. Contaba `j ? 'p_home'`, y la llave EXISTE con
-- valor null. Al contar `p_home is not null` el numero real fue 0. Estuve
-- a un paso de reportar exactamente lo contrario de la verdad.
--
-- ============ LA CAUSA RAIZ: 6 TRABAJOS MUERTOS ============
--
-- Fui hacia atras en la cadena: sin muestra domestica no hay prediccion,
-- y la muestra la llena v2.soccer_coverage_job. Ahi estaba todo:
--
--   218 trabajos en cola
--   199 con CERO observaciones
--   153 con attempts = 0 y last_run_at NULL: JAMAS habian sido tocados
--
-- Y a la cabeza de la cola, estos seis:
--
--   Willem II        102 intentos   kickoff 11-sep   6 observaciones
--   Ross County      100 intentos   kickoff 12-sep   0 observaciones
--   Lyngby Boldklub   97 intentos   kickoff 13-sep   8 observaciones
--   Monza             96 intentos   kickoff 13-sep   4 observaciones
--   KV Kortrijk       87 intentos   kickoff 13-sep   6 observaciones
--   Abha              10 intentos   kickoff 13-sep   7 observaciones
--
-- Hoy es 16 de septiembre. Los seis partidos YA SE JUGARON.
--
-- get_soccer_coverage_jobs ordenaba por next_kickoff ASCENDENTE. Un partido
-- del 11 de septiembre siempre es "mas urgente" que uno del 19. Como esos
-- seis nunca terminaban, se quedaban eternamente a la cabeza, y el worker
-- se los volvia a comer CADA CINCO MINUTOS, gastando 3 llamadas a la API
-- cada vez. Bloqueo de cabeza de linea, de manual.
--
-- Eso explica el sintoma que vi en ISS137 y no supe leer: la ingesta paso
-- de 24 equipos por media hora a 6. No era la cuota. Era que estos seis
-- habian llegado a la cabeza y ya no soltaban la cola.
--
-- ============ EL ARREGLO, EN get_soccer_coverage_jobs ============
--
--  1) ESPERA EXPONENCIAL: 5 min, 10, 20 ... con tope de 12 horas. Un
--     trabajo que fallo cien veces no se reintenta a los cinco minutos.
--  2) UN PARTIDO YA JUGADO VA AL FINAL. Deja de ser urgente cuando ya paso.
--  3) LOS INTENTOS PESAN ANTES QUE EL KICKOFF: un trabajo nuevo le gana a
--     uno que ya fallo. Antes era al reves.
--
-- No se toco el limite de 6, ni la forma de la salida, ni que columnas
-- devuelve. Solo A CUALES trabajos les toca turno.
--
-- MEDIDO EN VIVO, UNA CORRIDA DESPUES DEL CAMBIO:
--   Imortal: de 0 a 39 observaciones, DATA_READY.
--   Es justo uno de los equipos de la Taca de Portugal que bloqueaban 39
--   eventos, y llevaba dias en la cola sin recibir un solo turno.
--
-- ============ LA POLITICA, Y POR QUE APROBARLA NO INVENTA NADA ============
--
-- Aprobar una competencia NO fabrica una prediccion. Solo autoriza a RETO a
-- publicarla CUANDO tenga los datos. Cada partido sigue exigiendo la forma
-- domestica real de los dos equipos y la fuerza de liga sellada; si falta
-- cualquiera, ese partido sigue sin publicar probabilidad. Por eso al
-- aprobar 8 competencias el resultado fue +2 publicados y 0 perdidos: los
-- otros siguen fallando cerrado, ahora con la razon HONESTA.
--
--   antes:  156 con P_RETO   |   despues: 158   |   ganados 2   |   PERDIDOS 0
--
-- Razones de los que siguen sin publicar, ya sin mentiras de permisos:
--   HOME_DOMESTIC_SAMPLE_BELOW_15 ........ 61  (esperan ingesta)
--   DOMESTIC_LEAGUE_PHI_NOT_SERVABLE_ASOF  10  (esperan phi, que sigue a la ingesta)
--   NO_APPROVED_SOCCER_POLICY ............  2  (Sudamericana, decision del dueno)
--
-- La decision de ALCANCE quedo escrita en v2.competencia_autorizada_por_dueno,
-- no metida a mano en la tabla de politica. Asi la Copa del Rey se enciende
-- sola el dia que aparezca en el catalogo, sin que nadie tenga que acordarse.
-- Sudamericana esta ahi con autorizada=false y G34.4 vigila que siga en NO.
--
-- La evidencia de cada aprobacion dice la verdad completa:
--   basis: MECANISMO_CROSS_LEAGUE_VALIDADO_EN_UCL_Y_UEL
--   oos_de_esta_competicion: null
--   riesgo_conocido: en una copa domestica una de las dos partes suele ser
--     de division inferior, con phi de muestra corta, y el modelo no incluye
--     efectos propios de copa (rotacion, motivacion). No hay OOS de esta
--     competencia todavia.
--
-- ============ EL ERROR QUE ESTUVE A PUNTO DE METER ============
--
-- 152 trabajos no tienen api_team_id y el worker falla con
-- TEAM_IDENTITY_NOT_RESOLVED. Note que las URLs de escudo que ya guardamos
-- traen un id: /teams/<id>.png. Resolvi 69 identidades con eso.
--
-- Antes de darlo por bueno lo VALIDE contra los equipos cuya identidad el
-- worker ya habia resuelto por nombre exacto:
--     46 comparables | 36 coinciden | 9 DISCREPAN | 1 ambiguo
--     Palmeiras: worker 121, escudo 24484
--     Troyes:    worker 110, escudo  9945
--     Viktoria Plzen: worker 567, escudo 7970
--
-- 20% de error. Esas URLs NO son ids de API-Football. REVERTI las 69
-- asignaciones y borre la funcion. Asignar ahi una identidad equivocada
-- significa bajar el historial de OTRO equipo y meterlo al modelo como si
-- fuera este: es exactamente la sustitucion silenciosa de identidad que el
-- dueno prohibio. La validacion es la unica razon por la que no se fue.
--
-- Y de ahi salio algo bueno: G34.9. Si el api_team_id fuera de otro equipo,
-- los goles que bajamos de API-Football no cuadrarian con el marcador que
-- ESPN tiene para ESE equipo ESE dia. Medido sobre lo ya cargado:
--     550 partidos de 25 equipos | 549 coinciden | 1 discrepa (0.18%)
-- Lo que ya esta en la base esta sano. Ahora queda vigilado para siempre.
--
-- ============ LO QUE NO SE HIZO, Y POR QUE ============
--
-- 1) LA EVIDENCIA DE COPA DOMESTICA PARA phi QUEDO INSTALADA Y APAGADA.
--    fn_fit_phi_extension acepta ahora p_incluir_copa_domestica (default
--    false, o sea: toda llamada existente se comporta identico; verificado
--    con Croacia, que reprodujo n=21, phi -0.406, Brier 0.7810 vs 0.8334,
--    byte a byte lo de ISS133).
--    Medida con copas encendidas sobre las segundas divisiones:
--      Serie B 2 filas | Championship 1 | Segunda Liga 1 | League Two 0
--      Eerste Divisie 0 | LaLiga2 0
--    No hay con que medirla contra el holdout. Encenderla sin poder medirla
--    seria justo lo que este proyecto no hace. Se enciende cuando la ingesta
--    de arriba llene esas ligas y el holdout pueda opinar.
--
-- 2) ligas_master NO SE PARCHEO. 24 filas de futbol tienen api_sports_id
--    apuntando a otra competicion que la del endpoint. Las dos con datos:
--      Scottish Cup (sco.tennents) -> 180 = Championship escoces, 303 partidos
--      KNVB Beker   (ned.cup)      ->  89 = Eerste Divisie,        172 partidos
--    Cambiar api_sports_id mueve de que competicion se descarga el historial
--    de ESPN. Se resuelve SIN tocarla: v2.v_ligas_domesticas_confiables solo
--    acepta los endpoints con forma de liga cuyo catalogo tambien dice liga
--    (55 de 141). Nadie vuelve a joinear el catalogo contra
--    historico_partidos_espn.liga_id. Ese join fue el bug de Stenhousemuir.
--
-- 3) LA RESOLUCION DE LIGA EXIGE RECENCIA, Y ESO COSTO EQUIPOS A PROPOSITO.
--    Sin recencia, el argmax historico resolvia 6 equipos. Cuatro estaban
--    MAL: Chaves, Portimonense, Farense y Vizela descendieron y su historial
--    viejo de Primeira pesaba mas que su presente. Con la ventana de 400
--    dias quedan 2, y los 2 verificados contra la tabla 2026:
--      Maritimo -> Primeira Liga (jornada 6, puesto 11)
--      St Johnstone -> Premiership (jornada 6, puesto 7)
--    Prefiero 2 correctos que 6 con cuatro mentiras.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) EL ARREGLO DE LA COLA. Es el que destraba todo lo demas.
-- ---------------------------------------------------------------------
create or replace function public.get_soccer_coverage_jobs(p_limit integer DEFAULT 3)
returns table(team_espn_id text, team_name text, api_team_id integer, domestic_league_id integer,
              domestic_league_name text, target_sample integer, status text, reason text,
              attempts integer, last_error text, last_run_at timestamp with time zone,
              next_kickoff timestamp with time zone, history_start timestamp with time zone)
language sql security definer set search_path to 'v2','public'
as $function$
with active_model as (
  select public.get_active_crossleague_model_version() model_version
), model_cut as (
  select r.model_version,r.training_cutoff
  from v2.crossleague_model_registry r join active_model a on a.model_version=r.model_version
), impacted as (
  select j.domestic_league_id,min(j.next_kickoff) impacted_kickoff
  from v2.soccer_coverage_job j cross join model_cut m
  left join v2.crossleague_league_strength s
    on s.model_version=m.model_version and s.training_cutoff=m.training_cutoff
   and s.league_id=j.domestic_league_id and s.servable
  where j.next_kickoff between now() and now()+interval '14 days'
    and j.domestic_league_id is not null and s.league_id is null
  group by j.domestic_league_id
), elegibles as (
  select j.*, i.impacted_kickoff,
         (j.next_kickoff is not null and j.next_kickoff < now()) as ya_se_jugo
  from v2.soccer_coverage_job j
  left join impacted i on i.domestic_league_id=j.domestic_league_id
  where (j.status in ('PENDING','RETRY')
         or (j.status='RUNNING' and coalesce(j.last_run_at,j.updated_at,j.created_at)<now()-interval '10 minutes'))
    -- espera exponencial: 5 min, 10, 20 ... con tope de 12 horas
    and (j.last_run_at is null
         or j.last_run_at < now() - least(
              (interval '5 minutes') * power(2, least(coalesce(j.attempts,0), 7)),
              interval '12 hours'))
)
select e.team_espn_id,e.team_name,e.api_team_id,e.domestic_league_id,e.domestic_league_name,e.target_sample,
       case when e.status='RUNNING' then 'RETRY' else e.status end as status,
       e.reason,e.attempts,e.last_error,e.last_run_at,e.next_kickoff,e.history_start
from elegibles e
order by
  e.ya_se_jugo,                      -- lo que ya se jugo, hasta el final
  case when e.reason in ('DOMESTIC_SAMPLE_BELOW_TARGET','BACKFILL_RETRY','DOMESTIC_SAMPLE_STILL_LOW')
            and e.next_kickoff<=now()+interval '14 days' then 0
       when e.reason='PHI_HISTORY_REQUIRED' and e.impacted_kickoff is not null then 1
       when e.next_kickoff<=now()+interval '14 days' then 2 else 3 end,
  e.attempts,                        -- los nuevos antes que los que ya fallaron
  e.impacted_kickoff nulls last,
  e.next_kickoff nulls last,
  e.team_name
limit greatest(1,least(p_limit,6));
$function$;


-- ---------------------------------------------------------------------
-- 2) Mapeo de liga confiable. NUNCA joinear el catalogo de API-Football
--    contra historico_partidos_espn.liga_id: ese join fue el bug de
--    Stenhousemuir y hay 24 filas de ligas_master que lo rompen.
-- ---------------------------------------------------------------------
create or replace view v2.v_ligas_domesticas_confiables as
select lm.espn_endpoint, lm.api_sports_id as league_id, c.nombre as league_name,
       c.pais, lm.nombre as nombre_espn
from public.ligas_master lm
join public.apifootball_ligas_catalogo c on c.liga_id = lm.api_sports_id
where lm.deporte='soccer'
  and lm.espn_endpoint ~ '^soccer/[a-z]+\.[0-9]+$'   -- forma de liga, no de copa
  and lower(c.tipo) = 'league'                        -- y el catalogo lo confirma
  and lm.api_sports_id is not null;

revoke all on v2.v_ligas_domesticas_confiables from public;
grant select on v2.v_ligas_domesticas_confiables to service_role;

-- Resolutor con RECENCIA OBLIGATORIA. Sin ella un equipo descendido se
-- queda asignado a la division de la que bajo.
create or replace function v2.fn_resolver_liga_domestica(p_team_espn_id text)
returns table(league_id int, league_name text, fuente text, evidencia int)
language sql stable set search_path to 'v2','public' as $fn$
  (select lc.league_id, lc.league_name, 'ESPN_STANDINGS'::text, coalesce(r.pj,0)
   from public.espn_standings_raw r
   join v2.v_ligas_domesticas_confiables lc on lc.espn_endpoint = r.espn_endpoint
   where r.espn_team_id = p_team_espn_id
   order by r.temporada desc, r.pj desc nulls last
   limit 1)
  union all
  (select x.league_id, x.league_name, 'HISTORIAL_ESPN_400D'::text, x.n
   from (
     select lc.league_id, min(lc.league_name) league_name, count(*)::int n
     from public.historico_partidos_espn h
     join v2.v_ligas_domesticas_confiables lc on lc.espn_endpoint = h.espn_endpoint
     where (h.home_espn_id = p_team_espn_id or h.away_espn_id = p_team_espn_id)
       and h.fecha >= now() - interval '400 days'
     group by lc.league_id
     having count(*) >= 5
     order by count(*) desc, lc.league_id
     limit 1
   ) x
   where not exists (
     select 1 from public.espn_standings_raw r
     join v2.v_ligas_domesticas_confiables l2 on l2.espn_endpoint = r.espn_endpoint
     where r.espn_team_id = p_team_espn_id));
$fn$;


-- ---------------------------------------------------------------------
-- 3) La decision de alcance del dueno, escrita. Y su sincronizacion.
--    v2.competencia_autorizada_por_dueno  (patron, autorizada, nota)
--    v2.sincronizar_politica_competencias()
--    v2.mantenimiento_cobertura_soccer()  -> cron '41 * * * *'
--    (definiciones completas en produccion y en el cuerpo de este commit)
-- ---------------------------------------------------------------------


-- =====================================================================
-- MEDIDO. GATE 34, 7 duras + 2 INFO:
--   G34.1 la cola no la acapara un trabajo muerto ........ PASS  0
--   G34.2 un partido ya jugado no va primero ............. PASS  0
--   G34.3 toda competencia aprobada declara su base ...... PASS  0
--   G34.4 lo que el dueno dijo que no, sigue en no ....... PASS  0
--   G34.5 ninguna liga asignada viene de un mapeo roto ... PASS  0
--   G34.6 la evidencia de copa domestica sigue apagada ... PASS  0
--   G34.9 la identidad del equipo cuadra con el marcador . PASS  1  (0.18%)
--   G34.7 por que falta cada partido sin probabilidad .... INFO  3
--   G34.8 ligas_master con mapeo inconsistente ........... INFO  24
--
-- G34.9 es la que mas me importa de todas: es la unica prueba dura de
-- identidad que se puede hacer con estos datos, y nacio de un error mio
-- que estuvo a punto de entrar a produccion.
--
-- GATE 30 y GATE 33 siguen verdes despues de todo esto.
--
-- REVERSION:
--   -- la cola: volver el order by a next_kickoff sin ya_se_jugo, sin
--   -- espera exponencial y con attempts despues del kickoff.
--   delete from v2.crossleague_competition_policy
--    where evidence->>'decidido_por' like 'dueno (v2.competencia_autorizada%';
--   select cron.unschedule('mantenimiento-cobertura-soccer');
--   drop function v2.sincronizar_politica_competencias();
--   drop table v2.competencia_autorizada_por_dueno;
-- =====================================================================
