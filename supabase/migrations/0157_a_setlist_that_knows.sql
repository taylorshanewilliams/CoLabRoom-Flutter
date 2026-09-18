-- A setlist that knows each song.
--
-- Every Musician, Same Song, 17 September 2026: the live scene runs on a
-- paper list anyone can trust. A set here stored titles and an order (0005)
-- and nothing a band actually needs on the night -- what key we do it in,
-- how fast, who counts it, the shape of it, how it ends, and "straight into
-- the next one". A stand-in handed that list still has to ask every question
-- in the van.
--
-- **Six columns on the row that already joins a song to a set.** Every one of
-- them is nullable, and null means "what the song says": the key falls back
-- to the band's key (key_override, 0144) or the detected one, the tempo and
-- the count-in to the analysis, the form to the song's sections. A band that
-- never touches any of this gets a list that already reads right, and a band
-- that does it in a different key on a Saturday writes that on the set, not
-- on the song. The song's own key stays the shared fact it was; the set's key
-- is what this occasion does with it.
--
-- **Whose they are.** The set's owner's, the way the set is. 0005's update
-- policy on setlist_projects already lets only the owner of the set write the
-- row, so no new policy and no function: an update from anybody else touches
-- nothing, and the app says so when it comes back with no row. Somebody who
-- can only look at a room can still say what key *their own* set does a song
-- in, because that is a fact about their set and not about the song.
--
-- **No numbers that are not music.** A tempo is a tempo. There is no score,
-- no count of anything, no date on the row beyond the one 0005 gave it.

alter table public.setlist_projects
  add column if not exists played_key text
  -- The same shape 0144 accepts for the song's own key: a root, an optional
  -- accidental, optionally which of the two modes it is.
  check (played_key is null
         or played_key ~ '^[A-G][#b]?( (major|minor))?$');

alter table public.setlist_projects
  add column if not exists bpm numeric
  -- The range practice_rules.dart plays at. A count-in outside it is refused
  -- by the app for the same reason, so the table should not hold one either.
  check (bpm is null or (bpm >= 40 and bpm <= 240));

alter table public.setlist_projects
  add column if not exists count_in text
  check (count_in is null or char_length(count_in) between 1 and 80);

alter table public.setlist_projects
  add column if not exists form text
  check (form is null or char_length(form) between 1 and 200);

alter table public.setlist_projects
  add column if not exists ending text
  check (ending is null or char_length(ending) between 1 and 80);

alter table public.setlist_projects
  add column if not exists note text
  check (note is null or char_length(note) between 1 and 200);

comment on column public.setlist_projects.played_key is
  'The key this set does the song in. Null means the song''s own key: the '
  'band''s (projects.key_override) or the detected one.';
comment on column public.setlist_projects.bpm is
  'The tempo this set does the song at. Null means the analysis''s tempo.';
comment on column public.setlist_projects.count_in is
  'Who counts it and how, in the band''s words. Null means one bar of the '
  'song''s own metre, where the analysis found one.';
comment on column public.setlist_projects.form is
  'The shape of the song as this set plays it. Null means the song''s '
  'sections, as typed or as the analysis heard them.';
comment on column public.setlist_projects.ending is
  'How the song ends: cold, ritard, tag the chorus. Null says nothing.';
comment on column public.setlist_projects.note is
  'One line for the stand-in: "straight into the next one". Null says nothing.';
