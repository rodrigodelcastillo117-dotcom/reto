-- ISS149: por que NRFI/YRFI no sale en la app. Respuesta medida, no de memoria.
--
-- EL DUENO RECLAMO: "sigue sin salir NRFI O YRFI, Over o Under de las lineas de
-- las carreras, el ML si esta en MLB".
--
-- LO PRIMERO: TENIA RAZON, Y LA CAUSA ES QUE NO EXISTEN.
-- public.v_mlb_publication_v1, que es el contrato publicado de MLB, tiene
-- exactamente estas columnas de probabilidad:
--     p_home_pct, p_away_pct, canonical_pick, canonical_probability_pct
-- Solo moneyline. No hay NRFI, ni YRFI, ni totales de carreras. No es que la
-- app no los pinte: no estan en el contrato porque no hay modelo medido.
--
-- HAY DATOS PARA INTENTARLO
--   v2.lab_mlb_inning_features_v1 ... 7063 juegos, 3 temporadas (2024-2026)
--   con carreras de la primera entrada por equipo y splits rodantes as-of.
--   Verificada la seguridad temporal: con h_n=0 (primer juego de temporada) los
--   features son NULL, o sea NO contienen el partido que se quiere predecir.
--
--   Tasa base NRFI:  2024 53.74% | 2025 50.02% | 2026 50.00%
--
-- ============================================================================
-- INTENTO 1: POISSON SOBRE MEDIAS DE CARRERAS -- FALLO, Y ENSENA ALGO
-- ============================================================================
--   P(NRFI) = exp(-(lambda_local + lambda_visita))
--   Brier modelo 0.27397 contra constante 0.24965 en entrenamiento. PEOR.
--   Media predicha 0.3708 contra tasa real 0.5188: sesgo de 14.8 puntos.
--
--   LA RAZON: las carreras por entrada NO son Poisson, estan infladas en cero.
--   Una entrada o va 1-2-3 o se abre. Con lambda=0.5187, exp(-0.5187)=0.595 por
--   equipo, pero la tasa REAL de primera entrada en blanco es 0.7142.
--   0.7142^2 = 0.5101, que si cuadra con el 0.519 observado.
--   => La media de carreras es el feature equivocado. La tasa de entrada en
--      blanco es la escala correcta.
--
-- ============================================================================
-- INTENTO 2: TASA DE PRIMERA ENTRADA EN BLANCO POR EQUIPO -- CONCLUYENTE: NO SIRVE
-- ============================================================================
--   Features construidos desde cero con ventanas as-of (solo partidos
--   anteriores de la misma temporada, el actual excluido por
--   "rows between unbounded preceding and 1 preceding").
--
--   Calibracion: arreglada (media predicha 0.514 contra real 0.519).
--   k optima: 200. O sea el ajuste pide ENCOGER CASI TODO hacia la media de
--   liga, que es la forma que tiene el modelo de decir "estos features no
--   aportan".
--
--   HOLDOUT 2026 (2202 juegos, sin tocar durante el ajuste):
--     correlacion ....... 0.0145
--     delta Brier ....... -0.000228
--     IC95 .............. [-0.001248, +0.000791]   CRUZA EL CERO
--
--   VEREDICTO: no se distingue de decir "50%". Publicarlo seria vender un
--   volado como analisis.
--
-- ============================================================================
-- INTENTO 3: FIP DE LOS ABRIDORES -- SENAL REAL, MUESTRA INSUFICIENTE
-- ============================================================================
--   La senal de NRFI esta en el PITCHER ABRIDOR, no en el equipo.
--   public.lab_mlb_wf trae home_pitcher_fip y away_pitcher_fip por juego.
--
--   Sobre 909 juegos cruzados:
--     corr(NRFI, FIP sumado) .. -0.0764   (signo correcto: peor FIP, menos NRFI)
--     corr(NRFI, ERA sumado) .. -0.0414   (FIP mejor que ERA, como se espera)
--     contra 0.0299 del historial de equipo
--
--   Modelo lineal sobre la suma de FIP, ajustado en los primeros 7 deciles de
--   tiempo, probado en los ultimos 3:
--     beta .............. -0.01745 por punto de FIP
--     HOLDOUT (272 juegos)
--       correlacion ..... 0.1269     (8.7x la del historial de equipo)
--       delta Brier ..... -0.002594  (mejor)
--       IC95 ............ [-0.005308, +0.000120]   TOCA EL CERO POR 0.00012
--
--   VEREDICTO: prometedor pero NO concluyente. Le falta MUESTRA, no senal.
--
-- ============================================================================
-- EL BLOQUEO, CONCRETO
-- ============================================================================
--   Solo 909 de 7063 juegos (13%) tienen FIP de los dos abridores.
--   public.mlb_player_game_logs con is_pitcher: 2132 filas, 185 pitchers,
--   1162 juegos, y SOLO temporada 2026 (2026-03-26 a 2026-09-16).
--   public.mlb_pitcheo_juego: 1 fila. public.mlb_probable_pitcher_enrichment_v1: 1 fila.
--
--   No falta modelo. Falta INGESTA HISTORICA DE ABRIDORES para 2024-2025 y
--   completar 2026. El cron 'mlb-linescore-backfill' ya baja linescores de esas
--   temporadas, asi que el camino existe; lo que no se esta pidiendo es el
--   abridor de cada juego.
--
--   Con los 7063 juegos en vez de 909 la muestra se multiplica por 7.8 y el
--   intervalo probablemente se despega del cero. Pero eso hay que MEDIRLO
--   despues de tener los datos, no asumirlo.
--
-- ============================================================================
-- QUE SE HIZO EN PRODUCCION
-- ============================================================================
-- NADA que publique un mercado nuevo. Se creo v2.evidencia_mercado_candidato
-- con las dos mediciones, para que la decision quede auditable y se pueda
-- volver a correr cuando haya mas datos. NRFI sigue sin publicarse, que es lo
-- correcto mientras el intervalo toque el cero.

create table if not exists v2.evidencia_mercado_candidato (
  id bigserial primary key,
  mercado text not null,
  variante text not null,
  n_entrenamiento int, n_holdout int,
  correlacion numeric, brier_modelo numeric, brier_constante numeric,
  delta_brier numeric, ic95_inferior numeric, ic95_superior numeric,
  veredicto text not null,
  bloqueo text,
  medido_at timestamptz default now(),
  notas text
);
-- (las dos filas de MLB_NRFI se insertaron en produccion; ver el commit)
