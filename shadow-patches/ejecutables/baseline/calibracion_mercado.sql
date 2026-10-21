-- baseline/calibracion_mercado.sql
-- VOLCADO INTEGRO. Estado de produccion al 2026-09-12.
-- Parte del cierre transitivo de la ruta de decision. No tenia definicion en Git.
--
-- NOTA DE LECTURA, Y UNA ADVERTENCIA:
--   Esta vista mide WR y ROI REALES por (mercado_norm, rango_momio) sobre
--   resultados YA LIQUIDADOS (resultado in ganado/perdido). Medir el pasado
--   esta permitido por el candado del dueno.
--   PERO la columna prob_observada mezcla el conteo de ganados con
--   40 * avg(1.0/momio_mercado): un prior de 40 observaciones tomado de la
--   PROBABILIDAD IMPLICITA DEL PRECIO. O sea, aqui el precio entra como prior
--   bayesiano de una probabilidad. ISS107 lo detecto por la FAMILIA FORMA
--   (1/momio) y lo dejo registrado. No se toca aqui: cambiarlo mueve una
--   probabilidad y eso es cutover de modelo, congelado.

create or replace view public.calibracion_mercado as
 WITH base AS (
         SELECT mercado_normalizado((COALESCE(oraculo_picks_tracking.mercado, ''::text) || ' '::text) || COALESCE(oraculo_picks_tracking.pick_nombre, ''::text)) AS mercado_norm,
            rango_de_momio(oraculo_picks_tracking.momio_mercado) AS rango_momio,
            oraculo_picks_tracking.resultado,
            oraculo_picks_tracking.momio_mercado
           FROM oraculo_picks_tracking
          WHERE (oraculo_picks_tracking.resultado = ANY (ARRAY['ganado'::text, 'perdido'::text])) AND oraculo_picks_tracking.momio_mercado IS NOT NULL AND oraculo_picks_tracking.momio_mercado > 1.01
        )
 SELECT mercado_norm,
    rango_momio,
    count(*)::integer AS muestra,
    round(100.0 * count(*) FILTER (WHERE resultado = 'ganado'::text)::numeric / count(*)::numeric, 2) AS wr_real,
    round(sum(
        CASE
            WHEN resultado = 'ganado'::text THEN momio_mercado - 1::numeric
            ELSE '-1'::integer::numeric
        END), 2) AS unidades_netas,
    round(100.0 * sum(
        CASE
            WHEN resultado = 'ganado'::text THEN momio_mercado - 1::numeric
            ELSE '-1'::integer::numeric
        END) / count(*)::numeric, 2) AS roi_real_pct,
    round((count(*) FILTER (WHERE resultado = 'ganado'::text)::numeric + 40::numeric * avg(1.0 / momio_mercado)) / (count(*) + 40)::numeric, 4) AS prob_observada,
    count(*) >= 40 AS confiable
   FROM base
  GROUP BY mercado_norm, rango_momio;
