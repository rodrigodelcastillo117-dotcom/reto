-- ISS148: additive NFL history ingestion for an independent temporal Elo challenger.
-- Reuses generic team_history_queue/absorber without changing NBA/WNBA/NHL ingestion.
create or replace function v2.enqueue_nfl_history_v1(
  p_from date default '2021-08-01'::date,
  p_to date default current_date
) returns jsonb
language plpgsql security definer
set search_path=v2,public,extensions,pg_temp
as $$
declare n int;
begin
  insert into v2.team_history_queue(req_id,sport,league_name,espn_endpoint,date_from,date_to)
  select net.http_get(
    'https://site.web.api.espn.com/apis/site/v2/sports/football/nfl/scoreboard?limit=400&dates='||
      to_char(g.d,'YYYYMMDD')||'-'||to_char(least((g.d+interval '1 month'-interval '1 day')::date,p_to),'YYYYMMDD')),
    'football','NFL','football/nfl',g.d,least((g.d+interval '1 month'-interval '1 day')::date,p_to)
  from generate_series(date_trunc('month',p_from::timestamp)::date,date_trunc('month',p_to::timestamp)::date,interval '1 month') g(d)
  on conflict(espn_endpoint,date_from,date_to) do nothing;
  get diagnostics n=row_count;
  return jsonb_build_object('queued',n,'from',p_from,'to',p_to,'endpoint','football/nfl');
end $$;

grant execute on function v2.enqueue_nfl_history_v1(date,date) to authenticated;
