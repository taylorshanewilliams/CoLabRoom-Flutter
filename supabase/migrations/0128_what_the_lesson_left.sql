-- What the lesson left.
--
-- Follow me (#307) lets one person lead and everybody else's song move with
-- them. An hour of that is one hour of a student's week, and when it ended
-- nothing of it was kept: the part they looped, the speed they got it to,
-- what the teacher said on the way out. The student was left to remember
-- "chorus two, slower" by themselves -- which is the whole of practising,
-- the reason to open the app on a Tuesday with nobody waiting.
--
-- So a followed session leaves a mark on the follower's own account: the
-- song, who led, the parts that were worked on and at what speed, and the
-- leader's note if they left one. Home turns it into one card with one verb,
-- Practise, which opens the song already looping that part at that speed.
--
-- The rules:
--
--   * A mark is the follower's, read by nobody else. It is a record of what
--     somebody practised, and practice is where people are allowed to be bad
--     at things. The leader is not told, the band is not told, and there is
--     no count of minutes anywhere a person can see.
--   * The follower's phone writes it, because that is where the session was
--     followed. The note travelled there inside the leader's stop message:
--     receiving it is what the follower agreed to by following.
--   * One mark per followed stretch, updated rather than duplicated: the
--     phone names the mark before it saves it, so saving again (the student
--     took over, then followed again) replaces the same row.
--   * Only on a song the person is actually in -- a room member or somebody
--     the song itself was shared with.

create table public.practice_marks (
  -- Named by the phone, so a second save of the same session is an update.
  id uuid primary key,
  profile_id uuid not null references public.profiles(id) on delete cascade,
  project_id uuid not null references public.projects(id) on delete cascade,

  -- Who led. Null once their account is gone, or when the id the phone
  -- heard is not a real person -- the name is kept either way, because it
  -- is what the card says.
  led_by uuid references public.profiles(id) on delete set null,
  led_by_name text not null check (char_length(trim(led_by_name)) between 1 and 80),

  note text check (note is null or char_length(note) <= 280),

  -- [{ "start": ms|null, "end": ms|null, "label": text, "rate": 0.5..1,
  --    "seconds": int }], most-worked-on first. Null start and end is the
  -- whole song.
  parts jsonb not null default '[]'::jsonb
    check (jsonb_typeof(parts) = 'array' and jsonb_array_length(parts) <= 6),

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index practice_marks_mine_idx
  on public.practice_marks (profile_id, updated_at desc);

alter table public.practice_marks enable row level security;

create policy practice_marks_read_own on public.practice_marks
for select to authenticated using (profile_id = (select auth.uid()));

-- Written only through keep_practice_mark, which checks the song and the
-- shape of what is kept.
grant select on public.practice_marks to authenticated;
revoke insert, update, delete on public.practice_marks from authenticated, anon;

-- ---------------------------------------------------------------------
-- Keeping one.
-- ---------------------------------------------------------------------

create or replace function public.keep_practice_mark(
  in_id uuid,
  in_project uuid,
  in_led_by uuid,
  in_led_by_name text,
  in_note text,
  in_parts jsonb
)
returns uuid
language plpgsql
security definer set search_path = ''
as $fn$
declare
  me uuid := auth.uid();
  song_room uuid;
  existing_owner uuid;
  part jsonb;
  cleaned_note text := nullif(left(trim(coalesce(in_note, '')), 280), '');
  cleaned_name text := left(trim(coalesce(in_led_by_name, '')), 80);
begin
  if me is null then
    raise exception 'Sign in first.' using errcode = '42501';
  end if;
  if in_id is null then
    raise exception 'A practice mark needs a name.' using errcode = '22023';
  end if;

  select p.room_id into song_room
  from public.projects p
  where p.id = in_project and p.deleted_at is null;
  if song_room is null then
    raise exception 'That song could not be found.' using errcode = '22023';
  end if;
  if private.room_role_for(song_room) is null
     and not private.is_project_member(in_project) then
    raise exception 'That song is not one of yours.' using errcode = '42501';
  end if;

  if cleaned_name = '' then
    cleaned_name := 'Someone';
  end if;

  if in_parts is null or jsonb_typeof(in_parts) <> 'array'
     or jsonb_array_length(in_parts) > 6 then
    raise exception 'The parts of a practice mark are a short list.' using errcode = '22023';
  end if;
  for part in select value from jsonb_array_elements(in_parts) loop
    if jsonb_typeof(part) <> 'object'
       or jsonb_typeof(part -> 'label') <> 'string'
       or char_length(part ->> 'label') not between 1 and 40
       or jsonb_typeof(part -> 'rate') <> 'number'
       or (part ->> 'rate')::numeric not between 0.25 and 2
       or jsonb_typeof(part -> 'seconds') <> 'number'
       or (part ->> 'seconds')::numeric < 0
       or coalesce(jsonb_typeof(part -> 'start'), 'null') not in ('null', 'number')
       or coalesce(jsonb_typeof(part -> 'end'), 'null') not in ('null', 'number') then
      raise exception 'A part of a practice mark is not one.' using errcode = '22023';
    end if;
  end loop;

  -- A mark somebody else already named is not yours to overwrite.
  select m.profile_id into existing_owner from public.practice_marks m where m.id = in_id;
  if existing_owner is not null and existing_owner is distinct from me then
    raise exception 'That practice mark is not yours.' using errcode = '42501';
  end if;

  insert into public.practice_marks
    (id, profile_id, project_id, led_by, led_by_name, note, parts)
  values (
    in_id,
    me,
    in_project,
    (select pr.id from public.profiles pr where pr.id = in_led_by),
    cleaned_name,
    cleaned_note,
    in_parts
  )
  on conflict (id) do update
    set parts = excluded.parts,
        -- A note, once left, is not taken away by a later save that did not
        -- carry one (the student followed again after the teacher stopped).
        note = coalesce(excluded.note, public.practice_marks.note),
        led_by = excluded.led_by,
        led_by_name = excluded.led_by_name,
        updated_at = now();

  return in_id;
end;
$fn$;

revoke all on function public.keep_practice_mark(uuid, uuid, uuid, text, text, jsonb)
  from public, anon;
grant execute on function public.keep_practice_mark(uuid, uuid, uuid, text, text, jsonb)
  to authenticated;

-- ---------------------------------------------------------------------
-- Reading your own: the last fortnight, newest first, on songs that still
-- exist.
-- ---------------------------------------------------------------------

create or replace function public.my_practice_marks()
returns table (
  id uuid,
  project_id uuid,
  led_by uuid,
  led_by_name text,
  note text,
  parts jsonb,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
stable
security definer set search_path = ''
as $fn$
  select m.id, m.project_id, m.led_by, m.led_by_name, m.note, m.parts,
         m.created_at, m.updated_at
  from public.practice_marks m
  join public.projects p on p.id = m.project_id and p.deleted_at is null
  where m.profile_id = auth.uid()
    and m.updated_at > now() - interval '14 days'
  order by m.updated_at desc
  limit 20;
$fn$;

revoke all on function public.my_practice_marks() from public, anon;
grant execute on function public.my_practice_marks() to authenticated;
