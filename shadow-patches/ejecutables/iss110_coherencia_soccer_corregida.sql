-- =====================================================================
-- ISS110  CORRECCION DE MI PROPIA MEDICION + SUPRESION FAIL-CLOSED
-- =====================================================================
-- LO QUE REPORTE MAL
--   En ISS103 reporte PICK_FUERA_DE_SU_DISTRIBUCION = 340 sobre 637 eventos
--   y se lo pase al dueno como defecto medido. Esta mal. El predicado era:
--
--     round(abs(COALESCE(ma.a_pick_prob, ma.a_h) - COALESCE(ma.a_h, 0)), 2)
--
--   Comparaba la probabilidad del PRIMER pick recomendado, cualquiera que
--   fuera su mercado, contra la probabilidad de GANA LOCAL. Tres errores:
--
--   1. Un pick de Under 3.5 al 68.9 % contra un local al 44.7 % daba un
--      "error" de 24 pp que no significa nada: son mercados distintos.
--      61 eventos de Under 3.5, 56 de Under 2.5, 28 de Over 2.5.
--   2. Un pick de Empate se comparaba contra el LOCAL en vez de contra el
--      empate. 60 eventos, error promedio 23.5 pp, todo artefacto.
--   3. La vista no filtra deporte. 30 eventos de baseball y 13 de football
--      estaban siendo juzgados por una matriz 1x2 de futbol. Ninguno tiene
--      a_h, asi que COALESCE(a_h, 0) hacia que el "error" fuera EXACTAMENTE
--      igual a la probabilidad del pick (ML Colorado Rockies: 38.7 vs 38.7).
--      Cuarenta y tres filas de puro artefacto aritmetico.
--
--   NUMERO REAL, comparando cada pick contra SU PROPIA marginal y solo en
--   soccer: 9 eventos incoherentes, error maximo 19.5 pp. No 340.
--
--   MODEL_MATRIX_INCOHERENT = 19 SI SE SOSTIENE: los 19 son soccer, los dos
--   motores tienen matriz 1x2, desacuerdo de 1.2 a 28.6 pp. Ese hallazgo
--   queda igual.
--
-- HALLAZGO NUEVO Y MAS GRANDE QUE EL QUE PERSEGUIA
--   462 de los 637 eventos con salida de modelo NO EXISTEN en agenda_espn.
--   277 de ellos si traen matriz 1x2. Es decir: hay modelo publicado sobre
--   eventos cuya identidad no se puede verificar contra el calendario
--   autoritativo. Eso no se arregla con una vista: o el generador escribe
--   solo sobre eventos de agenda, o agenda_espn esta incompleta. Se mide
--   aqui y se reporta; no se rellena.
--
-- LECCION, OTRA VEZ LA MISMA
--   Un contador grande no es evidencia. 340 se veia como un monstruo y era,
--   en su mayoria, mi comparacion mal armada. La regla que faltaba:
--   NO_APLICA nunca se pliega a 0 ni a violacion. Se cuenta aparte.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) A QUE MARGINAL PERTENECE UN PICK
-- ---------------------------------------------------------------------
create or replace function public.marginal_del_pick_1x2(p_pick text)
returns text language sql immutable as $fn$
  with limpio as (
    -- quita la etiqueta que mete la ruta del precio: "[PICK DE VALOR] ..."
    select btrim(regexp_replace(coalesce(p_pick,''), '\[[^]]*\]', '', 'g')) as t
  )
  select case
    when (select t from limpio) = ''                          then 'SIN_PICK'
    when (select t from limpio) ~* 'no\s*bet'                 then 'SIN_PICK'
    when (select t from limpio) ~* 'local o empate'           then 'DOBLE_1X'
    when (select t from limpio) ~* 'local o visitante'        then 'DOBLE_12'
    when (select t from limpio) ~* 'visitante o empate'       then 'DOBLE_X2'
    when (select t from limpio) ~* 'gana local'               then 'MARGINAL_LOCAL'
    when (select t from limpio) ~* 'gana visitante'           then 'MARGINAL_VISITA'
    when (select t from limpio) ~* 'empate'                   then 'MARGINAL_EMPATE'
    -- Over/Under y BTTS se derivan de la matriz de goles, no del vector 1x2.
    -- Compararlos contra una marginal 1x2 fue exactamente mi error.
    when (select t from limpio) ~* 'over|under|mas de|menos de|btts|ambos'
                                                              then 'NO_APLICA_A_LA_1X2'
    -- un ML sin lado resoluble no se adivina: se declara no resoluble
    when (select t from limpio) ~* '^ml\M|moneyline'           then 'ML_SIN_LADO_RESOLUBLE'
    else 'SIN_CLASIFICAR'
  end;
$fn$;

comment on function public.marginal_del_pick_1x2(text) is
'ISS110. Dice contra QUE marginal se debe comparar un pick. NO_APLICA_A_LA_1X2 para Over/Under y BTTS: esos se derivan de la matriz de goles y compararlos contra una marginal 1x2 fue el error que inflo PICK_FUERA_DE_SU_DISTRIBUCION de 9 a 340.';

-- ---------------------------------------------------------------------
-- 2) LA MEDICION CORREGIDA
-- ---------------------------------------------------------------------
create or replace view public.v_coherencia_soccer_v2 as
with pick1 as (
  select ap.espn_event_id,
         (select p.value->>'pick' from jsonb_array_elements(ap.analisis_json->'picks_recomendados') p limit 1) as pick_txt,
         (select (p.value->>'probabilidad_real')::numeric from jsonb_array_elements(ap.analisis_json->'picks_recomendados') p limit 1) as pick_prob
  from public.analisis_partidos ap
  where ap.analisis_json ? 'picks_recomendados'
)
select v.espn_event_id,
       ae.deporte,
       ae.liga_nombre                                as liga,
       (ae.espn_event_id is not null)                as existe_en_agenda,
       (ae.deporte ~* 'soccer|futbol')               as es_soccer,
       k.pick_txt,
       k.pick_prob,
       public.marginal_del_pick_1x2(k.pick_txt)      as marginal,
       v.a_h, v.a_d, v.a_a, v.b_h, v.b_d, v.b_a,
       v.desacuerdo_entre_motores_pp,
       -- la marginal que DE VERDAD corresponde al pick
       case public.marginal_del_pick_1x2(k.pick_txt)
         when 'MARGINAL_LOCAL'  then v.a_h
         when 'MARGINAL_EMPATE' then v.a_d
         when 'MARGINAL_VISITA' then v.a_a
         when 'DOBLE_1X'        then v.a_h + v.a_d
         when 'DOBLE_12'        then v.a_h + v.a_a
         when 'DOBLE_X2'        then v.a_d + v.a_a
       end                                           as marginal_esperada,
       case
         when ae.espn_event_id is null                     then 'SIN_EVENTO_EN_AGENDA'
         when not (ae.deporte ~* 'soccer|futbol')          then 'FUERA_DE_DEPORTE'
         when k.pick_prob is null                          then 'SIN_PROBABILIDAD'
         when public.marginal_del_pick_1x2(k.pick_txt)
              in ('SIN_PICK','NO_APLICA_A_LA_1X2','ML_SIN_LADO_RESOLUBLE','SIN_CLASIFICAR')
                                                           then 'NO_COMPARABLE'
         when v.a_h is null                                then 'SIN_MATRIZ'
         else 'COMPARABLE'
       end                                           as comparabilidad
from public.v_incoherencia_modelo_soccer v
left join public.agenda_espn ae on ae.espn_event_id = v.espn_event_id
left join pick1 k              on k.espn_event_id  = v.espn_event_id;

comment on view public.v_coherencia_soccer_v2 as
'ISS110. Coherencia de soccer medida bien: cada pick contra SU propia marginal, solo eventos de soccer que existen en agenda_espn, y una columna comparabilidad que separa COMPARABLE de NO_COMPARABLE. Lo no comparable NO se cuenta como violacion ni como cero.';

-- ---------------------------------------------------------------------
-- 3) GATE CON LA ARITMETICA HONESTA
-- ---------------------------------------------------------------------
create or replace function public.gate_coherencia_soccer_v2()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  select 'PICK_FUERA_DE_SU_DISTRIBUCION_V2'::text,
         case when count(*) filter (where comparabilidad='COMPARABLE'
                                      and abs(pick_prob - marginal_esperada) > 0.5) = 0
              then 'PASS' else 'FAIL' end,
         count(*) filter (where comparabilidad='COMPARABLE'
                            and abs(pick_prob - marginal_esperada) > 0.5),
         'sobre ' || count(*) filter (where comparabilidad='COMPARABLE')
           || ' eventos REALMENTE comparables. Error maximo '
           || coalesce(round(max(abs(pick_prob - marginal_esperada))
                 filter (where comparabilidad='COMPARABLE'), 2)::text, 'n/a') || ' pp'
  from public.v_coherencia_soccer_v2
  union all
  select 'MODEL_MATRIX_INCOHERENT'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         'eventos de soccer donde los dos motores discrepan mas de 1 pp. Maximo '
           || coalesce(round(max(desacuerdo_entre_motores_pp),1)::text,'n/a') || ' pp'
  from public.v_coherencia_soccer_v2
  where es_soccer and a_h is not null and b_h is not null
    and desacuerdo_entre_motores_pp > 1.0
  union all
  -- hallazgo nuevo: modelo publicado sobre eventos que el calendario no conoce
  select 'MODELO_SIN_EVENTO_EN_AGENDA'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         'eventos con salida de modelo que NO existen en agenda_espn; '
           || count(*) filter (where a_h is not null)
           || ' de ellos con matriz 1x2. Identidad no verificable.'
  from public.v_coherencia_soccer_v2 where not existe_en_agenda
  union all
  -- transparencia: lo no comparable se declara, no se esconde en un cero
  select 'COHERENCIA_NO_COMPARABLE_DECLARADO'::text, 'INFO',
         count(*) filter (where comparabilidad <> 'COMPARABLE'),
         (select string_agg(c || '=' || n, ', ' order by n desc)
            from (select comparabilidad c, count(*) n
                    from public.v_coherencia_soccer_v2
                   where comparabilidad <> 'COMPARABLE' group by 1) z)
  from public.v_coherencia_soccer_v2;
$fn$;

comment on function public.gate_coherencia_soccer_v2() is
'ISS110. Reemplaza a gate_coherencia_modelo_soccer en el contador de pick vs distribucion. Regla que faltaba: NO_APLICA nunca se pliega a 0 ni a violacion, se declara aparte. PICK_FUERA_DE_SU_DISTRIBUCION paso de 340 (mal medido) a 9 (bien medido).';

-- ---------------------------------------------------------------------
-- 4) SUPRESION FAIL-CLOSED QUE ORDENO EL DUENO
--    "Any violation => MODEL_MATRIX_INCOHERENT, secondary outputs
--     suppressed, event excluded from TOP_ONLY / actionable picks until
--     rebuilt."  (comentario 5646384073)
--    Se registra el evento suprimido con su evidencia. No se borra nada:
--    la supresion es una declaracion consultable, no un DELETE.
-- ---------------------------------------------------------------------
create table if not exists public.evento_suprimido (
  espn_event_id   text        not null,
  motivo          text        not null,
  evidencia       jsonb       not null,
  declarado_at    timestamptz not null default now(),
  primary key (espn_event_id, motivo)
);

comment on table public.evento_suprimido is
'ISS110. Eventos excluidos de TOP_ONLY y de picks accionables por incoherencia demostrada entre motores. La supresion se DECLARA con su evidencia; nunca se borra la fila original, porque borrar historia para limpiar una superficie prospectiva esta prohibido.';

create or replace function public.suprimir_eventos_incoherentes(p_dry_run boolean default true)
returns table(accion text, evento text, desacuerdo_pp numeric)
language plpgsql as $fn$
begin
  if p_dry_run then
    return query
      select 'SE_SUPRIMIRIA'::text, v.espn_event_id, v.desacuerdo_entre_motores_pp
      from public.v_coherencia_soccer_v2 v
      where v.es_soccer and v.a_h is not null and v.b_h is not null
        and v.desacuerdo_entre_motores_pp > 1.0
        and not exists (select 1 from public.evento_suprimido e
                        where e.espn_event_id = v.espn_event_id
                          and e.motivo = 'MODEL_MATRIX_INCOHERENT')
      order by v.desacuerdo_entre_motores_pp desc;
    return;
  end if;

  -- idempotente: solo inserta lo que falta, y no reescribe evidencia previa
  return query
    insert into public.evento_suprimido (espn_event_id, motivo, evidencia)
    select v.espn_event_id, 'MODEL_MATRIX_INCOHERENT',
           jsonb_build_object(
             'motorA_1x2', jsonb_build_array(v.a_h, v.a_d, v.a_a),
             'motorB_1x2', jsonb_build_array(v.b_h, v.b_d, v.b_a),
             'desacuerdo_pp', v.desacuerdo_entre_motores_pp,
             'liga', v.liga,
             'medido_at', now())
    from public.v_coherencia_soccer_v2 v
    where v.es_soccer and v.a_h is not null and v.b_h is not null
      and v.desacuerdo_entre_motores_pp > 1.0
    on conflict (espn_event_id, motivo) do nothing
    returning 'SUPRIMIDO'::text,
              public.evento_suprimido.espn_event_id,
              (public.evento_suprimido.evidencia->>'desacuerdo_pp')::numeric;
end;
$fn$;

comment on function public.suprimir_eventos_incoherentes(boolean) is
'ISS110. Declara suprimidos los eventos con incoherencia demostrada entre motores. Idempotente: on conflict do nothing, y no reescribe evidencia ya registrada. Por defecto p_dry_run=true.';

create or replace function public.evento_suprimido_por_incoherencia(p_event_id text)
returns boolean language sql stable as $fn$
  select exists (select 1 from public.evento_suprimido e
                 where e.espn_event_id = p_event_id
                   and e.motivo = 'MODEL_MATRIX_INCOHERENT');
$fn$;

comment on function public.evento_suprimido_por_incoherencia(text) is
'ISS110. Predicado para que las superficies excluyan el evento. Se deja listo para que el cutover lo consuma; conectarlo al selector canonico cambia QUE se publica y por eso espera autorizacion del dueno.';

grant execute on function public.marginal_del_pick_1x2(text)                to anon, authenticated, service_role;
grant execute on function public.gate_coherencia_soccer_v2()                to anon, authenticated, service_role;
grant execute on function public.evento_suprimido_por_incoherencia(text)    to anon, authenticated, service_role;
grant execute on function public.suprimir_eventos_incoherentes(boolean)     to service_role;
grant select on public.v_coherencia_soccer_v2 to anon, authenticated, service_role;
grant select on public.evento_suprimido       to anon, authenticated, service_role;
revoke insert, update, delete, truncate on public.evento_suprimido from anon, authenticated;

-- =====================================================================
-- MEDICION FINAL Y PRUEBAS
-- =====================================================================
--   comparabilidad          eventos   incoherentes   err_max
--   COMPARABLE                   10              9     19.50 pp
--   SIN_EVENTO_EN_AGENDA        462            n/a   (no verificable)
--   SIN_PROBABILIDAD             61              0
--   NO_COMPARABLE                60              0   (Over/Under, BTTS, NO BET)
--   FUERA_DE_DEPORTE             43              0   (30 baseball, 13 football)
--   SIN_MATRIZ                    1              0
--
--   PICK_FUERA_DE_SU_DISTRIBUCION_V2 = 9 sobre 10 comparables (antes 340)
--   MODEL_MATRIX_INCOHERENT          = 19, los 19 soccer, 1.2 a 28.6 pp  (se sostiene)
--   MODELO_SIN_EVENTO_EN_AGENDA      = 462, 277 con matriz 1x2           (hallazgo nuevo)
--
--   Clasificador de marginal: 11/11 pruebas PASS, incluidas las tres
--   familias que me hicieron fallar (Under 3.5, Empate, ML de MLB).
--
--   Supresion: 19 eventos declarados con evidencia.
--     run1 inserta 19, run2 inserta 0, run3 inserta 0
--     huella f226552ad4b0632eb5c481aafcbd61c6 identica
--     anon y authenticated no pueden borrar la supresion
--
--   CORRECCION DE METODO EN MI PROPIA PRUEBA
--     El primer intento de probar idempotencia midio mal: puse el INSERT y
--     el conteo como CTEs hermanos de la misma sentencia, y los efectos de
--     un CTE que modifica datos NO son visibles para los otros CTEs del
--     mismo statement. Daba filas=0 con 19 insertadas. Se repitio en
--     sentencias separadas, que es la unica forma honesta de medirlo.
--
-- LO QUE NO SE CONECTO
--   evento_suprimido_por_incoherencia() queda lista pero NO esta enganchada
--   al selector canonico. Engancharla cambia QUE se publica, y eso es
--   cutover de seleccion: espera autorizacion explicita del dueno.
