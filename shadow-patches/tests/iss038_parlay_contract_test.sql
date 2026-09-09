-- ============================================================================
-- iss038 — adversarial regression for canonical parlay leg contract
-- RUN ONLY after iss018 + iss021 + iss038 are installed in an ISOLATED DB branch.
-- READ-ONLY against the installed staged objects; no PROD execution under HOLD.
-- ============================================================================

-- 1) La vista visible JAMÁS publica probabilidad conjunta.
do $$
begin
  if exists (
    select 1 from v2.v_parlay_canonical_contract
    where joint_probability is not null
  ) then
    raise exception 'FAIL iss038: joint_probability must be NULL without validated joint model';
  end if;
end $$;

-- 2) Una pata con unavailable_reason JAMÁS puede exponer P_RETO.
do $$
begin
  if exists (
    select 1
    from v2.v_parlay_canonical_contract p,
         lateral jsonb_array_elements(coalesce(p.legs,'[]'::jsonb)) l
    where l->>'unavailable_reason' is not null
      and l->'p_reto' is not null
      and l->'p_reto' <> 'null'::jsonb
  ) then
    raise exception 'FAIL iss038: fail-closed leg exposes P_RETO';
  end if;
end $$;

-- 3) Toda P_RETO publicada cumple data_asof <= decision_time.
do $$
begin
  if exists (
    select 1
    from v2.v_parlay_canonical_contract p,
         lateral jsonb_array_elements(coalesce(p.legs,'[]'::jsonb)) l
    where l->'p_reto' is not null
      and l->'p_reto' <> 'null'::jsonb
      and (
        nullif(l#>>'{provenance,model_source,data_asof}','') is null
        or (l#>>'{provenance,model_source,data_asof}')::timestamptz > p.decision_time
      )
  ) then
    raise exception 'FAIL iss038: P_RETO leg violates data_asof <= decision_time';
  end if;
end $$;

-- 4) Adversarial O/U: si la línea real es 3.5, pedir 2.5 DEBE fail-close.
do $$
declare
  r record;
  x jsonb;
begin
  select canonical_event_id, linea_ou, data_asof
    into r
  from public.v_prediccion_reto_futbol
  where model_status='UNVALIDATED'
    and linea_ou=3.5
    and p_over is not null
    and data_asof is not null
  order by scheduled_at
  limit 1;

  if not found then
    raise notice 'SKIP iss038 O/U adversarial: no READY event with provider line 3.5 in isolated fixture set';
    return;
  end if;

  x := v2.fn_parlay_leg_canonical_contract(
    jsonb_build_object(
      'deporte','Fútbol',
      'espn_event_id',r.canonical_event_id,
      'pick_desc','Más de 2.5 goles'
    ),
    greatest(now(),r.data_asof)
  );

  if x->'p_reto' is not null and x->'p_reto' <> 'null'::jsonb then
    raise exception 'FAIL iss038: requested 2.5 was substituted when canonical provider line is 3.5: %',x;
  end if;
  if x->>'unavailable_reason' not like '%línea solicitada no coincide%'
     and x->>'unavailable_reason' <> 'LINE_MISMATCH' then
    raise exception 'FAIL iss038: expected LINE_MISMATCH semantics for 2.5 vs 3.5, got %',x;
  end if;
end $$;

-- 5) O/U exacta: cuando 3.5 sí es la línea canónica y es temporalmente válida,
--    la pata debe devolver esa MISMA línea, nunca 2.5.
do $$
declare
  r record;
  x jsonb;
  dt timestamptz;
begin
  select * into r
  from public.v_prediccion_reto_futbol
  where model_status='UNVALIDATED'
    and linea_ou=3.5
    and p_over is not null
    and data_asof is not null
    and provider_line_asof is not null
  order by scheduled_at
  limit 1;

  if not found then
    raise notice 'SKIP iss038 exact O/U: no READY 3.5 fixture in isolated fixture set';
    return;
  end if;

  dt := greatest(now(),r.data_asof,r.provider_line_asof);
  x := v2.fn_parlay_leg_canonical_contract(
    jsonb_build_object(
      'deporte','Fútbol',
      'espn_event_id',r.canonical_event_id,
      'pick_desc','Más de 3.5 goles'
    ),dt
  );

  if x->>'unavailable_reason' is not null then
    raise exception 'FAIL iss038: exact provider line 3.5 unexpectedly unavailable: %',x;
  end if;
  if (x->>'canonical_line')::numeric <> 3.5 then
    raise exception 'FAIL iss038: canonical_line changed from provider 3.5: %',x;
  end if;
  if (x->>'p_reto')::numeric <> r.p_over then
    raise exception 'FAIL iss038: leg P_RETO differs from canonical matrix p_over: % vs %',x->>'p_reto',r.p_over;
  end if;
end $$;

-- 6) BTTS No: sólo el campo EXPLÍCITO p_btts_no puede autorizar la pata.
do $$
declare
  r record;
  x jsonb;
  dt timestamptz;
begin
  select * into r
  from public.v_prediccion_reto_futbol
  where model_status='UNVALIDATED'
    and p_btts_no is not null
    and data_asof is not null
  order by scheduled_at
  limit 1;

  if not found then
    raise notice 'SKIP iss038 BTTS No: no explicit p_btts_no fixture in isolated fixture set';
    return;
  end if;

  dt := greatest(now(),r.data_asof);
  x := v2.fn_parlay_leg_canonical_contract(
    jsonb_build_object(
      'deporte','Fútbol',
      'espn_event_id',r.canonical_event_id,
      'pick_desc','BTTS No'
    ),dt
  );

  if x->>'unavailable_reason' is not null then
    raise exception 'FAIL iss038: explicit BTTS No unexpectedly unavailable: %',x;
  end if;
  if (x->>'p_reto')::numeric <> r.p_btts_no then
    raise exception 'FAIL iss038: BTTS No is not exact explicit matrix p_btts_no: % vs %',x->>'p_reto',r.p_btts_no;
  end if;
end $$;

-- 7) Contrato visible no debe contener ai_prob_combinada como columna top-level.
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema='v2'
      and table_name='v_parlay_canonical_contract'
      and column_name ilike '%ai_prob_combinada%'
  ) then
    raise exception 'FAIL iss038: ai_prob_combinada leaked into visible parlay contract';
  end if;
end $$;

select 'ISS038_PARLAY_CANONICAL_CONTRACT_TESTS_PASS' as result;
