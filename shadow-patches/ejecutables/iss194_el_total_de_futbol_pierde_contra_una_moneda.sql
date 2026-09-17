-- ISS194 · El total de futbol pierde contra una moneda, y yo lo habia leido mal
--
-- ===========================================================================
-- ESTABA EQUIVOCADO
-- ===========================================================================
-- En ISS191 escribi que la lambda del crossleague "gana en totales". Lo que gane
-- fue una comparacion entre DOS CANDIDATOS: lambda de crossleague 0.23952 contra
-- lambda de tiros 0.24338, sobre 175 partidos, y encima como resultado secundario
-- de una prueba cuyo primario era 1X2. Nunca la compare contra ADIVINAR.
-- Ganarle al otro candidato no es ganarle a una moneda.
--
-- La evidencia hacia adelante, que es la que manda, dice otra cosa. Sobre los
-- MISMOS 152 partidos ya calificados en vivo, con el baseline de dos salidas
-- (Brier de adivinar = 0.5):
--
--   p_over guardado pasado por calibracion   Brier 0.5436   IC95 [0.0065, 0.0808]
--   lambda del crossleague + Poisson (ISS191) Brier 0.5424  IC95 [0.0057, 0.0792]
--
-- En los dos casos el intervalo del 95% queda ENTERO por encima de cero: los dos
-- son concluyentemente peores que adivinar. El camino "nuevo" de ISS191 no
-- arreglo nada, mejoro 0.0012 y siguio perdiendo.
--
-- La regla de la casa, la misma que vigila G32.2, es que nada publicado puede ser
-- concluyentemente peor que adivinar. Asi que el mercado de altas y bajas de
-- futbol se RETIRA de la tarjeta. No se maquilla, no se acompana de una nota
-- chiquita, no se deja "informativo". Se cae.
--
-- El ganador (1X2) y el ambos anotan NO se tocan: su evidencia es otra y se mide
-- aparte. 1X2 de crossleague mide 0.6084 contra 0.6667 de adivinar, mejor.
--
-- ===========================================================================
-- COMO SE DESTAPO
-- ===========================================================================
-- Persiguiendo el FAIL de G32.2 se encontro que v2.refresh_model_learning
-- capturaba la evidencia de Over/Under con soccer_ou_calibrado, o sea el camino
-- RETIRADO, mientras la tarjeta publicaba fn_ou_desde_lambda desde ISS191. El
-- vigilante estaba midiendo algo que nadie veia. Al corregir la captura para que
-- midiera lo que de verdad se publica, el veredicto salio solo.
--
-- Y de paso se encontraron dos contradicciones mas en la propia tarjeta:
--   1. over_pct (linea real) salia de la lambda, pero over25_norm_pct seguia
--      saliendo del camino calibrado: la misma tarjeta mostraba 58.2% y 56.4%
--      para la misma pregunta en 69 de 132 casos.
--   2. La tarjeta universal declaraba el modelo de totales como "ou_tiros_v1"
--      con la evidencia de los 1080 partidos de los tiros, cuando el numero lo
--      producia el crossleague. Declaraba un cerebro y servia otro.
-- Las dos quedan cerradas aqui, aunque el mercado se retire igual.

-- ---------------------------------------------------------------------------
-- 1. Registro de mercados retirados. La evidencia mala NO se borra nunca; deja
--    de atribuirsele a algo que la app ya no sirve.
-- ---------------------------------------------------------------------------
create table if not exists v2.mercado_retirado (
  model_version text not null,
  market text not null,
  retirado_at timestamptz not null default now(),
  motivo text not null,
  evidencia jsonb not null default '{}'::jsonb,
  reemplazado_por text,
  primary key (model_version, market)
);
comment on table v2.mercado_retirado is
'ISS194. Registro de pares (modelo, mercado) que YA NO se publican. Existe para que la evidencia mala no se borre nunca y al mismo tiempo no se le atribuya a algo que la app ya no sirve. Un par aqui sale de G32.2 (nada publicado puede ser peor que adivinar) y entra a G32.6, que lo lista con su motivo a la vista.';

-- (filas insertadas: crossleague_v1/Over-Under reemplazado por el poisson;
--  crossleague_v1_ou_poisson y soccer_canonical_v2_ou_poisson SIN reemplazo,
--  con su evidencia y con la confesion del error de lectura de ISS191.)

-- ---------------------------------------------------------------------------
-- 2. La captura mide lo que se publica, con nombre propio
--    v2.refresh_model_learning: la rama SOCCER_V2 de Over/Under pasa de
--    soccer_ou_calibrado(p_over,...) a fn_ou_desde_lambda(lambda_home,
--    lambda_away, over_line) y etiqueta con model_version||'_ou_poisson'.
--    Las 152 filas viejas quedan intactas bajo crossleague_v1: son el registro
--    honesto de lo que el camino retirado hizo.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 3. La tarjeta deja de publicar totales
--    v_tarjeta_soccer_v1_calculo: over_pct, under_pct, over25_norm_pct y
--    under25_norm_pct pasan a NULL, y se refresca tarjeta_soccer_cache.
--    Antes de retirarlo se habia corregido over25_norm_pct para que saliera de
--    la misma lambda; esa correccion queda en el historial aunque el campo hoy
--    sea nulo, porque el dia que el mercado vuelva tiene que volver coherente.
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- 4. Gates alineados al contrato nuevo
--    G30.5  ya no exige over_pct cuando el mercado esta retirado sin reemplazo.
--    G30.7  contrasta el publicado contra la unica lambda (ISS191), no contra
--           el camino calibrado.
--    G30.11 NUEVO: si el mercado esta retirado sin reemplazo, ninguna tarjeta
--           puede publicar altas ni bajas. FAIL si alguna lo hace.
--    G32.2  ignora los pares registrados como retirados (ya no se publican).
--    G32.6  NUEVO, INFO: lista los retirados con su motivo, para que la
--           evidencia mala quede a la vista y no escondida.
--    G33.9  ahora exige coherencia entre las tres cosas: lo que la tarjeta
--           muestra, lo que la captura mide y lo que el registro declara.
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- VERIFICACION EJECUTADA (2026-09-17)
--
-- gate_tarjetas_soccer:        11 subgates, 0 FAIL (1 INFO de cobertura)
-- gate_calibracion_y_ligas:    0 FAIL
-- gate_evidencia_hacia_adelante: 0 FAIL
-- Tarjetas: 138 | 138 con ganador y BTTS | 126 con linea real | 0 con totales
-- Contradiccion over_pct contra over25_norm_pct: 69 casos -> 0, dif maxima 0.000
--
-- Total de gates del sistema: 25 FAIL -> 23 FAIL. Los 23 que quedan son deuda
-- de superficies viejas (precio que decide en funciones legacy, RLS de tablas de
-- laboratorio, linaje de modelos) y patas de tenis que nunca se pudieron
-- calificar. Ninguno de esos toca la tarjeta que el dueno ve.
-- ===========================================================================
