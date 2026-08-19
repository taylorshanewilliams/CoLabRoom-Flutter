create extension if not exists pgcrypto;

create schema if not exists private;
revoke all on schema private from public, anon, authenticated;

create type public.room_role as enum ('owner', 'editor', 'commenter', 'viewer');
create type public.project_status as enum ('active', 'completed');
create type public.contribution_kind as enum ('lyric', 'note', 'section');
create type public.invitation_status as enum ('pending', 'accepted', 'declined', 'expired');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Member',
  avatar_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.rooms (
  id uuid primary key default gen_random_uuid(),
  account_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 80),
  icon text not null default '♪',
  artwork_path text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index rooms_account_name_unique
  on public.rooms (account_id, lower(regexp_replace(trim(name), '\s+', ' ', 'g')))
  where deleted_at is null;

create table public.room_members (
  room_id uuid not null references public.rooms(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  display_name text not null default 'Member',
  role public.room_role not null default 'viewer',
  color_value bigint not null default 4294957644,
  joined_at timestamptz not null default now(),
  primary key (room_id, user_id)
);

create table public.projects (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  account_id uuid not null references public.profiles(id) on delete cascade,
  title text not null check (char_length(trim(title)) between 1 and 80),
  description text not null default '',
  status public.project_status not null default 'active',
  created_by uuid not null default auth.uid() references public.profiles(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create unique index projects_account_title_unique
  on public.projects (account_id, lower(regexp_replace(trim(title), '\s+', ' ', 'g')))
  where deleted_at is null;

create index projects_room_updated_idx on public.projects (room_id, updated_at desc);

create table public.contributions (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  author_id uuid not null default auth.uid() references public.profiles(id),
  author_name text not null default 'Member',
  body text not null check (char_length(trim(body)) > 0),
  color_value bigint not null default 4294937164,
  kind public.contribution_kind not null default 'lyric',
  revision integer not null default 1 check (revision > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create index contributions_project_created_idx
  on public.contributions (project_id, created_at);

-- Postgres does not automatically index foreign keys. These keep membership checks,
-- joins, and account-deletion cascades fast as the beta grows.
create index rooms_account_id_idx on public.rooms (account_id);
create index room_members_user_id_idx on public.room_members (user_id, room_id);
create index projects_account_id_idx on public.projects (account_id);
create index projects_created_by_idx on public.projects (created_by);
create index contributions_author_id_idx on public.contributions (author_id);

create table public.contribution_revisions (
  id uuid primary key default gen_random_uuid(),
  contribution_id uuid not null references public.contributions(id) on delete cascade,
  revision integer not null check (revision > 0),
  body text not null,
  edited_by uuid not null references public.profiles(id),
  created_at timestamptz not null default now(),
  unique (contribution_id, revision)
);

create table public.comments (
  id uuid primary key default gen_random_uuid(),
  contribution_id uuid not null references public.contributions(id) on delete cascade,
  author_id uuid not null default auth.uid() references public.profiles(id),
  body text not null check (char_length(trim(body)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.files (
  id uuid primary key default gen_random_uuid(),
  project_id uuid not null references public.projects(id) on delete cascade,
  uploaded_by uuid not null default auth.uid() references public.profiles(id),
  storage_path text not null,
  display_name text not null,
  mime_type text,
  byte_size bigint check (byte_size is null or byte_size >= 0),
  duration_ms integer check (duration_ms is null or duration_ms >= 0),
  created_at timestamptz not null default now(),
  deleted_at timestamptz
);

create table public.project_history (
  id bigint generated always as identity primary key,
  project_id uuid not null references public.projects(id) on delete cascade,
  actor_id uuid references public.profiles(id) on delete set null,
  event_type text not null,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create table public.invitations (
  id uuid primary key default gen_random_uuid(),
  room_id uuid not null references public.rooms(id) on delete cascade,
  invited_by uuid not null default auth.uid() references public.profiles(id),
  email text not null,
  role public.room_role not null default 'editor',
  token_hash text not null unique,
  status public.invitation_status not null default 'pending',
  expires_at timestamptz not null default (now() + interval '7 days'),
  created_at timestamptz not null default now()
);

create table public.feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references public.profiles(id) on delete cascade,
  category text not null,
  message text not null check (char_length(trim(message)) > 0),
  route text,
  platform text,
  app_version text,
  created_at timestamptz not null default now()
);

create index contribution_revisions_edited_by_idx
  on public.contribution_revisions (edited_by);
create index comments_contribution_id_idx on public.comments (contribution_id);
create index comments_author_id_idx on public.comments (author_id);
create index files_project_id_idx on public.files (project_id);
create index files_uploaded_by_idx on public.files (uploaded_by);
create index project_history_project_id_idx on public.project_history (project_id);
create index project_history_actor_id_idx on public.project_history (actor_id);
create index invitations_room_id_idx on public.invitations (room_id);
create index invitations_invited_by_idx on public.invitations (invited_by);
create index invitations_email_status_expires_idx
  on public.invitations (lower(email), status, expires_at);
create index feedback_user_id_idx on public.feedback (user_id);

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at before update on public.profiles
for each row execute function public.set_updated_at();
create trigger rooms_set_updated_at before update on public.rooms
for each row execute function public.set_updated_at();
create trigger projects_set_updated_at before update on public.projects
for each row execute function public.set_updated_at();
create trigger contributions_set_updated_at before update on public.contributions
for each row execute function public.set_updated_at();
create trigger comments_set_updated_at before update on public.comments
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data ->> 'display_name', 'Member'));
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.sync_member_display_name()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
begin
  if new.display_name is distinct from old.display_name then
    update public.room_members
    set display_name = new.display_name
    where user_id = new.id;
  end if;
  return new;
end;
$$;

create trigger profiles_sync_member_display_name
after update of display_name on public.profiles
for each row execute function public.sync_member_display_name();

create or replace function private.is_room_member(target_room uuid)
returns boolean
language sql
stable
security definer set search_path = ''
as $$
  select exists (
    select 1 from public.room_members
    where room_id = target_room and user_id = auth.uid()
  );
$$;

create or replace function private.room_role_for(target_room uuid)
returns public.room_role
language sql
stable
security definer set search_path = ''
as $$
  select role from public.room_members
  where room_id = target_room and user_id = auth.uid()
  limit 1;
$$;

create or replace function public.create_room_invitation(
  target_room uuid,
  invite_email text,
  invite_role public.room_role default 'editor'
)
returns text
language plpgsql
security definer set search_path = public, extensions
as $$
declare
  raw_token text := encode(gen_random_bytes(18), 'hex');
  normalized_email text := lower(trim(invite_email));
begin
  if private.room_role_for(target_room) <> 'owner' then
    raise exception 'Only the Room owner can invite collaborators.' using errcode = '42501';
  end if;
  if normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Enter a valid email address.' using errcode = '22023';
  end if;
  update public.invitations
  set status = 'expired'
  where room_id = target_room
    and lower(email) = normalized_email
    and status = 'pending';
  insert into public.invitations (
    room_id,
    invited_by,
    email,
    role,
    token_hash
  ) values (
    target_room,
    auth.uid(),
    normalized_email,
    invite_role,
    encode(digest(raw_token, 'sha256'), 'hex')
  );
  return raw_token;
end;
$$;

create or replace function public.accept_room_invitation_by_id(target_invitation uuid)
returns uuid
language plpgsql
security definer set search_path = public
as $$
declare
  selected public.invitations%rowtype;
  member_name text;
begin
  select * into selected
  from public.invitations
  where id = target_invitation
    and status = 'pending'
    and expires_at > now()
  for update;
  if selected.id is null then
    raise exception 'That invitation is no longer available.' using errcode = '22023';
  end if;
  if lower(selected.email) <> lower(coalesce(auth.jwt() ->> 'email', '')) then
    raise exception 'This invitation belongs to a different email address.' using errcode = '42501';
  end if;
  select display_name into member_name from public.profiles where id = auth.uid();
  insert into public.room_members (room_id, user_id, display_name, role)
  values (selected.room_id, auth.uid(), coalesce(member_name, 'Member'), selected.role)
  on conflict (room_id, user_id) do update
  set role = excluded.role, display_name = excluded.display_name;
  update public.invitations set status = 'accepted' where id = selected.id;
  return selected.room_id;
end;
$$;

create or replace function public.accept_room_invitation(invite_token text)
returns uuid
language plpgsql
security definer set search_path = public, extensions
as $$
declare
  target_id uuid;
begin
  select id into target_id
  from public.invitations
  where token_hash = encode(digest(trim(invite_token), 'sha256'), 'hex')
    and status = 'pending'
    and expires_at > now();
  if target_id is null then
    raise exception 'That invite code is invalid or expired.' using errcode = '22023';
  end if;
  return public.accept_room_invitation_by_id(target_id);
end;
$$;

create or replace function public.decline_room_invitation(target_invitation uuid)
returns void
language plpgsql
security definer set search_path = public
as $$
begin
  update public.invitations
  set status = 'declined'
  where id = target_invitation
    and status = 'pending'
    and lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''));
  if not found then
    raise exception 'That invitation is no longer available.' using errcode = '22023';
  end if;
end;
$$;

create or replace function public.delete_my_account()
returns void
language plpgsql
security definer set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  current_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if current_user_id is null then
    raise exception 'You must be signed in.' using errcode = '42501';
  end if;
  delete from public.invitations
  where invited_by = current_user_id or lower(email) = current_email;
  delete from public.comments where author_id = current_user_id;
  delete from public.files where uploaded_by = current_user_id;
  delete from public.contribution_revisions where edited_by = current_user_id;
  delete from public.contributions where author_id = current_user_id;
  delete from public.projects where created_by = current_user_id;
  delete from auth.users where id = current_user_id;
end;
$$;

revoke all on function public.create_room_invitation(uuid, text, public.room_role) from public, anon;
revoke all on function public.accept_room_invitation_by_id(uuid) from public, anon;
revoke all on function public.accept_room_invitation(text) from public, anon;
revoke all on function public.decline_room_invitation(uuid) from public, anon;
revoke all on function public.delete_my_account() from public, anon;
revoke all on function public.handle_new_user() from public, anon, authenticated;
revoke all on function public.sync_member_display_name() from public, anon, authenticated;
revoke all on function public.set_updated_at() from public, anon, authenticated;
revoke all on function private.is_room_member(uuid) from public, anon, authenticated;
revoke all on function private.room_role_for(uuid) from public, anon, authenticated;
grant execute on function public.create_room_invitation(uuid, text, public.room_role) to authenticated;
grant execute on function public.accept_room_invitation_by_id(uuid) to authenticated;
grant execute on function public.accept_room_invitation(text) to authenticated;
grant execute on function public.decline_room_invitation(uuid) to authenticated;
grant execute on function public.delete_my_account() to authenticated;

alter table public.profiles enable row level security;
alter table public.rooms enable row level security;
alter table public.room_members enable row level security;
alter table public.projects enable row level security;
alter table public.contributions enable row level security;
alter table public.contribution_revisions enable row level security;
alter table public.comments enable row level security;
alter table public.files enable row level security;
alter table public.project_history enable row level security;
alter table public.invitations enable row level security;
alter table public.feedback enable row level security;

create policy profiles_read_authenticated on public.profiles
for select to authenticated using (
  id = (select auth.uid())
  or exists (
    select 1 from public.room_members rm
    where rm.user_id = profiles.id and private.is_room_member(rm.room_id)
  )
  or exists (
    select 1 from public.invitations invitation
    where invitation.invited_by = profiles.id
      and lower(invitation.email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  )
);
create policy profiles_update_self on public.profiles
for update to authenticated using (id = (select auth.uid()))
with check (id = (select auth.uid()));

create policy rooms_read_members on public.rooms
for select to authenticated using (
  account_id = (select auth.uid())
  or private.is_room_member(id)
  or exists (
    select 1 from public.invitations invitation
    where invitation.room_id = rooms.id
      and invitation.status = 'pending'
      and lower(invitation.email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
  )
);
create policy rooms_create_owner on public.rooms
for insert to authenticated with check (account_id = (select auth.uid()));
create policy rooms_update_owner on public.rooms
for update to authenticated using (account_id = (select auth.uid()))
with check (account_id = (select auth.uid()));

create policy members_read_room on public.room_members
for select to authenticated using (private.is_room_member(room_id));
create policy members_add_owner on public.room_members
for insert to authenticated with check (
  exists (select 1 from public.rooms where id = room_id and account_id = (select auth.uid()))
);
create policy members_manage_owner on public.room_members
for update to authenticated using (private.room_role_for(room_id) = 'owner')
with check (private.room_role_for(room_id) = 'owner');
create policy members_remove_owner on public.room_members
for delete to authenticated using (
  private.room_role_for(room_id) = 'owner' or user_id = (select auth.uid())
);

create policy projects_read_members on public.projects
for select to authenticated using (private.is_room_member(room_id));
create policy projects_create_editors on public.projects
for insert to authenticated with check (
  private.room_role_for(room_id) in ('owner', 'editor')
  and exists (
    select 1 from public.rooms
    where id = room_id and account_id = projects.account_id
  )
);
create policy projects_update_editors on public.projects
for update to authenticated using (private.room_role_for(room_id) in ('owner', 'editor'))
with check (private.room_role_for(room_id) in ('owner', 'editor'));

create policy contributions_read_members on public.contributions
for select to authenticated using (
  exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
);
create policy contributions_create_editors on public.contributions
for insert to authenticated with check (
  author_id = (select auth.uid()) and exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);
create policy contributions_update_author_or_owner on public.contributions
for update to authenticated using (
  author_id = (select auth.uid()) or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) = 'owner'
  )
)
with check (
  author_id = (select auth.uid()) or exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) = 'owner'
  )
);

create policy revisions_read_members on public.contribution_revisions
for select to authenticated using (
  exists (
    select 1 from public.contributions c join public.projects p on p.id = c.project_id
    where c.id = contribution_id and private.is_room_member(p.room_id)
  )
);
create policy revisions_create_editors on public.contribution_revisions
for insert to authenticated with check (
  edited_by = (select auth.uid()) and exists (
    select 1 from public.contributions c join public.projects p on p.id = c.project_id
    where c.id = contribution_id and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

create policy comments_read_members on public.comments
for select to authenticated using (
  exists (
    select 1 from public.contributions c join public.projects p on p.id = c.project_id
    where c.id = contribution_id and private.is_room_member(p.room_id)
  )
);
create policy comments_create_participants on public.comments
for insert to authenticated with check (
  author_id = (select auth.uid()) and exists (
    select 1 from public.contributions c join public.projects p on p.id = c.project_id
    where c.id = contribution_id
      and private.room_role_for(p.room_id) in ('owner', 'editor', 'commenter')
  )
);

create policy files_read_members on public.files
for select to authenticated using (
  exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
);
create policy files_create_editors on public.files
for insert to authenticated with check (
  uploaded_by = (select auth.uid()) and exists (
    select 1 from public.projects p
    where p.id = project_id and private.room_role_for(p.room_id) in ('owner', 'editor')
  )
);

create policy history_read_members on public.project_history
for select to authenticated using (
  exists (select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id))
);
create policy history_create_members on public.project_history
for insert to authenticated with check (
  actor_id = (select auth.uid()) and exists (
    select 1 from public.projects p where p.id = project_id and private.is_room_member(p.room_id)
  )
);

create policy invitations_read_participants on public.invitations
for select to authenticated using (
  invited_by = (select auth.uid()) or private.room_role_for(room_id) = 'owner'
  or lower(email) = lower(coalesce((select auth.jwt()) ->> 'email', ''))
);
create policy invitations_create_owner on public.invitations
for insert to authenticated with check (
  invited_by = (select auth.uid()) and private.room_role_for(room_id) = 'owner'
);

create policy feedback_create_self on public.feedback
for insert to authenticated with check (user_id = (select auth.uid()));

-- New Supabase projects may not auto-expose SQL-created tables to the Data API.
-- Explicit, least-privilege grants keep the Flutter client working in either mode.
revoke all on table
  public.profiles,
  public.rooms,
  public.room_members,
  public.projects,
  public.contributions,
  public.contribution_revisions,
  public.comments,
  public.files,
  public.project_history,
  public.invitations,
  public.feedback
from anon;

grant select, update on table public.profiles to authenticated;
grant select, insert, update on table public.rooms to authenticated;
grant select, insert, update, delete on table public.room_members to authenticated;
grant select, insert, update on table public.projects to authenticated;
grant select, insert, update on table public.contributions to authenticated;
grant select, insert on table public.contribution_revisions to authenticated;
grant select, insert on table public.comments to authenticated;
grant select, insert on table public.files to authenticated;
grant select, insert on table public.project_history to authenticated;
grant select, insert on table public.invitations to authenticated;
grant insert on table public.feedback to authenticated;
grant usage, select on sequence public.project_history_id_seq to authenticated;
grant usage on type
  public.room_role,
  public.project_status,
  public.contribution_kind,
  public.invitation_status
to authenticated;

insert into storage.buckets (id, name, public)
values ('room-files', 'room-files', false)
on conflict (id) do nothing;

-- Object names begin with the Room UUID: <room-id>/<project-id>/<filename>.
create policy room_files_read_members on storage.objects
for select to authenticated using (
  bucket_id = 'room-files'
  and private.is_room_member(((storage.foldername(name))[1])::uuid)
);
create policy room_files_write_editors on storage.objects
for insert to authenticated with check (
  bucket_id = 'room-files'
  and private.room_role_for(((storage.foldername(name))[1])::uuid) in ('owner', 'editor')
);

alter publication supabase_realtime add table
  public.rooms,
  public.room_members,
  public.projects,
  public.contributions,
  public.invitations;
