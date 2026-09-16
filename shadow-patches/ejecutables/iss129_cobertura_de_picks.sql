-- =====================================================================
-- ISS129 -- "DATOS DEL EVENTO INSUFICIENTES" EN PARTIDOS QUE SI TIENEN DATOS
--
-- El dueno pregunto: "el backend si tiene los analisis, solo no se ven en
-- el frontend no?". La respuesta medida es MITAD Y MITAD, y la diferencia
-- importa. Sobre sus 15 partidos exactos:
--
--   ANALISIS FACTUAL (goles esperados, forma, H2H):
--     11 de 15 completo, 4 parcial. EXISTE en el backend.
--     El front dice "Datos del evento insuficientes". Eso SI es frontend.
--
--   P_RETO (la probabilidad, el pick):
--     NO existe. model_status=DATA_INCOMPLETE. Eso NO es frontend.
--
-- Y el DATA_INCOMPLETE tenia DOS razones distintas:
--   NO_APPROVED_SOCCER_POLICY
--     Libertadores, Sudamericana, AFC, EFL Cup. Esas competiciones no
--     estan en v2.crossleague_competition_policy (solo 16 ligas domesticas
--     + UCL + UEL).
--   DOMESTIC_LEAGUE_PHI_NOT_SERVABLE_ASOF
--     Europa League. La competicion SI esta aprobada. Lo que falta es la
--     FUERZA DE LIGA (phi) de la liga domestica de alguno de los dos
--     equipos. Sin phi de ambos, fn_crossleague_predict_canonical se niega
--     a predecir. Correcto: fallar cerrado.
--
-- LA CADENA COMPLETA, Y DONDE ESTABA ROTA:
--   1. v2.soccer_coverage_job encola equipos que necesitan historial.   OK
--   2. edge soccer-global-backfill baja su liga domestica de ESPN.      PARADA
--   3. v2.soccer_domestic_observation guarda gf/ga por partido.         2810 filas
--   4. v2.fn_fit_phi_extension estima phi con holdout temporal.         NUNCA CORRIO
--   5. v2.crossleague_league_strength + sello.                          19 ligas
--   6. El modelo ya puede predecir esos partidos.
--
--   El paso 4 existia y nadie lo habia ejecutado. El paso 2 lleva parado
--   desde el 2026-09-10 con 88 equipos que nunca se procesaron.
--
-- =============== LO QUE HICE, MEDIDO ===============
--
-- A) Corri fn_fit_phi_extension sobre las 11 ligas candidatas.
--    4 PASARON el holdout (mejoran Brier Y logloss contra phi=0):
--      333 Ucrania    n=23  phi -0.496  Brier 0.4198 vs 0.7066
--      345 Chequia    n=21  phi -0.512  Brier 0.5653 vs 0.8746
--      419 Azerbaiyan n=20  phi -0.548  Brier 0.4925 vs 0.8095
--      106 Polonia    n=20  phi -0.252  Brier 0.7472 vs 0.8354
--    7 fallaron INSUFFICIENT_SAMPLE y se quedan fuera:
--      373 Eslovenia n=10, 383 Israel n=9, 210 Croacia n=17,
--      271 Hungria n=15, 318 n=19, 95 n=0, 172 n=0, 343 n=0
--
--    DE ESAS 4, SOLO POLONIA ERA NUEVA. Ucrania, Chequia y Azerbaiyan ya
--    estaban desde el 2026-09-10 con phi IDENTICO. Mi re-fit las reprodujo
--    exactas, lo cual es una buena prueba de reproducibilidad, pero no me
--    las apunto como trabajo mio.
--
-- B) Insercion ATOMICA con re-sellado.
--    v2.crossleague_league_strength esta protegida por un sello
--    (league_count + config_hash + snapshot_hash) que
--    fn_crossleague_strength_integrity valida, y
--    fn_crossleague_predict_canonical CONSULTA. Insertar sin re-sellar
--    habria tumbado TODAS las predicciones del modelo.
--    Se hizo insert + update del sello en una sola transaccion.
--      integridad antes:   true (19 ligas)
--      integridad despues: true (20 ligas)
--    Respaldo: v2.crossleague_league_strength_bak_iss129
--              v2.crossleague_strength_seal_bak_iss129
--
-- C) Reconstruccion y medicion pareada evento por evento:
--      publicados 233 | antes 152 | ahora 154 | ganados 2 | PERDIDOS 0
--    Los 2 son exactamente los clubes polacos:
--      Olympiacos - Jagiellonia Bialystok  50.8 / 24.4 / 24.8  (lambda 1.49-0.95)
--      Crystal Palace - Lech Poznan        53.8 / 21.9 / 24.3  (lambda 1.76-1.09)
--    Olympiacos-Jagiellonia estaba en la lista del dueno.
--
-- D) La cola de ingesta estaba entregando basura: 88 equipos con
--    domestic_league_id NULL y attempts=0. El worker no puede bajar el
--    historial de un equipo si no sabe en que liga juega.
--    Resolvi la liga domestica por argmax de partidos jugados, EXCLUYENDO
--    torneos continentales (uefa/conmebol/concacaf/afc/fifa), y exigiendo
--    al menos 10 partidos: sin evidencia no se asigna.
--      88 sin liga -> 58 sin liga. 30 resueltos.
--    Ahora la cola entrega Coventry City, Fleetwood Town y Sheffield
--    United con su liga (EFL Championship / League Two), que son tres de
--    los partidos que el dueno reporto.
--    Respaldo: v2.soccer_coverage_job_bak_iss129
--
-- =============== LO QUE NO SE ARREGLA ASI ===============
--
-- Los 58 equipos que siguen sin liga y las 7 ligas con muestra corta
-- NECESITAN que la edge function soccer-global-backfill vuelva a correr.
-- El cron 420 la dispara cada 5 minutos y responde 202 accepted, pero
-- ningun job se ha movido desde el 2026-09-10. Con la cola ya arreglada
-- se puede ver si avanza; si no avanza, el problema esta DENTRO de la
-- edge function y hay que leer sus logs.
--
-- Libertadores, Sudamericana, AFC y EFL Cup siguen sin P_RETO porque no
-- estan en la politica de competiciones. Meterlas es una decision de
-- alcance del modelo, no un parche de datos.
--
-- REVERSION, UNA TRANSACCION:
--   begin;
--   delete from v2.crossleague_league_strength where model_version='crossleague_v1_1';
--   insert into v2.crossleague_league_strength select * from v2.crossleague_league_strength_bak_iss129;
--   delete from v2.crossleague_strength_seal where model_version='crossleague_v1_1';
--   insert into v2.crossleague_strength_seal select * from v2.crossleague_strength_seal_bak_iss129;
--   commit;
--
-- ADVERTENCIA HONESTA SOBRE EL TAMANO DE MUESTRA:
--   phi de Polonia sale de n=20 partidos inter-liga, con holdout de 6.
--   Pasa el criterio del propio proyecto (min 20, mejorar Brier Y logloss),
--   pero 6 partidos de prueba es evidencia debil. Los dos picks que
--   desbloquea van con la misma autoridad que el resto del modelo, que
--   tampoco tiene partidos terminados. No lo vendo como mas de lo que es.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Estimar phi de las ligas candidatas (SOLO LECTURA, no escribe nada)
-- ---------------------------------------------------------------------
-- with ligas(id) as (values (106),(383),(210),(345),(318),(419),(333),(271),(95),(172),(343),(373))
-- select l.id, f.* from ligas l
-- cross join lateral v2.fn_fit_phi_extension('crossleague_v1_1', l.id, 20) f
-- order by f.n_usable desc;

-- ---------------------------------------------------------------------
-- 2) Insertar SOLO las que pasan, y re-sellar, en una sola transaccion.
--    Si la integridad de despues sale false, hay que hacer ROLLBACK.
-- ---------------------------------------------------------------------
BEGIN;

create table if not exists v2.crossleague_league_strength_bak_iss129 as
  select * from v2.crossleague_league_strength where model_version='crossleague_v1_1';
create table if not exists v2.crossleague_strength_seal_bak_iss129 as
  select * from v2.crossleague_strength_seal where model_version='crossleague_v1_1';

with m as (select training_cutoff from v2.crossleague_model_registry where model_version='crossleague_v1_1'),
     cfg as (select max(config_hash) as ch from v2.crossleague_league_strength
             where model_version='crossleague_v1_1'),
     nuevas(league_id, league_name, phi, n_cross) as (values
       (333,'Ukrainian Premier League', -0.496::numeric, 23),
       (345,'Chance Liga',              -0.512::numeric, 21),
       (419,'Premyer Liqa',             -0.548::numeric, 20),
       (106,'Poland Ekstraklasa',       -0.252::numeric, 20))
insert into v2.crossleague_league_strength
  (model_version, training_cutoff, league_id, league_name, phi, n_cross, servable, config_hash, fitted_at)
select 'crossleague_v1_1', m.training_cutoff, n.league_id, n.league_name, n.phi, n.n_cross, true, cfg.ch, now()
from nuevas n, m, cfg
where not exists (select 1 from v2.crossleague_league_strength x
                  where x.model_version='crossleague_v1_1' and x.training_cutoff=m.training_cutoff
                    and x.league_id=n.league_id);

update v2.crossleague_strength_seal s
set league_count = (select count(*) from v2.crossleague_league_strength x
                    where x.model_version=s.model_version and x.training_cutoff=s.training_cutoff),
    config_hash  = (select max(config_hash) from v2.crossleague_league_strength x
                    where x.model_version=s.model_version and x.training_cutoff=s.training_cutoff),
    snapshot_hash= (select md5(string_agg(concat_ws(':',league_id::text,phi::text,n_cross::text,servable::text,config_hash),'|' order by league_id))
                    from v2.crossleague_league_strength x
                    where x.model_version=s.model_version and x.training_cutoff=s.training_cutoff),
    sealed_at    = now()
where s.model_version='crossleague_v1_1';

select 'DESPUES' as momento,
  (select count(*) from v2.crossleague_league_strength where model_version='crossleague_v1_1') as ligas,
  v2.fn_crossleague_strength_integrity('crossleague_v1_1',
    (select training_cutoff from v2.crossleague_model_registry where model_version='crossleague_v1_1')) as sello_ok;

COMMIT;

-- ---------------------------------------------------------------------
-- 3) Resolver la liga domestica de los equipos encolados sin liga.
--    Sin liga, el worker de ingesta no sabe que bajar.
--    argmax de partidos domesticos, excluyendo torneos continentales,
--    con minimo 10 partidos: sin evidencia no se asigna.
-- ---------------------------------------------------------------------
create table if not exists v2.soccer_coverage_job_bak_iss129 as
  select * from v2.soccer_coverage_job;

with cand as (
  select j.team_espn_id, h.liga_id, count(*) as partidos,
         row_number() over (partition by j.team_espn_id order by count(*) desc, h.liga_id) as rnk
  from v2.soccer_coverage_job j
  join public.historico_partidos_espn h
    on h.home_espn_id = j.team_espn_id or h.away_espn_id = j.team_espn_id
  join public.ligas_master lm on lm.api_sports_id = h.liga_id
  where j.domestic_league_id is null
    and lm.espn_endpoint not like 'soccer/uefa.%'
    and lm.espn_endpoint not like 'soccer/conmebol.%'
    and lm.espn_endpoint not like 'soccer/concacaf.%'
    and lm.espn_endpoint not like 'soccer/afc.%'
    and lm.espn_endpoint not like 'soccer/fifa.%'
  group by 1,2
),
elegidos as (
  select c.team_espn_id, c.liga_id,
         (select min(lm.nombre) from public.ligas_master lm where lm.api_sports_id=c.liga_id) as liga_nombre
  from cand c where c.rnk=1 and c.partidos >= 10
)
update v2.soccer_coverage_job j
set domestic_league_id = e.liga_id,
    domestic_league_name = e.liga_nombre,
    updated_at = now()
from elegidos e
where j.team_espn_id = e.team_espn_id and j.domestic_league_id is null;

-- ---------------------------------------------------------------------
-- 4) Verificacion: la cola debe entregar trabajo CON liga resuelta.
-- ---------------------------------------------------------------------
-- select team_name, domestic_league_id, domestic_league_name, status, reason
-- from public.get_soccer_coverage_jobs(6);
