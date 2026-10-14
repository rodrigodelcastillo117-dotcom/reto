-- =====================================================================
-- ISS112  UN PARLAY NO PUEDE PERDER SI NINGUNA PATA PERDIO
-- =====================================================================
-- EL CASO
--   parlay 861b03b9-4b16-4f21-9841-327a1feb4dcf
--     resultado      = 'perdido'
--     ganancia_neta  = -250.00   <- la plata YA se movio
--     manual_override = false    <- no fue un arreglo a mano, fue el pipeline
--     16 patas:  4 ganadas, 3 nulas, 9 PENDIENTES, 0 perdidas
--     las 9 pendientes son TODAS de tenis
--
--   Un parlay perdido sin una sola pata perdida es aritmeticamente imposible.
--   Y se cobro.
--
-- LA SECUENCIA, RECONSTRUIDA DEL CODIGO
--   1. Las patas de tenis se calificaron en algun momento desde live_scores,
--      que para tenis marca 'final' con marcador 0-0 porque el resultado de
--      tenis vive en sets y juegos, no en el marcador. (Hay 170 filas de tenis
--      en live_scores con final 0-0.)
--   2. cerrar_parlays_con_pata_perdida() vio perdidas > 0 y cerro:
--        SET resultado='perdido', ganancia_neta = -COALESCE(apuesta,0)
--   3. Despues, la GUARDA DE TENIS de sync_resultados_legs_parlay
--      (lineas 123-131: "un final con 1-0 o 1-1 en sets NO decide nada")
--      reevaluo esas patas, vio que los sets no prueban un final de verdad y
--      las devolvio a 'pendiente'. La funcion si permite reevaluar una pata ya
--      calificada: linea 27, if v_estado_actual in ('ganado','perdido').
--   4. El parlay quedo 'perdido' con -250 cobrados y cero patas perdidas.
--
--   LA GUARDA DE TENIS ESTA BIEN. El hueco es otro: cerrar un parlay es
--   irreversible, pero la evidencia que lo cerro si puede desaparecer. Nadie
--   reabre el parlay cuando eso pasa.
--
-- LIMITE DE LA RECONSTRUCCION, Y UNA CULPA MIA
--   No puedo fechar el cierre. Las tres filas incoherentes tienen
--   updated_at = 2026-09-12 14:21:40 identico: fue MI backfill de
--   picks_calificacion de hoy, que toco todas las filas y piso la marca
--   temporal original. Ademas ese backfill reescribio picks_calificacion
--   derivandola de picks_data, asi que si esa columna guardaba la pata
--   perdida original, yo borre ese rastro. No hay bitacora de cambios en
--   parlays. La SECUENCIA la sostengo porque esta en el codigo; las FECHAS no
--   las puedo probar.
--
-- LO QUE NO HAGO
--   No devuelvo los -250. El dueno prohibio el arreglo manual de dinero y de
--   calificacion como solucion, y revertir un cobro es una operacion de
--   dinero: la decide el. Aqui se instala el invariante para que no vuelva a
--   pasar y se deja el caso medido y visible.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) LAS CUATRO FORMAS DE INCOHERENCIA
-- ---------------------------------------------------------------------
create or replace view public.v_parlay_incoherente as
with l as (
  select p.id, p.resultado, p.ganancia_neta, p.manual_override,
         count(*)                                                                   total,
         count(*) filter (where lower(coalesce(x->>'resultado','')) = 'perdido')     perdidos,
         count(*) filter (where lower(coalesce(x->>'resultado','')) = 'ganado')      ganados,
         count(*) filter (where lower(coalesce(x->>'resultado','')) = 'nulo')        nulos,
         count(*) filter (where lower(coalesce(x->>'resultado','pendiente')) = 'pendiente') pendientes
  from public.parlays p, jsonb_array_elements(p.picks_data) x
  where jsonb_typeof(p.picks_data) = 'array'
  group by p.id, p.resultado, p.ganancia_neta, p.manual_override
)
select l.*, z.invariante
from l
join lateral (
  select unnest(array_remove(array[
    case when l.resultado = 'perdido' and l.perdidos = 0
         then 'PERDIDO_SIN_LEG_PERDIDO' end,
    case when l.resultado = 'ganado' and l.perdidos > 0
         then 'GANADO_CON_LEG_PERDIDO' end,
    case when l.resultado = 'ganado' and l.pendientes > 0
         then 'GANADO_CON_LEGS_PENDIENTES' end,
    case when l.resultado <> 'pendiente' and l.pendientes > 0 and l.perdidos = 0
         then 'CERRADO_CON_LEGS_PENDIENTES_Y_SIN_PERDIDA' end
  ], null)) as invariante
) z on true;

comment on view public.v_parlay_incoherente is
'ISS112. Un parlay cuyo resultado contradice a sus propias patas. PERDIDO_SIN_LEG_PERDIDO es el grave: significa que se cobro una perdida que las patas no respaldan.';

-- ---------------------------------------------------------------------
-- 2) BITACORA DE CIERRES RECHAZADOS
-- ---------------------------------------------------------------------
create table if not exists public.parlay_cierre_rechazado (
  id            bigserial primary key,
  parlay_id     uuid        not null,
  resultado_intentado text  not null,
  evidencia     jsonb       not null,
  rechazado_at  timestamptz not null default now()
);

comment on table public.parlay_cierre_rechazado is
'ISS112. Cada intento de cerrar un parlay como perdido sin una sola pata perdida. Si esta tabla crece, el calificador que la llena es el que hay que arreglar.';

-- ---------------------------------------------------------------------
-- 3) LA GUARDA
--    Falla cerrado hacia el lado que NO mueve dinero: el parlay se queda
--    pendiente en vez de cobrarse una perdida sin respaldo.
--    No levanta excepcion: abortaria el lote del calificador.
-- ---------------------------------------------------------------------
create or replace function public.tg_parlay_no_pierde_sin_pata_perdida()
returns trigger language plpgsql as $fn$
declare v_perdidos int; v_pendientes int; v_total int;
begin
  if NEW.resultado is distinct from 'perdido' then return NEW; end if;
  if TG_OP = 'UPDATE' and OLD.resultado = 'perdido' then return NEW; end if;  -- ya estaba asi
  if jsonb_typeof(NEW.picks_data) <> 'array' then return NEW; end if;

  select count(*),
         count(*) filter (where lower(coalesce(x->>'resultado','')) = 'perdido'),
         count(*) filter (where lower(coalesce(x->>'resultado','pendiente')) = 'pendiente')
    into v_total, v_perdidos, v_pendientes
  from jsonb_array_elements(NEW.picks_data) x;

  if v_total > 0 and v_perdidos = 0 then
    insert into public.parlay_cierre_rechazado (parlay_id, resultado_intentado, evidencia)
    values (NEW.id, 'perdido',
            jsonb_build_object('legs_total', v_total,
                               'legs_perdidos', v_perdidos,
                               'legs_pendientes', v_pendientes,
                               'ganancia_neta_intentada', NEW.ganancia_neta,
                               'por_que', 'ninguna pata perdio: cobrar la perdida seria mover dinero sin respaldo'));

    -- se rechaza el cierre hacia el lado que no mueve dinero
    NEW.resultado := coalesce(case when TG_OP='UPDATE' then OLD.resultado end, 'pendiente');
    if TG_OP = 'UPDATE' then
      NEW.ganancia_neta := OLD.ganancia_neta;
    else
      -- En INSERT no hay valor anterior al que volver. La primera version solo
      -- devolvia resultado a 'pendiente' y dejaba la ganancia_neta negativa:
      -- un parlay pendiente cargando un cobro. Lo atrapo la prueba adversarial,
      -- en el detalle de un error de NOT NULL. Se anula tambien el monto.
      NEW.ganancia_neta := null;
    end if;
  end if;

  return NEW;
end;
$fn$;

comment on function public.tg_parlay_no_pierde_sin_pata_perdida() is
'ISS112. Impide cerrar un parlay como perdido sin una sola pata perdida. Falla hacia el lado que NO mueve dinero: el parlay se queda pendiente. No levanta excepcion porque abortaria el lote del calificador; deja el intento registrado con su evidencia.';

-- zzzz_ para correr despues de los demas disparadores BEFORE, igual que
-- tg_derivar_picks_calificacion, y tener la ultima palabra sobre resultado.
drop trigger if exists zzzzz_parlay_no_pierde_sin_pata_perdida on public.parlays;
create trigger zzzzz_parlay_no_pierde_sin_pata_perdida
  before insert or update on public.parlays
  for each row execute function public.tg_parlay_no_pierde_sin_pata_perdida();

-- ---------------------------------------------------------------------
-- 4) GATE
-- ---------------------------------------------------------------------
create or replace function public.gate_parlay_coherente()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  select 'PARLAY_PERDIDO_SIN_LEG_PERDIDO'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(id::text || ' (' || coalesce(ganancia_neta::text,'sin monto') || ')', ', '),
                  'ninguno')
  from public.v_parlay_incoherente where invariante = 'PERDIDO_SIN_LEG_PERDIDO'
  union all
  select 'PARLAY_CERRADO_CON_LEGS_PENDIENTES'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(id::text || ' [' || resultado || ', ' || pendientes || ' pendientes]', ', '),
                  'ninguno')
  from public.v_parlay_incoherente
  where invariante = 'CERRADO_CON_LEGS_PENDIENTES_Y_SIN_PERDIDA'
  union all
  select 'DINERO_COBRADO_SIN_RESPALDO'::text,
         case when coalesce(sum(ganancia_neta),0) = 0 then 'PASS' else 'FAIL' end,
         count(*),
         'suma de ganancia_neta de parlays perdidos sin pata perdida: '
           || coalesce(sum(ganancia_neta)::text, '0')
           || '. Revertir un cobro es operacion de dinero: la decide el dueno, no este parche.'
  from public.v_parlay_incoherente
  where invariante = 'PERDIDO_SIN_LEG_PERDIDO' and coalesce(ganancia_neta,0) <> 0
  union all
  select 'GUARDA_DE_CIERRE_INSTALADA'::text,
         case when count(*) = 1 then 'PASS' else 'FAIL' end, count(*),
         'disparador zzzzz_parlay_no_pierde_sin_pata_perdida en parlays'
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  where c.relname = 'parlays'
    and t.tgname = 'zzzzz_parlay_no_pierde_sin_pata_perdida' and not t.tgisinternal
  union all
  select 'CIERRES_RECHAZADOS_POR_LA_GUARDA'::text, 'INFO', count(*),
         'intentos de cobrar una perdida sin respaldo que la guarda rechazo'
  from public.parlay_cierre_rechazado;
$fn$;

comment on function public.gate_parlay_coherente() is
'ISS112. El resultado de un parlay no puede contradecir a sus patas. DINERO_COBRADO_SIN_RESPALDO se reporta aparte a proposito: medir el dinero mal cobrado no es lo mismo que moverlo, y moverlo no es decision de un parche.';

grant select on public.v_parlay_incoherente to anon, authenticated, service_role;
grant select on public.parlay_cierre_rechazado to anon, authenticated, service_role;
revoke insert, update, delete, truncate on public.parlay_cierre_rechazado from anon, authenticated;
grant all on public.parlay_cierre_rechazado to service_role;
grant execute on function public.gate_parlay_coherente() to anon, authenticated, service_role;

-- =====================================================================
-- MEDICION Y PRUEBAS
-- =====================================================================
--   PARLAY_PERDIDO_SIN_LEG_PERDIDO        FAIL  1   861b03b9 (-250.00)
--   PARLAY_CERRADO_CON_LEGS_PENDIENTES    FAIL  3   d3adc9fc [nulo, 8 pend]
--                                                  c9237cf6 [nulo, 2 pend]
--                                                  861b03b9 [perdido, 9 pend]
--   DINERO_COBRADO_SIN_RESPALDO           FAIL  1   -250.00
--   GUARDA_DE_CIERRE_INSTALADA            PASS  1
--
--   De los 68 parlays NINGUNO esta pendiente: 59 perdido, 7 ganado, 2 nulo.
--   Las 9 patas pendientes del de -250 son TODAS de tenis; las 8 del
--   d3adc9fc son de baseball y las 2 del c9237cf6 de tenis otra vez.
--
-- PRUEBA ADVERSARIAL, CAMINO UPDATE, SOBRE UNA FILA REAL
--   ATAQUE  update parlays set resultado='perdido', ganancia_neta=-999
--           sobre un parlay ganado sin ninguna pata perdida
--   -> RECHAZADO. resultado y ganancia_neta intactos, huella economica
--      global IDENTICA antes y despues, evidencia registrada:
--      legs_total=2, legs_perdidos=0, ganancia_neta_intentada=-10000
--
--   Detalle que vale la pena: la evidencia dice -10000, no -999. Otro
--   disparador economico ya habia recalculado el cobro desde el stake antes
--   de que corriera el mio. Confirma que la guarda esta bien colocada al
--   final de la cadena (zzzzz_) y que atrapa el monto que la capa economica
--   de verdad queria escribir, no el que yo puse en la prueba.
--
-- DOS PRUEBAS MIAS QUE SALIERON MAL ANTES DE SALIR BIEN
--   1. La primera version de la guarda, en INSERT, devolvia resultado a
--      'pendiente' pero DEJABA la ganancia_neta en -500: un parlay pendiente
--      cargando un cobro. Lo vi en el detalle de un error de NOT NULL, no
--      porque lo buscara. Corregido: en INSERT la ganancia_neta se anula.
--   2. Mi prueba del camino UPDATE buscaba un parlay 'pendiente' y no existe
--      ninguno, asi que la prueba no ejecutaba nada y no fallaba. Era una
--      prueba vacia. Lo detecte porque la tabla de evidencia quedo vacia.
--      Se rehizo sobre un parlay 'ganado'.
--
-- DOS CONSTRAINTS DE PRODUCCION QUE SE CONTRADICEN (hallazgo aparte)
--   tg_limite_exposicion() bloquea un parlay nuevo sin modelo conjunto
--   validado y su HINT dice textualmente: "Para guardarlo solo como
--   propuesta observacional, mandalo con apuesta = 0".
--   Pero el CHECK parlays_apuesta_check RECHAZA apuesta = 0.
--   O sea: el sistema le da al operador una instruccion que otra restriccion
--   del mismo sistema prohibe cumplir. No lo toque; queda reportado.
--
-- LO QUE NO HICE
--   No devolvi los -250. Revertir un cobro es una operacion de dinero y el
--   dueno prohibio el arreglo manual de dinero y de calificacion como
--   solucion. El invariante ya impide que se repita; el caso viejo queda
--   medido, visible y esperando su decision.
