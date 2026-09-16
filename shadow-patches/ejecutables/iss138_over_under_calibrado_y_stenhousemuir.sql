-- =====================================================================
-- ISS138 -- EL OVER/UNDER SI TENIA ARREGLO, Y STENHOUSEMUIR ERA MI BUG
--
-- El dueno planteo esto: "si un equipo mete 2.2 goles por partido y recibe
-- 1.3, y el rival mete 1.7 y recibe 2.8, podrias deducir que probablemente
-- se haga un O2.5. Tenemos toda la informacion. No crees?"
--
-- Lo medi en serio, y la respuesta tiene dos mitades.
--
-- ============ MITAD 1: SU METODO NO GANA MAS PARTIDOS ============
--
-- Implemente exactamente lo que describio, sobre 26,777 partidos REALES de
-- futbol del historial de ESPN, con ventana movil de los 10 partidos
-- anteriores de cada equipo (sin mirar el futuro, por construccion):
--     lambda_local   = (GF del local + GC del visitante) / 2
--     lambda_visita  = (GF del visitante + GC del local) / 2
--     total esperado = lambda_local + lambda_visita
--
--   n = 26,777   predicho medio 2.8140   real medio 2.8136
--   correlacion con el total real: 0.1443      MAE 1.3449
--
-- El modelo publicado tiene correlacion 0.147 en el mismo tipo de medicion.
-- O sea: SU METODO ES IGUAL DE BUENO QUE EL QUE YA TENEMOS, ni mejor ni peor.
-- Eso no es un fracaso suyo: es el techo del problema. El total de goles de
-- UN partido esta dominado por ruido. La diferencia entre dos equipos (que
-- es lo que decide el 1X2) se predice con correlacion 0.451; la SUMA no.
--
-- PRIMER ERROR MIO EN ESTA MEDICION, Y COMO LO CACHE:
--   La primera corrida me dio correlacion 0.7775, que habria sido
--   espectacular. Era falso: historico_partidos_espn mezcla deportes.
--     soccer   33,505 partidos  total medio  2.84
--     baseball 11,444           total medio  9.15
--     football  1,986           total medio 44.71
--   La correlacion de 0.78 era "adivinar si esto es beisbol o futbol". Al
--   filtrar espn_endpoint like 'soccer/%' cayo a 0.1443, que es la real.
--
-- ============ MITAD 2: LO QUE SI ESTABA ROTO, Y SE ARREGLO ============
--
-- Ordene los 26,777 partidos por la probabilidad de Over 2.5 que sale de
-- ese lambda y los parti en deciles. Esto es lo que aparecio:
--
--   decil  el modelo dice   la realidad fue   goles reales
--     1        33.3%            44.4%             2.447
--     2        41.0%            47.9%             2.547
--     3        45.2%            49.9%             2.612
--     4        48.5%            51.9%             2.703
--     5        51.6%            52.4%             2.746
--     6        54.4%            54.9%             2.885
--     7        57.3%            55.9%             2.877
--     8        60.4%            56.6%             2.930
--     9        64.2%            61.2%             3.128
--    10        70.8%            63.5%             3.261
--
-- Dos cosas, y las dos importan:
--
-- 1) LA COLUMNA DE EN MEDIO SI SUBE, DE 44.4% A 63.5%, SIN UN SOLO TROPIEZO.
--    Hay senal de verdad. El dueno tenia razon en que la informacion sirve.
--    Los goles reales tambien suben, de 2.45 a 3.26.
--
-- 2) EL MODELO ES SISTEMATICAMENTE DEMASIADO CONFIADO. Cuando dice 70.8%
--    la realidad es 63.5%. Cuando dice 33.3% la realidad es 44.4%. Se pasa
--    por los dos lados. La pendiente real no es 1, es ~0.5.
--
-- EL ARREGLO ES ENCOGER LA PROBABILIDAD HACIA LA BASE:
--     p_calibrada = intercepto + encogimiento * p_cruda
--
-- Ajustado en el 70% temporal mas VIEJO y medido en el 30% mas NUEVO, sin
-- traslape. Las cuatro lineas reales que existen en la app:
--
--   linea  encogim.  Brier crudo  Brier calib.  Brier constante   t    IC95 inf
--    1.5    0.4865     0.176632     0.174855      0.176148       3.69   0.000606
--    2.5    0.5032     0.247669     0.244970      0.247980       5.24   0.001883
--    3.5    0.5530     0.214813     0.212846      0.215713       5.08   0.001762
--    4.5    0.5461     0.131231     0.130108      0.131566       4.30   0.000794
--
-- Las cuatro le ganan al constante con el IC95 ENTERO por encima de cero.
-- 18,744 partidos de ajuste, 8,033 de prueba. Es la primera calibracion de
-- total de goles del proyecto que pasa la prueba estadistica.
--
-- CONFIRMACION INDEPENDIENTE, QUE ES LO QUE ME CONVENCIO:
--   La pendiente 0.5032 salio del historial de ESPN con un metodo GF/GA.
--   Medida por separado sobre las 146 predicciones REALES ya calificadas del
--   cerebro dc-2026.09.1 (otro pipeline, otros datos), la pendiente sale
--   0.5388. Dos estimaciones independientes, las dos cerca de 0.5.
--   No es una casualidad del historial: es una propiedad de los modelos
--   Poisson de goles, que ignoran la incertidumbre de su propio lambda.
--   Aplicando la calibracion de ESPN a esas 146 de dc:
--     Brier 0.251931 -> 0.245405, contra un constante de 0.249249.
--   Mejora fuera de muestra y en un pipeline distinto.
--
-- ============ ESTO NO ES UN SEGUNDO CEREBRO ============
--
-- La regla del dueno es absoluta: UN cerebro por deporte, un solo analisis.
-- Aqui NO se sustituye nada. El cerebro canonico sigue produciendo lambda y
-- p_over igual que antes. Lo unico que se agrega es una transformacion afin
-- DECLARADA Y VERSIONADA de su propio numero, con su evidencia pegada.
-- El crudo se conserva en over_crudo_pct para poder auditarlo.
--
-- Por lo mismo NO se metio el p_over de dc-2026.09.1, aunque su correlacion
-- (0.2746) casi duplica la del publicado. Eso SI seria un segundo cerebro.
--
-- ============ LO QUE LA CALIBRACION NO ARREGLA ============
--
-- G33.12 replica el veredicto de G32.2 con la calibracion puesta, sobre las
-- 243 observaciones crudas que ya estaban calificadas:
--     crudo      vs adivinar  0.0365  IC95[0.0065, 0.0665]
--     calibrado  vs adivinar  0.0328  IC95[0.0026, 0.0629]
--
-- O sea: el Over/Under de RETO, incluso calibrado, SIGUE SIENDO
-- CONCLUYENTEMENTE PEOR QUE ADIVINAR sobre lo ya calificado. La calibracion
-- lo mejora (0.0365 -> 0.0328) pero no lo salva. Ese numero no se maquilla.
--
-- Por eso G32.2 SIGUE EN ROJO y debe seguir. Se pone verde de dos maneras
-- honestas, ninguna de las cuales es bajar el umbral:
--   a) que las predicciones nuevas, ya calibradas, acumulen muestra y ganen
--   b) que el dueno decida dejar de publicar ese mercado
-- Mientras tanto se aplica lo que el propio dueno eligio para el moneyline
-- de MLB en ISS128: publicarlo CON LA VERDAD PEGADA. Cada tarjeta lleva
-- evidencia_por_mercado con el veredicto de los tres mercados:
--     ganador  MEJOR_QUE_ADIVINAR_CONCLUYENTE
--     btts     SIN_VEREDICTO_MUESTRA_INSUFICIENTE
--     total    PEOR_QUE_ADIVINAR_CONCLUYENTE
--
-- ============ SE CALIFICA LO QUE SE PUBLICA ============
--
-- Este era el riesgo real de meter una calibracion: que la tarjeta muestre
-- el numero calibrado y el vigilante califique el crudo. El vigilante
-- estaria midiendo algo que nadie vio. v2.refresh_model_learning ahora
-- guarda la probabilidad CALIBRADA, y el crudo queda en meta para auditar.
-- El bloque de MLB NO se toco: la guarda de "exactamente 1 coincidencia"
-- reprobo con 2 y me obligo a anclar solo el bloque de futbol. Hizo su
-- trabajo.
--
-- ============ STENHOUSEMUIR: EL BUG ERA MIO ============
--
-- En ISS137 escribi que el catalogo tenia una copa mal tipada. ESTABA MAL,
-- y lo dejo por escrito. El catalogo esta bien:
--     apifootball_ligas_catalogo: liga_id 181 = "FA Cup", Scotland, tipo "Cup"
--
-- El error fue mio, de ISS129: al resolver la liga domestica por argmax de
-- partidos jugados exclui los torneos CONTINENTALES (uefa/conmebol/concacaf/
-- afc/fifa) pero NO las COPAS DOMESTICAS. A Stenhousemuir se le asigno una
-- copa como si fuera su liga.
--
-- Y hay una razon de fondo por la que ese equipo no se puede resolver:
--     ESPN solo lo cubre en soccer/sco.cis (18 partidos) y
--     soccer/sco.tennents (6). Las dos son copas.
--     No hay UN SOLO partido de liga suyo en toda la base.
-- Tampoco aparece en soccer_standings, ni en espn_standings_raw con liga,
-- ni en team_aliases_apifootball. NINGUNA fuente de esta base dice en que
-- liga juega.
--
-- Yo se de memoria en que division escocesa juega. NO LA ESCRIBI. Escribir
-- un dato que la base no puede verificar es exactamente lo que el dueno
-- prohibio. Se falla cerrado:
--     domestic_league_id  -> null
--     status              -> BLOCKED
--     reason              -> NO_DOMESTIC_LEAGUE_EVIDENCE
-- y ademas deja de quemar reintentos: llevaba 89.
--
-- ALCANCE MEDIDO DEL DANO: exactamente 1 equipo y 3 observaciones, todas de
-- copa (4-0 a Clachnacuddin, 4-1 a Morton, 0-2 con Falkirk). Esas 3 inflaban
-- su ataque con rivales de otra division. Se borraron.
-- Ninguna phi instalada venia de una copa (verificado: 0).
--
-- ============ HALLAZGO ADICIONAL, REPORTADO Y NO PARCHEADO ============
--
-- ligas_master tiene 15 filas donde api_sports_id apunta a una competicion
-- DISTINTA de la que dice espn_endpoint. Las dos con datos de verdad:
--     id 105  ESPN "Scottish Cup"  (sco.tennents) -> api_sports 180 = Championship de Escocia
--     id 101  ESPN "KNVB Beker"    (ned.cup)      -> api_sports  89 = Eerste Divisie
-- Son 303 y 172 partidos historicos cargados con el id de OTRA competicion.
-- Las otras 13 tienen 0 partidos.
--
-- Verifique si eso contamino la cola de cobertura: NO. Los unicos 2 equipos
-- con liga 89 son ADO Den Haag y SC Cambuur, que si son de la Eerste
-- Divisie. Ninguno se asigno por esa via.
--
-- NO LO PARCHEE. Cambiar api_sports_id en ligas_master mueve de que
-- competicion se descarga el historial de ESPN, y eso hay que medirlo
-- aparte. Queda reportado, con su alcance medido, no escondido.
-- =====================================================================


-- ---------------------------------------------------------------------
-- 1) STENHOUSEMUIR: retirar la copa, purgar lo contaminado, fallar cerrado
-- ---------------------------------------------------------------------
BEGIN;

create table if not exists v2.soccer_coverage_job_bak_iss138 as
  select * from v2.soccer_coverage_job j
  left join public.apifootball_ligas_catalogo c on c.liga_id=j.domestic_league_id
  where j.domestic_league_id is not null and (c.tipo is null or lower(c.tipo)<>'league');

create table if not exists v2.soccer_domestic_observation_bak_iss138 as
  select o.* from v2.soccer_domestic_observation o
  left join public.apifootball_ligas_catalogo c on c.liga_id=o.domestic_league_id
  where c.tipo is null or lower(c.tipo)<>'league';

delete from v2.soccer_domestic_observation o
 using public.apifootball_ligas_catalogo c
 where c.liga_id=o.domestic_league_id and lower(c.tipo)<>'league';

delete from v2.soccer_domestic_observation o
 where not exists (select 1 from public.apifootball_ligas_catalogo c where c.liga_id=o.domestic_league_id);

update v2.soccer_coverage_job j
   set domestic_league_id = null, domestic_league_name = null,
       status = 'BLOCKED', reason = 'NO_DOMESTIC_LEAGUE_EVIDENCE', attempts = 0,
       last_error = 'La liga que tenia asignada era una COPA segun apifootball_ligas_catalogo, no una liga domestica. Se retira. No hay en esta base ninguna fuente que diga en que liga juega este equipo: ESPN solo lo cubre en copas. No se inventa una.',
       updated_at = now()
 from public.apifootball_ligas_catalogo c
 where c.liga_id = j.domestic_league_id and lower(c.tipo) <> 'league';

COMMIT;

-- Y que no vuelva a pasar: el ajuste automatico de phi ya no considera
-- siquiera intentar una competicion que el catalogo marca como copa.
DO $outer$
DECLARE v_def text; v_o text; v_n text; c int;
BEGIN
  SELECT pg_get_functiondef(p.oid) INTO v_def
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='v2' AND p.proname='ajustar_e_instalar_phi';
  v_o := $r$    from v2.soccer_domestic_observation o
    where not exists (select 1 from v2.crossleague_league_strength s$r$;
  v_n := $r$    from v2.soccer_domestic_observation o
    join public.apifootball_ligas_catalogo cat
      on cat.liga_id = o.domestic_league_id and lower(cat.tipo) = 'league'
    where not exists (select 1 from v2.crossleague_league_strength s$r$;
  c := (length(v_def)-length(replace(v_def,v_o,'')))/length(v_o);
  IF c <> 1 THEN RAISE EXCEPTION 'ISS138 aborta: % coincidencias, se exigia 1', c; END IF;
  EXECUTE replace(v_def, v_o, v_n);
END
$outer$;


-- ---------------------------------------------------------------------
-- 2) La calibracion del Over/Under, versionada y con su evidencia
-- ---------------------------------------------------------------------
create table if not exists v2.calibracion_over_under (
  linea numeric not null, medido_at timestamptz not null default now(),
  fuente text not null, n_train int not null, n_test int not null,
  encogimiento numeric not null, intercepto numeric not null,
  ancla_y numeric not null, ancla_p numeric not null,
  brier_crudo numeric not null, brier_calibrado numeric not null,
  brier_constante numeric not null, mejora numeric not null, ee numeric not null,
  t_stat numeric not null, ic95_inf numeric not null, correlacion numeric not null,
  veredicto text not null, vigente boolean not null default true, nota text,
  primary key (linea, medido_at)
);
create index if not exists ix_cal_ou_vigente on v2.calibracion_over_under (linea) where vigente;

create or replace function v2.medir_calibracion_over_under()
returns int language plpgsql security definer
set search_path to 'v2','public' set statement_timeout to '300s'
as $fn$
declare n_inst int := 0;
begin
  create temp table _ou_base on commit drop as
  with base as (
    select h.espn_event_id, h.fecha, h.home_espn_id, h.away_espn_id, h.home_score, h.away_score
    from public.historico_partidos_espn h
    where h.espn_endpoint like 'soccer/%'
      and h.home_score is not null and h.away_score is not null
      and h.home_espn_id is not null and h.away_espn_id is not null
  ),
  lado as (
    select espn_event_id, fecha, home_espn_id as team, home_score as gf, away_score as ga from base
    union all
    select espn_event_id, fecha, away_espn_id, away_score, home_score from base
  ),
  roll as (
    select l.*, count(*) over w n_prev, avg(l.gf) over w gf_m, avg(l.ga) over w ga_m
    from lado l
    window w as (partition by l.team order by l.fecha rows between 10 preceding and 1 preceding)
  )
  select b.espn_event_id, b.fecha, (b.home_score+b.away_score)::numeric total_real,
         ((rh.gf_m+ra.ga_m)/2 + (ra.gf_m+rh.ga_m)/2)::float8 lam
  from base b
  join roll rh on rh.espn_event_id=b.espn_event_id and rh.team=b.home_espn_id and rh.n_prev>=10
  join roll ra on ra.espn_event_id=b.espn_event_id and ra.team=b.away_espn_id and ra.n_prev>=10;

  with lineas(linea) as (values (1.5::numeric),(2.5),(3.5),(4.5)),
  x as (
    select t.fecha, l.linea,
      case l.linea
        when 1.5 then 1 - exp(-t.lam)*(1+t.lam)
        when 2.5 then 1 - exp(-t.lam)*(1+t.lam+t.lam^2/2)
        when 3.5 then 1 - exp(-t.lam)*(1+t.lam+t.lam^2/2+t.lam^3/6)
        when 4.5 then 1 - exp(-t.lam)*(1+t.lam+t.lam^2/2+t.lam^3/6+t.lam^4/24)
      end as p_over,
      case when t.total_real > l.linea then 1 else 0 end y
    from _ou_base t cross join lineas l
  ),
  s as (select percentile_disc(0.7) within group (order by fecha) corte from x),
  tr as (select x.* from x, s where x.fecha <= s.corte),
  te as (select x.* from x, s where x.fecha >  s.corte),
  fit as (select linea, regr_slope(y::float8,p_over) b, avg(y)::float8 ybar,
                 avg(p_over) pbar, count(*)::int n from tr group by linea),
  ev as (
    select te.linea, te.y, te.p_over,
           greatest(0.02, least(0.98, f.ybar + f.b*(te.p_over - f.pbar))) p_cal, f.ybar p0
    from te join fit f on f.linea = te.linea
  ),
  res as (
    select linea, count(*)::int n_test,
           avg((p_over-y)^2) b_crudo, avg((p_cal-y)^2) b_cal, avg((p0-y)^2) b_const,
           avg((p0-y)^2)-avg((p_cal-y)^2) mejora,
           stddev_samp((p0-y)^2-(p_cal-y)^2)/sqrt(count(*)) ee,
           corr(p_cal, y::float8) c
    from ev group by linea
  ),
  final as (
    select f.linea, f.n n_train, r.n_test, f.b, (f.ybar - f.b*f.pbar) a,
           f.ybar, f.pbar, r.b_crudo, r.b_cal, r.b_const, r.mejora, r.ee,
           r.mejora/nullif(r.ee,0) t, r.mejora-1.96*r.ee ic_inf, r.c
    from fit f join res r on r.linea=f.linea
  ),
  apagar as (
    update v2.calibracion_over_under c set vigente=false
    where c.vigente and c.linea in (select linea from final) returning 1
  )
  insert into v2.calibracion_over_under
    (linea, fuente, n_train, n_test, encogimiento, intercepto, ancla_y, ancla_p,
     brier_crudo, brier_calibrado, brier_constante, mejora, ee, t_stat, ic95_inf,
     correlacion, veredicto, vigente, nota)
  select f.linea,
         'HISTORICO_ESPN_GF_GA_VENTANA10_CORTE_TEMPORAL_70_30',
         f.n_train, f.n_test,
         round(f.b::numeric,4), round(f.a::numeric,4),
         round(f.ybar::numeric,4), round(f.pbar::numeric,4),
         round(f.b_crudo::numeric,6), round(f.b_cal::numeric,6), round(f.b_const::numeric,6),
         round(f.mejora::numeric,6), round(f.ee::numeric,6),
         round(f.t::numeric,2), round(f.ic_inf::numeric,6),
         round(f.c::numeric,4),
         case when f.ic_inf > 0 then 'VALIDADA_MEJORA_LA_CONSTANTE'
              else 'NO_VALIDADA_FALLA_CERRADO' end,
         (f.ic_inf > 0),
         'Encogimiento afin p_cal = intercepto + encogimiento*p_crudo. Mide que el modelo Poisson de goles es SISTEMATICAMENTE DEMASIADO CONFIADO: la pendiente real ronda 0.5. Ajustado en el 70% temporal mas viejo y medido en el 30% mas nuevo, sin traslape.'
  from final f;

  get diagnostics n_inst = row_count;
  return n_inst;
end $fn$;

-- Cuando el propio cerebro publicado junte muestra suficiente, SU calibracion
-- manda sobre la prestada del historial. Falla cerrado: n_test>=200 e ic95_inf>0.
create or replace function v2.medir_calibracion_over_under_del_modelo(
  p_model_version text, p_min_test int default 200)
returns int language plpgsql security definer
set search_path to 'v2','public' set statement_timeout to '180s'
as $fn$
declare n_inst int := 0;
begin
  with o as (
    select ob.line linea, ob.kickoff,
           coalesce((ob.meta->>'p_over_crudo_pct')::float8/100.0, ob.p1::float8) p_over,
           case when ob.outcome_idx=1 then 1 else 0 end y
    from v2.model_learning_observation ob
    where ob.sport='soccer' and ob.market='Over/Under'
      and ob.model_version=p_model_version and ob.outcome_idx is not null
      and ob.line is not null and ob.p1 is not null
  ),
  s as (select linea, percentile_disc(0.7) within group (order by kickoff) corte from o group by linea),
  tr as (select o.* from o join s on s.linea=o.linea where o.kickoff <= s.corte),
  te as (select o.* from o join s on s.linea=o.linea where o.kickoff >  s.corte),
  fit as (select linea, regr_slope(y::float8,p_over) b, avg(y)::float8 ybar, avg(p_over) pbar, count(*)::int n
          from tr group by linea),
  ev as (select te.linea, te.y, te.p_over,
                greatest(0.02,least(0.98, f.ybar + f.b*(te.p_over-f.pbar))) p_cal, f.ybar p0
         from te join fit f on f.linea=te.linea),
  res as (select linea, count(*)::int n_test,
                 avg((p_over-y)^2) b_crudo, avg((p_cal-y)^2) b_cal, avg((p0-y)^2) b_const,
                 avg((p0-y)^2)-avg((p_cal-y)^2) mejora,
                 stddev_samp((p0-y)^2-(p_cal-y)^2)/sqrt(count(*)) ee,
                 corr(p_cal,y::float8) c
          from ev group by linea),
  final as (select f.linea, f.n n_train, r.n_test, f.b, (f.ybar-f.b*f.pbar) a, f.ybar, f.pbar,
                   r.b_crudo, r.b_cal, r.b_const, r.mejora, r.ee,
                   r.mejora/nullif(r.ee,0) t, r.mejora-1.96*r.ee ic_inf, r.c
            from fit f join res r on r.linea=f.linea
            where r.n_test >= p_min_test and (r.mejora-1.96*r.ee) > 0 and f.b is not null),
  apagar as (
    update v2.calibracion_over_under c set vigente=false
    where c.vigente and c.fuente like 'MODELO_PROPIO|'||p_model_version||'%'
      and c.linea in (select linea from final) returning 1)
  insert into v2.calibracion_over_under
    (linea, fuente, n_train, n_test, encogimiento, intercepto, ancla_y, ancla_p,
     brier_crudo, brier_calibrado, brier_constante, mejora, ee, t_stat, ic95_inf,
     correlacion, veredicto, vigente, nota)
  select f.linea, 'MODELO_PROPIO|'||p_model_version, f.n_train, f.n_test,
         round(f.b::numeric,4), round(f.a::numeric,4), round(f.ybar::numeric,4), round(f.pbar::numeric,4),
         round(f.b_crudo::numeric,6), round(f.b_cal::numeric,6), round(f.b_const::numeric,6),
         round(f.mejora::numeric,6), round(f.ee::numeric,6), round(f.t::numeric,2), round(f.ic_inf::numeric,6),
         round(f.c::numeric,4), 'VALIDADA_MEJORA_LA_CONSTANTE', true,
         'Medida con las predicciones REALES de este cerebro ya calificadas, no con el historial prestado. Manda sobre la prestada.'
  from final f;
  get diagnostics n_inst = row_count;
  return n_inst;
end $fn$;

-- El aplicador. Prefiere la medida del propio cerebro cuando exista.
create or replace function public.soccer_ou_calibrado(
  p_over_crudo numeric, p_linea numeric, p_push_pct numeric default 0)
returns jsonb language plpgsql stable set search_path to 'public','v2'
as $fn$
declare c record; v_p numeric; v_cal numeric; v_disp numeric;
begin
  if p_over_crudo is null or p_linea is null then
    return jsonb_build_object('estado','SIN_LINEA_O_SIN_PROBABILIDAD','over_pct',null,'under_pct',null,
      'nota','Sin linea de casa o sin probabilidad del modelo no se publica nada. No se inventa.');
  end if;

  select * into c from v2.calibracion_over_under
   where vigente and linea = p_linea
   order by (fuente like 'MODELO_PROPIO%') desc, medido_at desc limit 1;

  if not found then
    return jsonb_build_object('estado','SIN_CALIBRACION_PARA_ESTA_LINEA',
      'over_pct', round(p_over_crudo,1),
      'under_pct', round(100 - p_over_crudo - coalesce(p_push_pct,0),1),
      'over_crudo_pct', round(p_over_crudo,1), 'encogimiento_aplicado', null,
      'nota','Esta linea no tiene calibracion medida. Se publica el numero crudo del cerebro, sin tocar, y se declara que no esta calibrado.');
  end if;

  v_p    := p_over_crudo / 100.0;
  v_cal  := greatest(0.02, least(0.98, c.intercepto + c.encogimiento * v_p));
  v_disp := 100 - coalesce(p_push_pct,0);

  return jsonb_build_object(
    'estado','CALIBRADA',
    'over_pct',  round((v_cal*v_disp)::numeric,1),
    'under_pct', round(((1-v_cal)*v_disp)::numeric,1),
    'push_pct',  round(coalesce(p_push_pct,0),1),
    'over_crudo_pct', round(p_over_crudo,1),
    'movimiento_pp', round((v_cal*v_disp - p_over_crudo)::numeric,1),
    'encogimiento_aplicado', c.encogimiento,
    'intercepto', c.intercepto,
    'medida_con', jsonb_build_object('fuente',c.fuente,'partidos_ajuste',c.n_train,'partidos_prueba',c.n_test,
        'brier_crudo',c.brier_crudo,'brier_calibrado',c.brier_calibrado,'brier_constante',c.brier_constante,
        'mejora_vs_constante',c.mejora,'t',c.t_stat,'ic95_inferior',c.ic95_inf,
        'correlacion',c.correlacion,'veredicto',c.veredicto),
    'que_significa','El modelo de goles es demasiado confiado: cuando dice 70% la realidad ronda 63%, y cuando dice 33% la realidad ronda 44%. El encogimiento acerca la probabilidad a la base por el factor medido.',
    'politica','SIN_EV_SIN_KELLY_EL_PRECIO_NO_DECIDE');
end $fn$;

revoke all on function public.soccer_ou_calibrado(numeric,numeric,numeric) from public;
grant execute on function public.soccer_ou_calibrado(numeric,numeric,numeric) to anon, authenticated, service_role;

create or replace function v2.correr_calibraciones_soccer()
returns jsonb language plpgsql security definer
set search_path to 'v2','public' set statement_timeout to '600s' as $fn$
declare a int; b int; c int;
begin
  a := v2.medir_calibracion_over_under();
  b := v2.medir_calibracion_over_under_del_modelo('soccer_canonical_v2');
  perform v2.medir_calibracion_total_goles('soccer_canonical_v2');
  perform v2.medir_calibracion_total_goles('dc-2026.09.1');
  perform v2.medir_calibracion_total_goles('crossleague_v1');
  select count(*) into c from v2.calibracion_over_under where vigente;
  return jsonb_build_object('ou_prestada_medida',a,'ou_propia_instalada',b,'lineas_vigentes',c,'at',now());
end $fn$;

select cron.schedule('calibracion-soccer-diaria','24 5 * * *',
  $$select v2.correr_calibraciones_soccer();$$);


-- ---------------------------------------------------------------------
-- 3) Se califica lo que se publica
-- ---------------------------------------------------------------------
-- v2.refresh_model_learning guardaba s.p_over/100.0 en p1. Ahora guarda
-- (soccer_ou_calibrado(...)->>'over_pct')/100.0, y el crudo va en meta junto
-- con el encogimiento aplicado. El bloque de MLB usa el mismo fragmento y NO
-- se toco: la guarda de exactamente-1 lo impidio y hubo que anclar mas largo.


-- =====================================================================
-- MEDIDO. GATE 30 (tarjeta de futbol), 9 duras + 1 INFO:
--   G30.1  los tres o ninguno .................. PASS  0
--   G30.2  suman 100 ........................... PASS  0
--   G30.3  el ganador es el argmax ............. PASS  0
--   G30.4  rangos posibles ..................... PASS  0
--   G30.5  la linea declara su fuente .......... PASS  0
--   G30.6  sin momios / EV / Kelly ............. PASS  0
--   G30.7  crudo = cerebro Y publicado = calibracion declarada  PASS  0
--   G30.8  monotonia de lineas ................. PASS  0
--   G30.9  sin linea no se inventa ............. PASS  0
--   G30.10 cobertura ........................... INFO  232
--
-- G30.7 quedo MAS estricto, no menos. Antes exigia over_pct == p_over del
-- modelo. Ahora exige DOS cosas: que over_crudo_pct sea byte a byte el del
-- cerebro canonico, Y que over_pct sea exactamente la transformacion afin
-- declarada de ese crudo. Un modelo paralelo seguiria reprobando.
--
-- GATE 33 (calibracion e identidad de liga), 9 duras + 3 INFO:
--   G33.1  ningun job apunta a una copa ........ PASS  0
--   G33.2  ninguna observacion viene de copa ... PASS  0
--   G33.3  ninguna phi es de copa .............. PASS  0
--   G33.4  toda calibracion vigente tiene IC>0 . PASS  0
--   G33.5  el encogimiento no invierte el pick . PASS  0   (pendiente en (0,1])
--   G33.6  over + under + push = 100 ........... PASS  0
--   G33.7  con linea conocida va calibrada ..... PASS  0
--   G33.8  el crudo queda auditable ............ PASS  0
--   G33.9  se califica lo que se publica ....... PASS  0
--   G33.10 efecto medido ....................... INFO  150
--          crudo medio 43.85 -> calibrado 44.65 | movimiento max 12.4 pp
--          17 tarjetas cambian de lado, las 17 de UNDER a OVER, 0 al reves.
--          Ese sesgo a UNDER es justo lo que el dueno reporto cuando vio un
--          "UNDER 2.5" en un partido que iba 1-3 al medio tiempo.
--   G33.11 equipos sin liga verificable ........ INFO  1  (Stenhousemuir)
--   G33.12 replay de G32.2 con la calibracion .. INFO  243
--
-- REVERSION:
--   begin;
--     update v2.calibracion_over_under set vigente=false;
--     -- soccer_ou_calibrado cae solo a SIN_CALIBRACION_PARA_ESTA_LINEA y
--     -- la tarjeta vuelve a publicar el crudo, declarandolo.
--     delete from v2.soccer_coverage_job where team_espn_id in
--       (select team_espn_id from v2.soccer_coverage_job_bak_iss138);
--     insert into v2.soccer_coverage_job select (bak).* from ... bak_iss138;
--     insert into v2.soccer_domestic_observation
--       select * from v2.soccer_domestic_observation_bak_iss138;
--   commit;
--   select cron.unschedule('calibracion-soccer-diaria');
-- =====================================================================
