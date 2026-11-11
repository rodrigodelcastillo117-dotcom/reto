-- Mercado CONTRARIAN: detecta (deporte,mercado) que acierta < 50% fuera de muestra.
-- Si invertir=true, el email manda el LADO OPUESTO automáticamente. Gate: solo con margen y muestra
-- (hit_test<45, hit_train<48, n_test>=30). Nunca por ruido. Hoy no hay ninguno. DINERO OFF.
create or replace view v_reto_polaridad_mercado_v1 as
with g as (
  select deporte, lower(coalesce(mercado,'(nulo)')) mercado, acierto, kickoff,
         row_number() over (partition by deporte, lower(coalesce(mercado,'(nulo)')) order by kickoff) rn,
         count(*)    over (partition by deporte, lower(coalesce(mercado,'(nulo)'))) tot
  from v_reto_pick_grade_v1 where acierto is not null
),
split as (
  select deporte, mercado, acierto,
         case when rn <= floor(tot*0.7) then 'train' else 'test' end parte
  from g
),
agg as (
  select deporte, mercado,
    count(*) filter (where parte='train') n_train,
    count(*) filter (where parte='test')  n_test,
    round(avg(acierto::numeric) filter (where parte='train')*100,1) hit_train,
    round(avg(acierto::numeric) filter (where parte='test')*100,1)  hit_test,
    round(avg(acierto::numeric)*100,1) hit_total,
    count(*) n_total
  from split group by deporte, mercado
)
select *, (n_test >= 30 and hit_test < 45 and hit_train < 48) as invertir
from agg order by hit_total asc;
grant select on v_reto_polaridad_mercado_v1 to anon, authenticated;
