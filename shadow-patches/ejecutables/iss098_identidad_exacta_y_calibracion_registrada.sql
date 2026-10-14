-- ISS098 — AUDIT_NO_PASS 5644082184, los cuatro puntos del dueno.
-- EJECUTABLE. Orden: 1 tabla de alias, 2 identidad exacta, 3 estado_respaldo con
-- error de version explicito, 4 gate de desplazamiento consciente del registro,
-- 5 tombstone de v_mis_favoritos_analisis, 6 gates nuevos, 7 runner.
--
-- SONDAS DEL DUENO REPRODUCIDAS ANTES DE TOCAR NADA (2026-09-12, produccion):
--   identidad_valida('401876965','soccer','Moneyline','Gana local','a','e',
--                    'motor_futbol_calibrado')                        -> PASS   (defecto)
--   estado_respaldo('baseball','Over/Under','mlb_totales_normal_v1',
--                   'NO_EXISTE')                                      -> INSUFFICIENT (defecto)
--   gate_p_reto_sin_desplazar() exigia P_RETO == P_RAW en las 302 filas.

begin;

-- =====================================================================
-- 1) LISTA BLANCA EXPLICITA DE VARIANTES DE NOMBRE
-- =====================================================================
-- Por que una tabla y no una normalizacion mas agresiva: las 13 variantes reales
-- incluyen 'Red Bull New York' vs 'New York Red Bulls' y 'Club America' vs
-- 'America'. Resolverlas por regla obligaria a comparar bolsas de palabras, y una
-- comparacion de bolsas de palabras acepta colisiones que no puedo enumerar.
--
-- Por que NO uso equipos_alias, la tabla que ya existe y que llena
-- aprender_alias_equipos() por cron: esa tabla se construye con
-- similarity() >= 0.75 e incluye entradas 'espn_inferido' / 'odds_api_inferido'
-- con confianza 0.80-0.85. Es matching difuso. Usarla seria lavar por tabla
-- exactamente lo que el dueno acaba de rechazar.
create table if not exists public.identidad_equipo_alias (
  deporte       text not null,
  alias_norm    text not null,
  espn_id       text not null,
  nombre_agenda text not null,
  origen        text not null,
  registrado_at timestamptz not null default now(),
  primary key (deporte, alias_norm),
  constraint identidad_equipo_alias_alias_min_len check (length(alias_norm) >= 3),
  constraint identidad_equipo_alias_norm_check    check (alias_norm = lower(btrim(alias_norm)))
);

comment on table public.identidad_equipo_alias is
 'Lista blanca EXPLICITA de variantes de nombre de equipo. Cada fila ata un alias normalizado a UN espn_id concreto. No se genera por similitud ni por substring: se registra a mano tras revision. identidad_valida() solo acepta igualdad normalizada contra agenda_espn o una fila exacta de esta tabla.';

-- Las 13 variantes observadas el 2026-09-12 entre v_pick_canonico y agenda_espn.
-- Cada una verificada 1:1 (un solo espn_id) y sin colisionar con el nombre
-- canonico de ningun otro equipo.
insert into public.identidad_equipo_alias (deporte, alias_norm, espn_id, nombre_agenda, origen) values
 ('soccer','austin','20906','Austin FC','revision_manual_iss098'),
 ('soccer','charlotte','21300','Charlotte FC','revision_manual_iss098'),
 ('soccer','chicago fire','182','Chicago Fire FC','revision_manual_iss098'),
 ('soccer','club america','227','América','revision_manual_iss098'),
 ('soccer','dc united','193','D.C. United','revision_manual_iss098'),
 ('soccer','houston dynamo','6077','Houston Dynamo FC','revision_manual_iss098'),
 ('soccer','inter miami','20232','Inter Miami CF','revision_manual_iss098'),
 ('soccer','los angeles fc','18966','LAFC','revision_manual_iss098'),
 ('soccer','los angeles galaxy','187','LA Galaxy','revision_manual_iss098'),
 ('soccer','new york red bulls','190','Red Bull New York','revision_manual_iss098'),
 ('soccer','san diego','22529','San Diego FC','revision_manual_iss098'),
 ('soccer','seattle sounders','9726','Seattle Sounders FC','revision_manual_iss098'),
 ('soccer','st. louis city','21812','St. Louis CITY SC','revision_manual_iss098')
on conflict (deporte, alias_norm) do nothing;

-- =====================================================================
-- 2) IDENTIDAD EXACTA
-- =====================================================================
-- Fuera las dos ramas que dejaban pasar 'a':
--     or sin_acentos(a.home_nombre) ilike '%'||sin_acentos(p_home)||'%'
--     or sin_acentos(p_home)        ilike '%'||sin_acentos(a.home_nombre)||'%'
-- La segunda aguja de Moneyline SE QUEDA, pero su sentido es el seguro:
-- pick_desc (frase) CONTIENE el nombre del equipo (aguja ya verificada).
create or replace function public.identidad_valida(
  p_event text, p_deporte text, p_mercado text, p_pick_desc text,
  p_home text, p_away text, p_fuente text)
returns text language sql stable set search_path to 'public' as $function$
with a as (select deporte, home_nombre, away_nombre, home_espn_id, away_espn_id, fecha
           from agenda_espn where espn_event_id = p_event)
select case
  when not exists (select 1 from a) then 'EVENTO_INEXISTENTE'
  when p_home is null or p_away is null then 'SIN_EQUIPOS'
  when btrim(coalesce(p_home,'')) = '' or btrim(coalesce(p_away,'')) = '' then 'SIN_EQUIPOS'
  when (select home_espn_id is null or away_espn_id is null from a) then 'AGENDA_SIN_IDENTIDAD'
  when (select fecha is null from a) then 'AGENDA_SIN_HORA'
  when not exists (
        select 1 from a
        where sin_acentos(lower(btrim(a.home_nombre))) = sin_acentos(lower(btrim(p_home)))
           or exists (select 1 from identidad_equipo_alias x
                       where x.deporte    = a.deporte
                         and x.alias_norm = sin_acentos(lower(btrim(p_home)))
                         and x.espn_id    = a.home_espn_id))
       then 'HOME_NO_COINCIDE_CON_AGENDA'
  when not exists (
        select 1 from a
        where sin_acentos(lower(btrim(a.away_nombre))) = sin_acentos(lower(btrim(p_away)))
           or exists (select 1 from identidad_equipo_alias x
                       where x.deporte    = a.deporte
                         and x.alias_norm = sin_acentos(lower(btrim(p_away)))
                         and x.espn_id    = a.away_espn_id))
       then 'AWAY_NO_COINCIDE_CON_AGENDA'
  when p_mercado not in ('Moneyline','Over/Under','BTTS') then 'MERCADO_DESCONOCIDO'
  when p_mercado = 'Over/Under'
       and not public.linea_es_canonica(p_deporte, p_mercado, p_pick_desc)
       then 'LINEA_NO_CANONICA'
  when p_mercado = 'Moneyline'
       and p_pick_desc !~* 'empate|draw'
       and p_pick_desc !~* 'gana +(local|visitante)'
       and sin_acentos(lower(p_pick_desc)) not like '%'||sin_acentos(lower(btrim(p_home)))||'%'
       and sin_acentos(lower(p_pick_desc)) not like '%'||sin_acentos(lower(btrim(p_away)))||'%'
       then 'LADO_NO_CORRESPONDE_AL_EVENTO'
  when not exists (select 1 from motor_modelo_mapa m
                    where m.fuente = p_fuente and m.deporte = p_deporte and m.mercado = p_mercado)
       then 'MOTOR_SIN_PROVENIENCIA'
  else 'PASS'
end;
$function$;

-- =====================================================================
-- 3) ERROR DE VERSION EXPLICITO
-- =====================================================================
-- Antes, una calibration_version inexistente caia en 'INSUFFICIENT' porque la
-- tercera rama soltaba calibration_version del predicado. Fallaba cerrado pero
-- mentia en el diagnostico: 'muestra insuficiente' y 'esa version no existe' son
-- dos cosas distintas. Se anade ademas CALIBRADOR_INVALIDADO (el caso NFL sucio).
create or replace function public.estado_respaldo(
  p_deporte text, p_mercado text, p_model_version text, p_calibration_version text)
returns text language sql stable set search_path to 'public' as $function$
with k as (
  select case
           when p_deporte ~* 'baseball|beisbol' then 'baseball'
           when p_deporte ~* 'football|nfl'     then 'football'
           when p_deporte ~* 'soccer|futbol'    then 'soccer'
           else p_deporte end dep,
         case
           when p_deporte ~* 'soccer|futbol' and p_mercado = 'Moneyline' then '1X2'
           else p_mercado end merc
)
select case
  when p_model_version is null or btrim(p_model_version) = '' then 'SIN_REGISTRO'
  when p_calibration_version is null or btrim(p_calibration_version) = '' then 'SIN_CALIBRATION_VERSION'
  when not exists (select 1 from calibradores c, k
                    where c.model_version = p_model_version
                      and c.deporte = k.dep and c.mercado = k.merc)
       then 'NO_APLICA_A_ESTE_MERCADO'
  when not exists (select 1 from calibradores c, k
                    where c.model_version = p_model_version
                      and c.calibration_version = p_calibration_version
                      and c.deporte = k.dep and c.mercado = k.merc)
       then 'CALIBRATION_VERSION_INEXISTENTE'
  when not exists (select 1 from calibradores c, k
                    where c.model_version = p_model_version
                      and c.calibration_version = p_calibration_version
                      and c.deporte = k.dep and c.mercado = k.merc
                      and not c.invalidado)
       then 'CALIBRADOR_INVALIDADO'
  when exists (select 1 from calibradores c, k
                where c.model_version = p_model_version
                  and c.calibration_version = p_calibration_version
                  and c.deporte = k.dep and c.mercado = k.merc
                  and c.apto_para_lock and not c.invalidado)
       then 'VALIDADO'
  when exists (select 1 from calibradores c, k
                where c.model_version = p_model_version
                  and c.calibration_version = p_calibration_version
                  and c.deporte = k.dep and c.mercado = k.merc
                  and c.elegido and not c.invalidado)
       then 'EARLY'
  else 'INSUFFICIENT'
end;
$function$;

-- =====================================================================
-- 4) EL GATE DETECTA TRANSFORMACIONES NO REGISTRADAS, NO PROHIBE TRANSFORMAR
-- =====================================================================
alter table public.ajustes_a_p_reto add column if not exists magnitud_max_pp numeric;

comment on column public.ajustes_a_p_reto.magnitud_max_pp is
 'Cota superior NUMERICA, en puntos porcentuales, del desplazamiento que este ajuste puede provocar. Obligatoria para que el ajuste pueda estar habilitado: el gate amplia su tolerancia solo con este numero, nunca leyendo el texto de magnitud.';

-- Solo un calibrador apto_para_lock esta autorizado a mover P_RETO en produccion.
-- Si no hay ninguno, la transformacion esperada es la identidad. vector_scaling es
-- multiclase y no se puede comprobar desde un escalar: devuelve null y el gate lo
-- cuenta como violacion (falla cerrado).
create or replace function public.aplicar_calibrador_autorizado(
  p_deporte text, p_mercado text, p_model_version text, p_calibration_version text,
  p_prob_pct numeric)
returns numeric language sql stable set search_path to 'public' as $function$
with k as (
  select case
           when p_deporte ~* 'baseball|beisbol' then 'baseball'
           when p_deporte ~* 'football|nfl'     then 'football'
           when p_deporte ~* 'soccer|futbol'    then 'soccer'
           else p_deporte end dep,
         case
           when p_deporte ~* 'soccer|futbol' and p_mercado = 'Moneyline' then '1X2'
           else p_mercado end merc
),
autorizado as (
  select c.metodo, c.params
  from calibradores c, k
  where c.model_version = p_model_version
    and c.calibration_version = p_calibration_version
    and c.deporte = k.dep and c.mercado = k.merc
    and c.apto_para_lock and not c.invalidado
  order by c.creado_at desc
  limit 1
),
p01 as (select greatest(1e-9, least(1 - 1e-9, p_prob_pct / 100.0)) v)
select case
  when not exists (select 1 from autorizado) then p_prob_pct
  when (select metodo from autorizado) = 'identity' then p_prob_pct
  when (select metodo from autorizado) = 'platt' then
       round((100.0 / (1 + exp(-( ((select (params->>'a')::numeric from autorizado))
                                + ((select (params->>'b')::numeric from autorizado))
                                  * ln((select v from p01) / (1 - (select v from p01))) ))))::numeric, 1)
  when (select metodo from autorizado) = 'isotonic' then
       case when (select params ? 'bloques' from autorizado)
            then round((100.0 * aplicar_isotonica((select params from autorizado),
                                                  (select v from p01)::double precision))::numeric, 1)
            else null end
  else null
end;
$function$;

create or replace function public.tolerancia_desplazamiento_pp(
  p_deporte text, p_mercado text, p_model_version text, p_calibration_version text)
returns numeric language sql stable set search_path to 'public' as $function$
  select 0.05 + coalesce((
    select sum(aj.magnitud_max_pp)
    from ajustes_a_p_reto aj
    where aj.habilitado
      and aj.validado_fuera_de_muestra
      and aj.magnitud_max_pp is not null
      and (aj.deporte is null or aj.deporte = p_deporte)
      and (aj.mercado is null or aj.mercado = p_mercado)
      and (aj.model_version is null or aj.model_version = p_model_version)
      and (aj.calibration_version is null or aj.calibration_version = p_calibration_version)
  ), 0);
$function$;

create or replace function public.gate_p_reto_sin_desplazar()
returns jsonb language sql set search_path to 'public' as $function$
with fuente as (
  select c.espn_event_id, c.mercado, c.pick pick_desc, 'motor_futbol_calibrado'::text fuente,
         c.probabilidad_pct p_motor
  from v_picks_futbol_calibrado c
  union all
  select mm.espn_event_id, mm.mercado, mm.pick, 'motor_mlb_cuantitativo'::text, mm.prob
  from v_picks_mlb_modelo mm
  union all
  select p.espn_event_id, p.mercado, p.pick_desc, 'motor_picks'::text,
         round(p.probabilidad_real * 100::numeric, 1)
  from picks_recomendados_hoy p
),
comparado as (
  select k.espn_event_id, k.mercado, k.pick_desc, k.fuente, k.deporte,
         f.p_motor, k.probabilidad_pct p_canonico,
         modelo_de_pick(k.fuente, k.deporte, k.mercado)      as model_version,
         calibracion_de_pick(k.fuente, k.deporte, k.mercado) as calibration_version,
         aplicar_calibrador_autorizado(k.deporte, k.mercado,
             modelo_de_pick(k.fuente, k.deporte, k.mercado),
             calibracion_de_pick(k.fuente, k.deporte, k.mercado),
             f.p_motor)                                      as p_esperado,
         tolerancia_desplazamiento_pp(k.deporte, k.mercado,
             modelo_de_pick(k.fuente, k.deporte, k.mercado),
             calibracion_de_pick(k.fuente, k.deporte, k.mercado)) as tolerancia_pp
  from v_pick_canonico k
  join fuente f on f.espn_event_id = k.espn_event_id and f.mercado = k.mercado
              and f.fuente = k.fuente and f.pick_desc = k.pick_desc
  where k.probabilidad_pct is not null and f.p_motor is not null
),
evaluado as (
  select *, case when p_esperado is null then null
                 else round(abs(p_canonico - p_esperado), 2) end as desplazamiento_no_explicado_pp
  from comparado
),
malos as (
  select * from evaluado
  where p_esperado is null or desplazamiento_no_explicado_pp > tolerancia_pp
)
select jsonb_build_object(
  'P_RETO_DESPLAZADA', (select count(*) from malos),
  'comparados', (select count(*) from evaluado),
  'filas_canonicas', (select count(*) from v_pick_canonico where probabilidad_pct is not null),
  'sin_llave_verificacion_vacia',
      (select count(*) from evaluado where model_version is null or calibration_version is null),
  'no_verificables', (select count(*) from evaluado where p_esperado is null),
  'desplazamiento_no_explicado_max_pp',
      coalesce((select max(desplazamiento_no_explicado_pp) from malos), 0),
  'transformacion_autorizada_activa', (select count(*) from calibradores
                                        where apto_para_lock and not invalidado),
  'ajustes_habilitados_sin_cota', (select count(*) from ajustes_a_p_reto
                                    where habilitado
                                      and (not validado_fuera_de_muestra
                                           or magnitud_max_pp is null)),
  'detalle', coalesce((select jsonb_agg(jsonb_build_object(
      'evento',espn_event_id,'pick',pick_desc,'fuente',fuente,'mv',model_version,
      'motor',p_motor,'esperado',p_esperado,'canonico',p_canonico,
      'no_explicado_pp',desplazamiento_no_explicado_pp,'tolerancia_pp',tolerancia_pp)
      order by desplazamiento_no_explicado_pp desc nulls first)
      from (select * from malos limit 5) m), '[]'));
$function$;

-- =====================================================================
-- 5) TOMBSTONE DE v_mis_favoritos_analisis — SE RETIRA, NO SE RECONSTRUYE
-- =====================================================================
create table if not exists public.superficie_retirada (
  vista                       text primary key,
  retirada_at                 timestamptz not null default now(),
  motivo                      text not null,
  evidencia_cero_consumidores text not null,
  definicion_historica        text,
  fuente_de_la_definicion     text
);

comment on table public.superficie_retirada is
 'Lapidas. Una vista que se retira del contrato visible queda AQUI con la prueba de que no tenia consumidores al momento del retiro y su definicion historica para auditoria. No se reconstruye: se retira.';

-- NOTA: la fila concreta de v_mis_favoritos_analisis, con su definicion historica
-- recuperada de pg_stat_statements, se inserta en
-- iss098b_tombstone_favoritos.sql para no mezclar DDL con evidencia.

-- una superficie retirada no puede volver a existir en silencio
create or replace function public.gate_superficie_resucitada()
returns jsonb language sql stable set search_path to 'public' as $function$
with resucitadas as (
  select r.vista, 'el objeto existe de nuevo en public'::text as como
  from superficie_retirada r
  where exists (select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
                 where n.nspname='public' and c.relkind in ('v','m') and c.relname::text = r.vista)
  union all
  select r.vista, 'esta registrada otra vez como superficie viva'
  from superficie_retirada r
  where exists (select 1 from superficie_usuario s where s.vista = r.vista)
)
select jsonb_build_object(
  'SUPERFICIE_RETIRADA_RESUCITADA', (select count(*) from resucitadas),
  'lapidas', (select count(*) from superficie_retirada),
  'detalle', coalesce((select jsonb_agg(jsonb_build_object('vista',vista,'como',como) order by vista)
                       from resucitadas), '[]'));
$function$;

-- la UNICA salida del contrato visible es una lapida con evidencia.
-- Esto cierra el atajo de borrar la fila del registro para apagar el gate.
create or replace function public.tg_superficie_solo_sale_con_lapida()
returns trigger language plpgsql set search_path to 'public' as $function$
begin
  if not exists (select 1 from superficie_retirada r where r.vista = old.vista) then
    raise exception 'SUPERFICIE_SIN_LAPIDA: no se puede quitar % del registro de superficie sin una fila en superficie_retirada con motivo y evidencia de cero consumidores', old.vista;
  end if;
  return old;
end;
$function$;

drop trigger if exists tg_superficie_solo_sale_con_lapida on public.superficie_usuario;
create trigger tg_superficie_solo_sale_con_lapida
  before delete on public.superficie_usuario
  for each row execute function public.tg_superficie_solo_sale_con_lapida();

-- =====================================================================
-- 6) GATES NUEVOS
-- =====================================================================
-- CONDUCTUAL, no por nombre: muta nombres reales de la agenda y exige rechazo.
-- Con la version vieja (%substring%) este gate marca 190 de 240 mutaciones
-- aceptadas, incluidas 30 del caso 'a'/'e' del dueno. Con la nueva, 0.
create or replace function public.gate_identidad_exacta()
returns jsonb language sql stable set search_path to 'public' as $function$
with equipos as (
  select distinct deporte, home_espn_id espn_id, sin_acentos(lower(btrim(home_nombre))) nom from agenda_espn
  union
  select distinct deporte, away_espn_id, sin_acentos(lower(btrim(away_nombre))) from agenda_espn
),
alias_huerfano as (
  select x.* from identidad_equipo_alias x
  where not exists (select 1 from equipos e where e.deporte=x.deporte and e.espn_id=x.espn_id)
),
alias_colision as (
  select x.alias_norm, x.espn_id apunta_a, e.espn_id choca_con
  from identidad_equipo_alias x
  join equipos e on e.deporte=x.deporte and e.nom=x.alias_norm and e.espn_id<>x.espn_id
),
muestra as (
  select espn_event_id, deporte, home_nombre, away_nombre
  from agenda_espn
  where home_espn_id is not null and away_espn_id is not null and fecha is not null
  order by fecha desc limit 40
),
mutaciones as (
  select m.espn_event_id, m.deporte, etiqueta, h, a from muestra m,
  lateral (values
    ('primer_caracter',      left(m.home_nombre,1),            left(m.away_nombre,1)),
    ('prefijo_3',            left(m.home_nombre,3),            left(m.away_nombre,3)),
    ('sufijo_3',             right(m.home_nombre,3),           right(m.away_nombre,3)),
    ('superstring',          m.home_nombre||' Club Deportivo', m.away_nombre||' Club Deportivo'),
    ('una_vocal',            'a',                              'e'),
    ('lados_invertidos',     m.away_nombre,                    m.home_nombre)
  ) v(etiqueta,h,a)
),
aceptadas as (
  select mu.etiqueta, count(*) n
  from mutaciones mu
  where identidad_valida(mu.espn_event_id, mu.deporte, 'Moneyline', 'Gana local',
                         mu.h, mu.a, 'motor_futbol_calibrado')
        not in ('HOME_NO_COINCIDE_CON_AGENDA','AWAY_NO_COINCIDE_CON_AGENDA','SIN_EQUIPOS')
  group by 1
)
select jsonb_build_object(
  'IDENTIDAD_PARCIAL_ACEPTADA', coalesce((select sum(n) from aceptadas), 0),
  'ALIAS_SIN_EQUIPO_EN_AGENDA', (select count(*) from alias_huerfano),
  'ALIAS_COLISIONA_CON_OTRO_EQUIPO', (select count(*) from alias_colision),
  'mutaciones_probadas', (select count(*) from mutaciones),
  'alias_registrados', (select count(*) from identidad_equipo_alias),
  'detalle_mutaciones_aceptadas', coalesce((select jsonb_object_agg(etiqueta, n) from aceptadas), '{}'));
$function$;

-- Hallazgo propio de esta ronda: el calibrador isotonico guardado tiene
-- params = {bins, nota}, pero aplicar_isotonica() lee params->'bloques'. Ese
-- calibrador NO se puede reproducir desde su propio registro. No esta
-- apto_para_lock, asi que no bloquea, pero esta en el registro como si sirviera.
create or replace function public.gate_calibrador_reproducible()
returns jsonb language sql stable set search_path to 'public' as $function$
with evaluado as (
  select c.deporte, c.mercado, c.model_version, c.calibration_version, c.metodo,
         c.elegido, c.apto_para_lock, c.invalidado,
         case
           when c.metodo = 'identity' then true
           when c.metodo = 'platt' then (c.params ? 'a' and c.params ? 'b')
           when c.metodo = 'isotonic' then (c.params ? 'bloques'
                                            and jsonb_typeof(c.params->'bloques') = 'array')
           when c.metodo in ('vector_scaling','multiclase_dirichlet')
                then (c.params ? 'b' and c.params ? 'a_draw' and c.params ? 'a_away')
           else false
         end as reproducible_desde_params,
         (c.metodo in ('identity','platt','isotonic')) as verificable_escalarmente
  from calibradores c
  where not c.invalidado
)
select jsonb_build_object(
  'CALIBRADOR_APTO_NO_REPRODUCIBLE',
      (select count(*) from evaluado where apto_para_lock and not reproducible_desde_params),
  'CALIBRADOR_APTO_NO_VERIFICABLE_ESCALAR',
      (select count(*) from evaluado where apto_para_lock and not verificable_escalarmente),
  'no_reproducibles_total', (select count(*) from evaluado where not reproducible_desde_params),
  'evaluados', (select count(*) from evaluado),
  'detalle', coalesce((select jsonb_agg(jsonb_build_object(
      'deporte',deporte,'mercado',mercado,'model',model_version,'cal',calibration_version,
      'metodo',metodo,'elegido',elegido,'apto',apto_para_lock,
      'reproducible',reproducible_desde_params,'verificable_escalar',verificable_escalarmente)
      order by metodo) from evaluado where not reproducible_desde_params
                                       or not verificable_escalarmente), '[]'));
$function$;

commit;

-- =====================================================================
-- 7) ASSERTIONS — el parche falla si no se cumple cada una
-- =====================================================================
do $$
declare v jsonb; n int;
begin
  -- sonda del dueno: tiene que rechazar
  if identidad_valida('401876965','soccer','Moneyline','Gana local','a','e','motor_futbol_calibrado')
     <> 'HOME_NO_COINCIDE_CON_AGENDA' then
    raise exception 'ASSERT 1 FALLO: la sonda a/e del dueno sigue pasando';
  end if;

  -- calibration_version inexistente: error de version, no muestra insuficiente
  if estado_respaldo('baseball','Over/Under','mlb_totales_normal_v1','NO_EXISTE')
     <> 'CALIBRATION_VERSION_INEXISTENTE' then
    raise exception 'ASSERT 2 FALLO: version fantasma no devuelve CALIBRATION_VERSION_INEXISTENTE';
  end if;

  -- el caso NFL sucio se distingue
  if estado_respaldo('football','Over/Under','nfl_totales_normal_v1','cal_v4_historia_completa')
     <> 'CALIBRADOR_INVALIDADO' then
    raise exception 'ASSERT 3 FALLO: calibrador invalidado no se distingue';
  end if;

  -- identidad: cero mutaciones aceptadas, cero alias huerfanos, cero colisiones
  v := gate_identidad_exacta();
  if (v->>'IDENTIDAD_PARCIAL_ACEPTADA')::int <> 0
     or (v->>'ALIAS_SIN_EQUIPO_EN_AGENDA')::int <> 0
     or (v->>'ALIAS_COLISIONA_CON_OTRO_EQUIPO')::int <> 0 then
    raise exception 'ASSERT 4 FALLO: gate_identidad_exacta = %', v;
  end if;

  -- la identidad exacta no debe costar filas canonicas legitimas
  select count(*) into n from v_pick_canonico p
   where identidad_valida(p.espn_event_id,p.deporte,p.mercado,p.pick_desc,p.home,p.away,p.fuente)
         in ('HOME_NO_COINCIDE_CON_AGENDA','AWAY_NO_COINCIDE_CON_AGENDA');
  if n <> 0 then
    raise exception 'ASSERT 5 FALLO: % filas canonicas rechazadas por identidad', n;
  end if;

  -- desplazamiento: sin cobertura parcial y sin violaciones
  v := gate_p_reto_sin_desplazar();
  if (v->>'comparados')::int <> (v->>'filas_canonicas')::int then
    raise exception 'ASSERT 6 FALLO: el gate compara % de % filas (abanico o cobertura parcial)',
      v->>'comparados', v->>'filas_canonicas';
  end if;
  if (v->>'P_RETO_DESPLAZADA')::int <> 0 then
    raise exception 'ASSERT 7 FALLO: desplazamiento no explicado = %', v;
  end if;

  -- nada autorizado puede ser irreproducible
  v := gate_calibrador_reproducible();
  if (v->>'CALIBRADOR_APTO_NO_REPRODUCIBLE')::int <> 0
     or (v->>'CALIBRADOR_APTO_NO_VERIFICABLE_ESCALAR')::int <> 0 then
    raise exception 'ASSERT 8 FALLO: calibrador autorizado no verificable = %', v;
  end if;

  raise notice 'ISS098 OK: 8 assertions pasadas';
end $$;
