-- iss058 — AUTOMATIC START/SIT v2 · STAGED / NO PROD CUTOVER
-- Depends on iss054 fantasy_projection_snapshot + iss056 canonical identity.
-- The user never has to manually choose two players. The engine optimizes the full saved roster.

create or replace function v2.fantasy_start_sit_auto_v2(
  p_apodo text,
  p_season int,
  p_week int,
  p_mode text default 'BALANCEADO',
  p_asof timestamptz default now(),
  p_model_version text default 'fantasy_weekly_v1'
) returns jsonb
language plpgsql security definer
set search_path to public,v2
as $$
declare
  v_roster jsonb;
  v_mode text:=upper(coalesce(p_mode,'BALANCEADO'));
  v_result jsonb;
begin
  if v_mode not in ('SEGURO','BALANCEADO','UPSIDE') then raise exception 'invalid fantasy mode'; end if;
  select v2.fn_fantasy_roster_canonicalize_v1(r.jugadores,p_season,p_week)
    into v_roster
  from public.fantasy_roster_semanal r
  where r.apodo=p_apodo and r.temporada=p_season and r.semana=p_week
  order by r.guardado_at desc limit 1;
  if v_roster is null then
    return jsonb_build_object('ok',false,'reason','ROSTER_NOT_FOUND','apodo',p_apodo,'season',p_season,'week',p_week);
  end if;

  with r as (
    select ord::int idx,
      coalesce(x->>'canonical_player_id','UNRESOLVED:'||ord) canonical_player_id,
      nullif(x->>'espn_player_id','') espn_player_id,
      coalesce(x->>'nombre',x->>'name') player_name,
      upper(coalesce(x->>'posicion',x->>'position','')) player_position,
      upper(coalesce(x->>'equipo',x->>'team','')) team,
      upper(coalesce(x->>'slot','BANCA')) current_slot,
      nullif(x->>'opponent','') opponent_from_roster,
      nullif(x->>'kickoff','')::timestamptz kickoff_from_roster,
      coalesce(x->>'availability_status','UNKNOWN') availability_from_roster,
      x original
    from jsonb_array_elements(v_roster) with ordinality j(x,ord)
  ),
  p0 as (
    select distinct on (s.espn_player_id)
      s.espn_player_id,s.player_name,s.team,s.opponent,s.position,s.kickoff,
      s.projection_floor,s.projection_median,s.projection_ceiling,s.projection_status,
      s.injury_status,s.depth_order,s.confidence_score,s.matchup_factor,s.role_factor,
      s.availability_factor,s.uncertainty,s.feature_asof,s.decision_time,s.model_version
    from v2.fantasy_projection_snapshot s
    where s.season=p_season and s.week=p_week and s.decision_time<=p_asof
      and s.model_version=p_model_version
    order by s.espn_player_id,s.decision_time desc,s.built_at desc
  ),
  b as (
    select r.*,
      coalesce(p.opponent,r.opponent_from_roster) opponent,
      coalesce(p.kickoff,r.kickoff_from_roster) kickoff,
      p.projection_floor,p.projection_median,p.projection_ceiling,p.projection_status,
      coalesce(p.injury_status,r.availability_from_roster) injury_status,
      p.depth_order,p.confidence_score,p.matchup_factor,p.role_factor,p.availability_factor,p.uncertainty,
      p.feature_asof,p.decision_time,p.model_version,
      case v_mode when 'SEGURO' then p.projection_floor when 'UPSIDE' then p.projection_ceiling else p.projection_median end mode_score,
      (coalesce(p.kickoff,r.kickoff_from_roster) is not null and coalesce(p.kickoff,r.kickoff_from_roster)<=p_asof) already_started,
      (coalesce(p.kickoff,r.kickoff_from_roster) is not null and coalesce(p.kickoff,r.kickoff_from_roster)<=p_asof and r.current_slot<>'BANCA') locked_start,
      (coalesce(p.kickoff,r.kickoff_from_roster) is not null and coalesce(p.kickoff,r.kickoff_from_roster)<=p_asof and r.current_slot='BANCA') locked_bench,
      upper(coalesce(p.injury_status,r.availability_from_roster,'')) in
       ('OUT','INACTIVE','IR','IR-R','PUP-R','PUP-P','NFI-R','RESERVE-SUS','RESERVE-CEL','RESERVE-DNR') unavailable
    from r left join p0 p on p.espn_player_id=r.espn_player_id
  ),
  caps as (
    select count(*)filter(where current_slot='QB')::int qb_cap,
      count(*)filter(where current_slot='RB')::int rb_cap,
      count(*)filter(where current_slot='WR')::int wr_cap,
      count(*)filter(where current_slot='TE')::int te_cap,
      count(*)filter(where current_slot='FLEX')::int flex_cap,
      count(*)filter(where current_slot='K')::int k_cap,
      count(*)filter(where current_slot in('DST','DEF','D/ST'))::int dst_cap,
      count(*)filter(where locked_start and current_slot='QB')::int qb_locked,
      count(*)filter(where locked_start and current_slot='RB')::int rb_locked,
      count(*)filter(where locked_start and current_slot='WR')::int wr_locked,
      count(*)filter(where locked_start and current_slot='TE')::int te_locked,
      count(*)filter(where locked_start and current_slot='FLEX')::int flex_locked,
      count(*)filter(where locked_start and current_slot='K')::int k_locked,
      count(*)filter(where locked_start and current_slot in('DST','DEF','D/ST'))::int dst_locked
    from b
  ),
  eligible as (
    select b.*,row_number()over(partition by player_position order by mode_score desc nulls last,projection_median desc nulls last,confidence_score desc nulls last,player_name) pos_rank
    from b where not locked_start and not locked_bench and not unavailable and not already_started
  ),
  mandatory as (
    select b.canonical_player_id,b.current_slot recommended_slot,'LOCKED'::text selection_kind from b where b.locked_start
    union all select e.canonical_player_id,'QB','MANDATORY' from eligible e,caps c where e.player_position='QB' and e.projection_status='PROJECTED' and e.pos_rank<=greatest(c.qb_cap-c.qb_locked,0)
    union all select e.canonical_player_id,'RB','MANDATORY' from eligible e,caps c where e.player_position='RB' and e.projection_status='PROJECTED' and e.pos_rank<=greatest(c.rb_cap-c.rb_locked,0)
    union all select e.canonical_player_id,'WR','MANDATORY' from eligible e,caps c where e.player_position='WR' and e.projection_status='PROJECTED' and e.pos_rank<=greatest(c.wr_cap-c.wr_locked,0)
    union all select e.canonical_player_id,'TE','MANDATORY' from eligible e,caps c where e.player_position='TE' and e.projection_status='PROJECTED' and e.pos_rank<=greatest(c.te_cap-c.te_locked,0)
    union all select e.canonical_player_id,'K','FIXED_NO_MODEL' from eligible e,caps c where e.player_position in('K','PK') and e.current_slot='K' and greatest(c.k_cap-c.k_locked,0)>0
    union all select e.canonical_player_id,'DST','FIXED_NO_MODEL' from eligible e,caps c where e.player_position in('DST','DEF','D/ST') and e.current_slot in('DST','DEF','D/ST') and greatest(c.dst_cap-c.dst_locked,0)>0
  ),
  flex_pool as (
    select e.*,row_number()over(order by e.mode_score desc nulls last,e.projection_median desc nulls last,e.confidence_score desc nulls last,e.player_name) flex_rank
    from eligible e where e.player_position in('RB','WR','TE') and e.projection_status='PROJECTED'
      and not exists(select 1 from mandatory m where m.canonical_player_id=e.canonical_player_id)
  ),
  selected as (
    select * from mandatory
    union all select f.canonical_player_id,'FLEX','FLEX' from flex_pool f,caps c where f.flex_rank<=greatest(c.flex_cap-c.flex_locked,0)
  ),
  advice as (
    select b.*,coalesce(s.recommended_slot,'BANCA') recommended_slot,coalesce(s.selection_kind,'BENCH') selection_kind,
      case when b.locked_start then 'BLOQUEADO_START' when b.locked_bench then 'BLOQUEADO_BANCA'
        when b.unavailable then 'OUT' when s.canonical_player_id is not null and b.current_slot='BANCA' then 'START'
        when s.canonical_player_id is not null and b.current_slot<>'BANCA' then 'MANTENER'
        when s.canonical_player_id is null and b.current_slot<>'BANCA' then 'SIT' else 'BANCA' end action,
      case when b.locked_start then 'Su partido ya empezó: queda bloqueado en tu alineación.'
        when b.locked_bench then 'Su partido ya empezó en banca: ya no puede entrar.'
        when b.unavailable then 'No disponible para esta semana: '||coalesce(b.injury_status,'OUT')||'.'
        when b.projection_status='DATA_INCOMPLETE' then 'No hay muestra suficiente para una proyección defendible; no se fuerza una decisión.'
        when s.selection_kind='FIXED_NO_MODEL' then 'Único jugador elegible de ese slot en tu roster; se mantiene, sin inventar proyección semanal.'
        when s.canonical_player_id is not null then 'Reto lo coloca entre tus mejores opciones disponibles para '||coalesce(s.recommended_slot,b.current_slot)||' en modo '||v_mode||'.'
        else 'Otra opción de tu roster proyecta mejor para los slots disponibles en modo '||v_mode||'.' end decision_reason
    from b left join selected s using(canonical_player_id)
  ),
  entrants as (select *,row_number()over(partition by recommended_slot order by mode_score desc nulls last,player_name) rn from advice where action='START'),
  exits as (select *,row_number()over(partition by current_slot order by mode_score asc nulls first,player_name) rn from advice where action='SIT'),
  changes as (
    select jsonb_agg(jsonb_build_object('entra',e.player_name,'entra_id',e.canonical_player_id,'sale',x.player_name,'sale_id',x.canonical_player_id,
      'slot',e.recommended_slot,'delta_proyectado',case when e.projection_median is not null and x.projection_median is not null then round(e.projection_median-x.projection_median,1) end,
      'por_que',e.decision_reason) order by e.recommended_slot,e.mode_score desc) j
    from entrants e left join exits x on x.current_slot=e.recommended_slot and x.rn=e.rn
  ),
  cards as (
    select jsonb_agg(jsonb_build_object('canonical_player_id',a.canonical_player_id,'espn_player_id',a.espn_player_id,'jugador',a.player_name,
      'posicion',a.player_position,'equipo',a.team,'rival',a.opponent,'kickoff',a.kickoff,'slot_actual',a.current_slot,
      'slot_recomendado',a.recommended_slot,'accion',a.action,'bloqueado',a.already_started,'estado',a.injury_status,'depth_order',a.depth_order,
      'piso',a.projection_floor,'proyeccion',a.projection_median,'techo',a.projection_ceiling,'score_modo',a.mode_score,
      'confianza',a.confidence_score,'uncertainty',a.uncertainty,'matchup_factor',a.matchup_factor,'role_factor',a.role_factor,
      'availability_factor',a.availability_factor,'projection_status',a.projection_status,'model_version',a.model_version,
      'decision_time',a.decision_time,'feature_asof',a.feature_asof,'por_que',a.decision_reason,
      'faltantes',case when a.projection_status='DATA_INCOMPLETE' then jsonb_build_array('Muestra/rol insuficiente para proyección semanal')
        when a.selection_kind='FIXED_NO_MODEL' then jsonb_build_array('Modelo semanal K/DST aún no disponible; decisión sólo por restricción del roster') else '[]'::jsonb end)
      order by case a.action when 'START' then 1 when 'MANTENER' then 2 when 'BLOQUEADO_START' then 3 when 'SIT' then 4 when 'OUT' then 5 else 6 end,
      a.mode_score desc nulls last,a.player_name) j from advice a
  ),
  sums as (
    select round(sum(coalesce(a.projection_median,0))filter(where a.recommended_slot<>'BANCA'),1) recommended_points,
      round(sum(coalesce(a.projection_median,0))filter(where a.current_slot<>'BANCA'),1) current_points,
      count(*)filter(where a.action='START') starts,count(*)filter(where a.action='SIT') sits,
      count(*)filter(where a.locked_start) locked_starts,count(*)filter(where a.unavailable) unavailable,
      count(*)filter(where a.projection_status='DATA_INCOMPLETE') incomplete from advice a
  )
  select jsonb_build_object('ok',true,'engine','fantasy_start_sit_auto_v2','apodo',p_apodo,'season',p_season,'week',p_week,'mode',v_mode,
    'asof',p_asof,'model_version',p_model_version,'automatico',true,
    'resumen',jsonb_build_object('proyeccion_actual',s.current_points,'proyeccion_recomendada',s.recommended_points,
      'mejora',round(coalesce(s.recommended_points,0)-coalesce(s.current_points,0),1),'cambios_start',s.starts,'cambios_sit',s.sits,
      'bloqueados',s.locked_starts,'no_disponibles',s.unavailable,'datos_incompletos',s.incomplete),
    'cambios',coalesce(c.j,'[]'::jsonb),'jugadores',coalesce(cd.j,'[]'::jsonb),
    'reglas',jsonb_build_object('locked_after_kickoff',true,'active_is_injury',false,'market_used',false,
      'historical_ppr_is_feature_not_projection',true,'optimizer','position+flex automatic')) into v_result
  from sums s cross join changes c cross join cards cd;
  return v_result;
end $$;

-- Thin public RPC wrapper. Logic stays in v2; frontend does not reimplement it.
create or replace function public.fantasy_start_sit_auto_v2(
  p_apodo text,p_season int,p_week int,p_mode text default 'BALANCEADO',p_asof timestamptz default now(),p_model_version text default 'fantasy_weekly_v1'
) returns jsonb language sql security definer set search_path to public,v2 as $$
  select v2.fantasy_start_sit_auto_v2(p_apodo,p_season,p_week,p_mode,p_asof,p_model_version);
$$;
