-- ============================================================================
-- iss030 TEST — invariantes del dossier manifest (BLOQUE 3)
-- Corre en tx con ROLLBACK. Requiere iss030 cargado. Prueba sobre un evento real.
-- ============================================================================
begin;
do $$
declare r record; n_model_active int:=0; n_bad_asof int:=0; n_bad_role int:=0;
begin
  for r in select * from v2.fn_soccer_dossier_manifest('401915446') loop
    -- INV1: role válido
    if r.role not in ('MODEL_ACTIVE','CONTEXT_ONLY','AVAILABLE_NOT_USED') then n_bad_role:=n_bad_role+1; end if;
    -- INV2: nada MODEL_ACTIVE con as_of > decision o sin as_of
    if r.role='MODEL_ACTIVE' then
      n_model_active:=n_model_active+1;
      if r.data_asof is null or r.data_asof > r.decision_time then
        raise exception 'FAIL: % es MODEL_ACTIVE con as_of inválido (asof=% dec=%)', r.source_name, r.data_asof, r.decision_time;
      end if;
    end if;
    -- INV3: used_in_p_reto sólo si MODEL_ACTIVE
    if r.used_in_p_reto and r.role<>'MODEL_ACTIVE' then
      raise exception 'FAIL: % used_in_p_reto sin ser MODEL_ACTIVE', r.source_name;
    end if;
    -- INV4: temporally_safe=false => nunca CONTEXT_ONLY/MODEL_ACTIVE
    if not r.temporally_safe and r.role in ('MODEL_ACTIVE','CONTEXT_ONLY') then
      raise exception 'FAIL: % usada sin ser temporally_safe', r.source_name;
    end if;
    -- INV5: freshness FUTURE_INVALID => no usada
    if r.freshness_status='FUTURE_INVALID' and r.role in ('MODEL_ACTIVE','CONTEXT_ONLY') then
      raise exception 'FAIL: % con as_of futuro pero marcada usada', r.source_name;
    end if;
  end loop;
  if n_bad_role>0 then raise exception 'FAIL: % roles inválidos', n_bad_role; end if;
  raise notice 'PASS dossier manifest: roles válidos, % MODEL_ACTIVE, sin fuga temporal ni as_of inventado', n_model_active;
end $$;
rollback;
