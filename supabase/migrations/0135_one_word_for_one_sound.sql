-- One word for one sound.
--
-- The audit of 17 September 2026 found the first-run tour offering "hip-hop"
-- and Open Mic settings offering "hip hop". `sounds_like` is matched word for
-- word (0076: `t = any(...)`), so somebody who picked one and somebody who
-- picked the other never counted as making the same music. The app now offers
-- one list; this folds the spellings people type into one word as well, on
-- the way in and for what is already stored.
--
-- A short table of spellings of the same thing, not a vocabulary: anything
-- not in it is kept as typed, lower-cased and single-spaced. The same table is
-- `_sameSound` in lib/domain/sounds.dart.

create or replace function private.one_sound_word(raw text)
returns text
language sql
immutable
as $fn$
  select case w
    when 'hip hop' then 'hip-hop'
    when 'hiphop' then 'hip-hop'
    when 'lo fi' then 'lo-fi'
    when 'lofi' then 'lo-fi'
    when 'rnb' then 'r&b'
    when 'r and b' then 'r&b'
    when 'r & b' then 'r&b'
    when 'r n b' then 'r&b'
    when 'k pop' then 'k-pop'
    when 'kpop' then 'k-pop'
    when 'singer songwriter' then 'singer-songwriter'
    when 'alt country' then 'alt-country'
    when 'altcountry' then 'alt-country'
    else w
  end
  from (select regexp_replace(lower(trim(raw)), '\s+', ' ', 'g') as w) spoken;
$fn$;

-- As 0076, with each tag folded before it is deduplicated, so "Hip Hop" and
-- "hip-hop" chosen together are one tag rather than two of the five.
create or replace function private.tidy_sounds_like(raw text[])
returns text[]
language sql
immutable
as $fn$
  select coalesce(
    (select array_agg(tag order by ord)
     from (
       select tag, min(ord) as ord
       from (
         select private.one_sound_word(t) as tag, ord
         from unnest(coalesce(raw, '{}'::text[])) with ordinality as u(t, ord)
         where char_length(trim(t)) between 1 and 40
       ) cleaned
       group by tag
       order by min(ord)
       limit 5
     ) kept),
    '{}'::text[]
  );
$fn$;

revoke all on function private.one_sound_word(text) from public, anon, authenticated;

-- What is already stored, spelled the same way.
update public.profiles
set sounds_like = private.tidy_sounds_like(sounds_like)
where sounds_like is distinct from private.tidy_sounds_like(sounds_like);
