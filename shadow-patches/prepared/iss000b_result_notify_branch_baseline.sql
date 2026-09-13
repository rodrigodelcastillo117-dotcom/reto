-- ISS000b — DISPOSABLE BRANCH BASELINE for result-event/WASTED dependencies
-- Mirrors only the production table/function shapes required by ISS127.
-- Branch/test support only; not a production migration.

create table if not exists public.notificaciones (
  id uuid primary key default gen_random_uuid(),
  apodo text not null,
  tipo text not null,
  titulo text not null,
  mensaje text,
  data jsonb,
  leida boolean default false,
  created_at timestamptz default now(),
  url text,
  push_disparada boolean default false
);

create table if not exists public.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  apodo text not null,
  subscription jsonb not null,
  created_at timestamptz default now(),
  active boolean default true
);

-- Disposable-only secret stub so ISS127 function compilation can be verified.
-- No real push is sent by acceptance tests; tests use a local enviar_alerta stub.
create or replace function public.sk()
returns text language sql stable as $$ select 'DISPOSABLE_TEST_ONLY'::text $$;