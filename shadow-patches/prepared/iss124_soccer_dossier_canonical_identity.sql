-- ISS124 — SOCCER DOSSIER CANONICAL IDENTITY · STAGED ONLY
-- Owner override: ChatGPT implementation branch. No production mutation.
--
-- Problem reproduced on disposable soccer-final-branch-gate:
-- fn_soccer_dossier_manifest pinned staged lookup to domestic dc-2026.09.1,
-- so all six real UCL crossleague_v1_1 fixtures reported "sin prediccion staged"
-- despite builder/staged/event-gate/candidates being valid.
--
-- Contract:
-- * event + decision_time must identify EXACTLY ONE staged canonical brain.
-- * never select an arbitrary LIMIT 1 when two brains exist.
-- * no model_version hardcode: domestic and crossleague use the same contract.
-- * expose exact staged model_version in provenance without changing return signature.
-- * fail closed on ambiguity.

DO $patch$
DECLARE
  v_def text;
  v_start text := 'select * into cfg from v2.model_config where sport=''soccer'' and model_version=''dc-2026.09.1'';';
  v_end text := 'v_sp_found := (sp.espn_event_id is not null);';
  p1 int;
  p2 int;
  v_block text;
BEGIN
  SELECT pg_get_functiondef('v2.fn_soccer_dossier_manifest(text,timestamp with time zone)'::regprocedure)
    INTO v_def;

  p1 := strpos(v_def, v_start);
  p2 := strpos(v_def, v_end);

  -- Source-guard: never silently patch an unexpected function body.
  IF p1 = 0 OR p2 = 0 OR p2 <= p1 THEN
    -- An already-hardened body is accepted only if both invariants are present.
    IF strpos(v_def, 'AMBIGUOUS_CANONICAL_STAGED') > 0
       AND strpos(v_def, 'model_version=''||coalesce(sp.model_version') > 0 THEN
      RETURN;
    END IF;
    RAISE EXCEPTION 'DOSSIER_PATCH_SOURCE_MISMATCH: expected legacy selection block not found';
  END IF;

  v_block := $body$-- canonical staged identity: exactly one row per event+decision snapshot.
  -- Never pin the dossier to a domestic model_version and never choose an arbitrary LIMIT 1.
  if p_decision_time is not null then
    if (select count(*) from v2.soccer_prediction_v2_staged spp
        where spp.espn_event_id=p_event_id and spp.decision_time=p_decision_time) > 1 then
      return query select 'modelo_p_reto'::text,'motor Dixon-Coles'::text,
        'v2.soccer_prediction_v2_staged'::text,false,null::timestamptz,p_decision_time,
        null::bigint,'AMBIGUOUS_CANONICAL_STAGED'::text,
        'múltiples filas staged para event+decision; fail-closed'::text,
        'AVAILABLE_NOT_USED'::text,false,false,false,
        null::numeric,null::uuid,null::text,null::timestamptz;
      return;
    end if;
    select spp.* into sp from v2.soccer_prediction_v2_staged spp
     where spp.espn_event_id=p_event_id and spp.decision_time=p_decision_time;
  else
    select max(spp.decision_time) into v_dec
      from v2.soccer_prediction_v2_staged spp where spp.espn_event_id=p_event_id;
    if v_dec is not null and
       (select count(*) from v2.soccer_prediction_v2_staged spp
         where spp.espn_event_id=p_event_id and spp.decision_time=v_dec) > 1 then
      return query select 'modelo_p_reto'::text,'motor Dixon-Coles'::text,
        'v2.soccer_prediction_v2_staged'::text,false,null::timestamptz,v_dec,
        null::bigint,'AMBIGUOUS_CANONICAL_STAGED'::text,
        'múltiples filas staged para el snapshot más reciente; fail-closed'::text,
        'AVAILABLE_NOT_USED'::text,false,false,false,
        null::numeric,null::uuid,null::text,null::timestamptz;
      return;
    end if;
    if v_dec is not null then
      select spp.* into sp from v2.soccer_prediction_v2_staged spp
       where spp.espn_event_id=p_event_id and spp.decision_time=v_dec;
    end if;
  end if;
  $body$;

  v_def := substr(v_def,1,p1-1) || v_block || substr(v_def,p2);

  v_def := replace(
    v_def,
    '''v2.soccer_prediction_v2_staged''::text prv,',
    '(''v2.soccer_prediction_v2_staged model_version=''||coalesce(sp.model_version,''NULL''))::text prv,'
  );

  EXECUTE v_def;
END
$patch$;
