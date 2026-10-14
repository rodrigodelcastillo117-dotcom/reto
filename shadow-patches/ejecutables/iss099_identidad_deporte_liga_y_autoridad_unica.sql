-- ISS099 — AUDIT_NO_PASS 5645505673, los tres hallazgos del dueno.
-- EJECUTABLE.
--
-- SONDAS REPRODUCIDAS ANTES DE TOCAR NADA (2026-09-12, produccion):
--   1) identidad_valida('401816997','soccer','Moneyline','Gana local',
--                       'Cleveland Guardians','Athletics','motor_futbol_calibrado')
--      -> PASS. Un MLB real pasado como soccer con motor de futbol. Y al reves
--      tambien: un partido de Liga MX pasado como baseball con motor de MLB -> PASS.
--      Los dos sentidos estaban abiertos.
--   2) gate_p_reto_sin_desplazar() -> 302 comparados / 0 desplazados / 302 SIN LLAVE.
--      El verde era vacio: ninguna fila tiene model_version trazable.
--   3) calibradores, por llave exacta, tiene 2 metodos con creado_at EMPATADO al
--      microsegundo (platt/isotonic y identity/vector_scaling). El aplicador usaba
--      ORDER BY creado_at DESC LIMIT 1: eleccion no determinista.

begin;

-- =====================================================================
-- 1) IDENTIDAD COMPLETA: + DEPORTE + LIGA
-- =====================================================================
-- Nota sobre el orden de las ramas: el americano va PRIMERO porque
-- 'futbol americano' contiene 'futbol' y caeria en soccer. La normalizacion de
-- estado_respaldo() tenia ese hueco latente; aqui no.
create or replace function public.deporte_canonico(p_deporte text)
returns text language sql immutable set search_path to 'public' as $function$
  -- el americano va PRIMERO: 'futbol americano' contiene 'futbol' y caeria en soccer
  select case
    when p_deporte is null then null
    when p_deporte ~* 'futbol americano|f[uú]tbol americano|football|nfl' then 'football'
    when p_deporte ~* 'baseball|beisbol|b[eé]isbol|mlb'                   then 'baseball'
    when p_deporte ~* 'soccer|futbol|f[uú]tbol'                           then 'soccer'
    else lower(btrim(p_deporte)) end;
$function$;

-- La liga se compara por NOMBRE normalizado y no por liga_id: en agenda_espn
-- liga_nombre esta al 100% (124 baseball, 270 football, 373 soccer) pero liga_id
-- es null en los 124 de baseball. Exigir liga_id habria rechazado todo MLB.
-- Medido antes de exigirlo: las 302 filas canonicas ya traen la liga exacta, asi
-- que el costo de este candado es 0 filas.
create or replace function public.identidad_valida(
  p_event text, p_deporte text, p_liga text, p_mercado text, p_pick_desc text,
  p_home text, p_away text, p_fuente text)
returns text language sql stable set search_path to 'public' as $function$
with a as (select deporte, liga_id, liga_nombre, home_nombre, away_nombre,
                  home_espn_id, away_espn_id, fecha
           from agenda_espn where espn_event_id = p_event)
select case
  when not exists (select 1 from a) then 'EVENTO_INEXISTENTE'
  when p_home is null or p_away is null then 'SIN_EQUIPOS'
  when btrim(coalesce(p_home,'')) = '' or btrim(coalesce(p_away,'')) = '' then 'SIN_EQUIPOS'
  when (select home_espn_id is null or away_espn_id is null from a) then 'AGENDA_SIN_IDENTIDAD'
  when (select fecha is null from a) then 'AGENDA_SIN_HORA'
  -- EL DEPORTE DEL PICK TIENE QUE SER EL DEL EVENTO. Sin esto se podia pasar un
  -- MLB real como 'soccer' con motor de futbol y sacar PASS.
  when btrim(coalesce(p_deporte,'')) = '' then 'SIN_DEPORTE'
  when (select deporte is null from a) then 'AGENDA_SIN_DEPORTE'
  when (select deporte_canonico(a.deporte) from a) is distinct from deporte_canonico(p_deporte)
       then 'DEPORTE_NO_COINCIDE_CON_AGENDA'
  -- Y LA LIGA TAMBIEN. liga_nombre esta al 100% en agenda_espn; liga_id solo en
  -- football y soccer, por eso la comparacion es por nombre normalizado.
  when btrim(coalesce(p_liga,'')) = '' then 'SIN_LIGA'
  when (select liga_nombre is null from a) then 'AGENDA_SIN_LIGA'
  when (select sin_acentos(lower(btrim(a.liga_nombre))) from a)
       <> sin_acentos(lower(btrim(p_liga)))
       then 'LIGA_NO_COINCIDE_CON_AGENDA'
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

-- La firma de 7 argumentos NO puede seguir usandose: no recibe liga y por tanto
-- no puede verificarla. Queda fallando cerrado en vez de desaparecer, para que
-- cualquier llamador olvidado se rompa a la vista y no en silencio. Y falla de
-- verdad: elegibilidad_no_economica_v1 exige semantic_validity = 'PASS', asi que
-- una vista que siga con la firma vieja deja de producir picks.
create or replace function public.identidad_valida(
  p_event text, p_deporte text, p_mercado text, p_pick_desc text,
  p_home text, p_away text, p_fuente text)
returns text language sql immutable set search_path to 'public' as $function$
  select 'FIRMA_OBSOLETA_SIN_LIGA'::text;
$function$;

commit;

-- =====================================================================
-- 2) v_pick_canonico PASA LA LIGA — parche guardado e idempotente
-- =====================================================================
-- No se reescribe la vista (21 KB, definicion no versionada): se sustituye la
-- llamada exacta, exigiendo 1 y solo 1 ocurrencia. Si hay 0 o 2, aborta.
do $$
declare
  v_def text; v_nuevo text;
  v_viejo text := 'identidad_valida(c.espn_event_id, c.deporte, c.mercado, c.pick_desc, c.home, c.away, c.fuente)';
  v_bueno text := 'identidad_valida(c.espn_event_id, c.deporte, c.liga, c.mercado, c.pick_desc, c.home, c.away, c.fuente)';
  v_n int;
begin
  v_def := pg_get_viewdef('public.v_pick_canonico'::regclass);
  if position(v_bueno in v_def) > 0 then
    raise notice 'ya usa la firma de 8, no toco nada';
    return;
  end if;
  v_n := (length(v_def) - length(replace(v_def, v_viejo, ''))) / length(v_viejo);
  if v_n <> 1 then
    raise exception 'PATCH ABORTADO: esperaba 1 ocurrencia de la llamada vieja, encontre %', v_n;
  end if;
  v_nuevo := replace(v_def, v_viejo, v_bueno);
  execute 'create or replace view public.v_pick_canonico as '||v_nuevo;
end $$;

-- =====================================================================
-- 3) UNA SOLA AUTORIDAD POR LLAVE
-- =====================================================================
begin;

-- EXACTAMENTE UNO elegido+apto por llave. Indice unico parcial: la ambiguedad
-- deja de ser detectable y pasa a ser imposible de insertar.
create unique index if not exists ux_calibrador_autoridad_unica
  on public.calibradores (deporte, mercado, model_version, calibration_version)
  where elegido and apto_para_lock and not invalidado;

comment on index public.ux_calibrador_autoridad_unica is
 'Una sola autoridad por llave exacta. Antes el aplicador tomaba cualquier fila apto_para_lock con ORDER BY creado_at LIMIT 1, y los timestamps estaban empatados al microsegundo entre platt e isotonic: la eleccion era no determinista.';

-- El aplicador ya no ordena ni limita: exige EXACTAMENTE UNA autoridad
-- (elegido AND apto_para_lock AND NOT invalidado). Cero o varias => null, y el
-- gate cuenta null como violacion.
create or replace function public.aplicar_calibrador_autorizado(
  p_deporte text, p_mercado text, p_model_version text, p_calibration_version text,
  p_prob_pct numeric)
returns numeric language sql stable set search_path to 'public' as $function$
with k as (
  select deporte_canonico(p_deporte) dep,
         case when deporte_canonico(p_deporte) = 'soccer' and p_mercado = 'Moneyline' then '1X2'
              else p_mercado end merc
),
candidatos as (
  select c.metodo, c.params
  from calibradores c, k
  where c.model_version = p_model_version
    and c.calibration_version = p_calibration_version
    and c.deporte = k.dep and c.mercado = k.merc
    and c.elegido and c.apto_para_lock and not c.invalidado
),
autorizado as (
  -- sin ORDER BY ni LIMIT: si hay mas de uno no hay autoridad, hay ambiguedad
  select * from candidatos where (select count(*) from candidatos) = 1
),
p01 as (select greatest(1e-9, least(1 - 1e-9, p_prob_pct / 100.0)) v)
select case
  -- cero autoridades: nada esta autorizado a mover P_RETO, lo esperado es identidad
  when (select count(*) from candidatos) = 0 then p_prob_pct
  -- dos o mas: AMBIGUO. No se adivina. Falla cerrado.
  when (select count(*) from candidatos) > 1 then null
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

commit;

-- =====================================================================
-- 4) GATES
-- =====================================================================
begin;

-- Conductual y ampliado: ahora muta tambien DEPORTE y LIGA, con valores REALES de
-- otros eventos de la propia agenda. La version de ISS098 acepta las 40
-- mutaciones 'deporte_cambiado' y las 40 'liga_cambiada'; esta, 0 de 320.
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
  select espn_event_id, deporte, liga_nombre, home_nombre, away_nombre
  from agenda_espn
  where home_espn_id is not null and away_espn_id is not null and fecha is not null
    and liga_nombre is not null
  order by fecha desc limit 40
),
-- deportes y ligas ajenas al evento, para mutar con valores REALES de otro deporte
otros as (
  select array_agg(distinct deporte) deportes, array_agg(distinct liga_nombre) ligas from agenda_espn
),
mutaciones as (
  select m.espn_event_id, m.deporte, m.liga_nombre, etiqueta, dep, lig, h, a
  from muestra m, otros o,
  lateral (values
    ('equipo_primer_caracter', m.deporte, m.liga_nombre, left(m.home_nombre,1), left(m.away_nombre,1)),
    ('equipo_prefijo_3',       m.deporte, m.liga_nombre, left(m.home_nombre,3), left(m.away_nombre,3)),
    ('equipo_sufijo_3',        m.deporte, m.liga_nombre, right(m.home_nombre,3), right(m.away_nombre,3)),
    ('equipo_superstring',     m.deporte, m.liga_nombre, m.home_nombre||' Club Deportivo', m.away_nombre||' Club Deportivo'),
    ('equipo_una_vocal',       m.deporte, m.liga_nombre, 'a', 'e'),
    ('equipo_lados_invertidos',m.deporte, m.liga_nombre, m.away_nombre, m.home_nombre),
    -- DEPORTE CAMBIADO: el evento es real, los equipos son los correctos,
    -- solo se declara otro deporte. Esto es la sonda del dueno.
    ('deporte_cambiado', (select d from unnest(o.deportes) d where d <> m.deporte limit 1),
                         m.liga_nombre, m.home_nombre, m.away_nombre),
    -- LIGA CAMBIADA: deporte y equipos correctos, liga de otra competencia
    ('liga_cambiada',    m.deporte,
                         (select l from unnest(o.ligas) l where l <> m.liga_nombre limit 1),
                         m.home_nombre, m.away_nombre)
  ) v(etiqueta, dep, lig, h, a)
),
aceptadas as (
  select mu.etiqueta, count(*) n
  from mutaciones mu
  where mu.dep is not null and mu.lig is not null
    and identidad_valida(mu.espn_event_id, mu.dep, mu.lig, 'Moneyline', 'Gana local',
                         mu.h, mu.a, 'motor_futbol_calibrado')
        not in ('HOME_NO_COINCIDE_CON_AGENDA','AWAY_NO_COINCIDE_CON_AGENDA','SIN_EQUIPOS',
                'DEPORTE_NO_COINCIDE_CON_AGENDA','LIGA_NO_COINCIDE_CON_AGENDA',
                'SIN_DEPORTE','SIN_LIGA')
  group by 1
),
-- la firma de 7 argumentos no puede volver a usarse en ninguna vista
firma_vieja as (
  select c.relname::text vista
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where n.nspname='public' and c.relkind in ('v','m')
    and pg_get_viewdef(c.oid) ~ 'identidad_valida\([^)]*?\)'
    and pg_get_viewdef(c.oid) not like '%identidad_valida(c.espn_event_id, c.deporte, c.liga,%'
)
select jsonb_build_object(
  'IDENTIDAD_PARCIAL_ACEPTADA', coalesce((select sum(n) from aceptadas), 0),
  'ALIAS_SIN_EQUIPO_EN_AGENDA', (select count(*) from alias_huerfano),
  'ALIAS_COLISIONA_CON_OTRO_EQUIPO', (select count(*) from alias_colision),
  'VISTA_CON_FIRMA_SIN_LIGA', (select count(*) from firma_vieja),
  'mutaciones_probadas', (select count(*) from mutaciones where dep is not null and lig is not null),
  'alias_registrados', (select count(*) from identidad_equipo_alias),
  'detalle_mutaciones_aceptadas', coalesce((select jsonb_object_agg(etiqueta, n) from aceptadas), '{}'),
  'detalle_vistas_firma_vieja', coalesce((select jsonb_agg(vista) from firma_vieja), '[]'));
$function$;

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
),
-- Mas de una autoridad por llave exacta. El indice unico parcial
-- ux_calibrador_autoridad_unica lo hace imposible de insertar; este gate existe
-- para que, si alguien tira el indice, la ambiguedad no vuelva en silencio.
autoridad as (
  select deporte, mercado, model_version, calibration_version, count(*) n,
         string_agg(metodo, '+' order by metodo) metodos
  from evaluado where elegido and apto_para_lock
  group by 1,2,3,4
),
-- apto_para_lock SIN elegido: el aplicador lo ignora (exige los dos). Una fila asi
-- parece autorizada en el registro y no lo esta. Hay que verla.
apto_sin_elegir as (
  select * from evaluado where apto_para_lock and not elegido
)
select jsonb_build_object(
  'CALIBRADOR_APTO_NO_REPRODUCIBLE',
      (select count(*) from evaluado where elegido and apto_para_lock and not reproducible_desde_params),
  'CALIBRADOR_APTO_NO_VERIFICABLE_ESCALAR',
      (select count(*) from evaluado where elegido and apto_para_lock and not verificable_escalarmente),
  'CALIBRADOR_AUTORIDAD_AMBIGUA', (select count(*) from autoridad where n > 1),
  'CALIBRADOR_APTO_SIN_ELEGIR',   (select count(*) from apto_sin_elegir),
  'autoridades_unicas', (select count(*) from autoridad where n = 1),
  'no_reproducibles_total', (select count(*) from evaluado where not reproducible_desde_params),
  'evaluados', (select count(*) from evaluado),
  'indice_autoridad_unica_presente',
      (select count(*) from pg_indexes where schemaname='public'
                                        and indexname='ux_calibrador_autoridad_unica'),
  'detalle_ambiguos', coalesce((select jsonb_agg(jsonb_build_object(
      'deporte',deporte,'mercado',mercado,'model',model_version,'cal',calibration_version,
      'n',n,'metodos',metodos)) from autoridad where n > 1), '[]'),
  'detalle', coalesce((select jsonb_agg(jsonb_build_object(
      'deporte',deporte,'mercado',mercado,'model',model_version,'cal',calibration_version,
      'metodo',metodo,'elegido',elegido,'apto',apto_para_lock,
      'reproducible',reproducible_desde_params,'verificable_escalar',verificable_escalarmente)
      order by metodo) from evaluado where not reproducible_desde_params
                                       or not verificable_escalarmente), '[]'));
$function$;

commit;

-- El contador de filas sin llave trazable pasa a ser BLOQUEANTE y SEPARADO en
-- pruebas_selector_limpio() (gate 13, ver gates_selector.sql). Separado a
-- proposito: "0 desplazados" y "no pudimos comprobar si se movio" son dos cosas
-- distintas y no deben sumarse en el mismo numero.

-- =====================================================================
-- 5) ASSERTIONS
-- =====================================================================
do $$
declare v jsonb; n int; ev text;
begin
  select espn_event_id into ev from agenda_espn
   where deporte='baseball' and liga_nombre='MLB' and home_espn_id is not null
     and away_espn_id is not null and fecha is not null limit 1;

  -- sonda del dueno: deporte cambiado tiene que rechazar
  if identidad_valida(ev,'soccer','MLB','Moneyline','Gana local',
        (select home_nombre from agenda_espn where espn_event_id=ev),
        (select away_nombre from agenda_espn where espn_event_id=ev),
        'motor_futbol_calibrado') <> 'DEPORTE_NO_COINCIDE_CON_AGENDA' then
    raise exception 'ASSERT 1 FALLO: se puede cambiar el deporte del evento';
  end if;

  -- liga cambiada tambien
  if identidad_valida(ev,'baseball','MLS','Moneyline','Gana local',
        (select home_nombre from agenda_espn where espn_event_id=ev),
        (select away_nombre from agenda_espn where espn_event_id=ev),
        'motor_mlb_cuantitativo') <> 'LIGA_NO_COINCIDE_CON_AGENDA' then
    raise exception 'ASSERT 2 FALLO: se puede cambiar la liga del evento';
  end if;

  -- la firma de 7 no puede devolver nada usable
  if identidad_valida(ev,'baseball','Moneyline','Gana local','x','y','z')
     <> 'FIRMA_OBSOLETA_SIN_LIGA' then
    raise exception 'ASSERT 3 FALLO: la firma de 7 argumentos sigue viva';
  end if;

  -- v_pick_canonico usa la firma de 8 y no pierde filas por el candado nuevo
  select count(*) into n from v_pick_canonico p
   where identidad_valida(p.espn_event_id,p.deporte,p.liga,p.mercado,p.pick_desc,
                          p.home,p.away,p.fuente)
         in ('DEPORTE_NO_COINCIDE_CON_AGENDA','LIGA_NO_COINCIDE_CON_AGENDA',
             'HOME_NO_COINCIDE_CON_AGENDA','AWAY_NO_COINCIDE_CON_AGENDA',
             'SIN_DEPORTE','SIN_LIGA','FIRMA_OBSOLETA_SIN_LIGA');
  if n <> 0 then
    raise exception 'ASSERT 4 FALLO: % filas canonicas rechazadas por identidad', n;
  end if;

  -- gate conductual en cero, incluidas deporte y liga
  v := gate_identidad_exacta();
  if (v->>'IDENTIDAD_PARCIAL_ACEPTADA')::int <> 0
     or (v->>'ALIAS_SIN_EQUIPO_EN_AGENDA')::int <> 0
     or (v->>'ALIAS_COLISIONA_CON_OTRO_EQUIPO')::int <> 0
     or (v->>'VISTA_CON_FIRMA_SIN_LIGA')::int <> 0 then
    raise exception 'ASSERT 5 FALLO: gate_identidad_exacta = %', v;
  end if;
  if (v->>'mutaciones_probadas')::int < 300 then
    raise exception 'ASSERT 6 FALLO: solo % mutaciones probadas, esperaba >= 300', v->>'mutaciones_probadas';
  end if;

  -- autoridad unica garantizada por indice, no solo por gate
  v := gate_calibrador_reproducible();
  if (v->>'indice_autoridad_unica_presente')::int <> 1 then
    raise exception 'ASSERT 7 FALLO: falta el indice ux_calibrador_autoridad_unica';
  end if;
  if (v->>'CALIBRADOR_AUTORIDAD_AMBIGUA')::int <> 0
     or (v->>'CALIBRADOR_APTO_SIN_ELEGIR')::int <> 0
     or (v->>'CALIBRADOR_APTO_NO_REPRODUCIBLE')::int <> 0
     or (v->>'CALIBRADOR_APTO_NO_VERIFICABLE_ESCALAR')::int <> 0 then
    raise exception 'ASSERT 8 FALLO: autoridad de calibrador invalida = %', v;
  end if;

  -- el gate vacio ya no puede dar verde: tiene que REPORTAR las filas sin llave
  v := gate_p_reto_sin_desplazar();
  if (v->>'comparados')::int <> (v->>'filas_canonicas')::int then
    raise exception 'ASSERT 9 FALLO: el gate compara % de % filas',
      v->>'comparados', v->>'filas_canonicas';
  end if;
  if (v->>'sin_llave_verificacion_vacia') is null then
    raise exception 'ASSERT 10 FALLO: el gate no reporta las filas sin llave';
  end if;

  raise notice 'ISS099 OK: 10 assertions pasadas';
end $$;

-- CONTROLES NEGATIVOS (probados el 2026-09-12, revertidos):
--   identidad sin verificar deporte ni liga -> gate_identidad_exacta marca 80 de
--       320 aceptadas: exactamente 40 'deporte_cambiado' y 40 'liga_cambiada'.
--   una sola autoridad (platt elegido+apto) -> aplicador: 62.5 -> 54.2
--   segunda autoridad en la misma llave (isotonic) -> BLOQUEADO por el indice
--   dos autoridades en soccer (identity + vector_scaling) -> BLOQUEADO por el indice
--   estado restaurado despues: 0 autoridades, 0 aptos
