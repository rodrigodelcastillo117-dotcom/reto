-- Elo por superficie (clay/grass/hard) para tenis — LISTO PARA APLICAR.
-- Validado OOS (holdout 2025-07): mejora Brier 0.2218->0.2212, acc 63.57->63.83%,
-- calibracion ECE 0.96->0.32; lift concentrado en arcilla (+0.83pp) y pasto (Brier -0.0024).
-- Modesto pero real y coherente. MOV (margen de victoria) se probo y se DESCARTO (no aporta).

-- 1) Superficie por torneo
create or replace function public.tenis_superficie(p_torneo text, p_tour text)
returns text language sql immutable as $$
  select case
    when p_torneo is null then 'hard'
    when lower(p_torneo) like '%stuttgart%' then case when p_tour='atp' then 'grass' else 'clay' end
    when lower(p_torneo) ~ '(wimbledon|eastbourne|libema|libéma|hertogenbosch|rosmalen|halle|terra wortmann|queen|cinch|hsbc championships|nottingham|birmingham|mallorca|bad homburg|newport|surbiton|ilkley|berlin)' then 'grass'
    when lower(p_torneo) ~ '(roland garros|french open|madrid|rome|italia|internazionali|monte.?carlo|barcelona|bastad|båstad|nordea|kitzb|hamburg|umag|gstaad|bucharest|estoril|munich|bmw open|genève|geneva|lyon|córdoba|cordoba|buenos aires|argentina open|rio |santiago|chile open|bogot|colsanitas|charleston|parma|warsaw|palermo|cluj|iasi|tunis|marrakech|houston|são paulo|sao paulo|florianopolis|guayaquil|quito|oeiras|bahia|contrexeville|salvador|perugia|trieste|como|genova|rabat)' then 'clay'
    else 'hard' end
$$;

-- 2) Tabla + refresh de Elo por superficie (K=32), desde cero por superficie
create table if not exists public.tenis_elo_surface_prod (
  player_id text not null, surface text not null, rating numeric not null,
  partidos integer not null, actualizado timestamptz not null default now(),
  primary key (player_id, surface)
);
create or replace function public.tenis_elo_surface_refresh()
returns void language plpgsql security definer set search_path to 'public' as $b$
declare m record; mp jsonb; np int; rt numeric[]; gc int[]; wi int; li int; rw numeric; rl numeric; expw numeric; k numeric:=32; surf text;
begin
  for surf in select unnest(array['hard','clay','grass']) loop
    select jsonb_object_agg(pid, idx), max(idx) into mp, np
    from (select pid, row_number() over (order by pid) idx
          from (select winner_id pid from public.tenis_partidos_v1 where tenis_superficie(torneo,tour)=surf
                union select loser_id from public.tenis_partidos_v1 where tenis_superficie(torneo,tour)=surf) a) p;
    if np is null then continue; end if;
    rt := array_fill(1500::numeric, array[np]); gc := array_fill(0, array[np]);
    for m in select winner_id, loser_id from public.tenis_partidos_v1
             where tenis_superficie(torneo,tour)=surf order by fecha, espn_match_id loop
      wi:=(mp->>m.winner_id)::int; li:=(mp->>m.loser_id)::int; rw:=rt[wi]; rl:=rt[li];
      expw:=1/(1+power(10,(rl-rw)/400.0)); rt[wi]:=rw+k*(1-expw); rt[li]:=rl-k*(1-expw);
      gc[wi]:=gc[wi]+1; gc[li]:=gc[li]+1;
    end loop;
    insert into public.tenis_elo_surface_prod(player_id, surface, rating, partidos)
    select key, surf, round(rt[value::int],1), gc[value::int] from jsonb_each_text(mp)
    on conflict (player_id, surface) do update set rating=excluded.rating, partidos=excluded.partidos, actualizado=now();
  end loop;
end $b$;
-- select public.tenis_elo_surface_refresh();  -- correr una vez; luego cron tras tenis-elo-refresh.

-- 3) PENDIENTE (hacer CON la DB, para testear): en v_reto_tenis_predicciones_v1,
--    reemplazar r1.rating/r2.rating por blend  rating = 0.8*global + 0.2*coalesce(surface,global)
--    con surface = tenis_superficie(a.torneo, a.tour) via LEFT JOIN tenis_elo_surface_prod.
