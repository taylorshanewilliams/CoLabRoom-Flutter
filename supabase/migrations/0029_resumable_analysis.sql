-- Pick an analysis back up where it was left.
--
-- The separation job runs on RunPod and does not care what the phone is
-- doing. The app has been the only thing holding the thread: if Android kills
-- it mid-analysis, the GPU job finishes, nobody collects the result, and the
-- user comes back to a song marked "processing" forever — then pays for the
-- whole thing again.
--
-- Recent work made a screen going off survivable. This makes the app being
-- killed survivable, which is the same problem one level up.
--
-- Storing the job id is all it takes. Everything else needed to finish —
-- the recording, its duration, where the stems go — is already on the row.

alter table public.project_audio_references
  add column if not exists analysis_job_id text,
  -- When the job was started, so a job id left behind by a crash that
  -- happened before it could be cleared doesn't get resumed forever. RunPod
  -- forgets a job long before this, and a resume attempt against a job it has
  -- dropped simply fails and falls through to a fresh analysis.
  add column if not exists analysis_started_at timestamptz;

alter table public.studio_drafts
  add column if not exists analysis_job_id text,
  add column if not exists analysis_started_at timestamptz;
