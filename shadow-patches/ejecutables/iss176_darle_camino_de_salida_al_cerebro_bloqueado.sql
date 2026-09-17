-- ISS176: darle camino de salida al cerebro de MLB que acabo de bloquear
--         + retirar solos los trabajos que persiguen partidos ya jugados
--
-- ===========================================================================
-- PARTE A. EL PROBLEMA QUE YO MISMO CREE EN ISS175R
-- ===========================================================================
-- En ISS175R cerre el grifo de mlb_one_brain_v2: de 24 probabilidades en
-- pantalla a 0, porque no tenia evidencia en ningun sitio. La regla nueva es
-- que para publicar favorito_pct hace falta una fila en v2.model_learning_gate
-- (Moneyline, GLOBAL) con brier_vs_naive_upper95 < 0.
--
-- Escribi entonces: "cuando acumule resultados se encendera SOLO". ESO ERA
-- FALSO y hay que decirlo claro. Medido despues:
--
--   v2.capture_mlb_learning_snapshot captura UNICAMENTE
--   v2.fn_mlb_runtime_version() = 'mlb_runtime_a7fb15853076', via
--   public.predecir_mlb(). mlb_one_brain_v2 no entraba nunca.
--
--   Sin snapshot no hay observacion; sin observacion no hay fila de gate; sin
--   fila de gate no publica. El bloqueo era permanente, no condicional.
--
-- Y NO se le puede prestar la evidencia del runtime, porque NO son el mismo
-- modelo. Comprobado sobre los mismos 24 partidos:
--   diferencia media de canonical_probability_pct   6.042 puntos
--   peor caso                                      16.2 puntos
--   partidos que coinciden dentro de 0.5 puntos       0
--
-- ===========================================================================
-- QUE SE HIZO (PARTE A)
-- ===========================================================================
--
-- A.1  v2.capture_mlb_one_brain_snapshot(p_max int default 60)
--      Lee public.v_mlb_publication_v1 donde model_version='mlb_one_brain_v2'
--      y escribe en v2.mlb_learning_snapshot con ventana por cercania al
--      kickoff (2h / 6h / 24h / 48h), una fila por (evento, ventana).
--      Solo partidos futuros: kickoff entre now()+5min y now()+50h, asi que
--      temporal_safe es cierto por construccion, no por confianza.
--
--      NO toca la vista publicada. v_mlb_publication_v1 sigue exponiendo el
--      analisis crudo; el grifo cerrado en ISS175R esta en public.v_favorito_mlb,
--      que es la superficie que ve el usuario. Se mide lo que el modelo diria,
--      sin que nadie lo vea. Es exactamente lo que hay que hacer.
--
-- A.2  Enganchada dentro de v2.run_model_learning_cycle, justo despues de la
--      captura del runtime, con parche de coincidencia exacta (si el ancla no
--      aparece exactamente 1 vez, aborta). Asi hereda el cron que ya existe,
--      reto-model-learning-v1 (17,47 * * * *), y sobre todo se ejecuta ANTES
--      de refresh_model_learning en la misma corrida.
--
--      No se creo cron nuevo a proposito: un cron aparte podria correr despues
--      del refresh y la evidencia llegaria siempre media hora tarde.
--
-- A.3  v2.refresh_model_learning NO se toco. Su bloque de MLB lee
--      v2.mlb_learning_snapshot sin filtrar por model_version, y el source_key
--      lleva el model_version dentro, asi que las filas nuevas entran solas y
--      no chocan con las del runtime. Comprobado leyendo el cuerpo entero.
--
-- ===========================================================================
-- PARTE B. G39, PARA QUE EL TRATO NO SE ROMPA POR NINGUN LADO
-- ===========================================================================
-- public.gate_mlb_one_brain_medible(). Vigila las dos mitades:
--
--   G39.1  mlb_no_publica_sin_evidencia
--          FAIL si v_favorito_mlb publica favorito_pct sin que exista la fila
--          de gate con el intervalo del 95% entero del lado bueno. Esta es la
--          guardia contra que alguien vuelva a aflojar la regla, como paso.
--
--   G39.2  la_evidencia_sigue_entrando
--          FAIL si hay partidos proximos de one_brain y la ultima captura tiene
--          mas de 90 minutos (el cron es cada 30: 90 min son 3 corridas
--          perdidas). Esta es la guardia contra lo que hice yo en ISS175R:
--          bloquear sin camino de salida. Mide el RESULTADO, no la causa.
--
--   G39.3  cuanta_evidencia_lleva  (INFO)
--          Cuenta observaciones calificadas y muestra el veredicto actual.
--
-- ===========================================================================
-- PARTE C. TRABAJOS ZOMBIS, AHORA SOLOS
-- ===========================================================================
-- En ISS167 limpie a mano 82 trabajos de cobertura que perseguian partidos ya
-- jugados (Willem II: 103 intentos por un partido de hace 6 dias). Limpiar a
-- mano no arregla nada: vuelven.
--
--   v2.retirar_trabajos_de_partidos_ya_jugados()
--     PENDING/RETRY con next_kickoff < now() - 6h  ->  RETIRADO_PARTIDO_YA_JUGADO
--     Deja el motivo y el numero de intentos en last_error. No borra nada.
--   cron 'retirar-trabajos-zombis'  ('17 * * * *')
--
-- CORRECCION AL REGISTRO: dije antes que su primera corrida habia retirado 30.
-- No era cierto. Esa llamada iba en un lote MCP junto a otra sentencia que
-- fallo, y el lote entero se deshizo; los 30 seguian en PENDING/RETRY al
-- revisarlo hoy. Ejecutada de verdad ahora: 30 retirados, comprobado que 30 de
-- ellos llevan la marca 'retirado automaticamente' en last_error.
--
-- ===========================================================================
-- ESTADO FINAL VERIFICADO (2026-09-17)
-- ===========================================================================
--   MLB publicando sin evidencia          0   de 88 partidos en agenda
--   snapshots one_brain acumulados       24   (5 en 24h, 15 en 48h, 4 en 6h)
--   todos temporal_safe                  24 / 24
--   ciclo de aprendizaje                 corre limpio, devuelve la llave
--                                        'one_brain' dentro de 'mlb_capture'
--   G39.1 PASS (0) | G39.2 PASS (24) | G39.3 INFO (0 calificadas todavia)
--   trabajos zombis en cola               0   (30 retirados, 51 en total)
--
-- Lo que NO esta probado y no se finge: cero observaciones calificadas de
-- one_brain, porque los 24 partidos aun no se juegan. La evidencia tarda lo
-- que tarda. Lo unico que cambia hoy es que ahora puede llegar.


-- ---------------------------------------------------------------------------
-- A.1  captura de mlb_one_brain_v2 hacia el aprendizaje
-- ---------------------------------------------------------------------------
create or replace function v2.capture_mlb_one_brain_snapshot(p_max int default 60)
returns jsonb
language plpgsql
as $fn$
declare n int := 0;
begin
  -- ISS176. mlb_one_brain_v2 se publicaba SIN que nadie lo midiera: cero filas
  -- en model_learning_gate, cero observaciones. Comprobado ademas que NO es el
  -- mismo modelo que mlb_runtime (sobre 24 partidos difieren 6.04 puntos de
  -- media y hasta 16.2), asi que la evidencia del runtime no le sirve.
  --
  -- Bloquearlo sin darle camino seria condenarlo. Esto lo mete al aprendizaje
  -- para que acumule resultados y se gane la entrada solo.
  insert into v2.mlb_learning_snapshot
    (espn_event_id, model_version, eval_window, captured_at, kickoff, league,
     home_team, away_team, p_home, p_away, temporal_safe, prediction)
  select p.espn_event_id, p.model_version,
         case when extract(epoch from (p.kickoff-now()))/3600.0 <= 2 then '2h'
              when extract(epoch from (p.kickoff-now()))/3600.0 <= 6 then '6h'
              when extract(epoch from (p.kickoff-now()))/3600.0 <= 24 then '24h'
              else '48h' end,
         now(), p.kickoff, coalesce(p.league_name,'MLB'),
         p.home_name, p.away_name, p.p_home_pct, p.p_away_pct,
         now() < p.kickoff,
         jsonb_build_object('fuente','v_mlb_publication_v1','pick',p.canonical_pick,
                            'pick_pct',p.canonical_probability_pct,
                            'validation_status',p.validation_status)
  from public.v_mlb_publication_v1 p
  where p.model_version = 'mlb_one_brain_v2'
    and p.p_home_pct is not null and p.p_away_pct is not null
    and p.kickoff > now() + interval '5 minutes'
    and p.kickoff < now() + interval '50 hours'
    and not exists (
      select 1 from v2.mlb_learning_snapshot s
      where s.espn_event_id = p.espn_event_id and s.model_version = p.model_version
        and s.eval_window = case when extract(epoch from (p.kickoff-now()))/3600.0 <= 2 then '2h'
                                 when extract(epoch from (p.kickoff-now()))/3600.0 <= 6 then '6h'
                                 when extract(epoch from (p.kickoff-now()))/3600.0 <= 24 then '24h'
                                 else '48h' end)
  limit greatest(1, p_max);
  get diagnostics n = row_count;
  return jsonb_build_object('capturadas', n, 'model_version', 'mlb_one_brain_v2');
end
$fn$;


-- ---------------------------------------------------------------------------
-- A.2  engancharla al ciclo existente. Coincidencia exacta o aborta.
-- ---------------------------------------------------------------------------
do $patch$
declare
  v_def text;
  v_o   text := E'  m:=v2.capture_mlb_learning_snapshot(150);\n';
  v_n   text := E'  m:=v2.capture_mlb_learning_snapshot(150);\n  m:=m||jsonb_build_object(''one_brain'',v2.capture_mlb_one_brain_snapshot(60));\n';
  c     int;
begin
  select pg_get_functiondef(p.oid) into v_def
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='v2' and p.proname='run_model_learning_cycle';

  if v_def is null then raise exception 'v2.run_model_learning_cycle no existe'; end if;
  if position('capture_mlb_one_brain_snapshot' in v_def) > 0 then
    raise notice 'ya parcheado, no hago nada';
    return;
  end if;

  c := (length(v_def) - length(replace(v_def, v_o, ''))) / length(v_o);
  if c <> 1 then raise exception 'ancla aparece % veces, esperaba 1', c; end if;

  execute replace(v_def, v_o, v_n);
end
$patch$;


-- ---------------------------------------------------------------------------
-- B  G39
-- ---------------------------------------------------------------------------
create or replace function public.gate_mlb_one_brain_medible()
returns table(gate text, estado text, cuenta bigint, detalle text)
language sql
stable
security definer
set search_path = public, v2, pg_catalog
as $g$
  -- G39 (ISS176). Dos mitades del mismo trato:
  --   a) mlb_one_brain_v2 no publica hasta que la evidencia le de la razon.
  --   b) la evidencia tiene que seguir entrando, o (a) lo condena para siempre.
  select 'G39.1_mlb_no_publica_sin_evidencia'::text,
    case when count(*) filter (where favorito_pct is not null) = 0 then 'PASS'
         when (select coalesce(bool_or(g.brier_vs_naive_upper95 < 0), false)
                 from v2.model_learning_gate g
                where g.model_version = 'mlb_one_brain_v2'
                  and g.market = 'Moneyline' and g.scope = 'GLOBAL'
                  and g.brier_vs_naive_upper95 is not null) then 'PASS'
         else 'FAIL' end,
    count(*) filter (where favorito_pct is not null),
    ('De '||count(*)||' partidos de MLB en agenda, '
     ||count(*) filter (where favorito_pct is not null)
     ||' publican probabilidad. Solo pueden hacerlo si existe fila en '
     ||'v2.model_learning_gate (Moneyline, GLOBAL) con brier_vs_naive_upper95 < 0. '
     ||'Declararse READY a si mismo no es evidencia.')::text
  from public.v_favorito_mlb
  union all
  select 'G39.2_la_evidencia_sigue_entrando'::text,
    case when (select count(*) from public.v_mlb_publication_v1 p
                where p.model_version='mlb_one_brain_v2' and p.p_home_pct is not null
                  and p.kickoff between now()+interval '5 minutes' and now()+interval '50 hours') = 0
           then 'INFO'
         when (select max(captured_at) from v2.mlb_learning_snapshot
                where model_version='mlb_one_brain_v2') > now()-interval '90 minutes'
           then 'PASS'
         else 'FAIL' end,
    (select count(*) from v2.mlb_learning_snapshot where model_version='mlb_one_brain_v2'),
    ('Ultima captura: '
     ||coalesce((select to_char(max(captured_at),'YYYY-MM-DD HH24:MI')
                   from v2.mlb_learning_snapshot where model_version='mlb_one_brain_v2'),'NUNCA')
     ||' UTC. Hay '
     ||(select count(*) from public.v_mlb_publication_v1 p
         where p.model_version='mlb_one_brain_v2' and p.p_home_pct is not null
           and p.kickoff between now()+interval '5 minutes' and now()+interval '50 hours')
     ||' partidos proximos en la vista de publicacion. La captura va dentro de '
     ||'v2.run_model_learning_cycle (cron 17,47). Mas de 90 minutos sin capturar '
     ||'son 3 corridas perdidas: el camino de salida esta roto.')::text
  union all
  select 'G39.3_cuanta_evidencia_lleva'::text, 'INFO'::text,
    (select count(*) from v2.model_learning_observation
      where model_version='mlb_one_brain_v2'),
    ('Resultados ya calificados: '
     ||(select count(*) from v2.model_learning_observation where model_version='mlb_one_brain_v2')
     ||'. Veredicto actual: '
     ||coalesce((select 'n='||g.n_events||', Brier '||round(g.brier_model,5)
                        ||' contra adivinar '||round(g.brier_naive,5)
                        ||', IC95 superior '||round(g.brier_vs_naive_upper95,5)
                   from v2.model_learning_gate g
                  where g.model_version='mlb_one_brain_v2' and g.market='Moneyline'
                    and g.scope='GLOBAL' order by g.n_events desc nulls last limit 1),
                'todavia sin fila de gate')
     ||'. Se encendera solo cuando el intervalo entero quede del lado bueno.')::text;
$g$;

grant execute on function public.gate_mlb_one_brain_medible() to anon, authenticated, service_role;


-- ---------------------------------------------------------------------------
-- C  trabajos zombis
-- ---------------------------------------------------------------------------
create or replace function v2.retirar_trabajos_de_partidos_ya_jugados()
returns int
language plpgsql
as $fn$
declare n int;
begin
  -- ISS176. Un trabajo cuyo partido ya se jugo no puede servir para nada, pero
  -- la cola lo reintentaba para siempre. Willem II llego a 103 intentos por un
  -- partido de hace 6 dias. Se limpiaron 82 a mano en ISS167; esto lo hace solo.
  update v2.soccer_coverage_job
  set status = 'RETIRADO_PARTIDO_YA_JUGADO',
      last_error = coalesce(last_error,'')||' | retirado automaticamente el '||now()::date
                   ||': su partido (next_kickoff '||next_kickoff::date||') ya se jugo. '
                   ||attempts||' intentos acumulados.',
      updated_at = now()
  where status in ('PENDING','RETRY')
    and next_kickoff is not null
    and next_kickoff < now() - interval '6 hours';
  get diagnostics n = row_count;
  return n;
end
$fn$;

select cron.schedule('retirar-trabajos-zombis', '17 * * * *',
                     $$select v2.retirar_trabajos_de_partidos_ya_jugados();$$);


-- ---------------------------------------------------------------------------
-- VERIFICACION
-- ---------------------------------------------------------------------------
-- select * from public.gate_mlb_one_brain_medible();
-- select count(*) total, count(favorito_pct) con_pct from public.v_favorito_mlb;
-- select eval_window, count(*) from v2.mlb_learning_snapshot
--   where model_version='mlb_one_brain_v2' group by 1;
-- select v2.run_model_learning_cycle();  -- debe traer 'one_brain' dentro de 'mlb_capture'
-- select count(*) from v2.soccer_coverage_job
--   where status in ('PENDING','RETRY') and next_kickoff < now() - interval '6 hours';  -- 0
