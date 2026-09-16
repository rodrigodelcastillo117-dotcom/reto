-- =====================================================================
-- ISS133 -- EL PASO QUE NUNCA CORRIO, AHORA CORRE SOLO
--
-- En ISS129 encontre que la cadena de cobertura de futbol estaba construida
-- entera y rota en dos puntos. ISS130 revivio la ingesta (estaba muerta 6
-- dias por un statement timeout). Quedaba el otro: v2.fn_fit_phi_extension,
-- el estimador de fuerza de liga, existia desde siempre y NADIE lo ejecutaba.
-- Cada liga nueva habia que ajustarla a mano.
--
-- Esto lo automatiza. Ahora la cadena completa se mueve sola:
--   ingesta llena soccer_domestic_observation
--     -> cada 30 min se intenta ajustar phi de las ligas sin phi
--        -> solo entran las que PASAN el holdout temporal
--           -> se re-sella el snapshot
--              -> el modelo ya puede predecir esos partidos
--
-- FALLA CERRADO POR DISENO:
--   - Solo instala ligas con fit_status='PASS', que exige mejorar Brier Y
--     logloss contra phi=0 sobre un holdout temporal 70/30, con minimo 20
--     partidos inter-liga usables y al menos 5 de prueba.
--   - Re-sella UNA sola vez al final y verifica la integridad. Si el sello
--     queda roto, RAISE EXCEPTION y la transaccion entera se revierte.
--     Preferible reventar que servir predicciones con un snapshot corrupto.
--   - Todo queda en public.phi_extension_log, incluidas las RECHAZADAS.
--     Lo que se rechaza tambien es evidencia.
--
-- POR QUE EL RE-SELLADO IMPORTA TANTO:
--   fn_crossleague_predict_canonical CONSULTA
--   fn_crossleague_strength_integrity antes de predecir. Insertar una liga
--   sin re-sellar no "agrega una liga": tumba TODAS las predicciones del
--   modelo. Por eso insert y reseal van en la misma transaccion.
-- =====================================================================

create table if not exists public.phi_extension_log (
  id bigserial primary key,
  corrida_at timestamptz not null default now(),
  league_id int, liga text, n_usable int, n_test int, phi numeric,
  brier_phi numeric, brier_phi0 numeric, fit_status text, accion text
);

drop function if exists v2.ajustar_e_instalar_phi(text,int,boolean);

create function v2.ajustar_e_instalar_phi(
  p_model_version text default 'crossleague_v1_1',
  p_min_usable int default 20,
  p_dry_run boolean default true)
returns table(out_league_id int, out_liga text, out_n_usable int, out_n_test int, out_phi numeric,
              out_brier_phi numeric, out_brier_phi0 numeric, out_fit_status text, out_accion text)
language plpgsql security definer
set search_path to 'v2','public' set statement_timeout = '300s'
as $fn$
-- NOTA: los parametros de salida se llaman out_* a proposito. Si se llaman
-- league_id/phi, el UPDATE del sello choca con las columnas de la tabla y
-- Postgres tira "column reference is ambiguous". Me paso, la primera corrida
-- programada fallo asi, y el error aborto todo sin corromper nada.
declare r record; f record; v_cut timestamptz; v_ch text; v_instaladas int := 0;
begin
  select training_cutoff into v_cut from v2.crossleague_model_registry where model_version=p_model_version;
  if v_cut is null then
    return query select null::int,'MODELO_NO_EXISTE'::text,null::int,null::int,null::numeric,
                        null::numeric,null::numeric,'MODEL_NOT_FOUND'::text,'ABORTADO'::text;
    return;
  end if;
  select max(s.config_hash) into v_ch from v2.crossleague_league_strength s
   where s.model_version=p_model_version and s.training_cutoff=v_cut;

  for r in
    select o.domestic_league_id as lid, min(o.domestic_league_name) as lname
    from v2.soccer_domestic_observation o
    where not exists (select 1 from v2.crossleague_league_strength s
                      where s.model_version=p_model_version and s.training_cutoff=v_cut
                        and s.league_id=o.domestic_league_id)
    group by o.domestic_league_id
  loop
    select * into f from v2.fn_fit_phi_extension(p_model_version, r.lid, p_min_usable);

    if f.fit_status = 'PASS' and not p_dry_run then
      insert into v2.crossleague_league_strength
        (model_version, training_cutoff, league_id, league_name, phi, n_cross, servable, config_hash, fitted_at)
      values (p_model_version, v_cut, r.lid, r.lname, f.phi_full, f.n_usable, true, v_ch, now())
      on conflict do nothing;
      v_instaladas := v_instaladas + 1;
    end if;

    out_league_id := r.lid; out_liga := r.lname;
    out_n_usable := f.n_usable; out_n_test := f.n_test; out_phi := f.phi_full;
    out_brier_phi := f.brier_phi; out_brier_phi0 := f.brier_phi0; out_fit_status := f.fit_status;
    out_accion := case when f.fit_status<>'PASS' then 'RECHAZADA_FALLA_CERRADO'
                       when p_dry_run then 'PASARIA_dry_run' else 'INSTALADA' end;
    return next;
  end loop;

  if v_instaladas > 0 and not p_dry_run then
    update v2.crossleague_strength_seal sl
    set league_count = (select count(*) from v2.crossleague_league_strength x
                        where x.model_version=sl.model_version and x.training_cutoff=sl.training_cutoff),
        config_hash  = (select max(x.config_hash) from v2.crossleague_league_strength x
                        where x.model_version=sl.model_version and x.training_cutoff=sl.training_cutoff),
        snapshot_hash= (select md5(string_agg(concat_ws(':',x.league_id::text,x.phi::text,x.n_cross::text,x.servable::text,x.config_hash),'|' order by x.league_id))
                        from v2.crossleague_league_strength x
                        where x.model_version=sl.model_version and x.training_cutoff=sl.training_cutoff),
        sealed_at    = now()
    where sl.model_version=p_model_version and sl.training_cutoff=v_cut;

    if not v2.fn_crossleague_strength_integrity(p_model_version, v_cut) then
      raise exception 'SELLO ROTO tras instalar % ligas. Se revierte todo.', v_instaladas;
    end if;
  end if;
end $fn$;

create or replace function v2.correr_ajuste_phi(p_dry_run boolean default false)
returns int language plpgsql security definer
set search_path to 'v2','public' set statement_timeout = '300s' as $fn$
declare n int;
begin
  insert into public.phi_extension_log
    (league_id, liga, n_usable, n_test, phi, brier_phi, brier_phi0, fit_status, accion)
  select out_league_id, out_liga, out_n_usable, out_n_test, out_phi,
         out_brier_phi, out_brier_phi0, out_fit_status, out_accion
  from v2.ajustar_e_instalar_phi('crossleague_v1_1', 20, p_dry_run);
  get diagnostics n = row_count;
  return n;
end $fn$;

-- Cada 30 minutos. Una corrida completa tarda ~60-70s.
select cron.schedule('phi-extension-30m', '7,37 * * * *', $$select v2.correr_ajuste_phi(false);$$);

-- =====================================================================
-- VERIFICADO EN VIVO, NO EN TEORIA:
--
--   La primera corrida programada FALLO con
--     ERROR: column reference "league_id" is ambiguous
--   El error aborto la transaccion: 0 ligas instaladas, sello intacto (22
--   ligas, integridad true). Ese es el comportamiento correcto y por eso
--   verifique antes de dar nada por bueno.
--
--   Tras renombrar los parametros de salida a out_*, tres corridas seguidas
--   SUCCEEDED (~60-70s cada una), y la automatizacion instalo sola:
--     HNL (Croacia, liga 210): n=21, holdout 7, phi -0.406,
--                              Brier 0.7810 vs 0.8334
--   Esa misma liga habia sido RECHAZADA una hora antes con n=17. La ingesta
--   la lleno y el ajuste automatico la recogio. El bucle funciona.
--
--   Ligas con phi: 19 al empezar la sesion -> 23 ahora, sello integro.
--   P_RETO publicado: 152 al empezar -> 156, con 0 PERDIDOS en toda la
--   secuencia (medicion pareada evento por evento contra iss129_antes).
--
--   Goles esperados sobre los 233 publicados:
--     169 completos | 15 parciales | 49 sin muestra
--
-- LO QUE SIGUE SOLO, SIN QUE NADIE LO EMPUJE:
--   cron 420 cada 5 min  -> ingesta de historial domestico (6 equipos/corrida)
--   cron 524 cada 30 min -> ajuste e instalacion de phi
--   cron 419 cada 3 h    -> reconstruccion de predicciones
--   A medida que la ingesta llene las ligas que hoy fallan por muestra
--   (Israel n=9, Eslovenia n=12, Hungria n=15), entraran solas.
--
-- LO QUE NO SE ARREGLA SOLO:
--   Las copas domesticas (EFL Cup, Copa del Rey, Coppa Italia) enfrentan
--   divisiones distintas del mismo pais. fn_fit_phi_extension solo cuenta
--   como "inter-liga" los partidos continentales (uefa/conmebol/concacaf/
--   afc/fifa), y los equipos de segunda division casi nunca juegan en
--   Europa. Para servir esas copas habria que dejar que los propios
--   partidos de copa domestica cuenten como evidencia inter-liga. Eso es
--   cambiar QUE DATOS ajustan el modelo, no un parche de cobertura, y no lo
--   hago sin medirlo aparte.
-- =====================================================================
