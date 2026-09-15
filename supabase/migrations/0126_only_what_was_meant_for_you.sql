-- Only what was meant for you.
--
-- `releases` (0121) was filled by a workflow that took the title of every
-- merge commit and showed it on Home, to everybody. Taylor caught it the
-- same day: "notifications in the app are very specific app notes, updating
-- me on work we are doing on the app itself ... the app should only notify
-- you about app related things, maybe feature updates, but not general app
-- work."
--
-- He is right, and the mistake is worth naming precisely: the workflow was
-- built on the observation that every pull request title in this repository
-- reads as a sentence. It does -- to somebody who works on it. "One dropped
-- connection" and "The expiry that never ran" are engineering notes, and a
-- musician opening the app to write a song is owed neither.
--
-- Two halves. The workflow now announces nothing unless the commit carries
-- an `Announce:` block written for a musician. This is the other half:
-- every row recorded under the old rule goes, because every one of them is
-- a note about the workshop rather than about the song.
--
-- Nothing here was ever a push. These rows feed one card on Home and no
-- notification of any kind -- worth writing down, because "was it sent to
-- everybody's phone" is the first question anybody would ask.

delete from public.releases;

comment on table public.releases is
  'Things somebody deliberately chose to tell the people using CoLabRoom, '
  'written for them. Filled only by a commit carrying an Announce: block; '
  'most merges are plumbing and say nothing here. Never a notification and '
  'never a push -- it is one card on Home.';
