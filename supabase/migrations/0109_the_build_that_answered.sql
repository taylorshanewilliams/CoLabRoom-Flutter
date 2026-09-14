-- Which build of the separation worker produced each cached analysis.
--
-- The worker's image is rolled by a RunPod release, and twice now the release
-- did not reach the workers while every log said it had. The cache row is the
-- one durable record of an analysis, so it now names the commit the worker
-- was built from. Null for rows written before the worker said, and for any
-- served by an image that predates the label.
alter table public.analysis_cache
  add column if not exists worker_build text;

comment on column public.analysis_cache.worker_build is
  'The git commit the separation worker image was built from, as the worker '
  'reported it. Null for analyses served before the worker said, or by an '
  'image that predates the label.';
