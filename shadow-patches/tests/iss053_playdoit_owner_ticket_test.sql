-- Permanent crash test from owner PlayDoIt ticket 5397925211 (2026-09-10).
-- 11 selections, 6 economic event groups, 5 SGP groups.
begin;
select v2.fn_seed_parlay_scanner_agenda_real();

do $t$
declare r jsonb; ids text[]; leagues text[]; n int; bad int;
begin
  r := v2.fn_finalize_scanned_parlay(jsonb_build_object(
    'casa','PlayDoIt','tipo','parlay','momio_total',37.80,'apuesta',1156,
    'pago_con_bono',43719.82,'bono',0,'bet_id_casa','5397925211',
    'picks',jsonb_build_array(
      jsonb_build_object('partido','Fenerbahçe vs AS Roma','espn_home_team','Fenerbahçe','espn_away_team','AS Roma','liga','UEFA Europa League','pick_desc','Ambos equipos marcan Sí','momio',1.869565,'intended_game_date','2026-09-10'),
      jsonb_build_object('partido','Fenerbahce - AS Roma','espn_home_team','Fenerbahce','espn_away_team','AS Roma','liga','UEFA Europa League','pick_desc','Over 2.5','momio',1.0,'intended_game_date','2026-09-10'),
      jsonb_build_object('partido','PSV Eindhoven - Shakhtar Donetsk','espn_home_team','PSV Eindhoven','espn_away_team','Shakhtar Donetsk','liga','NBA','pick_desc','Ambos equipos marcan Sí','momio',2.45,'intended_game_date','2026-09-10','espn_event_id','401915422'),
      jsonb_build_object('partido','PSV Eindhoven - Shakhtar Donetsk','espn_home_team','PSV Eindhoven','espn_away_team','Shakhtar Donetsk','liga','NBA','pick_desc','PSV Eindhoven ML','momio',1.0,'intended_game_date','2026-09-10','espn_event_id','401915422'),
      jsonb_build_object('partido','Bayern München - Bodo/Glimt','espn_home_team','Bayern München','espn_away_team','Bodo/Glimt','liga','UEFA Champions League','pick_desc','Bayern Munich -1.5 Hándicap Asiático','momio',2.33,'intended_game_date','2026-09-10','espn_event_id','af_1635632'),
      jsonb_build_object('partido','Bayern München - Bodo/Glimt','espn_home_team','Bayern München','espn_away_team','Bodo/Glimt','liga','UEFA Champions League','pick_desc','Ambos equipos marcan Sí','momio',1.0,'intended_game_date','2026-09-10','espn_event_id','af_1635632'),
      jsonb_build_object('partido','Como - RB Leipzig','espn_home_team','Como','espn_away_team','RB Leipzig','liga','UEFA Europa League','pick_desc','Como ML','momio',1.833333,'intended_game_date','2026-09-10'),
      jsonb_build_object('partido','Como - RB Leipzig','espn_home_team','Como','espn_away_team','RB Leipzig','liga','UEFA Europa League','pick_desc','Como Over 1.5 Goles','momio',1.0,'intended_game_date','2026-09-10'),
      jsonb_build_object('partido','Slavia Prague - Lens','espn_home_team','Slavia Prague','espn_away_team','Lens','liga','UEFA Europa League','pick_desc','Ambos equipos marcan Sí','momio',1.571429,'intended_game_date','2026-09-10','espn_event_id','401915440'),
      jsonb_build_object('partido','Manchester United - Sabah FA','espn_home_team','Manchester United','espn_away_team','Sabah FA','liga','UEFA Europa League','pick_desc','Manchester United -1.5 Hándicap Asiático','momio',1.222222,'intended_game_date','2026-09-10','espn_event_id','af_1635697'),
      jsonb_build_object('partido','Manchester United - Sabah FA','espn_home_team','Manchester United','espn_away_team','Sabah FA','liga','UEFA Europa League','pick_desc','Manchester United Over 1.5 Goles','momio',1.0,'intended_game_date','2026-09-10','espn_event_id','af_1635697')
    )));

  if r->>'status' <> 'STRUCTURALLY_RESOLVED' or (r->>'needs_manual_review')::boolean then
    raise exception 'owner ticket not structurally resolved: %',r;
  end if;
  if jsonb_array_length(r->'picks') <> 11 then raise exception 'expected 11 selections'; end if;
  if (r->>'economic_group_count')::int <> 6 then raise exception 'expected 6 economic groups: %',r->'economic_groups'; end if;
  if (r->>'correlated_group_count')::int <> 5 then raise exception 'expected 5 SGP groups'; end if;
  if r->>'correlation_status' <> 'UNMODELED_REQUIRES_JOINT_MODEL' then raise exception 'correlation status wrong'; end if;
  if r->'joint_probability' is not null or r->'EV_REAL' is not null or r->'house_edge' is not null then raise exception 'invented joint probability/EV/house edge'; end if;
  if (r->>'momio_total_ticket')::numeric <> 37.80 then raise exception 'ticket odds authority lost'; end if;
  if (r->>'momio_total_grouped')::numeric not between 37.4 and 37.8 then raise exception 'grouped odds wrong: %',r->>'momio_total_grouped'; end if;
  if (r->>'momios_desvio_pct')::numeric > 1 then raise exception 'grouped vs ticket deviation too high'; end if;
  if (r->>'payout_ticket_total')::numeric <> 43719.82 then raise exception 'printed payout lost'; end if;
  if (r->>'bonus_amount')::numeric <> 0 or r->>'bonus_status' <> 'NOT_PRINTED' then raise exception 'bonus invented'; end if;
  if (r->>'is_canonical_reto13m')::boolean then raise exception 'parlay became canonical without joint model'; end if;

  select array_agg(x->>'espn_event_id' order by ord), array_agg(x->>'liga' order by ord)
    into ids, leagues
    from jsonb_array_elements(r->'picks') with ordinality e(x,ord);
  if ids <> array['401915444','401915444','401915422','401915422','401915443','401915443','401915441','401915441','401915440','401915442','401915442'] then
    raise exception 'canonical ESPN IDs wrong: %',ids;
  end if;
  if exists(select 1 from unnest(leagues) z where z <> 'UEFA Champions League') then raise exception 'canonical leagues wrong: %',leagues; end if;

  select count(*) into bad from jsonb_array_elements(r->'picks') x
    where (x->>'sgp_group_size')::int > 1
      and ((x->>'individual_odds_required')::boolean or not (x->>'included_in_group_price')::boolean
           or coalesce((x->>'momio')::numeric,0) < 1.01);
  if bad <> 0 then raise exception 'SGP leg contract regression'; end if;
end
$t$;
rollback;
select 'PLAYDOIT_OWNER_TICKET_PASS' result;
