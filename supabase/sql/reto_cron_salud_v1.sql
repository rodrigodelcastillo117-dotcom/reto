-- Watchdog de salud de tareas: estado de las tareas CRÍTICAS del sistema.
-- Lo usa la edge function vigilar-crons. SECURITY DEFINER (lee cron.*), solo service_role.
-- Acotado a 14 días para no escanear todo el historial (rápido: ~0.6s).
create or replace function reto_cron_salud_v1()
returns table(jobname text, activo boolean, ultimo_status text, ultimo_run timestamptz, horas_desde numeric, fallos_24h bigint)
language sql
security definer
set search_path = cron, public
as $$
  with watched as (
    select jobid, jobname, active from cron.job
    where jobname in (
      'mejores-picks-diario-7am','ingestar-odds-multicasa-am','ingestar-odds-soccer-am',
      'reto-clv-snapshot-diario','reto-recalibrar-auto-semanal','reto-recalibrar-platt-semanal'
    )
  ),
  ultimo as (
    select distinct on (d.jobid) d.jobid, d.status, d.start_time
    from cron.job_run_details d
    join watched w on w.jobid = d.jobid
    where d.start_time > now() - interval '14 days'
    order by d.jobid, d.start_time desc
  ),
  fallos as (
    select d.jobid, count(*) c
    from cron.job_run_details d
    join watched w on w.jobid = d.jobid
    where d.status = 'failed' and d.start_time > now() - interval '24 hours'
    group by d.jobid
  )
  select w.jobname, w.active, u.status, u.start_time,
    round(extract(epoch from (now() - u.start_time))/3600, 1),
    coalesce(f.c, 0)
  from watched w
  left join ultimo u on u.jobid = w.jobid
  left join fallos f on f.jobid = w.jobid;
$$;
revoke all on function reto_cron_salud_v1() from public, anon, authenticated;
grant execute on function reto_cron_salud_v1() to service_role;
