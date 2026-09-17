-- ISS197 · El linaje se cuenta; la evidencia no se hereda
--
-- EL PROBLEMA
-- La tarjeta de futbol decia, en el mercado del ganador:
--   modelo soccer_canonical_v2, n=29, SIN_VEREDICTO_MUESTRA_INSUFICIENTE
-- O sea "todavia no se sabe si funciona". Pero el mismo cerebro, bajo la
-- etiqueta anterior crossleague_v1, tenia 161 resultados calificados y era
-- CONCLUYENTEMENTE mejor que adivinar (Brier 0.6084 contra 0.6667, IC95 de
-- -0.1036 a -0.0128). La etiqueta cambio el 15 de septiembre y la evidencia se
-- quedo del otro lado.
--
-- LAS DOS SALIDAS MALAS
--   a) Heredar la evidencia y declarar probado el modelo nuevo. Eso es prestarle
--      resultados a una version que no los gano.
--   b) Dejarlo como estaba. Eso es decirle al dueno "no se sabe" cuando si se
--      sabe algo, solo que de la version anterior.
--
-- LO QUE SE HIZO: ni una ni otra. Se mide el parecido entre las dos versiones,
-- se declara el linaje, y se muestra el resultado de la anterior ETIQUETADO como
-- lo que es, con la advertencia pegada. El veredicto de la version actual sigue
-- ganandose con los resultados de la version actual.
--
-- EL PARECIDO, MEDIDO (no asumido), sobre los 159 partidos que tienen prediccion
-- bajo las dos etiquetas:
--   predicciones identicas dentro de 0.05 pp:   91 de 159
--   diferencia media en p_home:               1.352 pp
--   diferencia maxima en p_home:              16.30 pp
--   diferencia media en lambda:               0.0381
-- Es el mismo cerebro con insumos y cobertura refrescados, NO una familia
-- distinta. Pero 68 de 159 partidos cambiaron y uno cambio 16.3 pp: por eso el
-- veredicto no se hereda.

create table if not exists v2.modelo_linaje (
  model_version text primary key,
  predecesor text not null,
  medido_at timestamptz not null default now(),
  parecido jsonb not null default '{}'::jsonb,
  nota text not null
);
comment on table v2.modelo_linaje is
'ISS197. Declara que una version de modelo desciende de otra, con la MEDICION del parecido entre las dos. Sirve para una sola cosa: poder contarle al dueno que la version anterior de este mismo cerebro si tenia resultados, SIN usar esos resultados como veredicto de la version actual. La evidencia NO se hereda. El veredicto de una version se gana con los resultados de esa version.';

-- (fila insertada: soccer_canonical_v2 <- crossleague_v1, con el parecido medido)

-- public.fn_evidencia_mercado gana un bloque 'linaje' que SOLO aparece cuando la
-- version actual NO tiene veredicto y el predecesor SI tiene resultados. Trae el
-- n, el Brier, el intervalo, el veredicto de la anterior, el parecido medido y
-- una advertencia explicita de que eso no es el veredicto de lo que estas viendo.

-- ===========================================================================
-- VERIFICACION EJECUTADA (2026-09-17), tarjeta de futbol, mercado ganador:
--   n de esta version:        29
--   veredicto de esta version: SIN_VEREDICTO_MUESTRA_INSUFICIENTE
--   linaje.version_anterior:   crossleague_v1
--   linaje.n:                  161
--   linaje.veredicto:          MEJOR_QUE_ADIVINAR_CONCLUYENTE
--   linaje.advertencia:        presente, con el parecido medido adentro
-- Gates: 118 PASS, 31 INFO, 17 FAIL (sin cambios: nada se rompio).
-- ===========================================================================
