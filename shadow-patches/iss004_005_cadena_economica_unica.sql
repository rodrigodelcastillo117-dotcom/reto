-- ============================================================================
-- ISS-004 + ISS-005 — SHADOW PATCH — CADENA ECONÓMICA ÚNICA
-- ============================================================================
-- ESTADO: SHADOW / NO DEPLOY. Este archivo es la PROPUESTA revisable. No se ha
-- aplicado a producción. CURRENT_AUTHORIZED_MODELS = NONE se mantiene: este
-- patch NO autoriza ningún modelo (no toca economic_model_authority) y no
-- cambia el hecho de que hoy todo sale en $0 por la puerta de ISS-006.2.
--
-- QUÉ ARREGLA
--   ISS-004  El P/EV que se MUESTRA (y el que ORDENA la tarjeta) no es el P/EV
--            que DECIDE el dinero. Medido hoy: 116/116 filas de v_pick_canonico
--            con divergencia >0.5pp entre ev_pct mostrado y EV_DECISION; 19
--            cambian de signo (se ven +EV y deciden −EV); desvío máximo 58.05pp.
--   ISS-005  Hay VARIAS autoridades de sizing/probabilidad en paralelo:
--            kelly_stake__base (canónica, sobre prob_decide) vs kelly_fraccion_pct
--            (tope plano 0.52, sobre calibrar_prob_motor_live) vs el clamp
--            [0.5,5.0] de v_super_pick vs el motor Kelly en JS del frontend.
--
-- PRINCIPIO (lo que pidió el auditor):
--   model output → economic_eligibility_v1 → P_DECISION → EV_DECISION
--                → kelly_base → risk/caps/portfolio → stake_final
--   UNA sola cadena. EV_UI == EV_DECISION dentro de redondeo. P_RAW se etiqueta
--   como info del modelo. Si eligible=false → stake=$0 con razón, en TODAS las
--   superficies.
--
-- AUTORIDADES CANÓNICAS (no se duplican; ya existen y son correctas):
--   * decision_economica_v1(p_prob, p_momio, p_mercado)  → P/EV  (ISS-006.1/#262)
--   * economic_eligibility_v1(jsonb)                      → 8 gates (ISS-006.2)
--   * kelly_stake__base(apodo, ...)                       → $ del usuario (#207)
--   Lo ÚNICO nuevo es un COMPOSITOR que las une para las superficies que hoy
--   inventan su propio número: decision_pick_v1(). No recomputa P/EV ni gates:
--   los llama. Es el único lugar donde P_RAW se convierte en fracción de Kelly.
--
-- PROTOCOLO PRE-DEPLOY (cuando se autorice):
--   1. Re-leer def viva de cada objeto y comparar md5 contra el fingerprint
--      anotado abajo. Si difiere → drift → ABORTAR y re-derivar el replace().
--   2. Envolver el deploy en UN BEGIN/COMMIT con lock_timeout='8s',
--      statement_timeout, snapshot previo y POST-VERIFY que hace ROLLBACK si
--      algún invariante se rompe (mismo runbook que Bloque 0 / ISS-006.2).
--   3. Prueba de humo: EV_UI==EV_DECISION en las 116 filas; una sola fracción
--      por pick entre superficies; eligible=false → $0.
--
-- FINGERPRINTS (md5 de pg_get_functiondef / pg_get_viewdef al 2026-09-07):
--   decision_economica_v1        d9ba6526...  (núcleo #262, NO se toca aquí)
--   kelly_stake__base            (NO se toca; ya usa prob_decide, es la referencia)
--   kelly_fraccion_pct           IMMUTABLE, tope plano 0.52  ← se reescribe (Parte 2)
--   v_pick_canonico              ← replace() ev_pct (Parte 3)
--   mejor_oportunidad_hoy        ← reescritura (Parte 4)
--   favoritos_bien_pagados       ← reescritura (Parte 5)
--   v_super_pick                 ← replace() kelly_pct_sugerido (Parte 6)
--   (los md5 exactos se recomputan en el paso 1 del protocolo; NO confiar en
--    los de este archivo si pasó tiempo — hay drift de migraciones en prod.)
-- ============================================================================


-- ============================================================================
-- PARTE 1 — decision_pick_v1(): EL COMPOSITOR (única autoridad de la cadena)
-- ============================================================================
-- Convierte (deporte, mercado, fuente, model_version, P_RAW, momio, push, techo)
-- en el contrato canónico completo. NO inventa matemática:
--   * P/EV lo da decision_economica_v1 (verbatim del núcleo de kelly_stake).
--   * La elegibilidad la da economic_eligibility_v1 (8 gates de ISS-006.2).
--   * La fracción de Kelly usa la MISMA fórmula que kelly_stake__base
--     (f_full = (p·b − q)/b, cuarto de Kelly), pero SOBRE prob_decide, nunca
--     sobre P_RAW ni sobre calibrar_prob_motor_live.
-- Si eligible=false → kelly_pct=0 (stake $0) y blocked_reason = reason_code.
--
-- CONTRATO DE CAMPOS (nombres sin ambigüedad, los que pidió el auditor):
--   p_raw               prob del modelo, SOLO informativa
--   p_fair              prob calibrada (sesgo medido + recorte Beta), antes del
--                       haircut de varianza. = prob_antes_wilson_pct. Es lo más
--                       cercano a "fair" que produce el núcleo; NO es una etapa
--                       independiente inventada.
--   p_decision          prob que DECIDE (después de Wilson). = prob_decide_pct
--   ev_decision         EV sobre p_decision  (el ÚNICO EV que se debe mostrar)
--   ev_declarado        EV sobre p_raw (se conserva SOLO para transparencia)
--   kelly_completo_pct  Kelly completo sobre p_decision (sin fracción, sin tope)
--   kelly_base_pct      cuarto de Kelly sobre p_decision, SIN tope (autoridad)
--   kelly_pct           kelly_base_pct topado a p_techo (fracción a mostrar)
--   economically_eligible  economic_eligibility_v1.eligible
--   blocked_reason      economic_eligibility_v1.reason_code (NULL si eligible)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.decision_pick_v1(
  p_deporte        text,
  p_mercado        text,
  p_fuente         text,
  p_model_version  text     DEFAULT NULL,
  p_prob           numeric  DEFAULT NULL,   -- P_RAW en % (0..100)
  p_momio          numeric  DEFAULT NULL,   -- momio decimal
  p_push_pct       numeric  DEFAULT 0,      -- % de push (línea entera); 0 si no aplica
  p_techo_pct      numeric  DEFAULT 5.0,    -- tope de fracción (política de la superficie)
  p_gates          jsonb    DEFAULT '{}'::jsonb  -- gates extra ya resueltos por la superficie
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_de        jsonb;   -- salida de decision_economica_v1 (P/EV canónico)
  v_elig      jsonb;   -- salida de economic_eligibility_v1 (gates)
  v_eligible  boolean;
  v_pdec      numeric; -- prob_decide en fracción
  v_push      numeric;
  v_b         numeric;
  v_q         numeric;
  v_f_full    numeric;
  v_f_usar    numeric;
  v_kelly_pct numeric;
BEGIN
  -- 1) P/EV CANÓNICO (no se recomputa nada aquí)
  v_de := public.decision_economica_v1(p_prob, p_momio, p_mercado);
  IF NOT COALESCE((v_de->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('ok', false, 'error', v_de->>'error',
                              'p_raw', p_prob, 'origen', 'decision_pick_v1');
  END IF;

  -- 2) ELEGIBILIDAD ECONÓMICA (los 8 gates de ISS-006.2). La superficie pasa
  --    lo que ya sabe (deporte/mercado/fuente/model_version + gates resueltos);
  --    el EV que entra al gate es el EV_DECISION, no el declarado.
  v_elig := public.economic_eligibility_v1(
    p_gates
    || jsonb_build_object(
         'deporte',       p_deporte,
         'mercado',       p_mercado,
         'fuente',        p_fuente,
         'model_version', p_model_version,
         'ev_pct',        (v_de->>'ev_pct')::numeric,
         'ev_threshold',  COALESCE((p_gates->>'ev_threshold')::numeric, 2.5)
       ));
  v_eligible := COALESCE((v_elig->>'eligible')::boolean, false);

  -- 3) FRACCIÓN DE KELLY sobre prob_decide (misma fórmula que kelly_stake__base)
  v_pdec := (v_de->>'prob_decide_pct')::numeric / 100.0;
  v_push := LEAST(1, GREATEST(0, COALESCE(p_push_pct,0) / 100.0));
  v_b    := p_momio - 1;
  v_q    := GREATEST(0, 1 - v_pdec - v_push);
  v_f_full := (v_pdec * v_b - v_q) / NULLIF(v_b,0);
  IF v_f_full IS NULL OR v_f_full <= 0 THEN
    v_f_usar := 0; v_kelly_pct := 0;
  ELSE
    v_f_usar    := v_f_full * 0.25;                       -- cuarto de Kelly (canónico)
    v_kelly_pct := LEAST(v_f_usar * 100.0, p_techo_pct);  -- tope de la superficie
  END IF;

  -- 4) CANDADO ECONÓMICO: sin elegibilidad no hay dinero. $0 y razón.
  IF NOT v_eligible THEN
    v_kelly_pct := 0;
  END IF;

  RETURN jsonb_build_object(
    'ok',                    true,
    'p_raw',                 p_prob,
    'p_fair',                (v_de->>'prob_antes_wilson_pct')::numeric,
    'p_decision',            (v_de->>'prob_decide_pct')::numeric,
    'ev_decision',           (v_de->>'ev_pct')::numeric,
    'ev_declarado',          (v_de->>'ev_pct_declarado')::numeric,
    'kelly_completo_pct',    CASE WHEN v_f_full > 0 THEN round(v_f_full*100,3) ELSE 0 END,
    'kelly_base_pct',        CASE WHEN v_f_usar > 0 THEN round(v_f_usar*100,3) ELSE 0 END,
    'kelly_pct',             round(COALESCE(v_kelly_pct,0), 2),
    'techo_pct',             p_techo_pct,
    'economically_eligible', v_eligible,
    'blocked_reason',        CASE WHEN v_eligible THEN NULL ELSE v_elig->>'reason_code' END,
    'sesgo_pp',              (v_de->>'sesgo_pp')::numeric,
    'recorte_beta_pp',       (v_de->>'recorte_beta_pp')::numeric,
    'factor_wilson',         (v_de->>'factor_wilson')::numeric,
    'medido',                (v_de->>'medido')::boolean,
    'origen',                'decision_pick_v1'
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.decision_pick_v1(text,text,text,text,numeric,numeric,numeric,numeric,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.decision_pick_v1(text,text,text,text,numeric,numeric,numeric,numeric,jsonb) TO authenticated, service_role;


-- ============================================================================
-- PARTE 2 — kelly_fraccion_pct(): deja de ser autoridad paralela
-- ============================================================================
-- ANTES: IMMUTABLE, aplicaba un tope PLANO de 0.52 a la prob cruda que le
-- pasaran (mejor_oportunidad_hoy y favoritos_bien_pagados le pasaban
-- calibrar_prob_motor_live). Nunca vio prob_decide → segunda autoridad de
-- probabilidad Y de sizing.
-- DESPUÉS: se convierte en un WRAPPER delgado que delega la probabilidad que
-- decide a decision_economica_v1. Ya no tiene su propia matemática de recorte.
-- Se mantiene la firma para no romper llamadores; se le añaden deporte/mercado
-- para poder pedir el prob_decide correcto. Los llamadores nuevos deben usar
-- decision_pick_v1 directo; este wrapper es la red de seguridad.
-- NOTA: pasa a STABLE (lee zonas_confiables vía decision_economica_v1) — deja
-- de ser IMMUTABLE a propósito.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.kelly_fraccion_pct(
  p_prob_pct   numeric,
  p_momio      numeric,
  p_push_pct   numeric DEFAULT 0,
  p_techo_pct  numeric DEFAULT 5.0,
  p_fraccion   numeric DEFAULT 0.25,
  p_mercado    text    DEFAULT NULL   -- NUEVO: para pedir el prob_decide correcto
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SET search_path TO 'public'
AS $function$
DECLARE
  v_de jsonb; p numeric; b numeric; push numeric; q numeric;
  f_completo numeric; f numeric;
BEGIN
  IF p_prob_pct IS NULL OR p_momio IS NULL OR p_momio <= 1 THEN
    RETURN jsonb_build_object('pct', 0, 'motivo', 'sin probabilidad o momio invalido');
  END IF;

  -- CAMBIO ISS-004/005: la probabilidad que dimensiona es prob_decide, no la
  -- cruda topada a 0.52. Se delega al núcleo canónico.
  v_de := public.decision_economica_v1(p_prob_pct, p_momio, p_mercado);
  IF NOT COALESCE((v_de->>'ok')::boolean, false) THEN
    RETURN jsonb_build_object('pct', 0, 'motivo', v_de->>'error');
  END IF;

  p    := (v_de->>'prob_decide_pct')::numeric / 100.0;
  push := LEAST(1, GREATEST(0, COALESCE(p_push_pct,0) / 100.0));
  b    := p_momio - 1;
  q    := GREATEST(0, 1 - p - push);
  f_completo := (p * b - q) / b;
  f := f_completo * COALESCE(p_fraccion, 0.25);

  IF f <= 0 THEN
    RETURN jsonb_build_object('pct', 0, 'motivo', 'kelly no positivo',
                              'kelly_completo_pct', round(f_completo*100,3),
                              'prob_decide_pct', (v_de->>'prob_decide_pct')::numeric);
  END IF;

  RETURN jsonb_build_object(
    'pct',                round(LEAST(f*100, p_techo_pct), 2),
    'kelly_completo_pct', round(f_completo*100, 3),
    'fraccion',           COALESCE(p_fraccion,0.25),
    'techo_pct',          p_techo_pct,
    'topado',             (f*100) > p_techo_pct,
    'prob_usada_pct',     round(p*100, 2),          -- = prob_decide
    'prob_declarada_pct', p_prob_pct,               -- = P_RAW
    'push_pct',           COALESCE(p_push_pct,0),
    'momio',              p_momio,
    'origen',             'kelly_fraccion_pct->decision_economica_v1');
END;
$function$;


-- ============================================================================
-- PARTE 3 — v_pick_canonico: ev_pct = EV_DECISION (arregla display + orden + gate)
-- ============================================================================
-- El ev_pct del CTE `calc` se calcula hoy con probabilidad_pct (P_RAW). Ese
-- mismo ev_pct alimenta TRES cosas: (a) la columna que se muestra, (b) el
-- ORDER BY de rank_en_partido, (c) el gate 'ev_pct' de economic_eligibility_v1.
-- Cambiándolo en el CTE `calc`, las tres pasan a EV_DECISION de una sola vez.
-- Se hace por replace()-transform contra la def viva para fidelidad de bytes.
DO $patch_vpc$
DECLARE
  s text; s2 text;
  needle text := 'round((m_1.probabilidad_pct / 100.0 * m_1.momio_mercado - 1::numeric) * 100::numeric, 1)';
  repl   text := '(decision_economica_v1(m_1.probabilidad_pct, m_1.momio_mercado, m_1.mercado) ->> ''ev_pct''::text)::numeric';
BEGIN
  SELECT pg_get_viewdef('public.v_pick_canonico'::regclass, true) INTO s;
  s2 := replace(s, needle, repl);
  IF s2 = s THEN RAISE EXCEPTION 'ISS004_VPC_SUBSTR_NOT_FOUND (drift: re-derivar needle)'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_pick_canonico AS ' || s2;
  RAISE NOTICE 'v_pick_canonico: ev_pct -> EV_DECISION OK';
END;
$patch_vpc$;


-- ============================================================================
-- PARTE 4 — mejor_oportunidad_hoy: una sola cadena (adiós calibrar + kelly_fraccion)
-- ============================================================================
-- ANTES: pcruda → calibrar_prob_motor_live (pu_pct) → ev sobre pu_pct →
--        kelly_fraccion_pct(pu_pct, ...) con techo 2/5% según rango.
--        Es decir: probabilidad paralela + fracción paralela.
-- DESPUÉS: pcruda + momio → decision_pick_v1 (P_DECISION, EV_DECISION, kelly).
--        Se conservan las columnas de salida (contrato de la RPC) pero su
--        contenido pasa a la cadena única. prob_cruda_pct sigue siendo P_RAW
--        (info), prob_pct pasa a P_DECISION, ev_pct a EV_DECISION, kelly_pct a
--        la fracción canónica. fuera_de_rango se mantiene informativo (ya no
--        cambia el sizing: el haircut lo hace Wilson dentro del núcleo).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.mejor_oportunidad_hoy(p_limite integer DEFAULT 10)
RETURNS TABLE(orden integer, espn_event_id text, deporte text, liga text, home text,
  away text, arranca_en timestamp with time zone, etiqueta_cuando text, mercado text,
  pick_nombre text, momio numeric, casa text, prob_cruda_pct numeric, prob_pct numeric,
  fuera_de_rango boolean, ev_crudo_pct numeric, ev_pct numeric, edge_pct numeric,
  kelly_pct numeric, techo_kelly numeric, piso_ev numeric, aviso text)
LANGUAGE sql
STABLE
SET search_path TO 'public'
AS $function$
  with base as (
    select v.espn_event_id, v.deporte, v.liga, v.home, v.away, v.arranca_en,
           v.etiqueta_cuando, v.mercado, v.pick_nombre,
           v.momio_mercado as mo, v.casa, v.probabilidad_pct as pcruda,
           case when v.deporte like 'baseball%' then 'baseball'
                when v.deporte like 'football%' then 'football'
                else 'soccer' end as dep_cal
      from public.v_pick_canonico v
     where v.momio_mercado is not null
       and v.probabilidad_pct is not null
       and v.arranca_en > now() - interval '1 hour'
       -- v.ev_pct ya es EV_DECISION (Parte 3): el filtro de valor es coherente
       and coalesce(v.ev_pct, -1) > 0
       and not (v.deporte like 'baseball%' and v.mercado = 'Over/Under')
       and v.es_pick
  ),
  -- CADENA ÚNICA: un solo llamado a decision_pick_v1 por fila.
  dp as (
    select b.*,
           case when b.mercado = 'Moneyline' then 2.0
                when b.mercado = 'BTTS' or b.pick_nombre ~* 'ambos' then 3.0
                else 0.0 end as piso,
           public.decision_pick_v1(
             public.deporte_registry(b.deporte), b.mercado, 'v_pick_canonico',
             NULL::text, b.pcruda, b.mo, 0, 5.0) as d
      from base b
  ),
  u as (
    select dp.*,
           (dp.d->>'p_decision')::numeric   as pu_pct,
           (dp.d->>'ev_decision')::numeric  as ev_cal,
           (dp.d->>'ev_declarado')::numeric as ev_cru,
           (dp.d->>'kelly_pct')::numeric    as kelly,
           (dp.d->>'economically_eligible')::boolean as elig
      from dp
  ),
  filtrado as (
    select u.*
      from u
     where u.pu_pct >= 50.0
       and u.mo <= 3.00
       and u.ev_cal > u.piso
  )
  select row_number() over (order by f.ev_cal desc)::integer,
         f.espn_event_id, f.deporte, f.liga, f.home, f.away, f.arranca_en,
         f.etiqueta_cuando, f.mercado, f.pick_nombre, f.mo, f.casa,
         f.pcruda,                    -- prob_cruda_pct = P_RAW (info)
         f.pu_pct,                    -- prob_pct       = P_DECISION
         false,                       -- fuera_de_rango: el haircut ya vive en el núcleo
         f.ev_cru,                    -- ev_crudo_pct   = EV declarado (transparencia)
         f.ev_cal,                    -- ev_pct         = EV_DECISION (el que decide)
         round((f.pu_pct/100.0 - 1.0/f.mo) * 100, 1),  -- edge sobre P_DECISION
         f.kelly,                     -- kelly_pct      = fracción canónica (0 si !elig)
         5.0,                         -- techo_kelly    = política única 5%
         f.piso,
         case when not f.elig
              then 'Sin autorización económica para este modelo/versión: no dimensiona.'
              else null end
    from filtrado f
   order by f.ev_cal desc
   limit greatest(1, coalesce(p_limite, 10));
$function$;


-- ============================================================================
-- PARTE 5 — favoritos_bien_pagados: misma cadena única
-- ============================================================================
-- ANTES: pu = coalesce(calibrar_prob_motor_live, cruda); ev = pu*m-1; fracción =
--        kelly_fraccion_pct(100*pu, ...). Probabilidad paralela + fracción paralela.
-- DESPUÉS: decision_pick_v1 sobre (prob cruda del motor_cache, momio). El
--        contrato de columnas se conserva. ev_pct = EV_DECISION, fraccion desde
--        la cadena única. info_completa sigue exigiendo el dato clave (abridor/
--        alineación) Y elegibilidad económica.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.favoritos_bien_pagados(
  p_momio_min numeric DEFAULT 1.30, p_momio_max numeric DEFAULT 1.85, p_prob_min numeric DEFAULT 0.55)
RETURNS TABLE(espn_event_id text, liga text, deporte text, partido text,
  saque timestamp with time zone, equipo text, lado text, pick text,
  prob_modelo numeric, momio numeric, casa text, prob_momio numeric,
  ventaja_pp numeric, ev_pct numeric, fraccion numeric, aporte_compuesto_pct numeric,
  info_completa boolean, falta text)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
with juego as (
  select distinct on (l.espn_event_id)
         l.espn_event_id, l.liga, l.home_team, l.away_team, l.game_date,
         coalesce((mc.probabilidades->>'gana_local')::numeric,
                  (mc.probabilidades->>'local_gana')::numeric)  as pl,
         coalesce((mc.probabilidades->>'gana_visita')::numeric,
                  (mc.probabilidades->>'visita_gana')::numeric) as pv
    from live_scores l
    join motor_cache mc on mc.espn_event_id = l.espn_event_id
   where l.game_date > now() and mc.suficiente
     and coalesce(mc.probabilidades->>'gana_local', mc.probabilidades->>'local_gana') is not null
     and l.liga in ('Premier League','La Liga','Serie A','Bundesliga','Ligue 1',
                    'UEFA Champions League','NFL','MLB','Liga MX')
   order by l.espn_event_id, mc.calculado_at desc
), juego_nfl as (
  select l.espn_event_id, l.liga, l.home_team, l.away_team, l.game_date,
         op.prob_local_modelo as pl,
         round(100 - op.prob_local_modelo, 1) as pv
    from live_scores l
    cross join lateral public.nfl_opinion_modelo(l.espn_event_id) op
   where l.game_date > now() and l.liga = 'NFL' and op.opina
), fav as (
  select j.*,
         case when j.liga='MLB' then 'MLB' when j.liga='NFL' then 'NFL' else 'Futbol' end as dep,
         case when j.pl >= j.pv then 'local' else 'visita' end as lado,
         case when j.pl >= j.pv then j.home_team else j.away_team end as equipo,
         greatest(j.pl, j.pv)/100.0 as prob
    from (select * from juego where liga <> 'NFL'
          union all select * from juego_nfl) j
), precio as (
  select f.*,
         case f.dep when 'MLB' then 'baseball' when 'NFL' then 'football'
                    else 'soccer' end as dep_cal,
         (select r.momio from public.momio_real_de_mercado(f.espn_event_id,'Moneyline',
            case when f.lado='local' then 'Gana local' else 'Gana visitante' end,
            f.home_team, f.away_team) r limit 1) as m,
         (select r.casa from public.momio_real_de_mercado(f.espn_event_id,'Moneyline',
            case when f.lado='local' then 'Gana local' else 'Gana visitante' end,
            f.home_team, f.away_team) r limit 1) as c,
         case
           when f.dep = 'MLB' then exists (select 1 from badrino_partidos b
                where b.espn_event_id = f.espn_event_id
                  and b.p_home_nombre is not null and b.p_away_nombre is not null)
           when f.dep = 'Futbol' then exists (select 1 from alineaciones_espn al
                where al.espn_event_id = f.espn_event_id and al.hay_alineacion)
           else true
         end as dato_clave_ok
    from fav f
),
-- CADENA ÚNICA: decision_pick_v1 sobre la prob CRUDA del motor + momio real.
dp as (
  select p.*,
         public.decision_pick_v1(
           public.deporte_registry(p.dep_cal), 'Moneyline', 'motor_cache',
           NULL::text, 100*p.prob, p.m, 0, 5.0) as d
    from precio p
   where p.m is not null
)
select d.espn_event_id, d.liga, d.dep,
       d.home_team || ' vs ' || d.away_team, d.game_date, d.equipo, d.lado,
       'Gana ' || d.equipo,
       round(100*d.prob,1),                          -- prob_modelo = P_RAW (info)
       round(d.m,4), d.c,
       round(100/d.m,1),                             -- prob_momio
       round((d.d->>'p_decision')::numeric - 100/d.m, 1),  -- ventaja_pp sobre P_DECISION
       (d.d->>'ev_decision')::numeric,               -- ev_pct = EV_DECISION
       round((d.d->>'kelly_pct')::numeric/100.0, 4), -- fraccion = cadena única (0 si !elig)
       round(100*((d.d->>'p_decision')::numeric/100.0*ln(1+(d.d->>'kelly_pct')::numeric/100.0*(d.m-1))
              + (1-(d.d->>'p_decision')::numeric/100.0)*ln(1-(d.d->>'kelly_pct')::numeric/100.0)),3),
       ((d.d->>'economically_eligible')::boolean and d.dato_clave_ok),  -- info_completa
       case when not (d.d->>'economically_eligible')::boolean
              then coalesce(d.d->>'blocked_reason','sin autorización económica')
            when d.dato_clave_ok then null
            when d.dep='MLB' then 'falta confirmar los abridores'
            when d.dep='Futbol' then 'falta la alineacion titular'
       end
  from dp d
 where d.m between p_momio_min and p_momio_max
   and (d.d->>'p_decision')::numeric >= p_prob_min*100
   and (d.d->>'ev_decision')::numeric > 0
 order by (d.d->>'p_decision')::numeric desc;
$function$;


-- ============================================================================
-- PARTE 6 — v_super_pick: la fracción sugerida sale de la cadena única
-- ============================================================================
-- ANTES: kelly_pct_sugerido = round(LEAST(5.0, GREATEST(0.5, COALESCE(kelly_pct,1.0))),2)
--        cuando eligible — un clamp [0.5,5.0] sobre un kelly_pct ALMACENADO,
--        sin relación con prob_decide. Tercera autoridad de sizing.
-- DESPUÉS: se pide la fracción a decision_pick_v1(prob_pct, momio_usado). El
--        gate de elegibilidad ya lo hace la propia decision_pick_v1, así que el
--        wrapper de economic_eligibility_v1 externo queda redundante pero
--        inofensivo (se conserva para no alterar apto_para_mostrar).
-- NOTA (fuera de este replace, follow-up de etiquetado): v_super_pick muestra
--        ev_real_pct (ROI histórico del SEGMENTO desde calibracion_mercado). Eso
--        NO es EV_DECISION; es una métrica distinta y legítima, pero está
--        rotulada como "EV". El frontend debe dejar de llamarla EV o mostrar
--        además ev_decision. Se documenta en FRONTEND_DIFF; no se cambia aquí
--        para no reescribir toda la vista.
DO $patch_sp$
DECLARE
  s text; s2 text;
  needle text := 'round(LEAST(5.0, GREATEST(0.5, COALESCE(kelly_pct, 1.0))), 2)';
  repl   text := '(decision_pick_v1(deporte_registry(deporte), ''Moneyline'', ''motor_picks'', NULL::text, prob_pct, momio_usado, 0, 5.0) ->> ''kelly_pct''::text)::numeric';
BEGIN
  SELECT pg_get_viewdef('public.v_super_pick'::regclass, true) INTO s;
  s2 := replace(s, needle, repl);
  IF s2 = s THEN RAISE EXCEPTION 'ISS004_SUPERPICK_SUBSTR_NOT_FOUND (drift: re-derivar needle)'; END IF;
  EXECUTE 'CREATE OR REPLACE VIEW public.v_super_pick AS ' || s2;
  RAISE NOTICE 'v_super_pick: kelly_pct_sugerido -> cadena única OK';
END;
$patch_sp$;


-- ============================================================================
-- POST-VERIFY (se ejecuta dentro del BEGIN/COMMIT del deploy real; aquí queda
-- como bloque de comprobación read-only que hace RAISE si algo no cuadra)
-- ============================================================================
-- Invariantes que deben pasar tras aplicar (con CURRENT_AUTHORIZED_MODELS=NONE
-- todos los stake salen $0; lo que se prueba es la PARIDAD INTERNA de números):
--   I1  EV_UI == EV_DECISION en 116/116 filas de v_pick_canonico (|diff|<=0.1pp).
--   I2  0 filas con sign flip entre ev mostrado y EV_DECISION.
--   I3  mejor_oportunidad_hoy.ev_pct == decision_pick_v1.ev_decision por fila.
--   I4  favoritos_bien_pagados.ev_pct == decision_pick_v1.ev_decision por fila.
--   I5  la fracción de cada superficie == decision_pick_v1.kelly_pct del mismo pick.
--   I6  economic_eligibility_v1=false  →  kelly_pct/fraccion = 0 en TODAS.
--   I7  authorized_models sigue = 0; es_pick=0; apto_para_mostrar=0 (ISS-006.2 intacto).
--   I8  cambiar P_RAW sin cambiar prob_decide NO cambia el stake (se prueba con
--       dos P_RAW que caen en el mismo tramo de zonas_confiables).
--   I9  reto_picks_hoy (cadena de usuario, kelly_stake__base) sigue devolviendo
--       el mismo prob_que_decide_pct que decision_pick_v1.p_decision (una verdad).
--   I10 kelly_fraccion_pct ya no topa en 0.52: su prob_usada_pct == prob_decide.
-- Los SELECT de estos 10 invariantes están en iss004_005_REVIEW.md (ADVERSARIAL_TESTS).
-- ============================================================================
