-- ============================================================================
-- iss040 — SGP (Same Game Parlay): 1 MOMIO y 1 CONFIRMACIÓN por PARTIDO · STAGED
-- NO APLICAR bajo PROD_FREEZE. Operacional (app reto), separado de P0=SOCCER canónico.
-- ============================================================================
-- PROBLEMA (boletos PlayDoIt SGP, ej. ticket 5396787662 = 10 partidos × 2 picks):
--   La casa arma cada partido como UN Same-Game-Parlay con UN solo momio combinado
--   (Fenerbahce -105, Bayern +200, ...). Las 2 selecciones van DENTRO del combo y
--   están correlacionadas: NO se pueden multiplicar como patas independientes.
--   La app hoy trata cada pick como una pata suelta =>
--     (a) obliga a capturar 2 momios por partido (y el usuario pone 1.01 en la 2a),
--     (b) obliga a CONFIRMAR el partido 2 veces (una por pick) — doble trabajo y
--         hasta con fecha distinta (Man United 09-09 vs 09-10),
--     (c) el `momio_total` = producto de TODAS las patas infla el número y dispara
--         la alerta "los momios no cuadran".
--
-- MODELO CORRECTO: agrupar por PARTIDO (evento canónico). Cada grupo = 1 momio SGP
--   (el precio combinado real de la casa). momio_total = producto de UN momio por
--   grupo (+ patas sueltas). El TOTAL REAL DEL BOLETO manda como autoridad (con
--   tolerancia por redondeo/boost). Las 2 selecciones se guardan sólo para calificar.
--
-- Este archivo deja listo el BACKEND. La CAPTURA (Lovable/ChatGPT) debe: pedir 1 momio
--   por grupo SGP, confirmar el partido 1 sola vez por grupo, y quitar el 1.01.
-- ============================================================================

-- 1) Clave de agrupación: evento canónico (id) y, en su defecto, el nombre del partido.
create or replace function public.parlay_group_key(p_leg jsonb)
returns text language sql immutable as $$
  select coalesce(nullif(p_leg->>'espn_event_id',''), nullif(p_leg->>'partido',''), '(sin_evento)');
$$;

-- 2) momio_total AUTORIDAD por grupos SGP: UN momio por partido (el mayor del grupo,
--    que es el precio SGP real; el 1.01 relleno queda ignorado), producto de grupos.
--    Determinista, IMMUTABLE. Es lo que debe alimentar parlays.momio_total en cutover.
create or replace function public.fn_parlay_momio_sgp(p_picks jsonb)
returns numeric language sql immutable as $$
  with legs as (
    select public.parlay_group_key(e.leg) gk,
           nullif(regexp_replace(coalesce(e.leg->>'momio',''),'[^0-9.]','','g'),'')::numeric m
    from jsonb_array_elements(coalesce(p_picks,'[]'::jsonb)) e
  ),
  grupos as (  -- UN momio por partido = el precio SGP real (max del grupo)
    select gk, max(m) as momio_grupo
    from legs where m is not null and m > 1.0001
    group by gk
  )
  select round(exp(coalesce(sum(ln(greatest(momio_grupo,1.0001))),0))::numeric, 4)
  from grupos;
$$;

-- 3) Coherencia por grupos: compara el momio real del boleto contra el producto por
--    grupos (no contra las patas crudas) con tolerancia (redondeo/boost de la casa).
--    Devuelve estado legible para el validador de captura.
create or replace function public.fn_parlay_coherencia_sgp(
  p_picks jsonb, p_momio_boleto numeric, p_tol numeric default 0.06
) returns table(momio_grupos numeric, momio_boleto numeric, diff_pct numeric, cuadra boolean, n_grupos int)
language sql stable as $$
  with g as (
    select public.parlay_group_key(e.leg) gk
    from jsonb_array_elements(coalesce(p_picks,'[]'::jsonb)) e
    group by 1
  )
  select
    public.fn_parlay_momio_sgp(p_picks) as momio_grupos,
    p_momio_boleto,
    case when coalesce(p_momio_boleto,0) > 0
         then round(abs(public.fn_parlay_momio_sgp(p_picks) - p_momio_boleto) / p_momio_boleto * 100, 2)
         end as diff_pct,
    case when coalesce(p_momio_boleto,0) > 0
         then abs(public.fn_parlay_momio_sgp(p_picks) - p_momio_boleto) / p_momio_boleto <= p_tol
         else null end as cuadra,
    (select count(*)::int from g) as n_grupos;
$$;

-- 4) reconstruir_sgm_picks_data v2: agrupa por EVENTO CANÓNICO (no sólo por texto),
--    marca UN carrier por grupo (el de mayor momio = precio SGP) con momio_is_group=true
--    y los demás false, y anota sgm_group_id / sgm_group_momio / sgm_group_size.
--    Con esto: momio_total = Π(legs con momio_is_group=true) + patas sueltas; la
--    confirmación de partido se hace 1 vez por sgm_group_id (lo consume el frontend).
create or replace function public.reconstruir_sgm_picks_data(p_picks jsonb)
returns jsonb language plpgsql set search_path to 'public' as $function$
declare v_out jsonb := '[]'::jsonb; v_leg jsonb; v_gk text; v_n int; v_gmomio numeric; v_carrier_seen jsonb := '{}'::jsonb; v_is_carrier boolean;
begin
  if p_picks is null or jsonb_typeof(p_picks) <> 'array' or jsonb_array_length(p_picks) < 2 then
    return p_picks;
  end if;
  -- si el frontend ya agrupó explícitamente, respetar
  if exists (select 1 from jsonb_array_elements(p_picks) e where (e->>'sgm_group_id') is not null
             and (e->>'sgm_group_id') not like 'auto-sgm-%') then
    return p_picks;
  end if;

  for v_leg in select * from jsonb_array_elements(p_picks) loop
    v_gk := public.parlay_group_key(v_leg);
    select count(*), max(nullif(regexp_replace(coalesce(e->>'momio',''),'[^0-9.]','','g'),'')::numeric)
      into v_n, v_gmomio
      from jsonb_array_elements(p_picks) e
      where public.parlay_group_key(e) = v_gk;

    if v_n >= 2 then
      -- carrier = primer leg del grupo cuyo momio == max (precio SGP); único por grupo
      v_is_carrier := (nullif(regexp_replace(coalesce(v_leg->>'momio',''),'[^0-9.]','','g'),'')::numeric = v_gmomio)
                      and not coalesce((v_carrier_seen ? v_gk), false);
      if v_is_carrier then v_carrier_seen := v_carrier_seen || jsonb_build_object(v_gk, true); end if;
      v_leg := v_leg || jsonb_build_object(
        'sgm_group_id',   'auto-sgm-' || md5(v_gk),
        'sgm_group_momio', v_gmomio,
        'sgm_group_size',  v_n,
        'momio_is_group',  v_is_carrier   -- true SÓLO en 1 leg por grupo (el que cuenta al momio_total)
      );
    end if;
    v_out := v_out || v_leg;
  end loop;
  return v_out;
end $function$;

-- 5) CONTRATO de cutover:
--    - parlays.momio_total := public.fn_parlay_momio_sgp(picks_data)  (1 momio por partido)
--    - momio_efectivo/total del boleto capturado = AUTORIDAD; si difiere >tol del
--      producto por grupos, avisar (fn_parlay_coherencia_sgp) — no bloquear por redondeo.
--    - grading: cada selección del grupo se califica por separado; el grupo gana si
--      TODAS sus selecciones ganan (SGP = todas las patas internas deben pegar).
--    - captura (frontend ChatGPT): 1 momio por grupo, confirmar partido 1 vez por grupo.
-- ============================================================================
