-- ISS144: el arreglo de ISS143 se deshizo solo. Esta es la razon y el cierre.
--
-- QUE PASO
-- En ISS143 saque 108 partidos de la liga JUVENIL portuguesa (Juniores U19,
-- liga_id 1041) que se estaban usando como forma SENIOR de Mafra, Beira Mar y
-- CF Benfica, y agregue el filtro de juveniles/femenil en tres lugares de SQL.
-- Horas despues los tres equipos volvieron a tener asignada la U19.
--
-- POR QUE SE DESHIZO
-- Porque el que elige la liga NO es SQL. Es la edge function
-- `soccer-global-backfill`, y tenia SU PROPIA regla dentro de chooseLeague():
--
--     .filter(x => String(x.c?.tipo||"").toLowerCase()==="league"
--                  && !/world|international/i.test(...))
--
-- Solo pedia tipo=League y que no fuera internacional. "Juniores U19" es
-- tipo=League y pais=Portugal, asi que pasaba. Mi filtro de ISS143 vivia en
-- v2.v_ligas_domesticas_confiables y en v2.fn_resolver_liga_domestica, y esa
-- funcion nunca las consulta. Habia DOS reglas para la misma pregunta y la que
-- mandaba era la que yo no habia tocado.
--
-- EL ARREGLO
-- Una sola regla, y en el punto de ESCRITURA, no en el de lectura. Asi ningun
-- escritor (SQL, edge, o uno que no existe todavia) se la puede saltar.
--
--   1. v2.fn_liga_domestica_valida(liga_id)  <- LA regla, escrita una vez.
--   2. public.upsert_soccer_domestic_observation  rechaza la observacion.
--   3. public.update_soccer_coverage_job          bloquea el equipo y escribe
--                                                 el motivo, en vez de guardar
--                                                 la liga mala.
--   4. public.filtrar_ligas_domesticas_validas(int[])  para que el trabajador
--      pregunte la MISMA regla en una sola llamada.
--   5. soccer-global-backfill v6: chooseLeague ya no decide, pregunta.
--   6. G34.10 y G34.11 vigilan que no vuelva a pasar en silencio.
--
-- ALCANCE MEDIDO ANTES DE FORZAR NADA: de 50 ligas en uso, 49 pasan la regla y
-- reprueba exactamente 1 (Juniores U19). El guardia no tira datos buenos.
--
-- LAS 108 OBSERVACIONES NO SE BORRARON: se movieron a
-- v2.observacion_domestica_cuarentena con su motivo. El historial no se destruye.

-- ---------------------------------------------------------------------------
-- 1. LA REGLA, UNA SOLA VEZ
-- ---------------------------------------------------------------------------
create or replace function v2.fn_liga_domestica_valida(p_liga_id integer)
returns boolean
language sql
stable
security definer
set search_path to 'v2','public'
as $$
  -- Una liga domestica sirve como forma SENIOR si:
  --  (a) existe en el catalogo de API-Football,
  --  (b) es de tipo League (no copa),
  --  (c) no es juvenil, ni de reservas, ni femenil,
  --  (d) no es una seleccion/torneo internacional.
  -- El nombre se compara SIN ACENTOS: "Juniores U19" tiene que caer igual que
  -- "Juniores U19". Sin fila en el catalogo => false (fallar cerrado).
  select coalesce(
    (select lower(coalesce(c.tipo,'')) = 'league'
        and translate(lower(coalesce(c.nombre,'')),
              'áéíóúàèìòùâêîôûãõäëïöüñç','aeiouaeiouaeiouaoaeiounc')
            !~ 'u1[5-9]|u2[01]|junior|juvenil|youth|sub.?1[5-9]|reserve|women|femenin|feminin'
        and coalesce(c.pais,'') !~* 'world|international'
     from public.apifootball_ligas_catalogo c
     where c.liga_id = p_liga_id),
    false);
$$;

-- ---------------------------------------------------------------------------
-- 2. EL TRABAJADOR PREGUNTA LA REGLA EN UNA SOLA LLAMADA
-- ---------------------------------------------------------------------------
create or replace function public.filtrar_ligas_domesticas_validas(p_liga_ids integer[])
returns integer[]
language sql
stable
security definer
set search_path to 'v2','public'
as $$
  -- La regla no se repite aqui: se pregunta a v2.fn_liga_domestica_valida.
  -- Existe para que la edge function consulte la MISMA regla sin tener copia.
  select coalesce(array_agg(id order by id), '{}'::integer[])
  from unnest(coalesce(p_liga_ids,'{}'::integer[])) as t(id)
  where v2.fn_liga_domestica_valida(id);
$$;

grant execute on function public.filtrar_ligas_domesticas_validas(integer[]) to service_role;

-- ---------------------------------------------------------------------------
-- 3. GUARDIA EN LA ESCRITURA DE OBSERVACIONES
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.upsert_soccer_domestic_observation(p_team_espn_id text, p_provider text, p_provider_team_id text, p_provider_fixture_id text, p_domestic_league_id integer, p_domestic_league_name text, p_kickoff timestamp with time zone, p_gf integer, p_ga integer, p_loaded_at timestamp with time zone, p_metadata jsonb)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'v2', 'public'
AS $function$
begin
 -- GUARDIA DE FORMA SENIOR. El historial domestico alimenta el cerebro como
 -- forma del equipo mayor. Un partido de juveniles, reservas o femenil NO es
 -- eso, y no entra aunque el proveedor lo marque como "League". La regla vive
 -- en v2.fn_liga_domestica_valida y es la unica: aqui solo se obedece.
 -- Falla cerrado: sin liga valida no se escribe y se avisa.
 if p_domestic_league_id is null or not v2.fn_liga_domestica_valida(p_domestic_league_id) then
   raise warning 'LIGA_NO_VALIDA_PARA_FORMA_SENIOR: equipo % liga % (%). Observacion descartada.',
     p_team_espn_id, p_domestic_league_id, coalesce(p_domestic_league_name,'sin nombre');
   return false;
 end if;

 insert into v2.soccer_domestic_observation(team_espn_id,provider,provider_team_id,provider_fixture_id,domestic_league_id,domestic_league_name,kickoff,gf,ga,loaded_at,metadata)
 values(p_team_espn_id,p_provider,p_provider_team_id,p_provider_fixture_id,p_domestic_league_id,p_domestic_league_name,p_kickoff,p_gf,p_ga,coalesce(p_loaded_at,now()),coalesce(p_metadata,'{}'::jsonb))
 on conflict(team_espn_id,provider,provider_fixture_id) do update set
  provider_team_id=excluded.provider_team_id,domestic_league_id=excluded.domestic_league_id,domestic_league_name=excluded.domestic_league_name,
  kickoff=excluded.kickoff,gf=excluded.gf,ga=excluded.ga,loaded_at=excluded.loaded_at,metadata=excluded.metadata;
 return true;
end $function$;

-- ---------------------------------------------------------------------------
-- 4. GUARDIA EN LA ASIGNACION DE LIGA AL TRABAJO
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.update_soccer_coverage_job(p_team_espn_id text, p_status text, p_api_team_id integer DEFAULT NULL::integer, p_domestic_league_id integer DEFAULT NULL::integer, p_domestic_league_name text DEFAULT NULL::text, p_reason text DEFAULT NULL::text, p_last_error text DEFAULT NULL::text, p_increment_attempt boolean DEFAULT false)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'v2', 'public'
AS $function$
declare
  v_nombre text;
begin
 -- GUARDIA DE FORMA SENIOR. Si el trabajador eligio una liga juvenil, de
 -- reservas o femenil, NO se guarda: el equipo queda bloqueado con el motivo
 -- escrito. Antes esto se colaba porque el selector de liga vive en la edge
 -- function y tenia su propia regla. La regla ahora es una sola y esta aqui.
 if p_domestic_league_id is not null and not v2.fn_liga_domestica_valida(p_domestic_league_id) then
   select c.nombre into v_nombre from public.apifootball_ligas_catalogo c where c.liga_id=p_domestic_league_id;
   update v2.soccer_coverage_job set
     status='BLOCKED',
     api_team_id=coalesce(p_api_team_id,api_team_id),
     domestic_league_id=null,
     domestic_league_name=null,
     reason='NO_DOMESTIC_LEAGUE_EVIDENCE',
     last_error=format('La liga elegida (%s %s) no sirve como forma senior: es juvenil, de reservas, femenil, una copa o no esta en el catalogo. No se asigna y no se inventa otra.',
                       p_domestic_league_id, coalesce(v_nombre,'sin nombre')),
     attempts=attempts+case when p_increment_attempt then 1 else 0 end,
     last_run_at=case when p_increment_attempt then now() else last_run_at end,
     updated_at=now()
   where team_espn_id=p_team_espn_id;
   return found;
 end if;

 update v2.soccer_coverage_job set
  status=p_status,
  api_team_id=coalesce(p_api_team_id,api_team_id),
  domestic_league_id=coalesce(p_domestic_league_id,domestic_league_id),
  domestic_league_name=coalesce(p_domestic_league_name,domestic_league_name),
  reason=coalesce(p_reason,reason),
  last_error=p_last_error,
  attempts=attempts+case when p_increment_attempt then 1 else 0 end,
  last_run_at=case when p_increment_attempt then now() else last_run_at end,
  updated_at=now()
 where team_espn_id=p_team_espn_id;
 return found;
end $function$;

-- ---------------------------------------------------------------------------
-- 5. CUARENTENA DE LO QUE YA SE HABIA COLADO (no se borra: se aparta)
-- ---------------------------------------------------------------------------
create table if not exists v2.observacion_domestica_cuarentena
  (like v2.soccer_domestic_observation including all);
alter table v2.observacion_domestica_cuarentena
  add column if not exists motivo_cuarentena text,
  add column if not exists cuarentena_at timestamptz default now();

insert into v2.observacion_domestica_cuarentena
select o.*, 'LIGA_JUVENIL_NO_ES_FORMA_SENIOR', now()
from v2.soccer_domestic_observation o
where not v2.fn_liga_domestica_valida(o.domestic_league_id)
on conflict do nothing;

delete from v2.soccer_domestic_observation o
where not v2.fn_liga_domestica_valida(o.domestic_league_id);

-- Los equipos afectados vuelven a la cola SIN liga, para que el selector
-- corregido busque su division senior real. Si no encuentra ninguna valida,
-- el guardia los deja BLOCKED con el motivo escrito: eso es lo correcto.
update v2.soccer_coverage_job
set status='PENDING', domestic_league_id=null, domestic_league_name=null,
    reason='DOMESTIC_LEAGUE_REQUIRED', attempts=0, last_run_at=null,
    last_error='Se reinicia con el selector corregido: la liga la vuelve a elegir el trabajador, ahora obligado a preguntarle la regla a la base.',
    updated_at=now()
where team_espn_id in ('21622','133251','1423');

-- ---------------------------------------------------------------------------
-- 6. EDGE FUNCTION: soccer-global-backfill v6
-- ---------------------------------------------------------------------------
-- chooseLeague() ya no decide que es una liga. Pregunta:
--
--   async function ligasValidas(ids:number[]):Promise<Set<number>>{
--     const limpios=[...new Set(ids.filter(n=>Number.isFinite(n)))];
--     if(!limpios.length)return new Set<number>();
--     const {data,error}=await sb.rpc("filtrar_ligas_domesticas_validas",{p_liga_ids:limpios});
--     if(error)throw new Error(`REGLA_DE_LIGA_NO_DISPONIBLE: ${error.message}`);
--     return new Set((data||[]).map((x:any)=>Number(x)));
--   }
--
-- y tanto el camino de fixtures recientes como el fallback de /leagues filtran
-- por ese conjunto. Si la base no responde, tira error: falla cerrado, no
-- asigna liga a lo bruto.

-- ---------------------------------------------------------------------------
-- VERIFICACION (lo que se corrio, con lo que devolvio)
-- ---------------------------------------------------------------------------
--  v2.fn_liga_domestica_valida(1041) -> false   (Juniores U19)
--  v2.fn_liga_domestica_valida(95)   -> true    (Segunda Liga)
--  v2.fn_liga_domestica_valida(40)   -> true    (Championship)
--  v2.fn_liga_domestica_valida(140)  -> true    (LaLiga)
--  v2.fn_liga_domestica_valida(-1)   -> false   (no existe)
--
--  ligas en uso 50 | pasan 49 | reprueban 1 (Juniores U19)
--
--  Prueba real del guardia de trabajos: se llamo
--    update_soccer_coverage_job('21622','DATA_READY',null,1041,'Juniores U19',...)
--  y el equipo quedo status=BLOCKED, domestic_league_id=null, con el motivo escrito.
--
--  Prueba real del guardia de observaciones: se llamo
--    upsert_soccer_domestic_observation('21622',...,1041,'Juniores U19',...)
--  y se escribieron 0 filas.
--
--  observaciones juveniles en produccion: 0
--  trabajos con liga invalida: 0
--  respaldadas en cuarentena: 108 (3 equipos, 1 liga)
--
--  build_soccer_prediction_v2() -> 227 | tarjetas con P_RETO 158 | perdidas 0
--  G33: 9 duros PASS | G34: 9 duros PASS, incluidos G34.10 y G34.11 nuevos
