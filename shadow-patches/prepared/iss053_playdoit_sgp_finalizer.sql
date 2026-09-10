-- iss053 — deterministic scanner finalizer for SGP / PlayDoIt
-- Branch-only until release gate. Does NOT call an LLM and does NOT invent odds/EV/bonus.
-- Depends on iss046/iss052 canonical resolver + agenda.

create schema if not exists v2;

-- A price is PRESENT only when the field is non-null and valid.  This is distinct
-- from fn_decimal_odds_valid(NULL), where NULL means "absent, not malformed".
create or replace function v2.fn_scanned_leg_price(p_leg jsonb)
returns numeric language plpgsql immutable as $$
declare t text; n numeric;
begin
  t := nullif(p_leg->>'sgm_group_momio','');
  if t is not null and v2.fn_decimal_odds_valid(t) then return t::numeric; end if;
  t := nullif(p_leg->>'sgp_group_odds','');
  if t is not null and v2.fn_decimal_odds_valid(t) then return t::numeric; end if;
  t := nullif(p_leg->>'momio','');
  if t is not null and v2.fn_decimal_odds_valid(t) then return t::numeric; end if;
  return null;
exception when others then
  return null;
end $$;

create or replace function v2.fn_finalize_scanned_parlay(p_payload jsonb)
returns jsonb language plpgsql stable as $$
declare
  v_picks jsonb := coalesce(p_payload->'picks','[]'::jsonb);
  v_norm jsonb := '[]'::jsonb;
  v_out jsonb := '[]'::jsonb;
  v_groups jsonb := '[]'::jsonb;
  v_leg jsonb; v_r jsonb; v_pair text[]; v_home text; v_away text; v_event text; v_liga text;
  v_group_id text; v_group_size int; v_group_odds numeric; v_price_count int;
  v_idx int := 0; v_carrier_seen jsonb := '{}'::jsonb;
  v_unresolved int := 0; v_price_conflicts int := 0;
  v_ticket_odds numeric; v_grouped_odds numeric; v_stake numeric; v_payout numeric; v_bonus numeric; v_diff numeric;
  v_corr_groups int := 0; v_status text;
begin
  if jsonb_typeof(p_payload) <> 'object' or jsonb_typeof(v_picks) <> 'array' or jsonb_array_length(v_picks)=0 then
    return jsonb_build_object('status','INVALID_SCAN_PAYLOAD','needs_manual_review',true,'is_canonical_reto13m',false);
  end if;

  -- Current scanner universe. On cutover this seeder is replaced by the normal
  -- agenda refresh; no OCR league is allowed to veto a unique team/date event.
  perform v2.fn_seed_parlay_scanner_agenda_real();

  -- 1) Resolve every selection to one canonical ESPN event. Any stale af_* id is
  -- ignored and repaired from teams + intended date. Canonical agenda league wins.
  for v_leg in select value from jsonb_array_elements(v_picks) loop
    v_idx := v_idx + 1;
    v_home := nullif(v_leg->>'espn_home_team','');
    v_away := nullif(v_leg->>'espn_away_team','');
    if v_home is null or v_away is null then
      v_pair := regexp_split_to_array(coalesce(v_leg->>'partido',''), '\s+(?:vs\.?|-|–|—|@)\s+', 'i');
      if coalesce(array_length(v_pair,1),0)>=2 then
        v_home := nullif(trim(v_pair[1]),'');
        v_away := nullif(trim(v_pair[array_length(v_pair,1)]),'');
      end if;
    end if;

    v_r := v2.fn_resolve_event(
      v_home, v_away, nullif(v_leg->>'intended_game_date','')::date, v_leg->>'liga',
      case when coalesce(v_leg->>'espn_event_id','') ~ '^\d{6,}$' then v_leg->>'espn_event_id' else null end, 1);
    if v_r->>'status' <> 'RESOLVED' then
      v_r := v2.fn_resolve_event(v_home,v_away,nullif(v_leg->>'intended_game_date','')::date,v_leg->>'liga',null,1);
    end if;

    v_event := nullif(v_r->>'canonical_event_id','');
    if v_event is null then v_unresolved := v_unresolved + 1; end if;
    select coalesce(a.liga_nombre, v_leg->>'liga') into v_liga
      from public.agenda_espn a where a.espn_event_id=v_event limit 1;
    v_liga := coalesce(v_liga,
      case when (v_r->>'competition_id')='2' then 'UEFA Champions League' else v_leg->>'liga' end);

    v_norm := v_norm || jsonb_build_array(v_leg || jsonb_build_object(
      '_ord',v_idx,
      'espn_event_id',v_event,
      'canonical_event_id',v_event,
      'espn_home_team',coalesce(v_r->>'home_canonical',v_home),
      'espn_away_team',coalesce(v_r->>'away_canonical',v_away),
      'partido',case when v_event is not null then coalesce(v_r->>'home_canonical',v_home)||' - '||coalesce(v_r->>'away_canonical',v_away) else v_leg->>'partido' end,
      'liga',v_liga,
      'identity_status',v_r->>'status',
      'identity_confidence',coalesce((v_r->>'identity_confidence')::numeric,0)
    ));
  end loop;

  -- 2) Economic grouping is by canonical event, not by OCR row. Multiple selections
  -- on one event are one SGP-priced economic leg. The selections remain separate
  -- for grading. A missing secondary individual price is valid and is never 1.0.
  with x as (
    select e.value leg, (e.value->>'_ord')::int ord,
           coalesce(nullif(e.value->>'canonical_event_id',''), 'unresolved:'||(e.value->>'_ord')) gk,
           v2.fn_scanned_leg_price(e.value) price
      from jsonb_array_elements(v_norm) e
  ), g as (
    select gk, count(*) n,
           min(price) filter(where price is not null) pmin,
           max(price) filter(where price is not null) pmax,
           count(distinct round(price,4)) filter(where price is not null) pn,
           min(ord) first_ord
      from x group by gk
  )
  select coalesce(jsonb_agg(jsonb_build_object(
      'group_id',gk,'size',n,'group_odds',pmax,'price_min',pmin,'price_max',pmax,
      'price_variants',pn,'first_ord',first_ord) order by first_ord),'[]'::jsonb)
    into v_groups from g;

  for v_leg in select value from jsonb_array_elements(v_norm) order by (value->>'_ord')::int loop
    v_event := nullif(v_leg->>'canonical_event_id','');
    v_group_id := coalesce(v_event,'unresolved:'||(v_leg->>'_ord'));
    select (g->>'size')::int, nullif(g->>'group_odds','')::numeric, coalesce((g->>'price_variants')::int,0)
      into v_group_size,v_group_odds,v_price_count
      from jsonb_array_elements(v_groups) g where g->>'group_id'=v_group_id limit 1;

    if v_price_count > 1 then v_price_conflicts := v_price_conflicts + 1; end if;
    if v_group_size > 1 and not (v_carrier_seen ? v_group_id) then v_corr_groups := v_corr_groups + 1; end if;

    -- Compatibility field momio receives the group display price on every SGP row,
    -- so legacy UI does not render a fake 1.0 / red invalid box. Only momio_is_group
    -- marks the economic carrier. New UI must use sgp_group_odds + individual_odds.
    v_leg := v_leg - '_ord' || jsonb_build_object(
      'sgp_group_id',case when v_group_size>1 then 'event:'||v_group_id else null end,
      'sgp_group_size',v_group_size,
      'sgp_group_odds',v_group_odds,
      'sgm_group_momio',v_group_odds,
      'included_in_group_price',v_group_size>1,
      'individual_odds',case when v_group_size=1 then v_group_odds else null end,
      'individual_odds_required',v_group_size=1,
      'momio',v_group_odds,
      'momio_legible',v_group_odds is not null,
      'momio_is_group',case when v_group_odds is null then false when not (v_carrier_seen ? v_group_id) then true else false end,
      'needs_manual_review',(v_event is null or v_group_odds is null or v_price_count>1)
    );
    if not (v_carrier_seen ? v_group_id) then
      v_carrier_seen := v_carrier_seen || jsonb_build_object(v_group_id,true);
    end if;
    v_out := v_out || jsonb_build_array(v_leg);
  end loop;

  select exp(sum(ln((g->>'group_odds')::numeric))) into v_grouped_odds
    from jsonb_array_elements(v_groups) g where nullif(g->>'group_odds','') is not null;
  if v_grouped_odds is not null then v_grouped_odds := round(v_grouped_odds,4); end if;

  v_ticket_odds := case when nullif(p_payload->>'momio_total','') is not null
                         and v2.fn_decimal_odds_valid(p_payload->>'momio_total')
                        then (p_payload->>'momio_total')::numeric else null end;
  begin v_stake := nullif(p_payload->>'apuesta','')::numeric; exception when others then v_stake:=null; end;
  begin v_payout := coalesce(nullif(p_payload->>'pago_con_bono','')::numeric,nullif(p_payload->>'pago_total','')::numeric); exception when others then v_payout:=null; end;
  begin v_bonus := case when coalesce(nullif(p_payload->>'bono','')::numeric,0)>0 then (p_payload->>'bono')::numeric else 0 end; exception when others then v_bonus:=0; end;
  v_diff := case when v_ticket_odds is not null and v_grouped_odds is not null
                 then round(abs(v_grouped_odds-v_ticket_odds)/v_ticket_odds*100,2) end;

  v_status := case
    when v_unresolved>0 then 'NEEDS_REVIEW_IDENTITY'
    when v_price_conflicts>0 then 'NEEDS_REVIEW_GROUP_PRICE_CONFLICT'
    when exists(select 1 from jsonb_array_elements(v_groups) g where nullif(g->>'group_odds','') is null) then 'NEEDS_REVIEW_MISSING_GROUP_PRICE'
    else 'STRUCTURALLY_RESOLVED' end;

  return p_payload || jsonb_build_object(
    'picks',v_out,
    'economic_groups',v_groups,
    'economic_group_count',jsonb_array_length(v_groups),
    'correlated_group_count',v_corr_groups,
    'correlation_status',case when v_corr_groups>0 then 'UNMODELED_REQUIRES_JOINT_MODEL' else 'NOT_MODELED' end,
    'joint_probability',null,
    'EV_REAL',null,
    'house_edge',null,
    'momio_total_ticket',v_ticket_odds,
    'momio_total_grouped',v_grouped_odds,
    'momios_desvio_pct',v_diff,
    'momios_coherentes',case when v_diff is null then null else v_diff<=8 end,
    'apuesta',v_stake,
    'payout_ticket_total',v_payout,
    'payout_derived_check',case when v_stake is not null and v_ticket_odds is not null then round(v_stake*v_ticket_odds,2) end,
    'payout_delta',case when v_payout is not null and v_stake is not null and v_ticket_odds is not null then round(v_payout-v_stake*v_ticket_odds,2) end,
    'payout_authority','PRINTED_TICKET_TOTAL',
    'bonus_amount',v_bonus,
    'bonus_status',case when v_bonus>0 then 'EXPLICIT_ON_TICKET' else 'NOT_PRINTED' end,
    'status',v_status,
    'needs_manual_review',v_status<>'STRUCTURALLY_RESOLVED',
    'is_canonical_reto13m',false,
    'canonical_reason','NO_VALIDATED_JOINT_PARLAY_MODEL'
  );
end $$;

comment on function v2.fn_finalize_scanned_parlay(jsonb) is
'iss053: deterministic post-OCR finalizer. Canonical ESPN event + canonical league, one economic SGP price per event, all selections preserved, no fake 1.0, no invented bonus/EV/joint probability.';
