-- =====================================================================
-- ISS136 -- LA EVIDENCIA HACIA ADELANTE, Y LO QUE DICE
--
-- El dueno pidio atacar la validacion de los modelos. Resulta que el
-- vigilante YA existia y YA estaba corriendo: v2.run_model_learning_cycle
-- llena v2.model_learning_gate cada ~30 min (13 corridas exitosas en las
-- ultimas 6 horas). Lo que faltaba era que MORDIERA.
--
-- El learning gate MIDE pero no FRENA. Para futbol,
-- product_release_authorized sale de crossleague_competition_policy, no de
-- la evidencia. Si manana el modelo resulta conclusivamente malo, nada lo
-- detiene solo. Eso es lo que cierra esta compuerta.
--
-- ============ RECONSTRUIR EL INTERVALO COMPLETO ============
--
-- La tabla solo guarda brier_vs_naive_upper95. Para saber si un modelo es
-- conclusivamente PEOR hace falta el limite inferior. Se reconstruye exacto:
--     upper95 = diff + 1.96*SE   =>   SE = (upper95 - diff)/1.96
--     lower95 = diff - 1.96*SE   =>   lower95 = 2*diff - upper95
--
-- VERIFICADO contra un caso conocido (NBA, que pasa la barra):
--     diff -0.0813, upper95 -0.0621 => SE implicito 0.00980
--     1.96 * 0.00980 = 0.01921 = medio ancho inferior. Simetrico. Correcto.
--
-- Conclusivamente PEOR = lower95 > 0 (el intervalo ENTERO por encima de cero).
-- Con muestra chica nunca se dispara, que es lo correcto.
--
-- ============ LO QUE LA EVIDENCIA DICE HOY ============
--
--   modelo / mercado              n      IC95 (modelo - naive)   veredicto
--   nba_elo_v1_k24_h50 ML       1352   [-0.1005, -0.0621]   MEJOR concluyente
--   crossleague_v1 1X2           149   [-0.0950, -0.0011]   MEJOR concluyente
--   crossleague_v1 BTTS          149   [-0.0149, +0.0274]   sin veredicto
--   crossleague_v1 Over/Under    144   [+0.0024, +0.0785]   PEOR concluyente
--   nfl-2026.09.2 Total           15   [+0.0082, +0.2727]   PEOR concluyente
--   nfl-2026.09.2 Spread          15   [-0.0220, +0.2540]   sin veredicto
--   nfl-2026.09.2 Moneyline       15   [-0.1167, +0.1248]   sin veredicto
--   soccer_canonical_v2 1X2        8   [-0.2635, +0.2687]   sin veredicto
--   soccer_canonical_v2 BTTS       8   [-0.0898, +0.0053]   sin veredicto
--   soccer_canonical_v2 O/U        8   [-0.0932, +0.3305]   sin veredicto
--
-- DOS CONCLUSIONES QUE IMPORTAN PARA EL PRODUCTO:
--
-- 1. EL "QUIEN GANA" DEL FUTBOL ESTA VALIDADO. Sobre 149 partidos reales el
--    prior que alimenta soccer_canonical_v2 supera al baseline con el
--    intervalo entero por debajo de cero. Es el mercado principal de la
--    tarjeta y es el bueno. Primera vez en toda la sesion que puedo decir
--    que algo de futbol esta demostrado.
--
-- 2. EL OVER/UNDER DEL FUTBOL ES PEOR QUE ADIVINAR, Y ESTA DEMOSTRADO.
--    Sobre 144 partidos, IC95 [+0.0024, +0.0785], entero por encima de cero.
--    No es ruido. Y el modelo publicado apunta igual: en sus primeros 8
--    partidos va 25% de acierto con un hueco de calibracion de 79.3 pp.
--    Dos senales independientes, misma direccion, mismo mercado.
--
-- soccer_canonical_v2 ya NO tiene cero partidos terminados: tiene 8. Lo que
-- le dije al dueno antes ("cero partidos") era cierto cuando lo medi y ya no
-- lo es; la evidencia empezo a llegar sola.
--
-- ============ QUE SE HIZO CON ESO ============
--
-- NO se borro el Over/Under de la tarjeta. Se aplico el mismo criterio que
-- el dueno eligio para MLB en ISS128: publicar el numero CON la verdad
-- pegada. Cada tarjeta lleva ahora evidencia_por_mercado, y cada mercado
-- carga su veredicto, su n, su intervalo y una explicacion en espanol.
--
-- Esconder un mercado malo y mostrar uno bueno sin decir cual es cual seria
-- peor que mostrar los dos etiquetados.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) Evidencia por mercado de la tarjeta, lista para el frontend
-- ---------------------------------------------------------------------
create or replace view public.v_evidencia_mercado_soccer as
with g as (
  select market, model_version, n_events, brier_model, brier_naive,
         brier_vs_naive_diff as diff,
         (2*brier_vs_naive_diff - brier_vs_naive_upper95) as lower95,
         brier_vs_naive_upper95 as upper95,
         leader_accuracy_pct, max_calibration_gap_pp
  from v2.model_learning_gate
  where scope='GLOBAL' and brier_vs_naive_upper95 is not null
),
m(mercado_tarjeta, market) as (values
  ('ganador','1X2'), ('btts','BTTS'), ('total','Over/Under')
)
select
  m.mercado_tarjeta,
  jsonb_build_object(
    'modelo','crossleague_v1',
    'papel','prior que alimenta soccer_canonical_v2 en las 16 ligas domesticas',
    'n', p.n_events,
    'brier_modelo', round(p.brier_model,4),
    'brier_adivinando', round(p.brier_naive,4),
    'ic95_inferior', round(p.lower95,4),
    'ic95_superior', round(p.upper95,4),
    'accuracy_pct', round(p.leader_accuracy_pct,1),
    'gap_calibracion_pp', round(p.max_calibration_gap_pp,1)
  ) as evidencia_prior,
  jsonb_build_object(
    'modelo','soccer_canonical_v2',
    'papel','el que publica hoy',
    'n', c.n_events,
    'brier_modelo', round(c.brier_model,4),
    'brier_adivinando', round(c.brier_naive,4),
    'ic95_inferior', round(c.lower95,4),
    'ic95_superior', round(c.upper95,4),
    'accuracy_pct', round(c.leader_accuracy_pct,1)
  ) as evidencia_publicado,
  case
    when p.lower95 > 0 then 'PEOR_QUE_ADIVINAR_CONCLUYENTE'
    when p.upper95 < 0 then 'MEJOR_QUE_ADIVINAR_CONCLUYENTE'
    else 'SIN_VEREDICTO_MUESTRA_INSUFICIENTE'
  end as veredicto,
  case
    when p.lower95 > 0 then
      format('Sobre %s partidos reales este mercado sale PEOR que adivinar, y el intervalo de confianza del 95%% esta entero por encima de cero. No es ruido.', p.n_events)
    when p.upper95 < 0 then
      format('Sobre %s partidos reales este mercado supera al baseline con el intervalo de 95%% entero por debajo de cero.', p.n_events)
    else
      format('Sobre %s partidos el intervalo cruza el cero: todavia no se puede afirmar ni que gana ni que pierde contra adivinar.', p.n_events)
  end as explicacion,
  'El baseline es adivinar con las frecuencias base (1/3 cada resultado en 1X2, 50/50 en BTTS y Over/Under). Brier mas bajo es mejor.'::text as como_leerlo,
  now() as evaluado_at
from m
left join g p on p.market = m.market and p.model_version = 'crossleague_v1'
left join g c on c.market = m.market and c.model_version = 'soccer_canonical_v2';

revoke all on public.v_evidencia_mercado_soccer from public;
grant select on public.v_evidencia_mercado_soccer to anon, authenticated, service_role;

-- ---------------------------------------------------------------------
-- 2) La compuerta. Su trabajo NO es estar verde: es no dejar pasar
--    una probabilidad que la realidad ya desmintio.
-- ---------------------------------------------------------------------
create or replace function public.gate_evidencia_hacia_adelante()
returns table(gate text, estado text, cuenta bigint, detalle text)
language plpgsql stable set statement_timeout='120s' as $fn$
begin
  -- G32.1: el vigilante tiene que seguir vivo. Si el ciclo se para, la
  -- evidencia deja de acumularse y nadie se entera. Es exactamente como
  -- murio la ingesta 6 dias sin que nadie lo viera (ISS130).
  return query
  select 'G32.1_el_vigilante_sigue_vivo'::text,
    case when max(g.computed_at) > now() - interval '3 hours' then 'PASS' else 'FAIL' end,
    (extract(epoch from (now() - max(g.computed_at)))/3600)::bigint,
    format('Ultima evaluacion hace %s horas. Si pasa de 3, la evidencia dejo de acumularse.',
           round(extract(epoch from (now() - max(g.computed_at)))/3600.0, 1))::text
  from v2.model_learning_gate g;

  -- G32.2: nada publicado puede ser CONCLUSIVAMENTE peor que adivinar.
  return query
  with pub as (
    select g.*, (2*g.brier_vs_naive_diff - g.brier_vs_naive_upper95) as lower95
    from v2.model_learning_gate g
    where g.scope='GLOBAL'
      and g.model_version in (
        select distinct p.model_version from v2.crossleague_competition_policy p
        where p.status='PROD_APPROVED'
        union select 'soccer_canonical_v2' union select 'mlb_one_brain_v2')
      and g.brier_vs_naive_upper95 is not null
  )
  select 'G32.2_nada_publicado_es_peor_que_adivinar'::text,
    case when count(*) filter (where lower95 > 0) = 0 then 'PASS' else 'FAIL' end,
    count(*) filter (where lower95 > 0),
    coalesce(string_agg(format('%s %s: n=%s diff=%s IC95[%s, %s]',
      model_version, market, n_events, round(brier_vs_naive_diff,4),
      round(lower95,4), round(brier_vs_naive_upper95,4)), ' | ')
      filter (where lower95 > 0),
      'Ningun modelo publicado es conclusivamente peor que el baseline.')::text
  from pub;

  -- G32.3: el estado de lo que publica, a la vista y no escondido.
  return query
  with pub as (
    select g.*, (2*g.brier_vs_naive_diff - g.brier_vs_naive_upper95) as lower95
    from v2.model_learning_gate g
    where g.scope='GLOBAL'
      and g.model_version in ('soccer_canonical_v2','mlb_one_brain_v2','nfl-2026.09.2')
  )
  select 'G32.3_estado_de_lo_publicado'::text, 'INFO'::text, count(*),
    string_agg(format('%s/%s n=%s brier %s vs naive %s (%s) acc %s%% gapCal %spp',
      model_version, market, n_events,
      round(brier_model,4), round(brier_naive,4),
      case when brier_vs_naive_diff < 0 then 'MEJOR' else 'PEOR' end,
      round(leader_accuracy_pct,1), round(max_calibration_gap_pp,1)),
      ' | ' order by model_version, market)::text
  from pub;

  -- G32.4: con muestra suficiente y sin superar el baseline, hay que decidir.
  -- No se puede vivir en el limbo para siempre.
  return query
  with pub as (
    select g.* from v2.model_learning_gate g
    where g.scope='GLOBAL' and g.n_events >= 200
      and g.model_version in ('soccer_canonical_v2','mlb_one_brain_v2','nfl-2026.09.2')
  )
  select 'G32.4_muestra_suficiente_sin_veredicto'::text,
    case when count(*)=0 then 'PASS' else 'FAIL' end, count(*),
    coalesce(string_agg(format('%s/%s ya tiene n=%s y sigue sin superar el baseline: toca decidir.',
      model_version, market, n_events), ' | '),
      'Ningun modelo publicado alcanzo muestra suficiente todavia.')::text
  from pub where brier_vs_naive_upper95 >= 0;

  -- G32.5: la barra tiene que ser alcanzable. Si NADA la pasa, la sospecha
  -- deberia ser de la barra, no de los modelos.
  return query
  select 'G32.5_la_barra_es_alcanzable'::text,
    case when count(*) > 0 then 'PASS' else 'FAIL' end, count(*),
    coalesce(string_agg(format('%s/%s n=%s brier %s vs %s, IC95 superior %s',
      model_version, market, n_events, round(brier_model,4), round(brier_naive,4),
      round(brier_vs_naive_upper95,4)), ' | '),
      'Ningun modelo en toda la base pasa la barra. Revisar si la barra es realista.')::text
  from v2.model_learning_gate
  where scope='GLOBAL' and brier_vs_naive_upper95 < 0 and n_events >= 200;
end $fn$;

-- =====================================================================
-- MEDIDO:
--   G32.1 el vigilante sigue vivo .............. PASS  (ultima hace 0.4 h)
--   G32.2 nada publicado es peor que adivinar .. FAIL  1
--         crossleague_v1 Over/Under: n=144 IC95[0.0024, 0.0785]
--   G32.3 estado de lo publicado ............... INFO  6
--   G32.4 muestra suficiente sin veredicto ..... PASS  0
--   G32.5 la barra es alcanzable ............... PASS  2 (NBA y WNBA)
--
-- G32.2 ESTA EN ROJO A PROPOSITO Y NO SE DEBE "ARREGLAR" SILENCIANDOLA.
-- Se pone verde de una sola forma honesta: que el Over/Under de futbol deje
-- de ser peor que adivinar, o que se deje de publicar. Bajar el umbral o
-- sacar el modelo de la lista seria taparlo.
--
-- G32.5 existe para que la barra no sea un imposible disfrazado de rigor:
-- NBA (n=1352) y WNBA (n=343) la pasan, asi que es alcanzable.
-- =====================================================================
