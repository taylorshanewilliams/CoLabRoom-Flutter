-- Recording a take stops telling everybody about it.
--
-- Since 0038 the notification has fired on insert, which means the moment a
-- take exists the whole room is told. Recording *is* publishing. Taylor,
-- 6 September:
--
--   "they dont need to be stressed that everyone will be notified of it until
--    they are happy with the result and ready for everyone to hear ... so it
--    feels like a creative place without pressure that someone will hear or
--    see before they are ready for it."
--
-- That is not a preference about notifications. It is about whether the app
-- is somewhere you can try something badly. Nobody experiments in front of an
-- audience, and an app that broadcasts every attempt has quietly decided that
-- only finished work happens in it — which is the opposite of what a room for
-- writing songs is for.
--
-- So: a take is yours until you say otherwise. Play it back, record it again,
-- delete it, keep it. The room finds out when you decide the room should.

alter table public.song_layers
  add column if not exists shared_at timestamptz;

-- Everything recorded before today was shared the moment it existed, and
-- people have already been told about it. Backfilling to created_at keeps
-- that true rather than retroactively hiding takes a band has been listening
-- to for weeks.
update public.song_layers
set shared_at = created_at
where shared_at is null;

comment on column public.song_layers.shared_at is
  'When the person who recorded this let the room hear it. Null means it is '
  'still a private draft, visible only to them.';

create index if not exists song_layers_shared_idx
  on public.song_layers (project_id, shared_at);

-- ---------------------------------------------------------------------
-- Who can see it
-- ---------------------------------------------------------------------

-- A room member sees shared takes. The person who recorded one sees their own
-- whatever its state — which is the entire point, and is why this cannot be
-- done by simply not notifying: a draft everybody can already hear is not a
-- draft.
drop policy if exists song_layers_read_members on public.song_layers;
create policy song_layers_read_members on public.song_layers
for select to authenticated using (
  (
    shared_at is not null
    or recorded_by = (select auth.uid())
  )
  and exists (
    select 1 from public.projects p
    where p.id = project_id and private.is_room_member(p.room_id)
  )
);

-- ---------------------------------------------------------------------
-- When the room is told
-- ---------------------------------------------------------------------

create or replace function public.notify_layer_added()
returns trigger
language plpgsql
security definer set search_path = ''
as $$
declare
  song record;
  member record;
  who text;
begin
  -- The whole change, in one condition. On insert: only if it arrived
  -- already shared, which is what a client that shares immediately would do.
  -- On update: only on the crossing from private to shared, so editing the
  -- label of a take somebody shared last week does not announce it again.
  if new.shared_at is null then
    return new;
  end if;
  if tg_op = 'UPDATE' and old.shared_at is not null then
    return new;
  end if;

  select id, room_id, title into song
  from public.projects
  where id = new.project_id;

  who := coalesce(
    nullif(trim(new.performer), ''),
    (select display_name from public.profiles where id = new.recorded_by),
    'Someone'
  );

  for member in
    select user_id from public.room_members where room_id = song.room_id
  loop
    perform private.notify_user(
      member.user_id,
      'project_update',
      who || ' added a part to ' || coalesce(song.title, 'a song'),
      case
        when coalesce(trim(new.label), '') <> '' then new.label
        else 'A new layer is on the song.'
      end,
      song.room_id,
      new.project_id,
      null,
      new.recorded_by
    );
  end loop;

  return new;
end;
$$;

drop trigger if exists song_layers_notify_added on public.song_layers;
create trigger song_layers_notify_added
after insert or update of shared_at on public.song_layers
for each row execute function public.notify_layer_added();

-- ---------------------------------------------------------------------
-- Saying so
-- ---------------------------------------------------------------------

-- A function rather than letting the client write the column, so that
-- "shared" always means the same thing and always happens once. The update
-- policy would allow a client to set any timestamp it liked, including one in
-- the past, which would put a take into a room's history at a moment it was
-- not there.
create or replace function public.share_layer(target_layer uuid)
returns timestamptz
language plpgsql
security invoker
set search_path = public
as $$
declare
  shared timestamptz;
begin
  update public.song_layers
  set shared_at = now()
  where id = target_layer
    and recorded_by = auth.uid()
    and shared_at is null
  returning shared_at into shared;

  if shared is null then
    -- Already shared, or not yours. Both are fine and neither is an error
    -- worth putting in front of somebody: return what is true now.
    select l.shared_at into shared
    from public.song_layers l
    where l.id = target_layer and l.recorded_by = auth.uid();
  end if;
  return shared;
end;
$$;

revoke all on function public.share_layer(uuid) from public, anon;
grant execute on function public.share_layer(uuid) to authenticated;

-- Taking it back.
--
-- Deliberately allowed. Somebody who shared a take by accident, or heard it
-- again in the morning and changed their mind, should be able to withdraw it
-- — and an app that makes sharing irreversible teaches people to share less.
-- The notification already sent is not recalled, because pretending something
-- was never said is a different and worse promise than letting it stop being
-- available.
create or replace function public.unshare_layer(target_layer uuid)
returns void
language sql
security invoker
set search_path = public
as $$
  update public.song_layers
  set shared_at = null
  where id = target_layer and recorded_by = auth.uid();
$$;

revoke all on function public.unshare_layer(uuid) from public, anon;
grant execute on function public.unshare_layer(uuid) to authenticated;
