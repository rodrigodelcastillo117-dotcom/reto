-- =====================================================================
-- ISS126 : LOS PICKS DE CORNERS SE CALIFICABAN CON EL TOTAL DE GOLES
-- =====================================================================
-- Hallazgo de la auditoria adversarial, confirmado por su esceptico y
-- re-confirmado hoy antes de tocar nada:
--
--   129 picks de mercado 'Corners' calificados como ganado/perdido.
--   129 de 129 coinciden EXACTAMENTE con el resultado que daria comparar
--   la linea de corners contra el TOTAL DE GOLES del partido.
--   Coincidencia 100%: es deterministico, no es casualidad estadistica.
--
-- Traduccion: el historial le decia al usuario que gano o perdio una
-- apuesta de tiros de esquina segun cuantos GOLES hubo.
--
-- COMPROBACION DE DINERO ANTES DE TOCAR:
--   user_apostado = 0 en los 129. Nadie aposto ninguno de verdad.
--   retorno es de seguimiento, no sale del bankroll.
--   => corregir el historial NO mueve dinero real. Aun asi, el retorno de
--      cada fila corregida se pone en NULL en vez de recalcularlo, para no
--      inventar una economia que no me consta.
--
-- =====================================================================
-- 1. LA FUENTE REAL DE CORNERS
-- =====================================================================
-- Devuelve NULL si no tenemos corners de ese evento. No se inventa.
create or replace function public.corners_totales_del_evento(p_espn_event_id text)
returns int language sql stable as $fn$
  select d.corners_home + d.corners_away
  from public.detalle_partido_espn d
  where d.espn_event_id = p_espn_event_id
    and d.corners_home is not null and d.corners_away is not null
  limit 1;
$fn$;

-- Lee la linea y el lado del texto del pick. Formatos REALES medidos en la
-- tabla, no supuestos:
--   "[PICK DE VALOR] Corners Over 9"      -> linea 9,    over
--   "[PICK DE VALOR] Corners Under 3.5"   -> linea 3.5,  under
--   "[ALTA PROBABILIDAD] Over 9.5 Corners"-> linea 9.5,  over
create or replace function public.corners_lee_pick(p_desc text)
returns table(linea numeric, es_over boolean) language sql immutable as $fn$
  select nullif((regexp_match(p_desc, '([0-9]+(?:\.[0-9]+)?)'))[1],'')::numeric,
         (p_desc ~* '\mover\M' or p_desc ~* 'm[aá]s de');
$fn$;

-- =====================================================================
-- 2. RASTRO FORENSE
-- =====================================================================
-- Se guarda el valor ANTERIOR de cada fila corregida antes de tocarla.
create table if not exists public.corners_recalificacion (
  pick_id uuid primary key,
  espn_event_id text,
  pick_desc text,
  linea numeric,
  es_over boolean,
  corners_home int,
  corners_away int,
  corners_total int,
  resultado_antes text,
  retorno_antes numeric,
  resultado_nuevo text,
  motivo text not null,
  aplicado_at timestamptz not null default now()
);
revoke all on public.corners_recalificacion from anon, authenticated;

alter table public.oraculo_picks_tracking
  add column if not exists recalificacion_motivo text,
  add column if not exists recalificado_at timestamptz;

-- =====================================================================
-- 3. LA REGLA, CON PUSH
-- =====================================================================
-- Detalle que casi se me pasa: hay lineas ENTERAS (Over 9, Under 7) donde
-- el total exacto es PUSH, y lineas .5 donde no puede haberlo. Mi primer
-- diagnostico trataba la igualdad como derrota y por eso conto 45 errores;
-- con push bien manejado son 48.
--
--   corners = linea            -> 'nulo'   (push)
--   over  y corners > linea    -> 'ganado'
--   over  y corners < linea    -> 'perdido'
--   under y corners < linea    -> 'ganado'
--   under y corners > linea    -> 'perdido'
--   sin corners reales         -> 'nulo' + motivo explicito
--
-- =====================================================================
-- 4. RESULTADO MEDIDO (2026-09-16)
-- =====================================================================
--   129 picks de Corners calificados al empezar
--    81 tenian corners reales en detalle_partido_espn
--    48 no los tenian
--
--   RUN 1: 96 filas corregidas
--       43 recalificadas con corners reales
--        5 resultaron PUSH (el total iguala la linea exacta)
--       48 anuladas por falta de datos, con motivo escrito
--   RUN 2: 0 cambios  <- idempotente
--
--   De las 81 verificables, 48 estaban mal: 25 marcadas GANADO que no lo
--   eran y 23 marcadas PERDIDO que no lo eran. 59% de error.
--
-- LO QUE **NO** TOQUE, y queda reportado:
--   7 picks de Corners ya estaban en 'nulo' antes de esta corrida
--   (recalificado_at IS NULL). De esos, 5 SI tienen corners reales y se
--   podrian resolver. No los toco porque no se por que se anularon, y
--   convertir un anulado en calificado es una decision distinta que no me
--   toca tomar sola.
-- =====================================================================
