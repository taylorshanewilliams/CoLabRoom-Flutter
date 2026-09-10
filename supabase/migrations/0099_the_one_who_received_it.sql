-- One more step: somebody who arrived on a shared chart went and made one.
--
-- 0098 counted `opened_shared` — a link was opened — and then had nothing to
-- say about what that person did next, which is the only question the sharing
-- feature exists to answer. Whoever opens one of those links is the most
-- interested visitor this site gets: they were sent chords by a musician they
-- already know, which is a warmer introduction than any advertisement buys.
--
-- `made_own` closes that loop. opened_shared → made_own is the share ratio,
-- and it is the number that decides whether the free tool is a channel or
-- just a nice thing to have.

alter table public.public_tool_funnel drop constraint public_tool_funnel_step_known;

alter table public.public_tool_funnel add constraint public_tool_funnel_step_known
  check (step in (
    'opened',        -- the page was loaded
    'chose_file',    -- a file was picked or dropped
    'analyzed_ok',   -- chords came back
    'analyzed_fail', -- something went wrong
    'limit_reached', -- five songs today: not a failure, the opposite
    'copied_text',   -- the chart was copied as text
    'shared_link',   -- a link to the chart was copied
    'opened_shared', -- somebody arrived on a link one of those made
    'made_own',      -- and then went to do it with a song of their own
    'clicked_onward',-- one of the cards under the result was followed
    'clicked_app'    -- somebody went from the tool towards the app itself
  ));
