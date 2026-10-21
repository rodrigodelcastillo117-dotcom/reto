-- ISS-004/005 ROLLBACK SNAPSHOT (pre-deploy, defs vivas al 2026-09-07)
-- Restaurar aplicando este archivo + DROP de decision_pick_v1.

-- FUNCTION favoritos_bien_pagados  md5=dbefd72eb990012a82a229f8f0d63575
CREATE OR REPLACE FUNCTION public.favoritos_bien_pagados(p_momio_min numeric DEFAULT 1.30, p_momio_max numeric DEFAULT 1.85, p_prob_min numeric DEFAULT 0.55)
 RETURNS TABLE(espn_event_id text, liga text, deporte text, partido text, saque timestamp with time zone, equipo text, lado text, pick text, prob_modelo numeric, momio numeric, casa text, prob_momio numeric, ventaja_pp numeric, ev_pct numeric, fraccion numeric, aporte_compuesto_pct numeric, info_completa boolean, falta text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
-- EL FAVORITO MEJOR PAGADO. 2-sep-2026. Solo futbol, MLB y NFL.
-- El motor de picks busca VALOR y el valor casi siempre cae del lado del NO
-- favorito: por eso la app nunca daba un pick seguro. Esto pregunta al reves:
-- quien es el favorito SEGUN EL MODELO y si la casa lo esta pagando de mas.
--
-- DOS VOCABULARIOS: el motor de futbol devuelve local_gana/visita_gana y el de
-- MLB y NFL devuelve gana_local/gana_visita. Leyendo solo uno, los 68 partidos
-- de futbol con modelo se caian del embudo sin avisar. Es el mismo tipo de bug
-- que partia la base con deporte/deporte_norm.
--
-- INFO COMPLETA, por deporte: en beisbol el abridor y en futbol la alineacion
-- titular. Sin eso el pick sale marcado: el dato que decide todavia no esta.
--
-- Rango 1.30 a 1.85. El piso no baja: el pick mas seguro que el modelo ha dado
-- es 61.8% y un momio de 1.20 exige creer en 83.3%.
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
  -- NFL EN TEMPORADA NUEVA. Verificado el 2-sep-2026: motor_nfl arma el perfil de
  -- los Seahawks con 19 juegos DESDE EL 8-SEP-2024, o sea las temporadas 2024 y
  -- 2025 completas y CERO de la 2026. Rosters, mariscales y entrenadores nuevos
  -- que ese promedio no puede ver. Para la semana 1 eso no es un modelo, es un
  -- recuerdo.
  -- El FPI de ESPN si se recalcula con las altas y bajas, y ademas nfl_opinion_modelo
  -- solo habla cuando se separa del mercado por mas de 2 desviaciones medidas.
  -- Probado en Seahawks-Patriots: FPI 61.8 vs mercado 61.6, se abstuvo.
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
         -- CALIBRACION. Hasta el 3-sep-2026 esta funcion dimensionaba con la
         -- probabilidad CRUDA del motor y jamas llamaba a calibrar_prob_motor.
         -- Medido en Puebla-Toluca (momio real 1.6452): cruda 66.8% -> EV 9.9%,
         -- Kelly 3.84%, $144.76 con bankroll 3,774. Calibrada 64.63% -> EV 6.33%,
         -- Kelly 2.45%, $92.50. Sobre-apostaba 57%.
         -- OJO CON EL NOMBRE DEL DEPORTE: calibracion_coef guarda soccer/baseball/
         -- football y aqui el campo dep dice Futbol/MLB/NFL. Pasarle 'Futbol'
         -- devuelve NULL y borraria todos los picks en silencio.
         case f.dep when 'MLB' then 'baseball' when 'NFL' then 'football'
                    else 'soccer' end as dep_cal,
         public.calibrar_prob_motor_live(f.prob,
           case f.dep when 'MLB' then 'baseball' when 'NFL' then 'football'
                      else 'soccer' end) as pc,
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
)
select p.espn_event_id, p.liga, p.dep,
       p.home_team || ' vs ' || p.away_team, p.game_date, p.equipo, p.lado,
       'Gana ' || p.equipo,
       round(100*p.pu,1), round(p.m,4), p.c,
       round(100/p.m,1),
       round(100*(p.pu - 1/p.m),1),
       round(100*(p.pu*p.m - 1),1),
       -- KELLY UNIFICADO: se deja de calcular a mano. kelly_fraccion_pct es la
       -- misma que usa el trigger del pick del dia: cuarto de Kelly, techo 5.0%
       -- y q = 1-p-push (aqui push=0 porque el moneyline no empata a efectos de
       -- la apuesta). La formula vieja, (p*m-1)/(m-1)*0.25, asumia q = 1-p y por
       -- eso no servia para totales de linea entera.
       case when (public.economic_eligibility_v1(jsonb_build_object('deporte',p.dep_cal,'mercado','Moneyline','fuente','motor_cache','model_version',NULL::text))->>'eligible')::boolean then round((public.kelly_fraccion_pct(100*p.pu, p.m, 0, 5.0)->>'pct')::numeric/100.0, 4) else 0 end,
       round(100*(p.pu*ln(1+(public.kelly_fraccion_pct(100*p.pu, p.m, 0, 5.0)->>'pct')::numeric/100.0*(p.m-1))
              + (1-p.pu)*ln(1-(public.kelly_fraccion_pct(100*p.pu, p.m, 0, 5.0)->>'pct')::numeric/100.0)),3),
       ((public.economic_eligibility_v1(jsonb_build_object('deporte',p.dep_cal,'mercado','Moneyline','fuente','motor_cache','model_version',NULL::text))->>'eligible')::boolean and p.dato_clave_ok and not p.fuera_de_rango and (p.pu - 1/p.m) <= 0.12),
       case when (p.pu - 1/p.m) > 0.12 then
              'ventaja de ' || round(100*(p.pu-1/p.m),1) ||
              ' puntos: demasiado grande. Cuando el modelo le gana al mercado por mas de 12 puntos, casi siempre el equivocado es el modelo'
            when p.fuera_de_rango then
              'probabilidad fuera del rango medido: la calibracion de este deporte solo esta comprobada en su tramo, ' ||
              'asi que este se dimensiona con la cruda y no se presenta como listo'
            when p.dato_clave_ok then null
            when p.dep='MLB' then 'falta confirmar los abridores'
            when p.dep='Futbol' then 'falta la alineacion titular'
       end
  -- pu = la probabilidad que se USA. calibrar_prob_motor devuelve NULL fuera de
  -- su rango medido (beisbol solo esta comprobado de 43.2% a 62.2%), y un NULL
  -- aqui haria desaparecer el pick sin decir nada: es exactamente como la NFL
  -- casi abre el 10-sep sin un solo pick. Por eso se cae a la cruda Y se marca.
  from (select p.*, coalesce(p.pc, p.prob) as pu, (p.pc is null) as fuera_de_rango
          from precio p) p
 where p.m is not null
   and p.m between p_momio_min and p_momio_max
   and p.pu >= p_prob_min
   and (p.pu * p.m - 1) > 0
 order by p.pu desc;
$function$;

-- FUNCTION kelly_fraccion_pct  md5=4e9f4475449c8be4b5bb10cbe349e2fc
CREATE OR REPLACE FUNCTION public.kelly_fraccion_pct(p_prob_pct numeric, p_momio numeric, p_push_pct numeric DEFAULT 0, p_techo_pct numeric DEFAULT 5.0, p_fraccion numeric DEFAULT 0.25)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
 SET search_path TO 'public'
AS $function$
declare
  b numeric; p numeric; push numeric; q numeric; f_completo numeric; f numeric;
begin
  if p_prob_pct is null or p_momio is null or p_momio <= 1 then
    return jsonb_build_object('pct', 0, 'motivo', 'sin probabilidad o momio invalido');
  end if;
  if p_prob_pct < 0 or p_prob_pct > 100 then
    return jsonb_build_object('pct', 0, 'motivo', 'probabilidad fuera de 0-100');
  end if;

  -- 4-sep-2026 (#191): TOPE DURO 0.52. Medido sobre 2,556 picks prepartido:
  -- skill NEGATIVO (Brier 0.25644 vs 0.24821 de una constante). Esta funcion no
  -- recibe mercado, asi que usa el tope global. kelly_stake topa por tasa base.
  p    := least(p_prob_pct / 100.0, 0.52);
  push := least(1, greatest(0, coalesce(p_push_pct, 0) / 100.0));
  b    := p_momio - 1;

  -- q es la probabilidad de PERDER, no 1-p. En linea entera el push devuelve el
  -- stake, asi que no es derrota. Sin esto, el Over 8 de Dodgers-Cardinals
  -- (p=45.2%, push=13.9%, momio 2.03) da f*=-8% y Kelly 0, cuando su EV real es
  -- +5.66%. Mismo error que hacia inservible a `edge_pp` (medido 3-sep-2026).
  q := greatest(0, 1 - p - push);

  f_completo := (p * b - q) / b;
  f := f_completo * p_fraccion;

  if f <= 0 then
    return jsonb_build_object('pct', 0, 'motivo', 'kelly no positivo',
                              'kelly_completo_pct', round(f_completo * 100, 3));
  end if;

  return jsonb_build_object(
    'pct',                round(least(f * 100, p_techo_pct), 2),
    'kelly_completo_pct', round(f_completo * 100, 3),
    'fraccion',           p_fraccion,
    'techo_pct',          p_techo_pct,
    'topado',             (f * 100) > p_techo_pct,
    'prob_usada_pct',       round(p * 100, 2),
    'prob_declarada_pct',   p_prob_pct,
    'topada_por_tasa_base', (p_prob_pct / 100.0) > 0.52,
    'push_pct',           coalesce(p_push_pct, 0),
    'momio',              p_momio);
end
$function$;

-- FUNCTION mejor_oportunidad_hoy  md5=5a13b42b1102b730dbbd86072dcaa265
CREATE OR REPLACE FUNCTION public.mejor_oportunidad_hoy(p_limite integer DEFAULT 10)
 RETURNS TABLE(orden integer, espn_event_id text, deporte text, liga text, home text, away text, arranca_en timestamp with time zone, etiqueta_cuando text, mercado text, pick_nombre text, momio numeric, casa text, prob_cruda_pct numeric, prob_pct numeric, fuera_de_rango boolean, ev_crudo_pct numeric, ev_pct numeric, edge_pct numeric, kelly_pct numeric, techo_kelly numeric, piso_ev numeric, aviso text)
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
       -- condiciones de es_pick reconstruidas a mano (NO se hereda la columna):
       and coalesce(v.ev_pct, -1) > 0
       and not (v.deporte like 'baseball%' and v.mercado = 'Over/Under')
       -- DESBLOQUEO DE MONEYLINE: la vista castiga dos veces. Su union ya exceptua
       -- al Moneyline y luego es_pick le vuelve a exigir calibracion_confiable, que
       -- viene de v_picks_futbol_calibrado con muestra_calibracion=0 (ausencia de
       -- muestra, no evidencia de mala calibracion). Aqui aplicamos encima
       -- calibrar_prob_motor (calibracion_coef id=7, n=148,764).
       and v.es_pick
  ),
  cal as (
    select b.*, public.calibrar_prob_motor_live(b.pcruda / 100.0, b.dep_cal) as pc
      from base b
  ),
  u as (
    select c.*,
           round(100.0 * coalesce(c.pc, c.pcruda / 100.0), 1) as pu_pct,
           (c.pc is null) as fuera,
           case when c.mercado = 'Moneyline' then 2.0
                when c.mercado = 'BTTS' or c.pick_nombre ~* 'ambos' then 3.0
                else 0.0 end as piso
      from cal c
  ),
  ev as (
    select u.*,
           round((u.pu_pct / 100.0 * u.mo - 1) * 100, 1) as ev_cal,
           round((u.pcruda / 100.0 * u.mo - 1) * 100, 1) as ev_cru,
           -- TECHO DE SEGURIDAD: fuera del rango medido, la banca maxima baja a 2.0%
           case when u.fuera then 2.0 else 5.0 end as techo
      from u
  ),
  filtrado as (
    select e.*,
           round((public.kelly_fraccion_pct(e.pu_pct, e.mo, 0, e.techo) ->> 'pct')::numeric, 2) as kelly
      from ev e
     where e.pu_pct >= 50.0
       and e.mo <= 3.00
       and e.ev_cal > e.piso
  ),
  tope as (
    select max(f.ev_cal) filter (where not f.fuera) as mejor_medido from filtrado f
  ),
  -- VETO SOLO DEL PUESTO #1: se ordena por EV, pero a un pick fuera de rango que
  -- ganaria el liderato se le recorta la llave de orden a un pelo por debajo del
  -- mejor pick medido. Baja al #2, no al fondo: el riesgo de dinero ya lo tapo el
  -- techo de Kelly de 2.0%, y el orden no arriesga banca.
  -- Si no hubiera NINGUN pick medido (mejor_medido null) no hay a quien cederle el
  -- lugar: encabeza uno fuera de rango con su aviso, antes que devolver cero en silencio.
  ordenado as (
    select f.*,
           case when f.fuera and t.mejor_medido is not null and f.ev_cal > t.mejor_medido
                then t.mejor_medido - 0.001
                else f.ev_cal end as llave
      from filtrado f cross join tope t
  )
  select row_number() over (order by o.llave desc, o.ev_cal desc)::integer,
         o.espn_event_id, o.deporte, o.liga, o.home, o.away, o.arranca_en,
         o.etiqueta_cuando, o.mercado, o.pick_nombre, o.mo, o.casa,
         o.pcruda, o.pu_pct, o.fuera,
         o.ev_cru, o.ev_cal,
         round((o.pu_pct / 100.0 - 1.0 / o.mo) * 100, 1),
         o.kelly, o.techo, o.piso,
         case when o.fuera
              then 'Probabilidad arriba del rango medido de calibracion para ' || o.dep_cal
                   || ' (futbol 70%, beisbol 62%): se muestra la cruda, sin corregir. '
                   || 'Banca limitada a 2.0% y no puede encabezar la tarjeta.'
              else null end
    from ordenado o
   order by o.llave desc, o.ev_cal desc
   limit greatest(1, coalesce(p_limite, 10));
$function$;

-- VIEW v_pick_canonico  md5=7c0d946e5d20dcb0fefd6c6f63a0771f
 SELECT espn_event_id,
    deporte,
    liga,
    home,
    away,
    arranca_en,
    mercado,
    pick_nombre,
    pick_desc,
    momio_declarado,
    probabilidad_pct,
    momio_justo,
    muestra_calibracion,
    calibracion_confiable,
    odds_source,
    odds_apertura,
    odds_cierre,
    clv_pct,
    clasificacion,
    confianza,
    razon,
    resumen,
    fuente,
    momio_mercado,
    casa,
    momio_capturado_at,
    home_ml,
    draw_ml,
    away_ml,
    prob_local_casa_pct,
    prob_visitante_casa_pct,
    ev_pct,
    edge_pct,
    prob_que_implica_el_precio_pct,
    favorito,
    favorito_pct,
    etiqueta_cuando,
    es_pick,
    es_senal,
    rank_en_partido,
    explicacion_precio,
    nivel_ventaja,
    zona_realidad(mercado, probabilidad_pct / 100.0) AS zona
   FROM ( WITH unidos AS (
                 SELECT p.espn_event_id,
                    COALESCE(ae.deporte, ls.deporte, 'soccer'::text) AS deporte,
                    p.liga,
                    p.home,
                    p.away,
                    p.arranca_en,
                    p.mercado,
                    p.pick_nombre,
                    p.pick_desc,
                    p.momio_mercado AS momio_declarado,
                        CASE
                            WHEN COALESCE(ae.deporte, ls.deporte, 'soccer'::text) ~~ 'baseball%'::text THEN prob_recalibrada_lado('MLB'::text, p.mercado, round(p.probabilidad_real * 100::numeric, 1), sin_acentos(p.pick_nombre) ~~ (('%'::text || sin_acentos(p.home)) || '%'::text) OR p.pick_nombre ~* '^(over|mas de)'::text)
                            ELSE round(p.probabilidad_real * 100::numeric, 1)
                        END AS probabilidad_pct,
                    NULL::numeric AS momio_justo,
                    NULL::integer AS muestra_calibracion,
                    NULL::boolean AS calibracion_confiable,
                    p.odds_source,
                    p.odds_apertura,
                    p.odds_cierre,
                    p.clv_pct,
                    p.clasificacion,
                    p.confianza,
                    p.razon,
                    p.resumen,
                    'motor_picks'::text AS fuente
                   FROM picks_recomendados_hoy p
                     LEFT JOIN agenda_espn ae ON ae.espn_event_id = p.espn_event_id
                     LEFT JOIN live_scores ls ON ls.espn_event_id = p.espn_event_id
                  WHERE COALESCE(ae.deporte, ls.deporte, 'soccer'::text) !~~ 'baseball%'::text
                UNION ALL
                 SELECT c.espn_event_id,
                    'soccer'::text AS text,
                    c.liga_nombre,
                    c.home_nombre,
                    c.away_nombre,
                    c.arranca_en,
                    c.mercado,
                    c.pick,
                    c.pick,
                    c.momio_casa,
                        CASE
                            WHEN c.mercado = 'Over/Under'::text AND c.pick ~* '^(over|mas de) *2\.5'::text THEN ajuste_h2h_over25(c.espn_event_id, c.probabilidad_pct)
                            ELSE c.probabilidad_pct
                        END AS probabilidad_pct,
                    c.momio_justo,
                    c.muestra_calibracion,
                    c.calibracion_confiable,
                    'motor_futbol_calibrado'::text AS text,
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::text AS text,
                    NULL::numeric AS "numeric",
                    c.como_se_calculo,
                    NULL::text AS text,
                    'motor_futbol_calibrado'::text AS text
                   FROM v_picks_futbol_calibrado c
                  WHERE (c.calibracion_confiable OR c.mercado = 'Moneyline'::text) AND c.mercado !~* '(corner|tarjeta)'::text
                UNION ALL
                 SELECT mm.espn_event_id,
                    'baseball'::text AS text,
                    mm.liga_nombre,
                    mm.home_nombre,
                    mm.away_nombre,
                    mm.arranca_en,
                    mm.mercado,
                    mm.pick,
                    mm.pick,
                    NULL::numeric AS "numeric",
                    mm.prob,
                    round(100.0 / NULLIF(mm.prob, 0::numeric), 2) AS round,
                    NULL::integer AS int4,
                    true AS bool,
                    'motor_mlb_cuantitativo'::text AS text,
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::numeric AS "numeric",
                    NULL::text AS text,
                    NULL::numeric AS "numeric",
                    mm.detalle,
                    NULL::text AS text,
                    'motor_mlb_cuantitativo'::text AS text
                   FROM v_picks_mlb_modelo mm
                ), precio AS (
                 SELECT u.espn_event_id,
                    u.deporte,
                    u.liga,
                    u.home,
                    u.away,
                    u.arranca_en,
                    u.mercado,
                    u.pick_nombre,
                    u.pick_desc,
                    u.momio_declarado,
                    u.probabilidad_pct,
                    u.momio_justo,
                    u.muestra_calibracion,
                    u.calibracion_confiable,
                    u.odds_source,
                    u.odds_apertura,
                    u.odds_cierre,
                    u.clv_pct,
                    u.clasificacion,
                    u.confianza,
                    u.razon,
                    u.resumen,
                    u.fuente,
                    r.momio AS momio_mercado,
                    r.casa,
                    r.capturado AS momio_capturado_at
                   FROM unidos u
                     LEFT JOIN LATERAL momio_real_de_mercado(u.espn_event_id, u.mercado, u.pick_nombre, u.home, u.away) r(momio, casa, capturado) ON true
                ), mercado AS (
                 SELECT p.espn_event_id,
                    p.deporte,
                    p.liga,
                    p.home,
                    p.away,
                    p.arranca_en,
                    p.mercado,
                    p.pick_nombre,
                    p.pick_desc,
                    p.momio_declarado,
                    p.probabilidad_pct,
                    p.momio_justo,
                    p.muestra_calibracion,
                    p.calibracion_confiable,
                    p.odds_source,
                    p.odds_apertura,
                    p.odds_cierre,
                    p.clv_pct,
                    p.clasificacion,
                    p.confianza,
                    p.razon,
                    p.resumen,
                    p.fuente,
                    p.momio_mercado,
                    p.casa,
                    p.momio_capturado_at,
                    m_1.home_ml,
                    m_1.draw_ml,
                    m_1.away_ml,
                        CASE
                            WHEN m_1.home_ml IS NOT NULL AND m_1.away_ml IS NOT NULL THEN round(100::numeric * (1::numeric / m_1.home_ml) / (1::numeric / m_1.home_ml + 1::numeric / m_1.away_ml + COALESCE(1::numeric / NULLIF(m_1.draw_ml, 0::numeric), 0::numeric)), 1)
                            ELSE NULL::numeric
                        END AS prob_local_casa_pct,
                        CASE
                            WHEN m_1.home_ml IS NOT NULL AND m_1.away_ml IS NOT NULL THEN round(100::numeric * (1::numeric / m_1.away_ml) / (1::numeric / m_1.home_ml + 1::numeric / m_1.away_ml + COALESCE(1::numeric / NULLIF(m_1.draw_ml, 0::numeric), 0::numeric)), 1)
                            ELSE NULL::numeric
                        END AS prob_visitante_casa_pct
                   FROM precio p
                     LEFT JOIN LATERAL ( SELECT s.home_ml,
                            s.draw_ml,
                            s.away_ml
                           FROM v_radar_odds_fase s
                          WHERE s.espn_event_id = p.espn_event_id AND s.home_ml IS NOT NULL AND s.fase <> 'en_vivo'::text
                          ORDER BY s.snapshot_at DESC
                         LIMIT 1) m_1 ON true
                ), calc AS (
                 SELECT m_1.espn_event_id,
                    m_1.deporte,
                    m_1.liga,
                    m_1.home,
                    m_1.away,
                    m_1.arranca_en,
                    m_1.mercado,
                    m_1.pick_nombre,
                    m_1.pick_desc,
                    m_1.momio_declarado,
                    m_1.probabilidad_pct,
                    m_1.momio_justo,
                    m_1.muestra_calibracion,
                    m_1.calibracion_confiable,
                    m_1.odds_source,
                    m_1.odds_apertura,
                    m_1.odds_cierre,
                    m_1.clv_pct,
                    m_1.clasificacion,
                    m_1.confianza,
                    m_1.razon,
                    m_1.resumen,
                    m_1.fuente,
                    m_1.momio_mercado,
                    m_1.casa,
                    m_1.momio_capturado_at,
                    m_1.home_ml,
                    m_1.draw_ml,
                    m_1.away_ml,
                    m_1.prob_local_casa_pct,
                    m_1.prob_visitante_casa_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN round((m_1.probabilidad_pct / 100.0 * m_1.momio_mercado - 1::numeric) * 100::numeric, 1)
                            ELSE NULL::numeric
                        END AS ev_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN round((m_1.probabilidad_pct / 100.0 - 1.0 / m_1.momio_mercado) * 100::numeric, 1)
                            ELSE NULL::numeric
                        END AS edge_pct,
                        CASE
                            WHEN m_1.momio_mercado IS NOT NULL THEN round(100.0 / m_1.momio_mercado, 1)
                            ELSE NULL::numeric
                        END AS prob_que_implica_el_precio_pct,
                        CASE
                            WHEN m_1.prob_local_casa_pct >= m_1.prob_visitante_casa_pct THEN m_1.home
                            ELSE m_1.away
                        END AS favorito,
                    GREATEST(m_1.prob_local_casa_pct, m_1.prob_visitante_casa_pct) AS favorito_pct,
                        CASE
                            WHEN (m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text)::date = (now() AT TIME ZONE 'America/Mexico_City'::text)::date THEN 'HOY '::text || to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'HH12:MI am'::text)
                            WHEN (m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text)::date = ((now() AT TIME ZONE 'America/Mexico_City'::text)::date + 1) THEN 'MAÑANA '::text || to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'HH12:MI am'::text)
                            ELSE (upper(to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'DD/MM'::text)) || ' · '::text) || to_char((m_1.arranca_en AT TIME ZONE 'America/Mexico_City'::text), 'HH12:MI am'::text)
                        END AS etiqueta_cuando
                   FROM mercado m_1
                ), marcado AS (
                 SELECT c.espn_event_id,
                    c.deporte,
                    c.liga,
                    c.home,
                    c.away,
                    c.arranca_en,
                    c.mercado,
                    c.pick_nombre,
                    c.pick_desc,
                    c.momio_declarado,
                    c.probabilidad_pct,
                    c.momio_justo,
                    c.muestra_calibracion,
                    c.calibracion_confiable,
                    c.odds_source,
                    c.odds_apertura,
                    c.odds_cierre,
                    c.clv_pct,
                    c.clasificacion,
                    c.confianza,
                    c.razon,
                    c.resumen,
                    c.fuente,
                    c.momio_mercado,
                    c.casa,
                    c.momio_capturado_at,
                    c.home_ml,
                    c.draw_ml,
                    c.away_ml,
                    c.prob_local_casa_pct,
                    c.prob_visitante_casa_pct,
                    c.ev_pct,
                    c.edge_pct,
                    c.prob_que_implica_el_precio_pct,
                    c.favorito,
                    c.favorito_pct,
                    c.etiqueta_cuando,
                    (economic_eligibility_v1(jsonb_build_object('deporte', deporte_registry(c.deporte), 'mercado', c.mercado, 'fuente', c.fuente, 'model_version', NULL::text, 'model_skill', NULL::text, 'empirical_sufficiency',
                        CASE
                            WHEN COALESCE(c.muestra_calibracion, 0) >= 20 THEN 'OK'::text
                            ELSE 'PENDING'::text
                        END, 'semantic_validity',
                        CASE
                            WHEN pick_sin_discrepancia_motores(c.espn_event_id, c.mercado, c.pick_desc) THEN 'PASS'::text
                            ELSE 'FAIL'::text
                        END, 'data_readiness', 'READY', 'exact_decision_price',
                        CASE
                            WHEN exact_decision_price(c.espn_event_id, c.mercado, c.pick_desc, c.home, c.away) THEN 'true'::text
                            ELSE 'false'::text
                        END, 'market_abstention', mercado_en_abstencion(c.mercado, c.pick_desc), 'ev_pct', c.ev_pct, 'ev_threshold', 2.5)) ->> 'eligible'::text)::boolean AS es_pick,
                    c.momio_mercado IS NULL AND c.probabilidad_pct >= 70::numeric AND c.calibracion_confiable AS es_senal
                   FROM calc c
                )
         SELECT m.espn_event_id,
            m.deporte,
            m.liga,
            m.home,
            m.away,
            m.arranca_en,
            m.mercado,
                CASE
                    WHEN m.deporte = 'soccer'::text AND m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text THEN 'Gana '::text || m.home
                    WHEN m.deporte = 'soccer'::text AND m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text THEN 'Gana '::text || m.away
                    ELSE m.pick_nombre
                END AS pick_nombre,
            m.pick_desc,
            m.momio_declarado,
            m.probabilidad_pct,
            m.momio_justo,
            m.muestra_calibracion,
            m.calibracion_confiable,
            m.odds_source,
            m.odds_apertura,
            m.odds_cierre,
            m.clv_pct,
            m.clasificacion,
            m.confianza,
            m.razon,
            m.resumen,
            m.fuente,
            m.momio_mercado,
            m.casa,
            m.momio_capturado_at,
            m.home_ml,
            m.draw_ml,
            m.away_ml,
            m.prob_local_casa_pct,
            m.prob_visitante_casa_pct,
            m.ev_pct,
            m.edge_pct,
            m.prob_que_implica_el_precio_pct,
                CASE
                    WHEN COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id), '-1'::numeric) >= COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id), '-1'::numeric) AND GREATEST(COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id)), COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id))) IS NOT NULL THEN m.home
                    WHEN GREATEST(COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id)), COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id))) IS NOT NULL THEN m.away
                    ELSE NULL::text
                END AS favorito,
            GREATEST(COALESCE(m.prob_local_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +local'::text) OVER (PARTITION BY m.espn_event_id)), COALESCE(m.prob_visitante_casa_pct, max(m.probabilidad_pct) FILTER (WHERE m.mercado = 'Moneyline'::text AND m.pick_nombre ~* '^gana +visitante'::text) OVER (PARTITION BY m.espn_event_id))) AS favorito_pct,
            m.etiqueta_cuando,
            m.es_pick,
            m.es_senal,
            row_number() OVER (PARTITION BY m.espn_event_id ORDER BY m.es_pick DESC, m.es_senal DESC, m.ev_pct DESC NULLS LAST, m.probabilidad_pct DESC) AS rank_en_partido,
                CASE
                    WHEN m.momio_mercado IS NULL THEN ('Todavia no tenemos precio de casa. Nuestro modelo le da '::text || m.probabilidad_pct) || '%.'::text
                    WHEN m.ev_pct > 0::numeric THEN ((((('La casa paga '::text || m.momio_mercado) || ', que implica '::text) || m.prob_que_implica_el_precio_pct) || '%. Nosotros le damos '::text) || m.probabilidad_pct) || '%: paga MAS de lo que vale.'::text
                    ELSE ((((('La casa paga '::text || m.momio_mercado) || ', que implica '::text) || m.prob_que_implica_el_precio_pct) || '%. Nosotros le damos '::text) || m.probabilidad_pct) || '%: paga MENOS de lo que vale. Aqui no hay apuesta.'::text
                END AS explicacion_precio,
                CASE
                    WHEN m.es_pick AND m.edge_pct >= 5::numeric THEN 'ok'::text
                    WHEN m.es_pick THEN 'ventaja_corta'::text
                    WHEN m.es_senal THEN 'alta_probabilidad'::text
                    WHEN m.momio_mercado IS NULL THEN 'sin_precio'::text
                    ELSE 'no_apostar'::text
                END AS nivel_ventaja
           FROM ( SELECT m0.espn_event_id,
                    m0.deporte,
                    m0.liga,
                    m0.home,
                    m0.away,
                    m0.arranca_en,
                    m0.mercado,
                    m0.pick_nombre,
                    m0.pick_desc,
                    m0.momio_declarado,
                    m0.probabilidad_pct,
                    m0.momio_justo,
                    m0.muestra_calibracion,
                    m0.calibracion_confiable,
                    m0.odds_source,
                    m0.odds_apertura,
                    m0.odds_cierre,
                    m0.clv_pct,
                    m0.clasificacion,
                    m0.confianza,
                    m0.razon,
                    m0.resumen,
                    m0.fuente,
                    m0.momio_mercado,
                    m0.casa,
                    m0.momio_capturado_at,
                    m0.home_ml,
                    m0.draw_ml,
                    m0.away_ml,
                    m0.prob_local_casa_pct,
                    m0.prob_visitante_casa_pct,
                    m0.ev_pct,
                    m0.edge_pct,
                    m0.prob_que_implica_el_precio_pct,
                    m0.favorito,
                    m0.favorito_pct,
                    m0.etiqueta_cuando,
                    m0.es_pick,
                    m0.es_senal,
                    row_number() OVER (PARTITION BY m0.espn_event_id, (
                        CASE
                            WHEN m0.deporte = 'soccer'::text AND m0.mercado = 'Moneyline'::text THEN
                            CASE
                                WHEN m0.pick_nombre ~* '^gana +local'::text OR sin_acentos(m0.pick_nombre) ~~ (('%'::text || sin_acentos(m0.home)) || '%'::text) THEN 'ML|local'::text
                                WHEN m0.pick_nombre ~* '^gana +visitante'::text OR sin_acentos(m0.pick_nombre) ~~ (('%'::text || sin_acentos(m0.away)) || '%'::text) THEN 'ML|visita'::text
                                WHEN m0.pick_nombre ~~* '%empate%'::text THEN 'ML|empate'::text
                                ELSE 'ML|'::text || m0.pick_nombre
                            END
                            ELSE (m0.mercado || '|'::text) || m0.pick_nombre
                        END) ORDER BY (m0.fuente = 'motor_futbol_calibrado'::text) DESC, m0.muestra_calibracion DESC NULLS LAST) AS rn_dup
                   FROM marcado m0) m
          WHERE m.rn_dup = 1 AND (m.mercado = 'Moneyline'::text OR m.mercado = 'BTTS'::text OR m.mercado = 'Over/Under'::text AND (m.deporte ~~ 'baseball%'::text OR m.deporte ~~ 'football%'::text OR m.pick_nombre ~* '^(over|mas de) *2\.5'::text OR m.pick_nombre ~* '^(over|under|mas de|menos de) *3\.5'::text))) v
  WHERE espn_event_id IS NOT NULL AND (EXISTS ( SELECT 1
           FROM agenda_espn a
          WHERE a.espn_event_id = v.espn_event_id AND NOT (EXISTS ( SELECT 1
                   FROM ligas_bloqueadas b
                  WHERE b.tipo = 'endpoint'::text AND a.espn_endpoint ~~ b.patron))));

-- VIEW v_super_pick  md5=1c4403dfbc1230d110bfc179f0fb8932
 WITH base AS (
         SELECT md5((((v.espn_event_id || '|'::text) || COALESCE(v.pick_nombre, ''::text)) || '|'::text) || COALESCE(v.mercado, ''::text))::uuid AS pick_id,
            v.espn_event_id,
            (v.home || ' vs '::text) || v.away AS partido,
            v.liga,
            COALESCE(deporte_por_liga_estricto(v.liga), '⚽ Fútbol'::text) AS deporte,
            v.mercado,
            COALESCE(v.pick_nombre, v.pick_desc) AS pick_desc,
            v.momio_mercado AS momio_ai,
            v.probabilidad_real AS prob_declarada,
            v.ev_numerico AS ev_declarado_pct,
            v.confianza AS confianza_ai,
            v.clasificacion,
            v.kelly_pct,
            COALESCE(v.razon, v.resumen) AS razonamiento,
            ls.game_date AS match_date,
            mercado_normalizado((COALESCE(v.mercado, ''::text) || ' '::text) || COALESCE(v.pick_nombre, ''::text)) AS mercado_norm
           FROM picks_recomendados_hoy v
             JOIN live_scores ls ON ls.espn_event_id = v.espn_event_id
          WHERE ls.game_date >= (now() - '02:00:00'::interval) AND ls.game_date <= (now() + '36:00:00'::interval) AND v.momio_mercado IS NOT NULL AND v.momio_mercado > 1.01
        ), conmomio AS (
         SELECT b.pick_id,
            b.espn_event_id,
            b.partido,
            b.liga,
            b.deporte,
            b.mercado,
            b.pick_desc,
            b.momio_ai,
            b.prob_declarada,
            b.ev_declarado_pct,
            b.confianza_ai,
            b.clasificacion,
            b.kelly_pct,
            b.razonamiento,
            b.match_date,
            b.mercado_norm,
            lb.momio_libro,
            lb.bookmaker,
            lb.momio_leido_en,
            COALESCE(lb.momio_libro, b.momio_ai) AS momio_usado,
            lb.momio_libro IS NOT NULL AS momio_verificado,
                CASE
                    WHEN lb.momio_libro IS NOT NULL THEN round(100.0 * (b.momio_ai - lb.momio_libro) / lb.momio_libro, 1)
                    ELSE NULL::numeric
                END AS desvio_vs_libro_pct
           FROM base b
             LEFT JOIN v_pick_momio_libro lb ON lb.espn_event_id = b.espn_event_id AND lb.pick_desc = b.pick_desc AND lb.momio_libro IS NOT NULL
        ), calc AS (
         SELECT c.pick_id,
            c.espn_event_id,
            c.partido,
            c.liga,
            c.deporte,
            c.mercado,
            c.pick_desc,
            c.momio_ai,
            c.prob_declarada,
            c.ev_declarado_pct,
            c.confianza_ai,
            c.clasificacion,
            c.kelly_pct,
            c.razonamiento,
            c.match_date,
            c.mercado_norm,
            c.momio_libro,
            c.bookmaker,
            c.momio_leido_en,
            c.momio_usado,
            c.momio_verificado,
            c.desvio_vs_libro_pct,
            rango_de_momio(c.momio_usado) AS rango_momio,
            k.muestra AS muestra_calibracion,
            k.roi_real_pct AS roi_segmento,
            k.wr_real AS wr_segmento,
            k.confiable,
            k.prob_observada,
                CASE
                    WHEN k.muestra IS NOT NULL THEN round(k.roi_real_pct * k.muestra::numeric / (k.muestra::numeric + 100.0), 2)
                    ELSE NULL::numeric
                END AS ev_real_pct,
            (EXISTS ( SELECT 1
                   FROM oraculo_picks_tracking o
                  WHERE o.espn_event_id = c.espn_event_id AND lower(COALESCE(o.pick_nombre, ''::text)) = lower(c.pick_desc))) AS analisis_confirma
           FROM conmomio c
             LEFT JOIN calibracion_mercado k ON k.mercado_norm = c.mercado_norm AND k.rango_momio = rango_de_momio(c.momio_usado)
        ), puntuado AS (
         SELECT c.pick_id,
            c.espn_event_id,
            c.partido,
            c.liga,
            c.deporte,
            c.mercado,
            c.pick_desc,
            c.momio_ai,
            c.prob_declarada,
            c.ev_declarado_pct,
            c.confianza_ai,
            c.clasificacion,
            c.kelly_pct,
            c.razonamiento,
            c.match_date,
            c.mercado_norm,
            c.momio_libro,
            c.bookmaker,
            c.momio_leido_en,
            c.momio_usado,
            c.momio_verificado,
            c.desvio_vs_libro_pct,
            c.rango_momio,
            c.muestra_calibracion,
            c.roi_segmento,
            c.wr_segmento,
            c.confiable,
            c.prob_observada,
            c.ev_real_pct,
            c.analisis_confirma,
            round(COALESCE(c.prob_observada, c.prob_declarada) * 100::numeric, 1) AS prob_pct,
            COALESCE(c.roi_segmento, 0::numeric) > 0::numeric AND c.confiable AS perfil_respalda,
            COALESCE(c.desvio_vs_libro_pct, 0::numeric) > 3.0 AS momio_inflado,
            LEAST(100::numeric, GREATEST(0::numeric, round(LEAST(60::numeric, GREATEST(0::numeric, COALESCE(c.ev_real_pct, 0::numeric) * 2.5)) + 25.0 * COALESCE(c.muestra_calibracion, 0)::numeric / (COALESCE(c.muestra_calibracion, 0)::numeric + 200.0) +
                CASE
                    WHEN c.analisis_confirma THEN 15
                    ELSE 0
                END::numeric +
                CASE
                    WHEN c.momio_verificado THEN 10
                    ELSE 0
                END::numeric)))::integer AS score_total
           FROM calc c
        ), rankeado AS (
         SELECT p.pick_id,
            p.espn_event_id,
            p.partido,
            p.liga,
            p.deporte,
            p.mercado,
            p.pick_desc,
            p.momio_ai,
            p.prob_declarada,
            p.ev_declarado_pct,
            p.confianza_ai,
            p.clasificacion,
            p.kelly_pct,
            p.razonamiento,
            p.match_date,
            p.mercado_norm,
            p.momio_libro,
            p.bookmaker,
            p.momio_leido_en,
            p.momio_usado,
            p.momio_verificado,
            p.desvio_vs_libro_pct,
            p.rango_momio,
            p.muestra_calibracion,
            p.roi_segmento,
            p.wr_segmento,
            p.confiable,
            p.prob_observada,
            p.ev_real_pct,
            p.analisis_confirma,
            p.prob_pct,
            p.perfil_respalda,
            p.momio_inflado,
            p.score_total,
            COALESCE(p.ev_real_pct, '-1'::integer::numeric) > 0::numeric AND COALESCE(p.roi_segmento, '-1'::integer::numeric) > 0::numeric AND p.confiable AND NOT p.momio_inflado AS apto,
            row_number() OVER (PARTITION BY (
                CASE
                    WHEN COALESCE(p.ev_real_pct, '-1'::integer::numeric) >= 20::numeric AND p.momio_verificado AND NOT p.momio_inflado AND COALESCE(p.roi_segmento, '-1'::integer::numeric) > 0::numeric AND p.confiable THEN 1
                    ELSE 0
                END) ORDER BY p.score_total DESC, p.ev_real_pct DESC NULLS LAST, p.momio_usado DESC, p.match_date) AS orden_estrella,
            COALESCE(p.ev_real_pct, '-1'::integer::numeric) >= 20::numeric AND p.momio_verificado AND NOT p.momio_inflado AND COALESCE(p.roi_segmento, '-1'::integer::numeric) > 0::numeric AND p.confiable AS elegible_estrella
           FROM puntuado p
        )
 SELECT pick_id,
    espn_event_id,
    partido,
    liga,
    deporte,
    mercado,
    pick_desc,
    momio_usado AS momio,
    match_date,
    clasificacion,
    confianza_ai,
    razonamiento,
    prob_pct,
    ev_real_pct,
    ev_declarado_pct,
    muestra_calibracion,
    analisis_confirma,
    perfil_respalda,
    wr_segmento AS wr_historico,
    muestra_calibracion AS muestra_historica,
    score_total,
        CASE
            WHEN momio_inflado THEN 'NO RECOMENDADO'::text
            WHEN elegible_estrella AND orden_estrella = 1 THEN 'PICK DEL DÍA 🔥'::text
            WHEN COALESCE(ev_real_pct, '-1'::integer::numeric) >= 8::numeric THEN 'FUERTE'::text
            WHEN COALESCE(ev_real_pct, '-1'::integer::numeric) > 0::numeric THEN 'SÓLIDO'::text
            ELSE 'NO RECOMENDADO'::text
        END AS tier,
    apto AND ((economic_eligibility_v1(jsonb_build_object('deporte', deporte_registry(deporte), 'mercado', 'Moneyline', 'fuente', 'motor_picks', 'model_version', NULL::text)) ->> 'eligible'::text)::boolean) AS apto_para_mostrar,
        CASE
            WHEN (economic_eligibility_v1(jsonb_build_object('deporte', deporte_registry(deporte), 'mercado', 'Moneyline', 'fuente', 'motor_picks', 'model_version', NULL::text)) ->> 'eligible'::text)::boolean THEN round(LEAST(5.0, GREATEST(0.5, COALESCE(kelly_pct, 1.0))), 2)
            ELSE 0::numeric
        END AS kelly_pct_sugerido,
    array_remove(ARRAY[
        CASE
            WHEN momio_verificado THEN ((('Momio verificado contra '::text || bookmaker) || ' ('::text) || to_char((momio_leido_en AT TIME ZONE 'America/Mexico_City'::text), 'HH24:MI'::text)) || ' hrs)'::text
            ELSE NULL::text
        END,
        CASE
            WHEN roi_segmento > 0::numeric THEN ((((((('En '::text || muestra_calibracion) || ' apuestas de este tipo ('::text) || mercado_norm) || ' a momio '::text) || rango_momio) || '), el sistema lleva ROI real de +'::text) || roi_segmento) || '%'::text
            ELSE NULL::text
        END,
        CASE
            WHEN wr_segmento IS NOT NULL THEN ('Acierto histórico del segmento: '::text || wr_segmento) || '%'::text
            ELSE NULL::text
        END,
        CASE
            WHEN analisis_confirma THEN 'Dos fuentes independientes coinciden'::text
            ELSE NULL::text
        END,
        CASE
            WHEN momio_usado >= 2.20 AND momio_usado <= 5.00 THEN 'Momio en el rango donde el sistema gana dinero de verdad'::text
            ELSE NULL::text
        END], NULL::text) AS razones_positivas,
    array_remove(ARRAY[
        CASE
            WHEN momio_inflado THEN ((((('MOMIO INFLADO: la IA dijo '::text || to_char(momio_ai, 'FM990.00'::text)) || ' pero '::text) || bookmaker) || ' paga '::text) || to_char(momio_libro, 'FM990.00'::text)) || '. La ventaja que mostraba no existe a ese precio.'::text
            ELSE NULL::text
        END,
        CASE
            WHEN NOT momio_verificado THEN 'MOMIO SIN VERIFICAR: no hay lectura de casa de apuestas para este partido. El momio lo puso la IA y nadie lo confirmó.'::text
            ELSE NULL::text
        END,
        CASE
            WHEN muestra_calibracion IS NULL THEN 'SIN HISTORIAL: nunca se ha medido este mercado en este rango de momio.'::text
            ELSE NULL::text
        END,
        CASE
            WHEN NOT COALESCE(confiable, false) AND muestra_calibracion IS NOT NULL THEN ('Muestra insuficiente ('::text || muestra_calibracion) || '): no alcanza para confiar.'::text
            ELSE NULL::text
        END,
        CASE
            WHEN COALESCE(roi_segmento, 0::numeric) <= 0::numeric AND confiable THEN ((('ESTE TIPO DE PICK PIERDE DINERO: '::text || muestra_calibracion) || ' apuestas con ROI real de '::text) || roi_segmento) || '%.'::text
            ELSE NULL::text
        END,
        CASE
            WHEN muestra_calibracion IS NOT NULL AND muestra_calibracion < 250 THEN ('Muestra de '::text || muestra_calibracion) || ': el ROI mostrado ya viene reducido porque números así regresan a la media.'::text
            ELSE NULL::text
        END,
        CASE
            WHEN NOT analisis_confirma THEN 'Una sola fuente lo recomienda.'::text
            ELSE NULL::text
        END,
        CASE
            WHEN elegible_estrella AND orden_estrella > 1 THEN ('Mismo perfil que el pick del día, pero quedó '::text || orden_estrella) || 'º al desempatar: el EV que se muestra es el del segmento, no exclusivo de este partido.'::text
            ELSE NULL::text
        END], NULL::text) AS red_flags,
    momio_ai AS momio_declarado_ia,
    momio_libro,
    momio_verificado,
    bookmaker,
    momio_leido_en,
    desvio_vs_libro_pct
   FROM rankeado r
  ORDER BY apto DESC, ev_real_pct DESC NULLS LAST, score_total DESC;

-- decision_pick_v1 es NUEVO: su rollback es DROP.
DROP FUNCTION IF EXISTS public.decision_pick_v1(text,text,text,text,numeric,numeric,numeric,numeric,jsonb);