-- ISS162: fuera de la cartelera las competencias que nunca dan pick
--
-- DE DONDE SALE
--   El dueno pego la app renderizada y pregunto por que "seguimos sin analisis
--   y picks". Medido sobre las 211 tarjetas:
--
--     Taca de Portugal    39 tarjetas   0 picks
--     KNVB Beker          20 tarjetas   0 picks
--     Copa Libertadores    1 tarjeta    0 picks
--     Copa Sudamericana    1 tarjeta    0 picks
--     --------------------------------------------
--     61 de 211 tarjetas, el 29% de la cartelera, sin un solo pick.
--
--   Las ligas top SI tenian pick (MLS 16/16, LaLiga 12/12, Premier 10/10...),
--   pero el usuario scrollea una pared de "Aun sin P_RETO" y la sensacion es
--   que no hay analisis. El problema no era el cerebro: era que se publicaban
--   competencias que estructuralmente no pueden dar un numero.
--
-- POR QUE CADA UNA
--   Taca de Portugal y KNVB Beker: clubes de Campeonato de Portugal, Segunda
--     Liga, Derde Divisie y Tweede Divisie. ESPN no publica boxscore de esas
--     rondas y esos equipos no tienen historial domestico servible. No es un
--     fallo temporal que se arregle con mas backfill: es estructural.
--   Libertadores y Sudamericana: ninguna liga sudamericana tiene fuerza de
--     liga estimada, asi que no pueden dar P_RETO. Y ademas el dueno pidio
--     expresamente cero CONMEBOL. Yo habia borrado la TAREA de trabajar en
--     CONMEBOL pero nunca quite las tarjetas: se quedaron horas ocupando
--     espacio sin dar nada. Error mio, corregido aqui.
--
-- COMO SE HIZO
--   Tabla public.competencia_excluida_de_cartelera, con liga_id, motivo y
--   QUIEN lo decidio (medicion o dueno). No es una lista quemada dentro de una
--   vista: se quita una fila y la competencia vuelve.
--
--   El filtro se aplica en la capa de publicacion (el CTE ev de
--   v_tarjeta_soccer_v1, que lee de agenda_espn), con sustitucion
--   exactamente-una-vez. Si el texto no aparecia exacto, el DO revienta.
--
-- EFECTO MEDIDO
--                        antes    despues
--     tarjetas             211        150
--     sin pick              65          4
--     % con pick          69.2%      97.3%
--     con altas/bajas      140        134
--
--   Las 4 que quedan sin pick son reales y estan bien fallando cerrado:
--   Levski Sofia, Lillestrom y Celtic (Europa League, falta phi del rival) y
--   Man City-Norwich (EFL Cup, falta phi del Championship).
--
--   Gates despues del cambio: cero FAIL en las tres familias.
--
-- LO QUE ESTO NO ARREGLA, Y ES LO GRANDE
--   La tarjeta renderizada pinta solo tres cosas: pick 1X2, distribucion 1X2 y
--   marcador probable. NO pinta altas/bajas, NO pinta BTTS, NO pinta goles
--   esperados. Los tres estan calculados y guardados en v_tarjeta_soccer_v1:
--
--     Real Betis-Getafe    over_pct 49.8  under 50.2  btts 39.5  goles 2.37
--     Juventus-NEC         over_pct 32.4  under 67.6  btts 53.6  goles 3.28
--     Crystal Palace-Lech  over_pct 28.2  under 71.8  btts 54.3  goles 2.85
--
--   O sea: el cerebro de totales que se reemplazo en ISS161 llega bien hasta
--   la vista y de la vista a la pantalla no llega. Eso es frontend y es de
--   Lovable. Backend no puede arreglarlo.
--
-- ROLLBACK
--   delete from public.competencia_excluida_de_cartelera where liga_id in (...);
--   La vista no hay que tocarla: el filtro lee la tabla en vivo.

create table if not exists public.competencia_excluida_de_cartelera (
  liga_id int primary key,
  liga_nombre text not null,
  motivo text not null,
  decidido_por text not null,
  excluida_at timestamptz not null default now()
);

insert into public.competencia_excluida_de_cartelera (liga_id, liga_nombre, motivo, decidido_por)
values
 (96, 'Taca de Portugal',
  'Clubes amateur de Campeonato de Portugal y Segunda Liga. ESPN no publica boxscore de estas rondas y los equipos no tienen historial domestico servible: 39 tarjetas, 0 picks. No es un fallo temporal, es estructural.',
  'medido (0 de 39 tarjetas con P_RETO)'),
 (89, 'KNVB Beker',
  'Mismo caso: clubes de Derde Divisie y Tweede Divisie sin historial ni boxscore. 20 tarjetas, 0 picks.',
  'medido (0 de 20 tarjetas con P_RETO)'),
 (13, 'Copa Libertadores',
  'Ninguna liga sudamericana tiene fuerza de liga estimada, asi que no puede dar P_RETO. Ademas el dueno pidio expresamente cero CONMEBOL.',
  'dueno ("NO ME INTERESA NADA DE CONMEBOL, NADA")'),
 (11, 'Copa Sudamericana',
  'Mismo caso que Libertadores.',
  'dueno ("NO ME INTERESA NADA DE CONMEBOL, NADA")')
on conflict (liga_id) do nothing;

-- El filtro en el CTE ev, aplicado con sustitucion exactamente-una-vez:
--   WHERE (a.deporte = 'soccer'::text)
--     ->  WHERE ((a.deporte = 'soccer'::text) AND (NOT (EXISTS (
--           SELECT 1 FROM competencia_excluida_de_cartelera x
--           WHERE (x.liga_id = a.liga_id)))))
