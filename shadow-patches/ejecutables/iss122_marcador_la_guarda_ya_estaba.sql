-- =====================================================================
-- ISS122 : INTENTE ARREGLAR 5 ESCRITORES DE MARCADOR Y ME EQUIVOQUE DOS VECES
-- =====================================================================
-- Este archivo documenta un parche que APLIQUE A PRODUCCION Y REVERTI, y la
-- correccion de la compuerta mia que lo habia pedido. Se versiona completo, con
-- el error incluido, porque el valor esta en que no se vuelva a intentar.
--
-- EL PENDIENTE QUE VENIA ARRASTRANDO decia:
--   "Arreglar los 5 escritores de live_scores sin guarda con
--    coalesce(excluded.home_score, live_scores.home_score)"
-- Salia de mi propia compuerta ESCRITOR_NFL_SIN_GUARDA_DE_MARCADOR (ISS111),
-- que reportaba 5 y FAIL.
--
-- ERROR 1 - MI COMPUERTA CONTABA UN ESCRITOR QUE NO ESCRIBE.
--   archivar_marcadores hace INSERT INTO marcadores_archivo y solo LEE
--   live_scores. Mi predicado buscaba 'live_scores' + 'on conflict' +
--   'home_score = EXCLUDED.home_score' en el MISMO cuerpo, sin verificar que el
--   upsert fuera A live_scores. Son 4 escritores, no 5.
--
-- ERROR 2 - EL PARCHE ERA REDUNDANTE, Y ADEMAS UNA REGRESION.
--   Lo aplique a los 4 y despues lo medi, que es el orden equivocado.
--
--   (a) REDUNDANTE. Ya existe trg_preservar_marcador_live, un disparador BEFORE
--       UPDATE de TABLA que cubre TODOS los deportes, no solo NFL, y que hace
--       exactamente esto:
--           if new.home_score is null and old.home_score is not null then
--             new.home_score := old.home_score;
--       Medido con filas sinteticas: con el patron viejo "= excluded", un tick
--       con NULL NO degrada nada.
--           NFL     21-17 -> se queda en 21-17
--           FUTBOL   2-1  -> se queda en 2-1
--       Yo habia supuesto que la proteccion era solo de NFL
--       (zz_no_degradar_marcador_nfl). Lo era la que yo escribi; la que de
--       verdad sostiene el invariante para los tres deportes ya estaba ahi.
--
--   (b) REGRESION. trg_preservar_marcador_live permite A PROPOSITO el reset a
--       NULL cuando el status es postponed / canceled / cancelled / suspended:
--           v_reset := coalesce(new.status,'') in ('postponed',...);
--           if not v_reset then ... preservar ... end if;
--       Con coalesce metido en el escritor, ese reset legitimo ya no puede
--       ocurrir, porque el escritor entrega el marcador viejo y el disparador
--       ya no ve un NULL que rescatar. Medido sobre un partido pospuesto:
--           patron viejo (= excluded)  -> NULL-NULL   el reset SI ocurre
--           patron nuevo (coalesce)    -> 2-1         mi parche lo ROMPE
--
--   REVERTIDO BYTE A BYTE. Se restauro el texto original de cada escritor con
--   su propio uso de mayusculas y su propio espaciado, y se verifico
--   md5(prosrc) contra el md5 capturado antes de tocar nada:
--     espejar_apifootball_a_live_scores  958f6aeb80ca3a8c8218c88291b9455b  OK
--     espejar_nfl_a_live                 cae95664d97028850b5560c1fda16dce  OK
--     sync_nfl_cdn_tick                  52b523c57a9a49a4113775b1924f2395  OK
--     sync_nfl_desde_cdn                 afb208661c78e96514f9d7286de9fc1b  OK
--   Produccion quedo identica a como estaba. El rastro del intento vive en
--   public.guarda_marcador_parche con su motivo de reversion.
--
-- LA LECCION, que es la misma de siempre en este proyecto: una compuerta que
-- mide un PATRON DE TEXTO no mide el invariante. Esta pedia coalesce en el
-- escritor cuando el invariante ya estaba garantizado en la tabla, y el
-- "arreglo" que pedia rompia un caso legitimo. Antes me habia mentido dando
-- verdes falsos; aqui me mintio dando un rojo falso, y casi le meto una
-- regresion a produccion por obedecerla.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. DETECCION CONSCIENTE DEL DESTINO DEL UPSERT
-- ---------------------------------------------------------------------
-- Se corta el cuerpo en cada INSERT INTO y se examina SOLO el tramo cuyo
-- destino es live_scores. Asi archivar_marcadores deja de salir acusado.
create or replace function public.escritor_live_scores_sin_coalesce()
returns table(funcion text, fragmento text)
language plpgsql stable as $fn$
declare r record; seg text;
begin
  for r in
    select p.proname, p.prosrc
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace and n.nspname='public'
    where p.prosrc ~* 'insert\s+into\s+(public\.)?live_scores\M'
  loop
    -- se corta el cuerpo en cada INSERT INTO y se mira solo el tramo cuyo
    -- destino es live_scores
    foreach seg in array regexp_split_to_array(r.prosrc, '(?i)insert\s+into\s+') loop
      if seg ~* '^(public\.)?live_scores\M'
         and seg ~* 'on\s+conflict'
         and seg ~* '(home_score|away_score)\s*=\s*excluded\.'
         and seg !~* 'coalesce\s*\(\s*excluded\.(home_score|away_score)' then
        funcion := r.proname;
        fragmento := btrim((regexp_match(seg, '(?i)((home_score|away_score)\s*=\s*excluded\.[^,\n]*)'))[1]);
        return next;
      end if;
    end loop;
  end loop;
end
$fn$;

-- ---------------------------------------------------------------------
-- 2. RASTRO FORENSE DEL INTENTO
-- ---------------------------------------------------------------------
create table if not exists public.guarda_marcador_parche (
  funcion text primary key,
  aplicado_at timestamptz not null default now(),
  md5_antes text not null,
  md5_despues text not null,
  cambios int not null,
  revertido_at timestamptz,
  motivo_revert text
);
revoke all on public.guarda_marcador_parche from anon, authenticated;

comment on table public.guarda_marcador_parche is
'ISS122. Rastro forense de un parche que aplique a 4 escritores de live_scores y REVERTI al medir que era redundante y que rompia el reset de partidos pospuestos. Se conserva para que no se vuelva a intentar.';

-- ---------------------------------------------------------------------
-- 3. COMPUERTA CORREGIDA (reemplaza la version de ISS111)
-- ---------------------------------------------------------------------
-- Lo que pasa a ser FAIL es que FALTE el disparador que sostiene el invariante.
-- Los 4 escritores con "= excluded" pasan a INFO, con el motivo escrito en el
-- propio detalle para que nadie los "arregle" otra vez.
create or replace function public.gate_marcador_posible_nfl()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql stable as $fn$
  select 'MARCADOR_NFL_IMPOSIBLE'::text,
         case when count(*) = 0 then 'PASS' else 'FAIL' end, count(*),
         coalesce(string_agg(ls.espn_event_id||': '||ls.home_score||'-'||ls.away_score
                    ||' pero los TD exigen >= '
                    ||coalesce(public.nfl_puntos_minimos_por_tds(ls.espn_event_id, ls.home_team)::text,'?')
                    ||'-'||coalesce(public.nfl_puntos_minimos_por_tds(ls.espn_event_id, ls.away_team)::text,'?'),
                  ' | '), 'ninguno')
  from public.live_scores ls
  where ls.liga = 'NFL'
    and public.nfl_marcador_imposible(ls.espn_event_id, ls.home_team, ls.away_team,
                                      ls.home_score, ls.away_score)
  union all
  -- LO QUE DE VERDAD SOSTIENE EL INVARIANTE. Es un disparador de TABLA y cubre
  -- TODOS los deportes, no solo NFL. Mientras este vivo, da igual que los
  -- escritores usen "= excluded": un tick con NULL no puede borrar un marcador.
  -- Si se cae, la proteccion se cae para futbol, MLB y NFL a la vez.
  select 'GUARDA_PRESERVA_MARCADOR_INSTALADA'::text,
         case when count(*) = 1 then 'PASS' else 'FAIL' end, count(*),
         'disparador trg_preservar_marcador_live (BEFORE UPDATE, todos los deportes). '
         || 'Preserva el marcador cuando el tick trae NULL, y PERMITE el reset cuando '
         || 'el status es postponed/canceled/suspended.'
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  where c.relname = 'live_scores' and t.tgname = 'trg_preservar_marcador_live'
    and not t.tgisinternal and t.tgenabled = 'O'
  union all
  select 'GUARDA_DE_MARCADOR_NFL_INSTALADA'::text,
         case when count(*) = 1 then 'PASS' else 'FAIL' end, count(*),
         'disparador zz_no_degradar_marcador_nfl en live_scores (cota por touchdowns, solo NFL)'
  from pg_trigger t join pg_class c on c.oid = t.tgrelid
  where c.relname = 'live_scores' and t.tgname = 'zz_no_degradar_marcador_nfl'
    and not t.tgisinternal and t.tgenabled = 'O'
  union all
  -- INFO, NO FAIL, Y AQUI ESTA EL PORQUE. Medi el comportamiento y el patron
  -- "= excluded" NO degrada nada: trg_preservar_marcador_live lo ataja antes.
  -- Peor todavia: meter coalesce en estos escritores ROMPE el reset legitimo de
  -- un partido pospuesto (probado: con coalesce el marcador se queda en 2-1
  -- cuando deberia volver a NULL). Lo intente, lo medi y lo revertí byte a byte.
  select 'ESCRITOR_LIVE_SCORES_SIN_COALESCE'::text,
         'INFO'::text, count(*),
         coalesce(string_agg(funcion, ', ' order by funcion), 'ninguno')
         || '. NO es falla y NO se deben "arreglar" con coalesce: el invariante lo '
         || 'sostiene trg_preservar_marcador_live para todos los deportes, y el coalesce '
         || 'en el escritor impide el reset legitimo de un partido pospuesto.'
  from public.escritor_live_scores_sin_coalesce()
  union all
  select 'DEGRADACIONES_RECHAZADAS'::text, 'INFO', count(*),
         'intentos de escribir un marcador imposible que la guarda rechazo'
  from public.marcador_degradacion_rechazada;
$fn$;

-- =====================================================================
-- 4. PRUEBA DE COMPORTAMIENTO (se corre con filas sinteticas y se revierte
--    con un RAISE deliberado; no deja ninguna fila en live_scores)
-- =====================================================================
-- do $t$
-- declare v_out text := ''; v_h int; v_a int;
--         k text := 'ISS122-' || floor(random()*1000000)::text;
-- begin
--   insert into public.live_scores (espn_event_id, liga, deporte, home_team, away_team,
--                                   home_score, away_score, status, game_date)
--   values (k,'Premier League','soccer','A','B',2,1,'post',now());
--
--   insert into public.live_scores (espn_event_id, liga, deporte, home_team, away_team,
--                                   home_score, away_score, status, game_date)
--   values (k,'Premier League','soccer','A','B',null,null,'in',now())
--   on conflict (espn_event_id) do update set
--     home_score = excluded.home_score, away_score = excluded.away_score;
--   select home_score, away_score into v_h, v_a from public.live_scores where espn_event_id=k;
--   v_out := v_out || E'\nen vivo con NULL, patron viejo -> '||coalesce(v_h::text,'NULL')||'-'||coalesce(v_a::text,'NULL');
--
--   update public.live_scores set home_score=2, away_score=1, status='post' where espn_event_id=k;
--   insert into public.live_scores (espn_event_id, liga, deporte, home_team, away_team,
--                                   home_score, away_score, status, game_date)
--   values (k,'Premier League','soccer','A','B',null,null,'postponed',now())
--   on conflict (espn_event_id) do update set
--     home_score = coalesce(excluded.home_score, live_scores.home_score),
--     away_score = coalesce(excluded.away_score, live_scores.away_score),
--     status = excluded.status;
--   select home_score, away_score into v_h, v_a from public.live_scores where espn_event_id=k;
--   v_out := v_out || E'\npospuesto, patron coalesce     -> '||coalesce(v_h::text,'NULL')||'-'||coalesce(v_a::text,'NULL');
--
--   raise exception E'ISS122 (revertido):%', v_out;
-- end $t$;
--
-- RESULTADOS MEDIDOS 2026-09-12:
--   NFL   21-17, tick NULL, patron viejo      -> 21-17     (el disparador lo salvo)
--   FUTBOL 2-1,  tick NULL, patron viejo      -> 2-1       (el disparador lo salvo)
--   FUTBOL 2-1,  tick NULL, patron coalesce   -> 2-1       (igual, redundante)
--   FUTBOL 2-1,  POSPUESTO, patron viejo      -> NULL-NULL (reset legitimo OK)
--   FUTBOL 2-1,  POSPUESTO, patron coalesce   -> 2-1       (REGRESION de mi parche)
--
-- ESTADO DEL GATE (2026-09-12):
--   MARCADOR_NFL_IMPOSIBLE               PASS  0
--   GUARDA_PRESERVA_MARCADOR_INSTALADA   PASS  1
--   GUARDA_DE_MARCADOR_NFL_INSTALADA     PASS  1
--   ESCRITOR_LIVE_SCORES_SIN_COALESCE    INFO  4   (eran 5 mal contados)
--   DEGRADACIONES_RECHAZADAS             INFO  1
-- =====================================================================
