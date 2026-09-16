-- =====================================================================
-- ISS128 -- MLB PUBLICA UN P_RETO QUE SU PROPIO CODIGO MANDA ESCONDER
--
-- NO APLICADO. Es un hallazgo con prueba, mas una compuerta que lo detecta.
-- El arreglo cambia lo que el usuario VE, y eso lo decide el dueno.
-- RELEASE=HOLD. PROD_MODEL_CUTOVER=FROZEN.
--
-- LO QUE PASA, EN TRES LINEAS DE CODIGO REAL:
--
--   public.mlb_terminal_v2_core_iss166, linea 17:
--     'official_probability_bar', jsonb_build_object(
--        'status','HIDDEN_NOT_RELEASE_AUTHORIZED',
--        'reason','MLB Moneyline no tiene P_RETO oficial validado.')
--
--   public.mlb_terminal_v2, lineas 13-21:
--     brain := public.mlb_one_brain_v2(p_espn_event_id);
--     if coalesce((brain->>'ok')::boolean,false) and brain->>'status'='READY' then
--       j := j || jsonb_build_object(
--         'official_prediction', jsonb_build_object('status','READY', ...),
--         'official_probability_bar', jsonb_build_object('status','READY',
--             'pick', brain#>>'{moneyline,pick}',
--             'p_reto_pct',(brain#>>'{moneyline,pick_pct}')::numeric));
--
--   La unica condicion es brain.ok AND brain.status='READY'.
--   La autoridad de release no se consulta NUNCA: 0 lineas de
--   mlb_terminal_v2 la mencionan. El core oculta, el envoltorio publica.
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
--   el unico MLB Moneyline registrado es mlb_ml_poisson_v1 = MODEL_REJECTED
--   motivo: "Sin habilidad: peor que un volado y peor que apostarle
--            siempre al local."
--   mlb_one_brain_v2 NO TIENE FILA en el registro.
--
-- EL RESULTADO EN PANTALLA:
--   El mismo contrato muestra, uno al lado del otro:
--     brain_authority    -> "Sin habilidad: peor que un volado"
--     official_prediction-> Los Angeles Dodgers 84.2%
--
-- PROBADO EN DOS EVENTOS INDEPENDIENTES:
--   401816962 -> official_probability_bar.status=READY, p_reto 84.2%
--   401816960 -> official_probability_bar.status=READY, p_reto 52.9%
--   en ambos: autoridad product_release_authorized = false
--
-- CONTROL NEGATIVO: NFL NO tiene este problema. nfl_terminal_v2 falla
--   cerrado de forma explicita (4 ramas NOT_RELEASE_AUTHORIZED / FAIL_CLOSED,
--   y secondary_markets = NOT_RELEASE_AUTHORIZED). La compuerta lo confirma
--   con PASS, o sea que no esta siempre en rojo.
--
-- LAS DOS SALIDAS, Y NINGUNA ES MIA:
--   A) FAIL CLOSED: que mlb_terminal_v2 respete la guarda del core y deje de
--      publicar P_RETO de MLB hasta que la autoridad lo apruebe. Es la regla
--      del dueno ("si falta evidencia: FAIL CLOSED"), pero le quita a MLB el
--      numero de la pantalla justo antes del release.
--   B) PUBLICAR ETIQUETADO: mantener el numero pero con estado honesto
--      (p.ej. 'PREDICCION_NO_VALIDADA', n_oos=14, sin autorizacion de dinero)
--      para que el usuario no lo lea como un P_RETO certificado.
--   Lo que NO es opcion es dejarlo como esta: el contrato se contradice solo.
-- =====================================================================

create or replace function public.gate_probabilidad_sin_autoridad()
returns table(gate text, estado text, cuenta bigint, detalle text)
language plpgsql stable as $fn$
declare v_auth_ok boolean; v_ev text; v_bar jsonb; v_core jsonb;
begin
  select coalesce(bool_or(product_release_authorized),false) into v_auth_ok
  from public.v_mlb_canonical_release_authority_v1
  where market_scope ilike '%MONEYLINE%';

  select a.espn_event_id into v_ev
  from public.agenda_espn a
  where a.deporte='baseball' and a.fecha >= now()
  order by a.fecha limit 1;

  if v_ev is null then
    return query select 'G28.0_sin_evento_mlb'::text,'INFO'::text,0::bigint,
                        'No hay evento MLB futuro para probar.'::text;
    return;
  end if;

  v_bar  := public.mlb_terminal_v2(v_ev)->'official_probability_bar';
  v_core := public.mlb_terminal_v2_core_iss166(v_ev)->'official_probability_bar';

  return query
  select 'G28.1_mlb_p_reto_sin_autoridad'::text,
         case when v_auth_ok or coalesce(v_bar->>'status','') <> 'READY' then 'PASS' else 'FAIL' end,
         case when v_auth_ok or coalesce(v_bar->>'status','') <> 'READY' then 0::bigint else 1::bigint end,
         format('evento %s | autoridad product_release_authorized=%s | contrato publica status=%s p_reto_pct=%s',
                v_ev, v_auth_ok, coalesce(v_bar->>'status','(nulo)'), coalesce(v_bar->>'p_reto_pct','-'))::text;

  return query
  select 'G28.2_envoltorio_pisa_guarda'::text,
         case when coalesce(v_core->>'status','') = 'HIDDEN_NOT_RELEASE_AUTHORIZED'
                   and coalesce(v_bar->>'status','') = 'READY' then 'FAIL' else 'PASS' end,
         case when coalesce(v_core->>'status','') = 'HIDDEN_NOT_RELEASE_AUTHORIZED'
                   and coalesce(v_bar->>'status','') = 'READY' then 1::bigint else 0::bigint end,
         format('core dice "%s" | mlb_terminal_v2 dice "%s". Si el core oculta y el envoltorio publica, la guarda es decorativa.',
                coalesce(v_core->>'status','(nulo)'), coalesce(v_bar->>'status','(nulo)'))::text;

  return query
  select 'G28.3_envoltorio_consulta_autoridad'::text,
         case when cnt > 0 then 'PASS' else 'FAIL' end, cnt,
         'Lineas de mlb_terminal_v2 que mencionan release authority. 0 = publica sin preguntar.'::text
  from (select count(*) as cnt from unnest(string_to_array(
          (select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname='mlb_terminal_v2'), E'\n')) l
        where l ~* 'release_authority|product_release_authorized|NOT_RELEASE_AUTHORIZED') z;

  return query
  select 'G28.4_nfl_falla_cerrado'::text,
         case when cnt >= 1 then 'PASS' else 'FAIL' end, cnt,
         'Control negativo: nfl_terminal_v2 debe tener ramas NOT_RELEASE_AUTHORIZED / FAIL_CLOSED explicitas.'::text
  from (select count(*) as cnt from unnest(string_to_array(
          (select p.prosrc from pg_proc p join pg_namespace n on n.oid=p.pronamespace
           where n.nspname='public' and p.proname='nfl_terminal_v2'), E'\n')) l
        where l ~* 'NOT_RELEASE_AUTHORIZED|FAIL_CLOSED') z;
end $fn$;

-- MEDIDO 2026-09-16:
--   G28.1 mlb p_reto sin autoridad ......... FAIL  1
--   G28.2 envoltorio pisa la guarda ........ FAIL  1
--   G28.3 envoltorio consulta autoridad .... FAIL  0
--   G28.4 nfl falla cerrado (control) ...... PASS  4
