-- Enough of Supabase to let this project's migrations run on a stock Postgres.
--
-- The migrations are written against a hosted Supabase project: they grant to
-- roles that exist there, reference `auth.users`, call `auth.uid()`, and put
-- policies on `storage.objects`. None of that exists in the postgres:16 image,
-- so without this the first migration fails on line one and nothing downstream
-- is ever exercised.
--
-- This is deliberately a stand-in, not a reproduction. It has to be faithful
-- in the places the migrations actually touch — `auth.uid()` returning the
-- current user, `storage.foldername` splitting a path the way policies expect
-- — and is free to be a stub everywhere else. A shim that drifts from the real
-- thing in the parts under test is worse than no shim, so keep additions here
-- narrow and obvious.

create extension if not exists pgcrypto;

-- The roles migrations grant to and revoke from.
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin noinherit;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin noinherit bypassrls;
  end if;
end $$;

create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;

grant usage on schema auth, storage, extensions to anon, authenticated, service_role;

-- `alter publication supabase_realtime add table ...` appears in several
-- migrations; hosted Supabase ships the publication already created.
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end $$;

-- Only the columns this project's own trigger reads (`id`,
-- `raw_user_meta_data`) plus the email it identifies people by.
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text unique,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- PostgREST sets `request.jwt.claims` per request and Supabase's `auth.uid()`
-- reads the subject out of it. Same contract here, so a smoke scenario can say
-- who it is by setting one GUC.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')::uuid;
$$;

create or replace function auth.jwt()
returns jsonb
language sql
stable
as $$
  select coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
$$;

create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  public boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id) on delete cascade,
  name text,
  owner uuid,
  metadata jsonb,
  created_at timestamptz not null default now()
);

alter table storage.objects enable row level security;

-- The folder parts of an object path, i.e. everything before the filename.
-- Storage policies here index into it — `(storage.foldername(name))[1]` is
-- compared against a user or project id — so returning the whole split,
-- filename included, would silently shift every one of those by a position.
create or replace function storage.foldername(name text)
returns text[]
language plpgsql
immutable
as $$
declare
  parts text[];
begin
  parts := string_to_array(name, '/');
  return parts[1:array_length(parts, 1) - 1];
end;
$$;

grant all on all tables in schema storage to service_role;
