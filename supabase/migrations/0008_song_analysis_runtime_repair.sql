-- Repair the premium song analyzer so it can persist a generated vocal draft,
-- word timing, and non-fatal partial-analysis warnings.

alter table public.project_audio_references
  add column if not exists transcript_text text,
  add column if not exists transcript_words jsonb not null default '[]'::jsonb,
  add column if not exists analysis_warning text;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'project_audio_references_transcript_words_array'
      and conrelid = 'public.project_audio_references'::regclass
  ) then
    alter table public.project_audio_references
      add constraint project_audio_references_transcript_words_array
      check (jsonb_typeof(transcript_words) = 'array');
  end if;
end;
$$;
