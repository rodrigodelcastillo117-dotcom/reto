-- =====================================================================
-- ISS120 : NINGUNA PATA NUEVA DE UN DEPORTE SIN CONTRATO CANONICO
-- =====================================================================
-- Origen: ultima clausula de la Decision 4 del dueno.
--   "Ademas: impedir patas NUEVAS de deportes/eventos no soportados o no
--    canonicos salvo que tengan contrato real de evento y resultado.
--    Las filas historicas se preservan."
--
-- El problema concreto: hay 78 patas historicas de Tenis en parlays. El
-- tenis no tiene contrato canonico en este backend: no hay autoridad de
-- resultado, no hay evento en agenda, no hay modelo. Esas patas no se
-- pueden calificar nunca, y arrastran al parlay entero a un estado que
-- no se puede resolver con evidencia. De ahi salieron las 9 patas
-- huerfanas de ISS113 y parte del settlement invalido de ISS119.
--
-- LO QUE ESTE PARCHE **NO** HACE:
--   - No borra ni reescribe nada historico. Cero.
--   - No cae patas en silencio. Ver la nota de diseno abajo.
--   - No usa lista dura de deportes. El contrato sale de agenda_espn.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. QUE SIGNIFICA "TENER CONTRATO CANONICO"
-- ---------------------------------------------------------------------
-- Deliberadamente NO es una lista hardcodeada de deportes. Se pregunta a
-- agenda_espn, que es la superficie canonica de eventos. Consecuencia
-- buscada: el dia que un deporte entre de verdad al producto (con eventos
-- canonicos reales), la guarda lo reconoce sola, sin que nadie tenga que
-- acordarse de editar esta funcion. Y al contrario: un deporte que solo
-- existe en el texto de un pick nunca pasa.
create or replace function public.deporte_tiene_contrato_canonico(p_deporte text)
returns boolean language sql stable as $fn$
  select exists (
    select 1 from public.agenda_espn a
    where public.deporte_canonico(a.deporte) = public.deporte_canonico(p_deporte)
  );
$fn$;

-- ---------------------------------------------------------------------
-- 2. LA GUARDA
-- ---------------------------------------------------------------------
-- NOTA DE DISENO, y es a proposito distinta de mis otras guardas:
-- esta SI lanza excepcion. Mis otras guardas corrigen en silencio porque
-- corrigen metadatos. Aqui no: caer una pata sin avisar alteraria la
-- apuesta del usuario a sus espaldas, y eso es peor que un error claro.
-- Si el producto quiere ofrecer ese deporte, primero necesita contrato,
-- no una excepcion a la regla.
--
-- En UPDATE solo se juzgan las patas NUEVAS: las que ya estaban en
-- OLD.picks_data (empatadas por pick_desc) pasan sin revisar. Asi se
-- cumple "las filas historicas se preservan": un parlay viejo con tenis
-- se puede seguir editando, calificando y reconciliando.
create or replace function public.tg_pata_sin_contrato_canonico()
returns trigger language plpgsql as $fn$
declare v_malos text;
begin
  if jsonb_typeof(NEW.picks_data) <> 'array' then return NEW; end if;

  -- SOLO patas NUEVAS. Lo historico se preserva: si la pata ya estaba en OLD
  -- con el mismo pick_desc, no se toca.
  select string_agg(distinct coalesce(x->>'deporte','(sin deporte)'), ', ')
    into v_malos
  from jsonb_array_elements(NEW.picks_data) x
  where coalesce(x->>'deporte','') <> ''
    and not public.deporte_tiene_contrato_canonico(x->>'deporte')
    and (TG_OP = 'INSERT'
         or not exists (select 1 from jsonb_array_elements(OLD.picks_data) o
                        where o->>'pick_desc' is not distinct from x->>'pick_desc'));

  if v_malos is not null then
    raise exception
      'PATA SIN CONTRATO CANONICO: % no esta declarado en agenda_espn. RETO 13M es MLB, NFL y futbol. Un pick de un deporte sin modelo, sin identidad en el calendario autoritativo y sin calibracion no puede existir como pata nueva.',
      v_malos
      using hint = 'Si ese deporte debe existir en el producto, primero necesita contrato canonico: evento en agenda_espn, modelo registrado y contrato de resultado. Las patas historicas se preservan; esto solo bloquea las NUEVAS.';
  end if;

  return NEW;
end;
$fn$;

drop trigger if exists zzzzzz_pata_sin_contrato_canonico on public.parlays;
create trigger zzzzzz_pata_sin_contrato_canonico
  before insert or update on public.parlays
  for each row execute function public.tg_pata_sin_contrato_canonico();

-- ---------------------------------------------------------------------
-- 3. COMPUERTA
-- ---------------------------------------------------------------------
create or replace function public.gate_pata_con_contrato_canonico()
returns table(gate text, estado text, cuenta bigint, detalle text)
language plpgsql stable as $fn$
declare
  -- Fecha en que quedo instalada la guarda. Lo historico ANTERIOR se
  -- preserva por orden del dueno y NO cuenta como violacion. Solo lo
  -- NUEVO se juzga.
  k_instalada constant timestamptz := '2026-09-12 00:00:00+00';
begin
  return query
  select 'GUARDA_CONTRATO_CANONICO_INSTALADA'::text,
         case when count(*) = 1 then 'PASS' else 'FAIL' end,
         count(*),
         case when count(*) = 1 then 'trigger presente y habilitado en public.parlays'
              else 'NO esta instalada la guarda: se pueden volver a meter patas de deportes sin contrato' end
  from pg_trigger t
  where t.tgrelid = 'public.parlays'::regclass
    and t.tgname = 'zzzzzz_pata_sin_contrato_canonico'
    and t.tgenabled = 'O';

  return query
  select 'PATA_NUEVA_SIN_CONTRATO_CANONICO'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end,
         count(*),
         coalesce(string_agg(distinct d.deporte || ' (parlay ' || left(d.id::text,8) || ')', '; '),
                  'ninguna pata nueva sin contrato canonico')
  from (
    select p.id, x->>'deporte' as deporte
    from public.parlays p, jsonb_array_elements(p.picks_data) x
    where p.created_at >= k_instalada
      and coalesce(x->>'deporte','') <> ''
      and not public.deporte_tiene_contrato_canonico(x->>'deporte')
  ) d;

  -- Lo historico se preserva a proposito. Es INFO, no FAIL: borrarlo seria
  -- limpiar la historia para que una superficie se vea bonita.
  return query
  select 'PATA_HISTORICA_SIN_CONTRATO_PRESERVADA'::text,
         'INFO'::text,
         count(*),
         coalesce(string_agg(distinct d.deporte, ', '), 'ninguna') ||
         ' -- preservadas por orden del dueno, no se tocan'
  from (
    select x->>'deporte' as deporte
    from public.parlays p, jsonb_array_elements(p.picks_data) x
    where p.created_at < k_instalada
      and coalesce(x->>'deporte','') <> ''
      and not public.deporte_tiene_contrato_canonico(x->>'deporte')
  ) d;

  -- Honestidad sobre el alcance real de la prueba: hoy la rama INSERT de mi
  -- guarda es INALCANZABLE en produccion porque zzzz_limite_exposicion corre
  -- antes y rechaza TODO parlay nuevo. Se declara en vez de fingir cobertura.
  return query
  select 'GUARDA_PRECEDIDA_EN_INSERT'::text,
         'INFO'::text,
         count(*),
         coalesce(string_agg(t.tgname, ', '), 'ninguna') ||
         ' corre(n) antes que mi guarda en INSERT; si rechazan primero, mi rama INSERT no se ejerce en produccion'
  from pg_trigger t
  where t.tgrelid = 'public.parlays'::regclass
    and not t.tgisinternal
    and t.tgenabled = 'O'
    and (t.tgtype & 2) = 2 and (t.tgtype & 4) = 4
    and t.tgname < 'zzzzzz_pata_sin_contrato_canonico';

  return query
  select 'DEPORTES_CON_CONTRATO_CANONICO'::text,
         'INFO'::text,
         count(distinct public.deporte_canonico(a.deporte)),
         string_agg(distinct public.deporte_canonico(a.deporte), ', ')
  from public.agenda_espn a;
end
$fn$;

-- =====================================================================
-- 4. EVIDENCIA ADVERSARIAL EJECUTADA (2026-09-12)
-- =====================================================================
-- A) Sobre public.parlays de PRODUCCION, 8 casos, todo revertido al final
--    por un RAISE deliberado (no quedo ni una fila de prueba):
--
--   CASO1 pata_nueva_tenis            => RECHAZADA por OTRO
--   CASO2 pata_nueva_futbol           => RECHAZADA por OTRO, ajeno a ISS120
--   CASO3 pata_nueva_baseball         => RECHAZADA por OTRO, ajeno a ISS120
--   CASO4 pata_nueva_football         => RECHAZADA por OTRO, ajeno a ISS120
--   CASO5 mixto_futbol_mas_tenis      => RECHAZADO por OTRO
--   CASO6 update_historico_con_tenis  => PERMITIDO (historia preservada)
--   CASO7 update_agrega_pata_tenis    => RECHAZADO por MI_GUARDA (correcto)
--   CASO8 update_agrega_pata_futbol   => ACEPTADO (correcto)
--
--    LECTURA HONESTA: los 5 INSERT **no probaron nada de ISS120**. Los
--    rechazo zzzz_limite_exposicion con 'PARLAY SIN MODELO CONJUNTO
--    VALIDADO', que corre antes que mi guarda y hoy rechaza TODO parlay
--    nuevo. Si yo reportara "5 de 5 rechazados, PASS" estaria cobrando
--    como mio el trabajo de otra compuerta. La rama INSERT de mi guarda
--    es inalcanzable en produccion mientras ese candado siga cerrado.
--    Por eso el gate lo declara como GUARDA_PRECEDIDA_EN_INSERT.
--
--    Lo que SI quedo probado en produccion es la parte discriminante y la
--    que el dueno pidio explicitamente: en UPDATE la guarda distingue
--    pata vieja de pata nueva (CASO6 pasa, CASO7 no) y no es un bloqueo
--    ciego por deporte (CASO8 pasa).
--
-- B) Para ejercer la rama INSERT de verdad, superficie DESECHABLE:
--    copia estructural de parlays con UNICAMENTE esta guarda encima,
--    creada y borrada dentro del mismo bloque (verificado:
--    to_regclass('public.iss120_superficie_desechable') = null):
--
--   INS-1 solo_tenis          => RECHAZADA por MI_GUARDA (correcto)
--   INS-2 cricket             => RECHAZADA por MI_GUARDA (correcto)
--   INS-3 mixto_fut_mas_tenis => RECHAZADO por MI_GUARDA (correcto)
--   INS-4 fut_mlb_nfl         => ACEPTADO (correcto)
--   INS-5 sin_patas           => ACEPTADO (correcto, no es asunto de ISS120)
--   INS-6 pata_sin_deporte    => ACEPTADA (hueco declarado, ver abajo)
--
-- C) Predicado solo, 7 entradas:
--      soccer, ⚽ Fútbol, ⚾ Baseball, football, 🏈 Futbol Americano = true
--      🎾 Tenis, cricket                                            = false
--
-- HUECO DECLARADO: una pata con 'deporte' vacio o ausente NO se juzga
-- (INS-6). No lo tapo inventando un deporte. Quien deberia cerrarlo es
-- la identidad de la pata (ISS113), no esta guarda: si aqui rechazara por
-- deporte vacio, estaria adivinando que una pata sin deporte es invalida,
-- cuando puede ser una pata que trg_canonizar_legs_parlay todavia no
-- normalizo.
--
-- ESTADO DEL GATE (2026-09-12):
--   GUARDA_CONTRATO_CANONICO_INSTALADA       PASS  1
--   PATA_NUEVA_SIN_CONTRATO_CANONICO         PASS  0
--   PATA_HISTORICA_SIN_CONTRATO_PRESERVADA   INFO  78   (🎾 Tenis)
--   GUARDA_PRECEDIDA_EN_INSERT               INFO  11
--   DEPORTES_CON_CONTRATO_CANONICO           INFO  3    (baseball, football, soccer)
--
-- md5(prosrc) de tg_pata_sin_contrato_canonico en produccion:
--   3a50fe2024090306cd15f1ea6be6650b
-- =====================================================================
