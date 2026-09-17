-- ISS156: el cerebro de totales, sobre tiros a puerta
--
-- DE DONDE VIENE
--   El dueno pidio una sola logica de altas/bajas, la mas exacta, y describio
--   la aritmetica: "si un equipo mete 3 goles por partido y recibe 1, son 4, y
--   si el rival mete 1 y recibe 2, probablemente sea altas de 3.5".
--   Esa aritmetica ya se midio sobre GOLES (gemelos ou_gfga_v1) y perdio
--   contra adivinar. Tambien perdio la version publicada (crossleague).
--   Las dos tenian correlacion NEGATIVA con el resultado real: apuntaban al
--   reves. Ver evidencia previa en v2.evidencia_mercado_candidato.
--
--   Este parche NO cambia la aritmetica del dueno. Cambia el INSUMO:
--   en vez de goles metidos/recibidos, tiros a puerta metidos/recibidos.
--
-- POR QUE TIROS A PUERTA Y NO TIROS
--   Medido sobre 1628 equipo-partido con boxscore real de ESPN:
--     corr(tiros a puerta, goles) = 0.6316
--     corr(tiros totales,  goles) = 0.3811
--     tasa de conversion = 2571 goles / 7682 tiros a puerta = 0.3347
--   Los tiros a puerta llevan casi todo el contenido; los tiros totales no.
--
-- QUE SE CREA
--   v2.fn_soccer_tiros_asof(equipo, corte, ventana, exigir_cargado_at)
--     Promedio de tiros, tiros a puerta propios y tiros a puerta concedidos
--     sobre los ultimos N partidos ANTERIORES al corte.
--
--   v2.fn_soccer_ou_por_tiros(local, visita, corte, linea, tasa, ...)
--     lambda_local = ((SoT_local + SoT_concedidos_visita)/2) * tasa
--     lambda_visita = ((SoT_visita + SoT_concedidos_local)/2) * tasa
--     P(over) = 1 - Poisson(total <= floor(linea) | lambda_local+lambda_visita)
--     Falla cerrado si cualquiera de los dos equipos no llega al minimo.
--
-- LAS DOS GUARDIAS TEMPORALES, Y POR QUE UNA ES OPCIONAL
--   1. fecha del partido < corte    -> SIEMPRE. Impide el lookahead real.
--   2. cargado_at <= corte          -> por defecto SI. PRODUCCION LA EXIGE.
--
--   Los tiros se bajaron en un backfill, asi que el cargado_at de todo el
--   historico es "hoy". Con la guardia 2 activa cualquier medicion
--   retrospectiva devuelve n=0 y no se puede medir nada. Para medir en
--   historico se pasa false, y eso asume que el boxscore de ESPN estaba
--   disponible poco despues del pitido final, que es como ESPN publica.
--   Supuesto declarado, no atajo. Nunca se pasa false desde produccion.
--
-- PRUEBAS HECHAS
--   Poisson contra valor de libro: lambda=2.5, linea 2.5 -> 0.4562. Cuadra.
--   Identidad de lado: 814 HOME y 814 AWAY, 100% coinciden con
--     historico_partidos_espn. Cero filas sin coincidir.
--   Guardia estricta: con exigir_cargado_at=true devuelve n=0 sobre el
--     historico backfilleado, que es lo correcto.
--
-- MEDICION PRELIMINAR (n=118, NO ES SUFICIENTE PARA PUBLICAR)
--   Solo 118 partidos tienen hoy 5+ partidos con tiros para los dos equipos,
--   porque el backfill va en 877 de 7249.
--
--     tasa real de over 2.5     0.6102
--     p_over medio del modelo   0.5984   <- calibracion a 1.2 puntos
--     Brier modelo              0.23788
--     Brier constante           0.23786
--     mejora                   -0.00002  IC95 +/- 0.01394   <- CRUZA CERO
--     correlacion               +0.0800
--
--   LECTURA HONESTA:
--     - Es la primera de las tres variantes con correlacion POSITIVA.
--       La publicada dio -0.1337 y la del dueno sobre goles -0.1049:
--       las dos apuntaban al reves. Esta apunta al derecho.
--     - La calibracion es la mejor de las tres (1.2 pp contra 18 pp de la
--       publicada).
--     - Pero el intervalo cruza cero. Con corr 0.08 hacen falta del orden de
--       600+ partidos para distinguirlo del ruido. Con 118 no se distingue.
--
--   POR LO TANTO: NO SE PUBLICA. Se vuelve a medir cuando el backfill termine.
--   Si con la muestra completa el intervalo sigue tocando cero, tampoco se
--   publica y se dice que no se pudo.

create or replace function v2.fn_soccer_tiros_asof(
  p_team_espn_id text,
  p_decision_time timestamptz,
  p_ventana int default 10,
  p_exigir_cargado_at boolean default true
) returns table(
  n int, tiros_pg numeric, sot_pg numeric, sot_contra_pg numeric, ultimo timestamptz
)
language sql stable as $$
  with ult as (
    select s.espn_event_id, s.fecha, s.tiros, s.tiros_a_puerta,
           (select r.tiros_a_puerta from v2.soccer_stats_partido r
            where r.espn_event_id=s.espn_event_id and r.team_espn_id<>s.team_espn_id
            limit 1) as sot_rival
    from v2.soccer_stats_partido s
    where s.team_espn_id = p_team_espn_id
      and s.fecha < p_decision_time
      and (not p_exigir_cargado_at or s.cargado_at <= p_decision_time)
    order by s.fecha desc
    limit greatest(1, p_ventana)
  )
  select count(*)::int,
         round(avg(tiros)::numeric, 3),
         round(avg(tiros_a_puerta)::numeric, 3),
         round(avg(sot_rival)::numeric, 3),
         max(fecha)
  from ult;
$$;

create or replace function v2.fn_soccer_ou_por_tiros(
  p_home_espn_id text,
  p_away_espn_id text,
  p_decision_time timestamptz,
  p_linea numeric default 2.5,
  p_tasa_conversion numeric default 0.3347,
  p_ventana int default 10,
  p_min_partidos int default 5,
  p_exigir_cargado_at boolean default true
) returns table(
  estado text, motivo text,
  lambda_home numeric, lambda_away numeric, lambda_total numeric,
  p_over numeric, p_under numeric,
  n_home int, n_away int, insumos jsonb
)
language plpgsql stable as $$
declare
  h record; a record;
  lh numeric; la numeric; lt double precision;
  k int; pk double precision; acum double precision;
begin
  select * into h from v2.fn_soccer_tiros_asof(p_home_espn_id, p_decision_time, p_ventana, p_exigir_cargado_at);
  select * into a from v2.fn_soccer_tiros_asof(p_away_espn_id, p_decision_time, p_ventana, p_exigir_cargado_at);

  -- FALLA CERRADO. Sin tiros de los dos equipos no hay numero.
  if h.n < p_min_partidos or a.n < p_min_partidos
     or h.sot_pg is null or a.sot_pg is null
     or h.sot_contra_pg is null or a.sot_contra_pg is null then
    return query select 'DATA_INCOMPLETE'::text,
      ('MUESTRA_DE_TIROS_INSUFICIENTE: local '||coalesce(h.n,0)||', visita '||coalesce(a.n,0)||', minimo '||p_min_partidos)::text,
      null::numeric,null::numeric,null::numeric,null::numeric,null::numeric,
      coalesce(h.n,0), coalesce(a.n,0),
      jsonb_build_object('minimo_exigido', p_min_partidos);
    return;
  end if;

  -- MISMA ARITMETICA QUE LA DEL DUENO, PERO SOBRE TIROS A PUERTA EN VEZ DE GOLES.
  lh := round(((h.sot_pg + a.sot_contra_pg) / 2.0) * p_tasa_conversion, 4);
  la := round(((a.sot_pg + h.sot_contra_pg) / 2.0) * p_tasa_conversion, 4);
  lt := (lh + la)::double precision;

  -- P(total <= floor(linea)) por Poisson, recurrencia P(k) = P(k-1)*lambda/k.
  pk := exp(-lt);
  acum := pk;
  for k in 1..floor(p_linea)::int loop
    pk := pk * lt / k;
    acum := acum + pk;
  end loop;

  return query select 'READY'::text, null::text, lh, la, (lh+la),
    round((1 - acum)::numeric, 4), round(acum::numeric, 4),
    h.n, a.n,
    jsonb_build_object(
      'home_sot_pg', h.sot_pg, 'home_sot_contra_pg', h.sot_contra_pg, 'home_n', h.n,
      'away_sot_pg', a.sot_pg, 'away_sot_contra_pg', a.sot_contra_pg, 'away_n', a.n,
      'tasa_conversion', p_tasa_conversion, 'linea', p_linea,
      'formula', 'lambda_local = ((SoT_local + SoT_concedidos_visita)/2) * tasa_conversion; idem al reves; Poisson sobre la suma',
      'ventana_partidos', p_ventana, 'guardia_cargado_at', p_exigir_cargado_at);
end
$$;

-- NOTA PARA EL QUE MIDA ESTO DESPUES:
--   v2.soccer_stats_partido.lado viene en MAYUSCULAS ('HOME'/'AWAY').
--   Comparar contra 'home' en minusculas no da error: cae al ELSE y le asigna
--   al local los goles del visitante. La correlacion se desploma de 0.6316 a
--   0.2193 y parece un problema del modelo. No lo es.
