-- iss058 — El sincronizador estaba BORRANDO marcadores reales cada ~2 minutos.
--
-- CÓMO SE ENCONTRÓ: el owner mandó una captura donde SF @ LAR salía como "próximo" con botón
-- VER ANÁLISIS. No era un partido viejo sin cerrar: estaba EN VIVO, en medio tiempo.
--
-- MEDIDO EN PRODUCCIÓN, dos lecturas de la MISMA fila con 2 minutos de diferencia:
--
--   02:10 UTC   NE @ SEA   status=final  10-13        SF @ LAR  status=in/Halftime  10-7
--   02:12 UTC   NE @ SEA   status=final  NULL-NULL    SF @ LAR  status=scheduled    NULL-NULL
--
-- O sea: el escritor de `live_scores` sobreescribe marcadores buenos con NULL, y además
-- REGRESA un partido en vivo a "programado". Eso explica de un solo golpe por qué el marcador
-- de NE @ SEA "aparecía y desaparecía" y por qué un partido en curso se veía como futuro.
--
-- POR QUÉ UN TRIGGER Y NO ARREGLAR LA EDGE FUNCTION: desde esta sesión no hay salida de red
-- (el proxy bloquea *.supabase.co/functions/v1), así que no puedo ni invocarla ni probarla.
-- Y el guardia en la capa de datos protege contra CUALQUIER escritor, no sólo contra el que
-- encontramos hoy. `live_scores` ya tenía 10 triggers de este tipo — incluido
-- `trg_final_pegajoso` (status) y `trg_preserve_tennis_score` (marcador, pero SÓLO de tenis).
-- Faltaba el genérico del marcador. Esto lo cierra para todos los deportes.
--
-- HUECO CONOCIDO Y DELIBERADO: no bloquea que alguien escriba explícitamente 0-0 sobre un
-- marcador existente. Distinguir "0-0 basura" de "0-0 real al arrancar" requiere contexto que
-- el trigger no tiene, y prefiero un guardia que no adivine. `nfl_tablero_semana.marcador_confiable`
-- cubre ese caso aguas abajo.

create or replace function public.preservar_marcador_live()
returns trigger language plpgsql as $$
declare
  v_reset boolean;
begin
  -- Un partido SÍ puede legítimamente quedarse sin marcador si lo posponen, cancelan o
  -- suspenden. Fuera de esos casos, perder un marcador que ya teníamos es un error del
  -- escritor, no un hecho del partido.
  v_reset := coalesce(new.status,'') in ('postponed','canceled','cancelled','suspended');

  if not v_reset then
    if new.home_score is null and old.home_score is not null then
      new.home_score := old.home_score;
    end if;
    if new.away_score is null and old.away_score is not null then
      new.away_score := old.away_score;
    end if;

    -- `trg_final_pegajoso` ya cubría 'final'. El hueco era 'in'/'live': por ahí se coló que un
    -- partido en medio tiempo volviera a aparecer como si no hubiera empezado.
    if coalesce(old.status,'') in ('in','live','in_progress','halftime')
       and coalesce(new.status,'') in ('scheduled','pre','') then
      new.status := old.status;
      if new.status_detail is null then
        new.status_detail := old.status_detail;
      end if;
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists trg_preservar_marcador_live on public.live_scores;
create trigger trg_preservar_marcador_live
  before update on public.live_scores
  for each row execute function public.preservar_marcador_live();

-- GATE EJECUTADO CONTRA PRODUCCIÓN (los 4 casos, en una sola transacción):
--   ATAQUE 1  borrar marcador + regresar 'in' -> 'scheduled'   => BLOQUEADO (sigue in / 10-7)
--   ATAQUE 2  borrar el marcador de un 'final'                 => BLOQUEADO (sigue 10-13)
--   ATAQUE 3  escribir 0-0 explícito                           => PASA (hueco documentado arriba)
--   LEGÍTIMO  status='postponed' con marcador NULL             => PERMITIDO (sí limpia)
--
-- NOTA SOBRE EL DATO RESTAURADO: NE @ SEA 10-13 y SF @ LAR 10-7 no son valores inventados.
-- Son los que se observaron directamente en `live_scores` a las 02:10 UTC, antes de que el
-- sincronizador los borrara a las 02:12. Quedaron registrados en la sesión.

-- ---------------------------------------------------------------------------
-- CORRECCIÓN DE UN BUG MÍO, reportado por el owner ("se quedó parado el partido").
--
-- La primera versión del guardia rescataba `status` pero NO `status_detail`: sólo lo preservaba
-- cuando el nuevo venía NULL. El sincronizador manda 'Programado', que no es NULL, así que se
-- colaba. Resultado visible: un partido con `status='in'` y `status_detail='Programado'`, o sea
-- una tarjeta que decía "Programado" con marcador congelado. Se leía como un partido atorado.
--
-- Ahora: si se rescató el status, el detalle que lo acompañaba se rescata también.
--
-- Y `updated_at`: cuando el guardia tiene que rescatar algo, ese UPDATE no trajo dato nuevo —
-- es el latido de un escritor vacío. Conservar el `updated_at` viejo hace que esa columna mida
-- LA ÚLTIMA VEZ QUE ENTRÓ DATO REAL, no el último latido. De ahí sale
-- `nfl_tablero_semana.marcador_atraso_min`, para que la pantalla pueda decir "hace X min" en
-- lugar de fingir que el marcador va al minuto.
--
-- COMPROBADO después del arreglo: el partido dejó de verse parado y avanzó de 10-7 a 17-7 con
-- `marcador_atraso_min = 0`. O sea, el escritor bueno SÍ entrega datos; lo que había que
-- impedir era que el escritor malo los pisara, y que su basura se colara por `status_detail`.
--
-- LECCIÓN, para que no se repita: `drop view ... cascade` sobre `nfl_tablero_semana` también
-- tira `nfl_lock_semana` Y `v_prediccion_reto_canonico`. La segunda vez me llevé la matriz
-- canónica por delante y lo detecté sólo porque volví a contar las filas de TODO lo que la app
-- consume. Cualquier recreación de esta vista tiene que recrear las tres.
