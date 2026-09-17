-- ISS171 + ISS172: dos frases contradiciendose, y por que el Championship
-- nunca tuvo fuerza de liga
--
-- ================================================================
-- 1. LA CONTRADICCION, QUE LA METI YO EN ISS168
-- ================================================================
-- El dueno lo vio en Levski Sofia vs RB Salzburg, la MISMA tarjeta:
--
--   "Los dos equipos tienen historial (25 y 47 partidos), pero a una de las
--    dos divisiones todavia no se le ha podido medir la fuerza de liga..."
--   "Solo RB Salzburg tiene historial verificable (5 partidos)"
--
-- Dos frases, la misma tarjeta, una diciendo que los dos tienen historial y la
-- otra que solo uno. Ambas mias de publicar: la primera la anadi en ISS168 sin
-- comprobarla contra la segunda, que ya estaba.
--
-- CAUSA: cuentan cosas distintas de fuentes distintas.
--   motivo_sin_p_reto   lee sample_home/sample_away del modelo, que mira la
--                       LIGA DOMESTICA COMPLETA.  Levski: 25 partidos.
--   contexto_sin_p_reto viene de ULTIMOS_5_TODAS_LAS_COMPETICIONES, otra
--                       fuente, que no encuentra a Levski y concluye que no
--                       tiene historial.
--
-- O sea: la fuente peor estaba contradiciendo a la mejor, en pantalla.
--
-- ARREGLO: public.contexto_sin_p_reto_coherente(). Para decir si un equipo
-- TIENE historial manda el modelo. El contexto sirve para dar numeros de los
-- ultimos 5, NO para negar que exista historial. Si el contexto viene con
-- status PARCIAL_SIN_RIVAL_VERIFICABLE y el modelo tiene muestra de los DOS
-- lados, esa afirmacion es falsa y no se publica.
--
-- Suprime 2 de 4: Levski-Salzburg y Lillestrom-Torreense.
-- Celtic-Ferencvaros y Man City-Norwich no se tocan: su contexto da numeros
-- (AVAILABLE_FROM_GOALS_FOR_AGAINST) y no afirma nada sobre historial.
--
-- ================================================================
-- 2. POR QUE EL CHAMPIONSHIP NUNCA PUDO TENER PHI
-- ================================================================
-- El dueno pregunto lo correcto: "por que no sale la tarjeta, estoy seguro que
-- datos SI tenemos". Man City 51 partidos, Norwich 28. Tiene razon en que hay
-- datos de los equipos; lo que falta es UN parametro, la fuerza de la liga.
--
-- Mirando por que el ajuste automatico nunca lo medio, aparecio esto en
-- v2.fn_fit_phi_extension:
--
--   and (lm.espn_endpoint like 'soccer/uefa.%' or ... conmebol/concacaf/afc/fifa
--        or (p_incluir_copa_domestica and ...))
--
-- Las copas domesticas solo cuentan si esa bandera esta encendida. Y
-- v2.ajustar_e_instalar_phi NI SIQUIERA TENIA EL PARAMETRO, asi que siempre
-- llamaba con el default false.
--
-- Para una segunda division eso es una condena: el Championship no juega
-- Champions League. Su UNICO puente contra ligas con phi medida son la FA Cup
-- y la EFL Cup. Excluirlas garantizaba n_usable=0 para siempre, y el log lo
-- confirma: "Championship, n_usable 0, INSUFFICIENT_SAMPLE", cada 30 minutos.
--
-- ARREGLO: ajustar_e_instalar_phi recibe y pasa la bandera, con default true.
--
-- ================================================================
-- Y AQUI ME CORRIJO A MI MISMO
-- ================================================================
-- Le dije al dueno que el Championship tenia "67 partidos contra ligas con phi
-- medida, muy por encima del umbral de 20". Ese 67 era una cuenta FLOJA: conte
-- cualquier partido en 400 dias entre un equipo del Championship y uno de liga
-- con phi.
--
-- El ajuste exige mucho mas: que el partido sea anterior al corte de
-- entrenamiento, que el equipo tenga observaciones domesticas previas a ESE
-- partido, que el rival tenga features servibles a esa fecha, y que no sean
-- los dos del mismo grupo objetivo.
--
-- Corrido de verdad con la bandera encendida:
--     v2.fn_fit_phi_extension('crossleague_v1_1', 40, 20, true)
--     -> n_usable 11, n_test 4, fit_status INSUFFICIENT_SAMPLE
--
-- ONCE, no 67. Y 11 < 20, asi que el ajuste SE SIGUE NEGANDO, y hace bien.
--
-- NO SE BAJA EL UMBRAL. Ponerlo en 11 para que pase seria fabricar el
-- resultado, que es justo lo que se ha rechazado toda la sesion. Man City vs
-- Norwich sigue sin probabilidad, y eso es lo correcto.
--
-- Lo que cambia es que ahora el Championship PUEDE llegar: pasa de 0 usables
-- estructurales a 11 reales, y cada ronda de copa que se juegue suma. Cuando
-- cruce 20 y ademas le gane a phi=0 en su propio holdout, entrara solo.
--
-- Las otras tres del dia no tienen arreglo posible y eso tambien esta medido:
--     NB I (Hungria)          2 partidos cruzados
--     Segunda Liga (Portugal) 2
--     First League (Bulgaria) 0
-- Ahi el "no se puede" es la verdad, no una excusa.

create or replace function public.contexto_sin_p_reto_coherente(p_event_id text)
returns jsonb language plpgsql stable security definer set search_path = public, v2, pg_temp as $$
declare j jsonb; sh int; sa int;
begin
  j := goles_esperados_contexto(p_event_id);
  if j is null then return null; end if;

  if (j->>'status') = 'PARCIAL_SIN_RIVAL_VERIFICABLE' then
    select sp.sample_home, sp.sample_away into sh, sa
    from v2.soccer_prediction_v2 sp
    where sp.espn_event_id = p_event_id
    order by sp.computed_at desc limit 1;

    if coalesce(sh,0) > 0 and coalesce(sa,0) > 0 then
      return null;
    end if;
  end if;

  return j;
end $$;
