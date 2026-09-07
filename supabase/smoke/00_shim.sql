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
  -- The two Supabase columns a migration can actually set, and the reason
  -- this shim grew them: 0077 puts a size cap and a type list on the buckets
  -- that take uploads, and a shim without the columns fails a migration that
  -- works perfectly in production — which is the shim reporting on itself
  -- rather than on the schema.
  file_size_limit bigint,
  allowed_mime_types text[],
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

-- Supabase refuses direct deletes from this table, and so does this.
--
-- Two functions shipped with a `delete from storage.objects` in them and
-- neither could ever have worked: the real database raises 42501 and tells
-- you to use the Storage API. Both passed here, against a plain table with
-- nothing guarding it — the shim proving that a forbidden delete works in a
-- database where it is allowed.
--
-- One of the two was the moderation takedown, whose entire purpose is to
-- remove something. This trigger is the reason that cannot happen twice.
create or replace function storage.protect_delete()
returns trigger
language plpgsql
as $shim$
begin
  raise exception
    'Direct deletion from storage tables is not allowed. Use the Storage API instead.'
    using errcode = '42501',
          hint = 'This prevents accidental data loss from orphaned objects.';
end;
$shim$;

drop trigger if exists protect_delete on storage.objects;
create trigger protect_delete
before delete on storage.objects
for each row execute function storage.protect_delete();

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

-- ---------------------------------------------------------------------
-- pg_net, which is a Supabase extension and not a Postgres one.
-- ---------------------------------------------------------------------

-- 0051 hands every new notification to the push sender through
-- net.http_post. That call has to exist here or the trigger raises the first
-- time the scenario invites somebody -- and it has to be a no-op, because the
-- point of the smoke test is the database, not Google's servers.
--
-- Matching pg_net's real signature exactly, defaults included. A shim with a
-- shorter argument list would let a migration that calls it wrongly pass here
-- and fail in production, which is the failure this whole file exists to
-- prevent.
create schema if not exists net;

create or replace function net.http_post(
  url text,
  body jsonb default '{}'::jsonb,
  params jsonb default '{}'::jsonb,
  headers jsonb default '{"Content-Type": "application/json"}'::jsonb,
  timeout_milliseconds integer default 5000
)
returns bigint
language sql
as $$
  select 1::bigint;
$$;

