-- =====================================================================
-- ISS128 -- MLB PUBLICABA UN P_RETO QUE SU PROPIO CODIGO MANDA ESCONDER
--
-- APLICADO. El dueno eligio: publicar el numero, pero ETIQUETADO.
--
-- LO QUE PASABA, EN CODIGO REAL:
--
--   public.mlb_terminal_v2_core_iss166, linea 17:
--     'official_probability_bar', jsonb_build_object(
--        'status','HIDDEN_NOT_RELEASE_AUTHORIZED',
--        'reason','MLB Moneyline no tiene P_RETO oficial validado.')
--
--   public.mlb_terminal_v2, lineas 17 y 21, lo pisaban con status='READY'
--   y p_reto_pct, condicionado SOLO a brain.ok AND brain.status='READY'.
--   La autoridad de release no se consultaba NUNCA: 0 lineas la mencionaban.
--   El core ocultaba, el envoltorio publicaba. La guarda era decorativa.
--
-- QUE DICE LA AUTORIDAD (public.v_mlb_canonical_release_authority_v1):
--   product_release_authorized = false
--   money_authorized           = false
--   validation_status          = FORWARD_SAMPLE_INSUFFICIENT
--   n_oos_events               = 14
--   brier_model 0.232387 vs brier_reference 0.25
--   brier_delta_upper95        = +0.011720   <- POSITIVO: no demuestra mejora
--
-- QUE DICE EL REGISTRO (public.modelo_registry):
--   mlb_one_brain_v2 NO TIENE FILA.
--   El unico MLB Moneyline registrado es mlb_ml_poisson_v1 = MODEL_REJECTED,
--   motivo: "Sin habilidad: peor que un volado y peor que apostarle
--            siempre al local."
--
-- EL SINTOMA EN PANTALLA:
--   el mismo contrato mostraba, uno al lado del otro,
--     brain_authority     -> "Sin habilidad: peor que un volado"
--     official_prediction -> Los Angeles Dodgers 84.2%
--   Y el veredicto de brain_authority ni siquiera se refiere al modelo que
--   produce ese pick: habla de mlb_ml_poisson_v1 y mlb_totales_*.
--
-- ============================ EL ARREGLO =============================
-- 1) official_prediction y official_probability_bar dejan de decir 'READY'.
--    Ahora dicen 'PREDICCION_NO_VALIDADA', con display=true y
--    display_label='Prediccion no validada'.
-- 2) Llevan pegados product_release_authorized=false y money_authorized=false.
-- 3) official_prediction.release_authority trae n_oos_events, brier y
--    validation_status LEIDOS DE LA TABLA con un subquery, no quemados,
--    para que no se desincronicen cuando la autoridad cambie.
-- 4) Se agrega brain_in_use con el brain_id real, para que brain_authority
--    (que lista OTROS modelos) no se lea como el veredicto del pick.
--
-- LO QUE NO TOQUE Y POR QUE:
--   El 'status' de nivel superior sigue en 'READY'. Ese campo significa
--   DISPONIBILIDAD DE DATOS (su rama else es 'DATA_UNAVAILABLE'), no
--   certificacion. Yo lo habia cambiado y lo revert: un front que filtre
--   por status='READY' habria escondido TODA la pantalla de MLB, no solo
--   la barra. Eso habria sido FAIL CLOSED por accidente, que no es lo que
--   el dueno eligio.
--
-- PENDIENTE DE FRONTEND (Lovable, no mio):
--   Si el front pinta la barra solo cuando status==='READY', el numero de
--   MLB va a desaparecer hasta que acepte tambien 'PREDICCION_NO_VALIDADA'.
--   El contrato ya trae display=true y display_label justo para eso.
--
-- MEDIDO ANTES DEL ARREGLO (401816962 y 401816960):
--   G28.1 p_reto sin autoridad ............. FAIL  1   (84.2% y 52.9%)
--   G28.2 envoltorio pisa la guarda ........ FAIL  1
--   G28.3 envoltorio consulta autoridad .... FAIL  0
--   G28.4 nfl falla cerrado (control) ...... PASS  4
--
-- MEDIDO DESPUES:
--   G28.1 no dice READY sin autoridad ...... PASS  0
--   G28.2 el numero viene etiquetado ....... PASS  0
--   G28.3 autoridad no quemada ............. PASS  0   (n_oos 14 = tabla)
--   G28.4 envoltorio consulta autoridad .... PASS  2
--   G28.5 brain_authority no confunde ...... PASS  0
--   G28.6 nfl falla cerrado (control) ...... PASS  4
--   G28.7 core sigue declarando ............ INFO
--         core HIDDEN_NOT_RELEASE_AUTHORIZED | contrato PREDICCION_NO_VALIDADA
--
--   Verificado que el resto del contrato sobrevive intacto:
--   expected_runs {away 6.50, home 3.66, total 10.16}, reto_markets.total
--   {line 8.5, over 68.5, under 31.5}, starting_pitchers presentes.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) EL PARCHE APLICADO. Tres reemplazos, cada uno con guarda de
--    "exactamente 1 coincidencia" (si aparece 0 o 2 veces, aborta).
-- ---------------------------------------------------------------------
DO $outer$
DECLARE v_def text; v_o text; v_n text; c int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public' AND p.proname='mlb_terminal_v2';

  v_o := $r$      'official_prediction',jsonb_build_object('status','READY','market','Moneyline','pick',brain#>>'{moneyline,pick}','p_reto_pct',(brain#>>'{moneyline,pick_pct}')::numeric,'home_pct',(brain#>>'{moneyline,home_pct}')::numeric,'away_pct',(brain#>>'{moneyline,away_pct}')::numeric,'brain_id',brain->>'brain_id'),$r$;

  v_n := $r$      'official_prediction',jsonb_build_object('status','PREDICCION_NO_VALIDADA','display',true,'display_label','Predicción no validada','market','Moneyline','pick',brain#>>'{moneyline,pick}','p_reto_pct',(brain#>>'{moneyline,pick_pct}')::numeric,'home_pct',(brain#>>'{moneyline,home_pct}')::numeric,'away_pct',(brain#>>'{moneyline,away_pct}')::numeric,'brain_id',brain->>'brain_id','release_authority',(select jsonb_build_object('product_release_authorized',a.product_release_authorized,'money_authorized',a.money_authorized,'validation_status',a.validation_status,'n_oos_events',a.n_oos_events,'brier_model',a.brier_model,'brier_reference',a.brier_reference,'brier_delta_upper95',a.brier_delta_upper95) from public.v_mlb_canonical_release_authority_v1 a where a.market_scope ilike '%MONEYLINE%' limit 1),'authority_note','Esta probabilidad NO tiene autorizacion de release ni de dinero. Muestra pocos partidos fuera de muestra y su mejora sobre el baseline no esta demostrada. Se publica como prediccion, no como P_RETO certificado.'),$r$;

  c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
  IF c <> 1 THEN RAISE EXCEPTION 'ISS128 R1 aborta: % coincidencias, se exigia 1', c; END IF;
  v_def := replace(v_def, v_o, v_n);

  v_o := $r$      'official_probability_bar',jsonb_build_object('status','READY','pick',brain#>>'{moneyline,pick}','p_reto_pct',(brain#>>'{moneyline,pick_pct}')::numeric)$r$;

  v_n := $r$      'official_probability_bar',jsonb_build_object('status','PREDICCION_NO_VALIDADA','display',true,'display_label','Predicción no validada','pick',brain#>>'{moneyline,pick}','p_reto_pct',(brain#>>'{moneyline,pick_pct}')::numeric,'product_release_authorized',false,'money_authorized',false,'note','Numero real del cerebro MLB, sin autorizacion de release. No es un P_RETO certificado.'),
      'brain_in_use',jsonb_build_object('brain_id',brain->>'brain_id','note','brain_authority lista OTROS modelos (mlb_ml_poisson_v1, mlb_totales_*). Sus veredictos no se refieren al pick mostrado arriba, que lo produce este brain_id.')$r$;

  c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
  IF c <> 1 THEN RAISE EXCEPTION 'ISS128 R2 aborta: % coincidencias, se exigia 1', c; END IF;
  v_def := replace(v_def, v_o, v_n);

  EXECUTE v_def;
END
$outer$;

-- ---------------------------------------------------------------------
-- 2) LA COMPUERTA. Ya no vigila "que no se muestre el numero": vigila que
--    si se muestra, venga con la verdad pegada, y que esa verdad salga de
--    la tabla de autoridad y no este quemada en el codigo.
-- ---------------------------------------------------------------------
create or replace function public.gate_probabilidad_sin_autoridad()
returns table(gate text, estado text, cuenta bigint, detalle text)
language plpgsql stable as $fn$
declare a record; v_ev text; v_bar jsonb; v_core jsonb; v_pred jsonb;
begin
  select * into a from public.v_mlb_canonical_release_authority_v1
  where market_scope ilike '%MONEYLINE%' limit 1;

  select x.espn_event_id into v_ev from public.agenda_espn x
  where x.deporte='baseball' and x.fecha >= now() order by x.fecha limit 1;

  if v_ev is null then
    return query select 'G28.0_sin_evento_mlb'::text,'INFO'::text,0::bigint,'No hay evento MLB futuro.'::text;
    return;
  end if;

  v_bar  := public.mlb_terminal_v2(v_ev)->'official_probability_bar';
  v_pred := public.mlb_terminal_v2(v_ev)->'official_prediction';
  v_core := public.mlb_terminal_v2_core_iss166(v_ev)->'official_probability_bar';

  -- G28.1: sin autoridad, el contrato NO puede decir READY
  return query select 'G28.1_no_dice_READY_sin_autoridad'::text,
    case when coalesce(a.product_release_authorized,false) or coalesce(v_bar->>'status','')<>'READY'
         then 'PASS' else 'FAIL' end,
    case when coalesce(a.product_release_authorized,false) or coalesce(v_bar->>'status','')<>'READY'
         then 0::bigint else 1::bigint end,
    format('evento %s | autoridad=%s | contrato status=%s p_reto=%s',
           v_ev, coalesce(a.product_release_authorized,false),
           coalesce(v_bar->>'status','(nulo)'), coalesce(v_bar->>'p_reto_pct','-'))::text;

  -- G28.2: si publica el numero, tiene que venir etiquetado. Numero sin etiqueta = mentira.
  return query select 'G28.2_numero_viene_etiquetado'::text,
    case when v_bar->>'p_reto_pct' is null
              or (coalesce((v_bar->>'product_release_authorized')::boolean,true) = false
              and coalesce((v_bar->>'money_authorized')::boolean,true) = false
              and nullif(v_bar->>'display_label','') is not null)
         then 'PASS' else 'FAIL' end,
    case when v_bar->>'p_reto_pct' is null
              or (coalesce((v_bar->>'product_release_authorized')::boolean,true) = false
              and coalesce((v_bar->>'money_authorized')::boolean,true) = false
              and nullif(v_bar->>'display_label','') is not null)
         then 0::bigint else 1::bigint end,
    format('display_label=%s product_release_authorized=%s money_authorized=%s',
           coalesce(v_bar->>'display_label','(falta)'),
           coalesce(v_bar->>'product_release_authorized','(falta)'),
           coalesce(v_bar->>'money_authorized','(falta)'))::text;

  -- G28.3: los numeros de autoridad mostrados deben salir de la tabla, no estar quemados
  return query select 'G28.3_autoridad_no_quemada'::text,
    case when (v_pred->'release_authority'->>'n_oos_events')::int = a.n_oos_events
          and (v_pred->'release_authority'->>'validation_status') = a.validation_status
         then 'PASS' else 'FAIL' end,
    case when (v_pred->'release_authority'->>'n_oos_events')::int = a.n_oos_events
          and (v_pred->'release_authority'->>'validation_status') = a.validation_status
         then 0::bigint else 1::bigint end,
    format('contrato n_oos=%s status=%s | tabla n_oos=%s status=%s',
           v_pred->'release_authority'->>'n_oos_events', v_pred->'release_authority'->>'validation_status',
           a.n_oos_events, a.validation_status)::text;

  -- G28.4: el envoltorio debe consultar la autoridad
  return query select 'G28.4_envoltorio_consulta_autoridad'::text,
    case when cnt > 0 then 'PASS' else 'FAIL' end, cnt,
    'Lineas de mlb_terminal_v2 que mencionan la autoridad de release.'::text
  from (select count(*) as cnt from unnest(string_to_array(
          (select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname='mlb_terminal_v2'), E'\n')) l
        where l ~* 'release_authority|product_release_authorized') z;

  -- G28.5: brain_authority no puede leerse como veredicto del pick mostrado
  return query select 'G28.5_brain_authority_no_confunde'::text,
    case when public.mlb_terminal_v2(v_ev)->'brain_in_use'->>'brain_id' is not null
         then 'PASS' else 'FAIL' end,
    case when public.mlb_terminal_v2(v_ev)->'brain_in_use'->>'brain_id' is not null
         then 0::bigint else 1::bigint end,
    'Debe existir brain_in_use para que brain_authority (que lista OTROS modelos) no se lea como el veredicto del pick.'::text;

  -- G28.6: control negativo, NFL. Si esta tambien fallara, la compuerta no probaria nada.
  return query select 'G28.6_nfl_falla_cerrado_control'::text,
    case when cnt >= 1 then 'PASS' else 'FAIL' end, cnt,
    'Control negativo: nfl_terminal_v2 con ramas NOT_RELEASE_AUTHORIZED / FAIL_CLOSED.'::text
  from (select count(*) as cnt from unnest(string_to_array(
          (select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname='nfl_terminal_v2'), E'\n')) l
        where l ~* 'NOT_RELEASE_AUTHORIZED|FAIL_CLOSED') z;

  -- G28.7: informativo, para que quede a la vista que el core sigue declarando lo suyo
  return query select 'G28.7_core_sigue_declarando'::text,'INFO'::text,1::bigint,
    format('core: %s | contrato: %s', coalesce(v_core->>'status','(nulo)'), coalesce(v_bar->>'status','(nulo)'))::text;
end $fn$;

-- El runner esta en gates_selector.sql como GATE 28.
