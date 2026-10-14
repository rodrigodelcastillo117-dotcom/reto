-- iss082 — AUDITORÍA DEL CANDADO DEL DUEÑO — SQL EJECUTABLE
-- Recaptura del 11-sep-2026. Reemplaza a shadow-patches/prepared/iss082_*.sql,
-- que era sólo prosa (blocker del auditor, comentario 5639091011).
--
-- CANDADO (textual, issue #4):
--   "sportsbook/market disagreement (score_valor, discriminacion_pp, brecha_pp,
--    implied-price gap, EV, etc.) may be shown as diagnostic context only;
--    it may never select, rank, authorize, suppress, or substitute a P_RETO pick."
--
-- CÓMO LEER ESTE ARCHIVO
-- Casi todo son cirugías de texto sobre pg_get_viewdef / pg_get_functiondef con
-- ASERCIÓN DE APARICIÓN ÚNICA antes de cada reemplazo. Eso las hace
-- auto-verificables: si la base no está en el estado esperado, revientan con
-- excepción en vez de aplicar algo distinto en silencio.
--
-- LIMITACIÓN, dicha claramente: este archivo reconstruye desde el estado
-- INMEDIATAMENTE ANTERIOR (el de las migraciones previas), no desde una base
-- vacía. Correrlo dos veces falla a propósito en la primera aserción.
-- Para comprobar que el resultado es idéntico a producción: MANIFIESTO.txt
-- + verificar.sql. Para comprobar que las reglas siguen vivas aunque el SQL
-- cambie de forma: verificar_invariantes.sql.

-- ===========================================================================
-- 1) v_pick_canonico — rank_en_partido lo decidía la brecha contra el precio
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_viewdef('public.v_pick_canonico'::regclass, true);
  a := E'ORDER BY m.es_pick DESC, m.es_senal DESC, (m.probabilidad_pct - m.prob_que_implica_el_precio_pct) DESC NULLS LAST, m.probabilidad_pct DESC)';
  b := E'ORDER BY m.es_pick DESC, m.es_senal DESC, '
    || E'(m.probabilidad_pct - CASE WHEN m.deporte ~* ''soccer|futbol'' AND m.mercado = ''Moneyline'' THEN 33.3 ELSE 50.0 END) DESC NULLS LAST, '
    || E'm.probabilidad_pct DESC)';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.1 no unica'; end if;
  execute 'create or replace view public.v_pick_canonico as ' || replace(v,a,b);
end $$;

-- ===========================================================================
-- 2) v_mejor_pick_por_partido — el mercado elegía EL pick de cada partido y
--    además suprimía los partidos sin precio
-- ===========================================================================
do $$
declare v text; a text; b text; base text;
begin
  base := 'CASE WHEN p.deporte ~* ''soccer|futbol'' AND p.mercado = ''Moneyline'' THEN 33.3 ELSE 50.0 END';
  v := pg_get_viewdef('public.v_mejor_pick_por_partido'::regclass, true);

  a := 'ORDER BY (p.probabilidad_pct - p.prob_que_implica_el_precio_pct) DESC NULLS LAST, p.probabilidad_pct DESC, p.mercado, p.pick_desc) AS rn';
  b := 'ORDER BY (p.probabilidad_pct - ' || base || ') DESC NULLS LAST, p.probabilidad_pct DESC, p.mercado, p.pick_desc) AS rn';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.2a no unica'; end if;
  v := replace(v,a,b);

  a := 'WHERE p.arranca_en > now() AND p.probabilidad_pct IS NOT NULL AND p.prob_que_implica_el_precio_pct IS NOT NULL AND p.probabilidad_pct >= 45::numeric) x';
  b := 'WHERE p.arranca_en > now() AND p.probabilidad_pct IS NOT NULL AND p.probabilidad_pct > ' || base || ') x';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.2b no unica'; end if;
  v := replace(v,a,b);

  execute 'create or replace view public.v_mejor_pick_por_partido as ' || v;
end $$;

-- ===========================================================================
-- 3) picks_premium — score_valor ERA el EV; ordenaba por "tiene precio"
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_viewdef('public.picks_premium'::regclass, true);

  a := E'WHEN a.precio_verificado THEN a.ev\n                    ELSE round(a.probabilidad / 100.0 * a.momio_justo * 1.06 - 1::numeric, 4)\n                END AS score_valor';
  b := E'WHEN true THEN round(a.probabilidad - CASE WHEN a.mercado = ''Moneyline''::text THEN 33.3 ELSE 50.0 END, 2)\n                    ELSE NULL::numeric\n                END AS score_valor';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.3a no unica'; end if;
  v := replace(v,a,b);

  a := 'AND (a.precio_verificado AND a.ev >= 0.02 OR NOT a.precio_verificado AND a.muestra_historica >= 300::numeric AND abs(COALESCE(a.sesgo_historico, 0::numeric)) <= 4::numeric)';
  b := 'AND a.muestra_historica >= 300::numeric AND abs(COALESCE(a.sesgo_historico, 0::numeric)) <= 4::numeric';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.3b no unica'; end if;
  v := replace(v,a,b);

  a := 'ORDER BY c.precio_verificado DESC, c.score_valor DESC) AS rn';
  b := 'ORDER BY c.score_valor DESC, c.muestra_historica DESC, c.mercado, c.pick) AS rn';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.3c no unica'; end if;
  v := replace(v,a,b);

  a := E'WHEN precio_verificado AND ev >= 0.06 AND muestra_historica >= 500::numeric THEN ''elite''::text\n            WHEN precio_verificado THEN ''alto''::text';
  b := E'WHEN score_valor >= 12::numeric AND muestra_historica >= 500::numeric THEN ''elite''::text\n            WHEN score_valor >= 6::numeric AND muestra_historica >= 300::numeric THEN ''alto''::text';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.3d no unica'; end if;
  v := replace(v,a,b);

  a := 'ORDER BY precio_verificado DESC, score_valor DESC, fecha;';
  b := 'ORDER BY score_valor DESC, muestra_historica DESC, fecha;';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.3e no unica'; end if;
  v := replace(v,a,b);

  execute 'create or replace view public.picks_premium as ' || v;
end $$;

-- piso propio: nunca publicar un pick por debajo de la base aritmética
do $$
declare v text; a text; b text;
begin
  v := pg_get_viewdef('public.picks_premium'::regclass, true);
  a := E'  WHERE rn <= 2\n';
  b := E'  WHERE rn <= 2 AND score_valor > 0::numeric\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.3f no unica'; end if;
  execute 'create or replace view public.picks_premium as ' || replace(v,a,b);
end $$;

-- ===========================================================================
-- 4) v_picks_con_valor — exigía que nuestra probabilidad le ganara al precio
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_viewdef('public.v_picks_con_valor'::regclass, true);
  a := 'AND prob_que_implica_el_precio_pct IS NOT NULL AND probabilidad_pct >= 50::numeric AND probabilidad_pct > prob_que_implica_el_precio_pct AND';
  b := 'AND probabilidad_pct >= 50::numeric AND';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.4 no unica'; end if;
  execute 'create or replace view public.v_picks_con_valor as ' || replace(v,a,b);
end $$;

-- ===========================================================================
-- 5) v_mejores_picks_mlb — DISTINCT ON por brecha_pp; nivel por brecha_pp;
--    sin piso propio (su única fila era de 49.2%, bajo el volado)
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_viewdef('public.v_mejores_picks_mlb'::regclass, true);

  a := 'ORDER BY espn_event_id, brecha_pp DESC NULLS LAST;';
  b := 'ORDER BY espn_event_id, ((f ->> ''prob_calibrada''::text)::numeric) DESC NULLS LAST, prob DESC NULLS LAST, mercado, pick;';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.5a no unica'; end if;
  v := replace(v,a,b);

  a := E'            WHEN brecha_pp >= 12::numeric THEN ''ojo''::text\n            WHEN brecha_pp >= 3::numeric THEN ''fuerte''::text';
  b := E'            WHEN ((f ->> ''prob_calibrada''::text)::numeric) >= 62::numeric THEN ''fuerte''::text\n            WHEN ((f ->> ''prob_calibrada''::text)::numeric) >= 55::numeric THEN ''medio''::text';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.5b no unica'; end if;
  v := replace(v,a,b);

  a := 'WHERE ((j.f ->> ''pasa''::text)::boolean) AND (j.mercado <> ''Moneyline''::text OR COALESCE(j.confiable, false))';
  b := a || ' AND ((j.f ->> ''prob_calibrada''::text)::numeric) > 50::numeric';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.5c no unica'; end if;
  v := replace(v,a,b);

  execute 'create or replace view public.v_mejores_picks_mlb as ' || v;
end $$;

-- ===========================================================================
-- 6) v_picks_para_parlay — SUSTITUÍA nuestra probabilidad por la implícita
--    de la casa cuando la IA no daba probabilidad (4 de 143 picks).
--    Es la regla permanente del dueño, violada literalmente.
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_viewdef('public.v_picks_para_parlay'::regclass, true);

  a := 'round(COALESCE(opt.probabilidad_real * 100::numeric, 100.0 / opt.momio_mercado), 1) AS probabilidad_pct,';
  b := 'round(opt.probabilidad_real * 100::numeric, 1) AS probabilidad_pct,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.6a no unica'; end if;
  v := replace(v,a,b);

  a := '(''Pick AI con EV ''::text || opt.ev_estimado::text) || ''% — sin track record verificado''::text AS razon,';
  b := '((''Pick AI: ''::text || round(opt.probabilidad_real * 100::numeric, 1)::text) || ''% de probabilidad segun el modelo — sin track record verificado''::text) AS razon,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.6b no unica'; end if;
  v := replace(v,a,b);

  a := 'AND opt.momio_mercado >= 1.50 AND opt.momio_mercado <= 8.00 AND opt.ev_estimado >= 5::numeric AND opt.ev_estimado <= 60::numeric AND COALESCE(opt.probabilidad_real * 100::numeric, 50::numeric) >= 15::numeric';
  b := 'AND opt.probabilidad_real IS NOT NULL AND opt.probabilidad_real * 100::numeric > CASE WHEN opt.mercado = ''Moneyline''::text AND opt.liga !~* ''nfl|mlb|nba''::text THEN 33.3 ELSE 50.0 END';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.6c no unica'; end if;
  v := replace(v,a,b);

  execute 'create or replace view public.v_picks_para_parlay as ' || v;
end $$;

-- ===========================================================================
-- 7) v_oraculo_picks_activos — la "barra de confianza" era 50 + ev_estimado*2
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_viewdef('public.v_oraculo_picks_activos'::regclass, true);

  a := E'            WHEN momio_mercado IS NULL OR ev_estimado IS NULL THEN 0::numeric\n            ELSE GREATEST(0::numeric, LEAST(100::numeric, 50::numeric + ev_estimado * 2::numeric))\n';
  b := E'            WHEN probabilidad_real IS NULL THEN 0::numeric\n            ELSE GREATEST(0::numeric, LEAST(100::numeric, round(probabilidad_real * 100::numeric, 1)))\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.7a no unica'; end if;
  v := replace(v,a,b);

  a := 'WHERE resultado = ''pendiente''::text AND odds_source IS NOT NULL AND momio_mercado >= 1.20 AND momio_mercado <= 15.0;';
  b := 'WHERE resultado = ''pendiente''::text AND probabilidad_real IS NOT NULL '
    || 'AND probabilidad_real * 100::numeric > CASE WHEN COALESCE(mercado, ''''::text) = ''Moneyline''::text '
    || 'AND COALESCE(liga, ''''::text) !~* ''nfl|mlb|nba|beisbol|baseball|football''::text THEN 33.3 ELSE 50.0 END;';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.7b no unica'; end if;
  v := replace(v,a,b);

  execute 'create or replace view public.v_oraculo_picks_activos as ' || v;
end $$;

-- ===========================================================================
-- 8) v_picks_premium (la de IA) y v_super_pick
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_viewdef('public.v_picks_premium'::regclass, true);
  a := 'AND opt.momio_mercado >= 1.40 AND opt.momio_mercado <= 5.00 ';
  b := 'AND opt.probabilidad_real IS NOT NULL ';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.8a no unica'; end if;
  v := replace(v,a,b);
  a := 'opt.ev_estimado AS ev_declarado,';
  b := 'NULL::numeric AS ev_declarado,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.8b no unica'; end if;
  execute 'create or replace view public.v_picks_premium as ' || replace(v,a,b);
end $$;

do $$
declare v text; a text; b text;
begin
  v := pg_get_viewdef('public.v_super_pick'::regclass, true);
  -- el EV que declara la IA es un número inventado hacia adelante
  a := E'\n    ev_declarado_pct,\n';
  b := E'\n    NULL::numeric AS ev_declarado_pct,\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.8c no unica'; end if;
  v := replace(v,a,b);
  -- el precio, por sí solo, no es razón para tomar un pick
  a := E'        CASE\n            WHEN momio_usado >= 2.20 AND momio_usado <= 5.00 THEN ''Momio en el rango donde el sistema gana dinero de verdad''::text\n            ELSE NULL::text\n        END], NULL::text) AS razones_positivas,';
  b := E'        NULL::text], NULL::text) AS razones_positivas,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.8d no unica'; end if;
  v := replace(v,a,b);
  -- el desempate del PICK DEL DÍA era el momio más alto
  a := 'ORDER BY p.score_total DESC, p.ev_real_pct DESC NULLS LAST, p.momio_usado DESC, p.match_date) AS orden_estrella,';
  b := 'ORDER BY p.score_total DESC, p.ev_real_pct DESC NULLS LAST, p.muestra_calibracion DESC NULLS LAST, p.prob_pct DESC NULLS LAST, p.match_date) AS orden_estrella,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.8e no unica'; end if;
  execute 'create or replace view public.v_super_pick as ' || replace(v,a,b);
end $$;

-- ===========================================================================
-- 9) v_picks_futbol_calc — "apostable" significaba: DraftKings le puso precio
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_viewdef('public.v_picks_futbol_calc'::regclass, true);
  a := 'momio_mercado IS NOT NULL AND precio_verificado AS apostable';
  b := 'probabilidad IS NOT NULL AND probabilidad > (CASE WHEN mercado = ''Moneyline''::text THEN 33.3 ELSE 50.0 END) AS apostable';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.9 no unica'; end if;
  execute 'create or replace view public.v_picks_futbol_calc as ' || replace(v,a,b);
end $$;

-- ===========================================================================
-- 10) parlay_del_dia_v3 — reescrita completa. Ordenaba, filtraba y ponía
--     'es_lock' con discriminacion_pp, y su propio texto 'criterio' ARGUMENTABA
--     a favor de ordenar por desacuerdo con el mercado.
-- ===========================================================================
create or replace function public.parlay_del_dia_v3(p_ventana_horas integer default 48)
 returns jsonb language sql stable security definer set search_path to 'public'
as $function$
  with base as (
    select v.*,
           (v.probabilidad_pct - case when v.deporte ~* 'soccer|futbol' and v.mercado = 'Moneyline'
                                      then 33.3 else 50.0 end) as ventaja_sobre_azar,
           row_number() over (partition by v.deporte
                              order by coalesce(v.calibracion_confiable,false) desc,
                                       (v.probabilidad_pct - case when v.deporte ~* 'soccer|futbol' and v.mercado = 'Moneyline'
                                                                 then 33.3 else 50.0 end) desc,
                                       coalesce(v.muestra_calibracion,0) desc,
                                       v.probabilidad_pct desc) as rn_dep
      from public.v_mejor_pick_por_partido v
     where v.arranca_en <= now() + make_interval(hours =>
             case when lower(v.deporte) in ('football','nfl') then greatest(p_ventana_horas, 192)
                  else p_ventana_horas end)
  ),
  fila as (
    select b.*, jsonb_build_object(
      'deporte', b.deporte, 'liga', b.liga, 'partido', b.home||' vs '||b.away,
      'arranca_en', b.arranca_en, 'mercado', b.mercado, 'pick', b.pick_desc,
      'probabilidad_pct', b.probabilidad_pct,
      'base_azar_pct', round(case when b.deporte ~* 'soccer|futbol' and b.mercado = 'Moneyline'
                                  then 33.3 else 50.0 end, 1),
      'ventaja_sobre_azar_pp', round(b.ventaja_sobre_azar, 1),
      'calibracion_confiable', coalesce(b.calibracion_confiable,false),
      'muestra_calibracion', b.muestra_calibracion,
      -- contexto diagnostico unicamente: NO selecciona, NO ordena, NO autoriza
      'contexto_mercado', jsonb_build_object(
         'prob_que_implica_el_precio_pct', b.prob_que_implica_el_precio_pct,
         'discriminacion_pp', b.discriminacion_pp,
         'momio_mercado', b.momio_mercado, 'casa', b.casa),
      'es_lock', (b.probabilidad_pct >= 65 and coalesce(b.calibracion_confiable,false)),
      'espn_event_id', b.espn_event_id) as j
      from base b
  )
  select jsonb_build_object(
    'generado_at', now(),
    'ventana_horas', p_ventana_horas,
    'nota_ventana', 'NFL usa 8 dias porque juega una vez por semana; los demas usan la ventana pedida.',
    'criterio', 'Se ordena SOLO con senal propia: primero que la calibracion del modelo sea confiable, luego la ventaja sobre el azar (probabilidad propia menos la base aritmetica del mercado: 33.3% en 1X2 de futbol, 50% en mercados de dos vias), luego el tamano de la muestra. El precio de la casa se muestra como contexto y nunca elige, ordena, autoriza ni suprime un pick.',
    'deportes_disponibles', (select jsonb_agg(distinct deporte) from base),
    'bloque_1_los_3_mejores', jsonb_build_object(
      'descripcion', 'Uno por deporte: el mas viable segun el modelo propio',
      'picks', coalesce((select jsonb_agg(j order by (j->>'ventaja_sobre_azar_pp')::numeric desc)
                           from fila where rn_dep = 1), '[]'::jsonb)),
    'bloque_2_mas_arriesgado', jsonb_build_object(
      'descripcion', 'Hasta 5, solo LOCK: probabilidad propia >= 65% Y calibracion confiable',
      'picks', coalesce((select jsonb_agg(j order by (j->>'probabilidad_pct')::numeric desc)
                           from (select j, probabilidad_pct from fila
                                  where probabilidad_pct >= 65
                                    and coalesce(calibracion_confiable,false)
                                  order by probabilidad_pct desc limit 5) z), '[]'::jsonb)),
    'bloque_3_los_6', jsonb_build_object(
      'descripcion', '2 por deporte, parejo entre deportes',
      'picks', coalesce((select jsonb_agg(j order by (j->>'deporte'), (j->>'ventaja_sobre_azar_pp')::numeric desc)
                           from fila where rn_dep <= 2), '[]'::jsonb))
  );
$function$;

-- ===========================================================================
-- 11) destacados: 'estable' era una prueba de EV contra la casa, cuando su
--     propio comentario decía que era la prueba de las TRES VENTANAS.
--     112 filas con mínimo 34.5% -> 33 filas, todas 51.3%-64.2%.
-- ===========================================================================
alter table public.destacados_cache
  add column if not exists prob_corta_pct numeric,
  add column if not exists prob_larga_pct numeric;
comment on column public.destacados_cache.prob_corta_pct is 'Probabilidad calibrada propia con la ventana de historia CORTA. Sustituye a ev_corta_pct, que multiplicaba por el momio de la casa.';
comment on column public.destacados_cache.prob_larga_pct is 'Probabilidad calibrada propia con la ventana de historia LARGA. Sustituye a ev_larga_pct.';
comment on column public.destacados_cache.estable is 'La probabilidad propia le gana a la base del azar (50% en dos vias) en las TRES ventanas de historia. No mira el precio de la casa.';

do $$
declare v text; a text; b text;
begin
  v := pg_get_functiondef('public.refrescar_destacados'::regproc);

  a := E'         (      (e.f->>''ev_pct'')::numeric > 0\n'
    || E'            and e.cal_corta is not null and (e.cal_corta*e.cu - 1) > 0\n'
    || E'            and e.cal_larga is not null and (e.cal_larga*e.cu - 1) > 0\n'
    || E'            and e.mercado_sin_vig is not null\n'
    || E'            and (e.f->>''prob_calibrada'')::numeric > e.mercado_sin_vig\n';
  b := E'         (      (e.f->>''prob_calibrada'')::numeric > 50\n'
    || E'            and e.cal_corta is not null and e.cal_corta*100 > 50\n'
    || E'            and e.cal_larga is not null and e.cal_larga*100 > 50\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.11a no unica'; end if;
  v := replace(v,a,b);

  a := E'         (e.f->>''ev_pct'')::numeric,\n';
  b := E'         null::numeric,\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.11b no unica'; end if;
  v := replace(v,a,b);

  a := E'         case when e.cal_corta is not null then round(((e.cal_corta*e.cu - 1)*100)::numeric, 1) end,\n'
    || E'         case when e.cal_larga is not null then round(((e.cal_larga*e.cu - 1)*100)::numeric, 1) end,\n';
  b := E'         null::numeric,\n         null::numeric,\n'
    || E'         case when e.cal_corta is not null then round((e.cal_corta*100)::numeric, 1) end,\n'
    || E'         case when e.cal_larga is not null then round((e.cal_larga*100)::numeric, 1) end,\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.11c no unica'; end if;
  v := replace(v,a,b);

  a := E'     ev_corta_pct, ev_larga_pct, estable)\n';
  b := E'     ev_corta_pct, ev_larga_pct, prob_corta_pct, prob_larga_pct, estable)\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.11d no unica'; end if;
  v := replace(v,a,b);

  a := E'    ''con_ev_positivo'',    (select count(*) from public.destacados_cache where ev_pct > 0),\n';
  b := E'    ''sobre_el_azar'',      (select count(*) from public.destacados_cache where prob_calibrada > 50),\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.11e no unica'; end if;
  v := replace(v,a,b);

  execute v;
end $$;

create or replace function public.destacados_del_dia(p_horas integer default 48, p_deporte text default null::text, p_solo_valor boolean default true)
 returns setof destacados_cache language sql stable security definer set search_path to 'public'
as $function$
  select * from public.destacados_cache
  where fecha > now() and fecha < now() + make_interval(hours => p_horas)
    and (p_deporte is null or deporte = p_deporte)
    -- "valor" ahora significa: la probabilidad propia le gana al azar en las TRES
    -- ventanas de historia. El precio de la casa no filtra ni ordena nada.
    and (not p_solo_valor or estable)
  order by prob_calibrada desc nulls last, muestra desc nulls last, fecha
$function$;

-- ===========================================================================
-- 12) mejor_oportunidad_hoy — reescrita. Filtraba ev_pct>0 (ya nulo, así que
--     devolvía CERO filas) y acotaba momio<=3.00. 0 filas -> 10, 66.9%-72.9%.
-- ===========================================================================
create or replace function public.mejor_oportunidad_hoy(p_limite integer default 10)
 returns table(orden integer, espn_event_id text, deporte text, liga text, home text, away text, arranca_en timestamp with time zone, etiqueta_cuando text, mercado text, pick_nombre text, momio numeric, casa text, prob_cruda_pct numeric, prob_pct numeric, fuera_de_rango boolean, ev_crudo_pct numeric, ev_pct numeric, edge_pct numeric, kelly_pct numeric, techo_kelly numeric, piso_ev numeric, aviso text)
 language sql stable set search_path to 'public'
as $function$
  with base as (
    select v.espn_event_id, v.deporte, v.liga, v.home, v.away, v.arranca_en,
           v.etiqueta_cuando, v.mercado, v.pick_nombre,
           v.momio_mercado as mo, v.casa, v.probabilidad_pct as pcruda,
           case when v.deporte ~* 'soccer|futbol' and v.mercado = 'Moneyline'
                then 33.3 else 50.0 end as base_azar
      from public.v_pick_canonico v
     where v.probabilidad_pct is not null
       and v.arranca_en > now() - interval '1 hour'
       and not (v.deporte like 'baseball%' and v.mercado = 'Over/Under')
  ),
  dp as (
    select b.*, public.decision_pick_v1(public.deporte_registry(b.deporte), b.mercado, 'v_pick_canonico',
             NULL::text, b.pcruda, b.mo, 0, 5.0) as d
      from base b
  ),
  u as (
    select dp.*, (dp.d->>'p_decision')::numeric as pu_pct,
           (dp.d->>'kelly_pct')::numeric as kelly,
           (dp.d->>'economically_eligible')::boolean as elig
      from dp
  ),
  filtrado as (
    select u.* from u where coalesce(u.pu_pct, u.pcruda) > u.base_azar
  )
  select row_number() over (order by (coalesce(f.pu_pct, f.pcruda) - f.base_azar) desc,
                                     coalesce(f.pu_pct, f.pcruda) desc)::integer,
         f.espn_event_id, f.deporte, f.liga, f.home, f.away, f.arranca_en,
         f.etiqueta_cuando, f.mercado, f.pick_nombre, f.mo, f.casa,
         f.pcruda, coalesce(f.pu_pct, f.pcruda), false,
         null::numeric, null::numeric,
         round(coalesce(f.pu_pct, f.pcruda) - f.base_azar, 1), f.kelly, 5.0, null::numeric,
         case when not coalesce(f.elig, false)
              then 'Sin autorizacion economica para este modelo/version: se muestra el analisis, no se dimensiona la apuesta.'
              else null end
    from filtrado f
   order by (coalesce(f.pu_pct, f.pcruda) - f.base_azar) desc, coalesce(f.pu_pct, f.pcruda) desc
   limit greatest(1, coalesce(p_limite, 10));
$function$;

-- mejor_oportunidad_hoy_v2__base — mismo problema, dos veces (tenía DOS gates de EV)
do $$
declare v text; a text; b text;
begin
  v := pg_get_functiondef('public.mejor_oportunidad_hoy_v2__base'::regproc);

  a := E'       and f.ev_dec is not null\n       and f.p_dec is not null\n       and f.pcruda >= 50.0\n       and f.mo <= 3.00\n       and f.ev_dec > f.piso\n';
  b := E'       and f.p_dec is not null\n'
    || E'       and f.pcruda > (case when f.deporte ~* ''soccer|futbol'' and f.mercado = ''Moneyline'' then 33.3 else 50.0 end)\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.12a no unica'; end if;
  v := replace(v,a,b);

  a := '  select row_number() over (order by o.ev_dec desc, o.espn_event_id, o.pick_nombre)::integer,';
  b := '  select row_number() over (order by (o.p_dec - (case when o.deporte ~* ''soccer|futbol'' and o.mercado = ''Moneyline'' then 33.3 else 50.0 end)) desc, o.p_dec desc, o.espn_event_id, o.pick_nombre)::integer,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.12b no unica'; end if;
  v := replace(v,a,b);

  a := '   order by o.ev_dec desc, o.espn_event_id, o.pick_nombre';
  b := '   order by (o.p_dec - (case when o.deporte ~* ''soccer|futbol'' and o.mercado = ''Moneyline'' then 33.3 else 50.0 end)) desc, o.p_dec desc, o.espn_event_id, o.pick_nombre';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.12c no unica'; end if;
  v := replace(v,a,b);

  a := E'         round(o.ev_declarado, 1),\n         round(o.ev_dec, 2),';
  b := E'         null::numeric,\n         null::numeric,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.12d no unica'; end if;
  v := replace(v,a,b);

  a := E'     where v.momio_mercado is not null\n       and v.probabilidad_pct is not null\n       and v.arranca_en > now() - interval ''1 hour''\n       and coalesce(v.ev_pct, -1) > 0\n';
  b := E'     where v.probabilidad_pct is not null\n       and v.arranca_en > now() - interval ''1 hour''\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.12e no unica'; end if;
  v := replace(v,a,b);

  execute v;
end $$;

-- ===========================================================================
-- 13) mejor_pick_hoy — reescrita. Todo el ranking era ev_ajustado. Se conserva
--     la firma para no romper al frontend; p_ev_min/p_ev_segundo se releen
--     como puntos porcentuales de ventaja sobre el azar.
--     Hoy devuelve CERO y es la respuesta honesta: de 5 picks fuente, 3 los
--     veta el aprendizaje medido y 2 son moneylines de MLB a 41.1% y 45.2%.
-- ===========================================================================
create or replace function public.mejor_pick_hoy(p_ev_min numeric default 4.0, p_ev_segundo numeric default 8.0, p_momio_min numeric default 1.40, p_momio_max numeric default 4.00, p_prob_min numeric default 0.35, p_horas integer default 30)
 returns table(deporte text, rank_deporte integer, liga text, partido text, mercado text, pick text, momio numeric, probabilidad numeric, ev_pct numeric, kelly_pct numeric, confianza numeric, momio_verificado boolean, momios_frescos boolean, razon text, resumen text, espn_event_id text)
 language sql stable set search_path to 'public'
as $function$
with fresco as (
  select coalesce(max(snapshot_at) > now() - interval '12 hours', false) ok
  from radar_odds_snapshots
),
base as (
  select
    case
      when r.liga ilike '%MLB%' or r.liga ilike '%baseball%' then 'MLB'
      when r.liga ilike '%NFL%' or r.liga ilike '%football%' then 'NFL'
      else 'SOCCER'
    end as deporte,
    left(regexp_replace(lower(r.home), '[^a-z0-9]', '', 'g'), 6) || '_' ||
    left(regexp_replace(lower(r.away), '[^a-z0-9]', '', 'g'), 6) as llave_partido,
    r.liga,
    r.home || ' vs ' || r.away as partido,
    r.mercado,
    coalesce(nullif(r.pick_desc,''), r.pick_nombre) as pick,
    r.momio_mercado as momio,
    r.probabilidad_real as probabilidad,
    round(r.probabilidad_real * 100 - (
      case when (r.liga ilike '%MLB%' or r.liga ilike '%baseball%'
                 or r.liga ilike '%NFL%' or r.liga ilike '%football%')
                then 50.0
           when coalesce(r.mercado,'') = 'Moneyline' then 33.3
           else 50.0 end), 2) as ventaja_pp,
    r.kelly_pct, r.confianza,
    (r.odds_source is not null) as momio_verificado,
    r.razon, r.resumen, r.espn_event_id
  from picks_recomendados_hoy r
  left join lateral ajuste_segmento(
    r.liga, coalesce(nullif(r.mercado,''), r.pick_desc, r.pick_nombre), r.momio_mercado
  ) a on true
  where r.probabilidad_real is not null
    and r.probabilidad_real >= p_prob_min
    and r.created_at > now() - make_interval(hours => p_horas)
    and not coalesce(a.vetar, false)
),
por_partido as (
  select distinct on (deporte, llave_partido) * from base
  where ventaja_pp > 0
  order by deporte, llave_partido, ventaja_pp desc, confianza desc
),
rankeado as (
  select p.*, row_number() over (partition by p.deporte order by p.ventaja_pp desc, p.confianza desc) rn
  from por_partido p
)
select k.deporte, k.rn::int, k.liga, k.partido, k.mercado, k.pick,
  k.momio, round(k.probabilidad, 4), null::numeric, k.kelly_pct, k.confianza,
  k.momio_verificado, f.ok, k.razon, k.resumen, k.espn_event_id
from rankeado k cross join fresco f
where (k.rn = 1 and k.ventaja_pp >= coalesce(p_ev_min, 4.0))
   or (k.rn = 2 and k.ventaja_pp >= coalesce(p_ev_segundo, 8.0))
order by k.deporte, k.rn;
$function$;

-- ===========================================================================
-- 14) veredicto_lote__base — el lote de la canasta se ordenaba por EV
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_functiondef('public.veredicto_lote__base'::regproc);
  a := 'order by (v->>''veredicto'') = ''ENTRA'' desc, (v->''ev_pct'')::numeric desc nulls last)';
  b := 'order by (v->>''veredicto'') = ''ENTRA'' desc, (v->>''prob_calibrada'')::numeric desc nulls last)';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.14a no unica'; end if;
  v := replace(v,a,b);
  a := '''ev_pct'', v->''ev_pct'', ''vs_mercado_pts'', v->''vs_mercado_pts'',';
  b := '''ev_pct'', null::jsonb, ''prob_calibrada'', v->''prob_calibrada'', ''muestra'', v->''muestra'', ''vs_mercado_pts'', v->''vs_mercado_pts'',';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.14b no unica'; end if;
  execute replace(v,a,b);
end $$;

-- ===========================================================================
-- 15) rongol_seleccionar_dia — "tener precio de DraftKings" era el PRIMER
--     criterio de orden, en tres ORDER BY distintos.
-- ===========================================================================
do $$
declare v text; a text; b text;
  orden_fam text := E'case b.nivel when ''elite'' then 1 when ''alto'' then 2 else 3 end,\n               b.score_valor desc nulls last,\n               b.error_historico, b.probabilidad desc) rn_fam';
begin
  v := pg_get_functiondef('public.rongol_seleccionar_dia'::regproc);

  a := E'           case when p.momio_mercado is not null and p.precio_verificado\n'
    || E'                then (p.probabilidad/100.0 * p.momio_mercado - 1)\n'
    || E'                else null end as ev_real,\n'
    || E'           -- P6: EV ponderado por el aprendizaje del segmento (solo para ordenar)\n'
    || E'           case when p.momio_mercado is not null and p.precio_verificado\n'
    || E'                then (p.probabilidad/100.0 * p.momio_mercado - 1) * a.ajuste\n'
    || E'                else null end as ev_ajustado,\n';
  b := E'           null::numeric as ev_real,\n'
    || E'           -- 11-sep-2026 (candado del dueno): el EV contra el precio de la casa\n'
    || E'           -- ya no se calcula ni ordena. Se selecciona con senal propia.\n'
    || E'           null::numeric as ev_ajustado,\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.15a no unica'; end if;
  v := replace(v,a,b);

  a := E'      and (p.momio_mercado is null\n           or not p.precio_verificado\n           or (p.probabilidad/100.0 * p.momio_mercado - 1) >= 0.03)\n';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.15b no unica'; end if;
  v := replace(v,a,'');

  a := E'      order by b.tiene_precio desc,\n               coalesce(b.ev_ajustado, -1) desc,\n               case b.nivel when ''elite'' then 1 else 2 end,\n               b.error_historico, b.probabilidad desc) rn_fam';
  b := '      order by ' || orden_fam;
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.15c no unica'; end if;
  v := replace(v,a,b);

  a := '        order by c.tiene_precio desc, coalesce(c.ev_ajustado,-1) desc, c.rn_fam) rn_partido,';
  b := '        order by case c.nivel when ''elite'' then 1 when ''alto'' then 2 else 3 end, c.score_valor desc nulls last, c.rn_fam) rn_partido,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.15d no unica'; end if;
  v := replace(v,a,b);

  a := '        order by c.tiene_precio desc, coalesce(c.ev_ajustado,-1) desc, c.rn_fam) rn_liga';
  b := '        order by case c.nivel when ''elite'' then 1 when ''alto'' then 2 else 3 end, c.score_valor desc nulls last, c.rn_fam) rn_liga';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.15e no unica'; end if;
  v := replace(v,a,b);

  a := E'    order by tiene_precio desc, coalesce(ev_ajustado,-1) desc,\n             case nivel when ''elite'' then 1 else 2 end, error_historico, probabilidad desc';
  b := E'    order by case nivel when ''elite'' then 1 when ''alto'' then 2 else 3 end,\n             score_valor desc nulls last, error_historico, probabilidad desc';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.15f no unica'; end if;
  v := replace(v,a,b);

  execute v;
end $$;

-- ===========================================================================
-- 16) tg_filtrar_pick_del_dia — SUSTITUÍA el pick del día por el alternativo
--     de mayor EV. "Substitute" es el verbo exacto que el candado prohíbe.
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_functiondef('public.tg_filtrar_pick_del_dia'::regproc);

  a := '  e jsonb; alt jsonb; mejor jsonb; mejor_ev numeric := -999; e_alt jsonb;';
  b := '  e jsonb; alt jsonb; mejor jsonb; mejor_prob numeric := -999; e_alt jsonb;';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.16a'; end if;
  v := replace(v,a,b);

  a := E'           AND (e_alt->>''ev_pct'')::numeric > mejor_ev THEN\n          mejor_ev := (e_alt->>''ev_pct'')::numeric;';
  b := E'           AND (e_alt->>''prob_modelo_pct'')::numeric > mejor_prob THEN\n          mejor_prob := (e_alt->>''prob_modelo_pct'')::numeric;';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.16b'; end if;
  v := replace(v,a,b);

  a := E'          ''ev_original_pct'', e->>''ev_pct'',\n          ''ev_nuevo_pct'', mejor_ev));';
  b := E'          ''prob_original_pct'', e->>''prob_modelo_pct'',\n          ''prob_nueva_pct'', mejor_prob));';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.16c'; end if;
  v := replace(v,a,b);

  a := '        WHEN mejor_ev >= 4 THEN ''⭐⭐ PICK FUERTE (validado por modelo propio)''';
  b := '        WHEN mejor_prob >= 65 THEN ''⭐⭐ PICK FUERTE (validado por modelo propio)''';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.16d'; end if;
  v := replace(v,a,b);

  a := E'        ''Sustituye a "%s" (EV %s%%, %s). El modelo propio da a "%s" un EV de %s%%. Ganador probable: %s. Marcador mas probable: %s.'',\n        v_pick_original, e->>''ev_pct'', e->>''veredicto'',\n        NEW.pick_desc, mejor_ev,';
  b := E'        ''Sustituye a "%s" (el modelo le da %s%% de probabilidad, %s). El modelo propio da a "%s" un %s%% de probabilidad. Ganador probable: %s. Marcador mas probable: %s.'',\n        v_pick_original, e->>''prob_modelo_pct'', e->>''veredicto'',\n        NEW.pick_desc, mejor_prob,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.16e'; end if;
  v := replace(v,a,b);

  a := '''🚫 SIN VALOR — el modelo propio no confirma edge''';
  b := '''🚫 NO PUBLICADO — el modelo propio no respalda este pick''';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.16f'; end if;
  v := replace(v,a,b);

  a := E'        ''AVISO: el modelo propio calcula %s%% contra %s%% implicito del momio (EV %s%%). Veredicto: %s. Ganador probable segun el modelo: %s.'',\n        e->>''prob_modelo_pct'', e->>''prob_implicita_pct'', e->>''ev_pct'',\n        e->>''veredicto'', e->>''ganador_probable_modelo'');';
  b := E'        ''AVISO: el modelo propio calcula %s%% de probabilidad (la casa implica %s%%, solo como referencia). Veredicto: %s. Ganador probable segun el modelo: %s.'',\n        e->>''prob_modelo_pct'', e->>''prob_implicita_pct'',\n        e->>''veredicto'', e->>''ganador_probable_modelo'');';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.16g'; end if;
  v := replace(v,a,b);

  a := E'      WHEN (e->>''ev_pct'')::numeric >= 4\n        THEN ''⭐⭐⭐ PICK PREMIUM (modelo propio: EV '' || (e->>''ev_pct'') || ''%)''\n      ELSE ''⭐ PICK CON VALOR (modelo propio: EV '' || (e->>''ev_pct'') || ''%)'' END;';
  b := E'      WHEN (e->>''prob_modelo_pct'')::numeric >= 65\n        THEN ''⭐⭐⭐ PICK PREMIUM (modelo propio: '' || (e->>''prob_modelo_pct'') || ''% de probabilidad)''\n      ELSE ''⭐ PICK RESPALDADO (modelo propio: '' || (e->>''prob_modelo_pct'') || ''% de probabilidad)'' END;';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.16h'; end if;
  v := replace(v,a,b);

  a := E'    NEW.razon_principal := format(''%s | Modelo propio: %s%% de probabilidad vs %s%% implicito, EV %s%%. Ganador probable: %s. Marcador mas probable: %s.'',\n      COALESCE(NEW.razon_principal,''''), e->>''prob_modelo_pct'', e->>''prob_implicita_pct'',\n      e->>''ev_pct'', e->>''ganador_probable_modelo'', e->>''marcador_mas_probable'');';
  b := E'    NEW.razon_principal := format(''%s | Modelo propio: %s%% de probabilidad (la casa implica %s%%, solo como referencia). Ganador probable: %s. Marcador mas probable: %s.'',\n      COALESCE(NEW.razon_principal,''''), e->>''prob_modelo_pct'', e->>''prob_implicita_pct'',\n      e->>''ganador_probable_modelo'', e->>''marcador_mas_probable'');';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.16i'; end if;
  v := replace(v,a,b);

  execute v;
end $$;

-- ===========================================================================
-- 17) seleccionar_picks_seguro_valor — el pick "VALOR" era, por construcción,
--     donde más le llevábamos la contraria a la casa, con una cota que además
--     exigía estar cerca del precio implícito.
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_functiondef('public.seleccionar_picks_seguro_valor'::regproc);

  a := E'    -- SEGURO: prob >= 48%, momio 1.40-2.40 (sin cambios)\n    IF prob IS NOT NULL AND momio IS NOT NULL\n       AND prob >= 48 AND momio BETWEEN 1.40 AND 2.40\n       AND prob > best_seguro_prob THEN';
  b := E'    -- SEGURO: el mas probable. 11-sep-2026: se quito "momio BETWEEN 1.40 AND 2.40".\n    -- El precio de la casa no decide si un pick nuestro puede existir.\n    IF prob IS NOT NULL\n       AND prob >= 48\n       AND prob > best_seguro_prob THEN';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.17a'; end if;
  v := replace(v,a,b);

  a := '        ''prob_normalizada_pct'', prob, ''momio_normalizado'', momio, ''ev_normalizado'', ev' || E'\n      );';
  b := '        ''prob_normalizada_pct'', prob, ''momio_normalizado'', momio, ''ev_normalizado'', null::numeric' || E'\n      );';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.17b'; end if;
  v := replace(v,a,b);

  a := E'    -- VALOR: exige prob >= 40% Y coherencia con momio (no longshots).\n    -- P6: se ordena por EV * ajuste del segmento, no por EV crudo.\n    ev_ajustado := ev * COALESCE(v_aj.ajuste, 1.0);\n    IF ev IS NOT NULL AND ev > 0 AND ev_ajustado > best_valor_ev_aj\n       AND prob IS NOT NULL AND prob >= 40\n       AND ev <= 25  -- EV irreal = calibracion rota\n       AND (prob_implicita IS NULL OR prob <= (prob_implicita + 10)) THEN';
  b := E'    -- VALOR (11-sep-2026, candado del dueno): probabilidad propia ponderada\n    -- por el ROI real medido del segmento. Ya no usa EV ni el precio.\n    ev_ajustado := prob * COALESCE(v_aj.ajuste, 1.0);\n    IF prob IS NOT NULL AND prob >= 40 AND ev_ajustado > best_valor_ev_aj THEN';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.17c'; end if;
  v := replace(v,a,b);

  a := '        ''razon_tipo'', format(''Mayor valor matemático: EV +%s%%'', round(ev::numeric, 1)),';
  b := '        ''razon_tipo'', format(''Mejor respaldo medido: %s%% de probabilidad en un segmento donde el sistema lleva ROI real de %s%%'', round(prob), COALESCE(v_aj.roi_pct, 0)),';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.17d'; end if;
  v := replace(v,a,b);

  a := '        ''prob_normalizada_pct'', prob, ''momio_normalizado'', momio, ''ev_normalizado'', ev,';
  b := '        ''prob_normalizada_pct'', prob, ''momio_normalizado'', momio, ''ev_normalizado'', null::numeric,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.17e'; end if;
  v := replace(v,a,b);

  execute v;
end $$;

-- ===========================================================================
-- 18) generar_parlay_seguro — LA PEOR. Si no había calibración medida usaba
--     (1/momio)*0.92 y 100/momio*0.95 -- la probabilidad implícita de
--     DraftKings -- y la publicaba como 'probabilidad_real'. El
--     'probabilidad_total' de un parlay podía ser puro precio de casa.
-- ===========================================================================
do $$
declare v text; a text; b text; n int;
begin
  v := pg_get_functiondef('public.generar_parlay_seguro'::regproc);

  a := E'        pp.prob_base * 0.95 / 100.0\n';
  select (length(v) - length(replace(v,a,''))) / length(a) into n;
  if n <> 2 then raise exception 'iss082.18a esperaba 2 apariciones, hay %', n; end if;
  v := replace(v, a, E'        NULL::numeric   -- sin medicion propia no hay probabilidad: NO se usa la de la casa\n');

  a := '    IF v_pick.momio IS NULL THEN CONTINUE; END IF;';
  b := E'    IF v_pick.momio IS NULL THEN CONTINUE; END IF;\n'
    || E'    -- 11-sep-2026 (candado del dueno): antes, si no habia calibracion medida,\n'
    || E'    -- se usaba (1/momio)*0.92 -- la probabilidad implicita de DraftKings -- y se\n'
    || E'    -- publicaba como ''probabilidad_real''. La prohibicion es explicita: nunca\n'
    || E'    -- sustituir nuestra probabilidad con la implied/no-vig de la casa.\n'
    || E'    IF v_pick.prob_calibrada IS NULL THEN CONTINUE; END IF;';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.18b'; end if;
  v := replace(v,a,b);

  a := '      v_prob_calibrada := COALESCE(v_pick.prob_calibrada, (1.0 / v_pick_momio) * 0.92);';
  b := '      v_prob_calibrada := v_pick.prob_calibrada;';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.18c'; end if;
  v := replace(v,a,b);

  a := '        AND safe_numeric(pick_item ->> ''momio_mercado'') BETWEEN v_min_momio AND v_max_momio';
  b := '        AND safe_numeric(pick_item ->> ''momio_mercado'') > 1.01';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.18d'; end if;
  v := replace(v,a,b);

  execute v;
end $$;

-- ===========================================================================
-- 19) enrich_oraculo_prob_with_momio — su bloque de filtros era una pared de
--     autorización del mercado, con un rechazo que decía literalmente
--     "mercado ya tiene precio justo".
--     NOTA: el patrón se ancla en "v_pasa_filtros := false" porque
--     "IF NEW.momio_mercado IS NULL THEN" también aparece en el PASO 1.
-- ===========================================================================
do $$
declare v text; nuevo text; n int; pat text;
begin
  v := pg_get_functiondef('public.enrich_oraculo_prob_with_momio'::regproc);
  pat := 'IF NEW\.momio_mercado IS NULL THEN\s*\n\s*v_pasa_filtros := false;.*?END IF;';
  select count(*) into n from regexp_matches(v, pat, 'gs');
  if n <> 1 then raise exception 'iss082.19 bloque no unico (%)', n; end if;
  nuevo :=
    'IF NEW.probabilidad_modelo IS NULL THEN' || E'\n' ||
    '    v_pasa_filtros := false;' || E'\n' ||
    '    v_razon_no_pasa := ''Sin probabilidad propia del modelo: no hay pick que publicar'';' || E'\n' ||
    '  ELSIF v_prob_decimal < 0.62 THEN' || E'\n' ||
    '    v_pasa_filtros := false;' || E'\n' ||
    '    v_razon_no_pasa := ''Prob '' || ROUND(v_prob_decimal * 100, 0) || ''% < 62% minimo (oraculo_prob solo apuesta favoritos solidos)'';' || E'\n' ||
    '  END IF;';
  execute regexp_replace(v, pat, nuevo, 's');
end $$;

-- ===========================================================================
-- 20) favoritos_bien_pagados — reescrita. "where p.m is not null" BORRABA de
--     la pantalla, sin avisar, todo partido sin precio. Con la banda
--     1.30-1.85 y ev_decision>0 encima, devolvía CERO filas: la caja LISTOS
--     de RETO 13M llevaba tiempo vacía y nadie sabía por qué.
--     0 filas -> 73 (19 con precio, 54 en espera).
-- ===========================================================================
create or replace function public.favoritos_bien_pagados(p_momio_min numeric default 1.30, p_momio_max numeric default 1.85, p_prob_min numeric default 0.55)
 returns table(espn_event_id text, liga text, deporte text, partido text, saque timestamp with time zone, equipo text, lado text, pick text, prob_modelo numeric, momio numeric, casa text, prob_momio numeric, ventaja_pp numeric, ev_pct numeric, fraccion numeric, aporte_compuesto_pct numeric, info_completa boolean, falta text)
 language sql stable security definer set search_path to 'public'
as $function$
with juego as (
  select distinct on (l.espn_event_id)
         l.espn_event_id, l.liga, l.home_team, l.away_team, l.game_date,
         coalesce((mc.probabilidades->>'gana_local')::numeric,(mc.probabilidades->>'local_gana')::numeric) as pl,
         coalesce((mc.probabilidades->>'gana_visita')::numeric,(mc.probabilidades->>'visita_gana')::numeric) as pv
    from live_scores l join motor_cache mc on mc.espn_event_id = l.espn_event_id
   where l.game_date > now() and mc.suficiente
     and coalesce(mc.probabilidades->>'gana_local', mc.probabilidades->>'local_gana') is not null
     and l.liga in ('Premier League','La Liga','Serie A','Bundesliga','Ligue 1','UEFA Champions League','NFL','MLB','Liga MX')
   order by l.espn_event_id, mc.calculado_at desc
), juego_nfl as (
  select l.espn_event_id, l.liga, l.home_team, l.away_team, l.game_date,
         op.prob_local_modelo as pl, round(100 - op.prob_local_modelo, 1) as pv
    from live_scores l cross join lateral public.nfl_opinion_modelo(l.espn_event_id) op
   where l.game_date > now() and l.liga = 'NFL' and op.opina
), fav as (
  select j.*, case when j.liga='MLB' then 'MLB' when j.liga='NFL' then 'NFL' else 'Futbol' end as dep,
         case when j.pl >= j.pv then 'local' else 'visita' end as lado,
         case when j.pl >= j.pv then j.home_team else j.away_team end as equipo,
         greatest(j.pl, j.pv)/100.0 as prob
    from (select * from juego where liga <> 'NFL' union all select * from juego_nfl) j
), precio as (
  select f.*, case f.dep when 'MLB' then 'baseball' when 'NFL' then 'football' else 'soccer' end as dep_cal,
         (select r.momio from public.momio_real_de_mercado(f.espn_event_id,'Moneyline',
            case when f.lado='local' then 'Gana local' else 'Gana visitante' end, f.home_team, f.away_team) r limit 1) as m,
         (select r.casa from public.momio_real_de_mercado(f.espn_event_id,'Moneyline',
            case when f.lado='local' then 'Gana local' else 'Gana visitante' end, f.home_team, f.away_team) r limit 1) as c,
         case when f.dep = 'MLB' then exists (select 1 from badrino_partidos b
                where b.espn_event_id = f.espn_event_id and b.p_home_nombre is not null and b.p_away_nombre is not null)
           when f.dep = 'Futbol' then exists (select 1 from alineaciones_espn al
                where al.espn_event_id = f.espn_event_id and al.hay_alineacion)
           else true end as dato_clave_ok
    from fav f
),
dp as (
  select p.*, public.decision_pick_v1(public.deporte_registry(p.dep_cal), 'Moneyline', 'motor_cache',
           NULL::text, 100*p.prob, p.m, 0, 5.0) as d
    from precio p where p.m is not null and p.m > 1.01
)
-- CON precio: se puede dimensionar la apuesta.
select d.espn_event_id, d.liga, d.dep, d.home_team || ' vs ' || d.away_team, d.game_date, d.equipo, d.lado,
       'Gana ' || d.equipo, round(100*d.prob,1), round(d.m,4), d.c, round(100/d.m,1),
       round((d.d->>'p_decision')::numeric - 100/d.m, 1),
       null::numeric,
       round((d.d->>'kelly_pct')::numeric/100.0, 4),
       round(100*((d.d->>'p_decision')::numeric/100.0*ln(1+(d.d->>'kelly_pct')::numeric/100.0*(d.m-1))
              + (1-(d.d->>'p_decision')::numeric/100.0)*ln(1-(d.d->>'kelly_pct')::numeric/100.0)),3),
       ((d.d->>'economically_eligible')::boolean and d.dato_clave_ok),
       case when not (d.d->>'economically_eligible')::boolean
              then coalesce(d.d->>'blocked_reason','sin autorización económica')
            when d.dato_clave_ok then null
            when d.dep='MLB' then 'falta confirmar los abridores'
            when d.dep='Futbol' then 'falta la alineacion titular' end
  from dp d
 where 100*d.prob >= p_prob_min*100

union all

-- SIN precio: el modelo igual opina. Se muestra EN ESPERA, no se borra.
select p.espn_event_id, p.liga, p.dep, p.home_team || ' vs ' || p.away_team, p.game_date, p.equipo, p.lado,
       'Gana ' || p.equipo, round(100*p.prob,1),
       null::numeric, null::text, null::numeric, null::numeric, null::numeric, null::numeric, null::numeric,
       false,
       'falta el precio de la casa'
  from precio p
 where (p.m is null or p.m <= 1.01)
   and 100*p.prob >= p_prob_min*100

 order by 9 desc;
$function$;

-- ===========================================================================
-- 21) reto_13m_estado__base — ponía el letrero SEGURO cuando ev_pct>=5, o sea
--     decía "seguro" por lo que paga la casa y no por lo que es probable.
-- ===========================================================================
do $$
declare v text; a text; b text;
begin
  v := pg_get_functiondef('public.reto_13m_estado__base'::regproc);

  a := E'        ''nivel_seguridad'', case\n            when c.ev_pct is null or c.ev_pct <= 0 then ''MONEDA AL AIRE''\n            when c.ev_pct >= 5 or c.fraccion >= 0.025 then ''SEGURO''\n            else ''MODERADO'' end,';
  b := E'        ''nivel_seguridad'', case\n            when c.prob_modelo is null or c.prob_modelo <= 50 then ''MONEDA AL AIRE''\n            when c.prob_modelo >= 65 and coalesce(c.gana_volado, false) then ''SEGURO''\n            else ''MODERADO'' end,';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.21a'; end if;
  v := replace(v,a,b);

  a := '-- SELLO POR VENTAJA, NO POR PROBABILIDAD (3-sep-2026).';
  b := '-- SELLO POR PROBABILIDAD PROPIA (11-sep-2026). El candado del dueno dice que'
    || E'\n        -- el desacuerdo con la casa (EV, ventaja_pp, brecha) puede MOSTRARSE como'
    || E'\n        -- contexto pero NUNCA elegir, ordenar, autorizar ni suprimir un pick. Un'
    || E'\n        -- sello que decia SEGURO porque el EV era alto estaba llamando seguro a lo'
    || E'\n        -- que la casa paga de mas, no a lo que es probable que pase. Ahora SEGURO'
    || E'\n        -- exige 65% de probabilidad propia Y que la calibracion medida del modelo'
    || E'\n        -- le gane al volado. Los tres literales no cambian: Reto13M.tsx mapea el'
    || E'\n        -- color por esos textos exactos (type NivelSeguridad).'
    || E'\n        -- (comentario anterior, ya no vigente:)';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.21b'; end if;
  v := replace(v,a,b);

  a := 'then ''Hoy no hay pick. Ninguna liga top tiene un favorito con precio a favor y el dato que decide.''';
  b := 'then ''Hoy no hay pick. Ninguna liga top tiene un favorito claro del modelo con el dato que decide confirmado.''';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.21c'; end if;
  v := replace(v,a,b);

  a := 'then ''Un pick hoy: el unico favorito de liga top al que la casa le paga de mas y que ya tiene confirmado el dato que decide el partido.''';
  b := 'then ''Un pick hoy: el unico favorito de liga top que el modelo ve claro y que ya tiene confirmado el dato que decide el partido.''';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.21d'; end if;
  v := replace(v,a,b);

  a := '''precio_a_favor'', (c.ev_pct > 0),';
  b := '''precio_a_favor'', (c.prob_modelo is not null and c.prob_momio is not null and c.prob_modelo > c.prob_momio),';
  if (length(v) - length(replace(v,a,''))) / length(a) <> 1 then raise exception 'iss082.21e'; end if;
  v := replace(v,a,b);

  execute v;
end $$;

-- FIN iss082. Verificar con: verificar.sql (md5 contra MANIFIESTO.txt)
--              y verificar_invariantes.sql (las reglas, como asserts).
