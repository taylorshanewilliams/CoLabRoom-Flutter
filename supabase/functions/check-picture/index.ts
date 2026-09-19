// A look at every picture somebody puts on themselves.
//
// Avatars are readable by every signed-in account, so one vile image reaches
// everybody in the app at once. Reporting and takedown exist — 0077 and 0079
// built both — but they are the slow half: somebody has to see it first, and
// the whole point of a profile picture is that it is seen.
//
// **What this is.** Every uploaded avatar and room logo goes to OpenAI's
// omni-moderation model, which reads images. Anything it flags for sexual,
// sexual/minors, violence or graphic content is unpointed immediately and a
// report is filed for a person to look at. The picture never becomes visible.
//
// **What this is not, and this matters.** It is *not* a CSAM detector. Real
// detection of child sexual abuse material is hash matching against known
// material — PhotoDNA, NCMEC's own tooling — and a general-purpose classifier
// is not a substitute and must never be described as one. This catches the
// ordinary case: somebody putting pornography or gore on a profile. The legal
// obligation under 18 U.S.C. 2258A is unchanged and still runs through
// reports, human review, and the CyberTipline.
//
// **It fails open, deliberately.** If the moderation call errors or times
// out, the picture is left alone and the failure is recorded. The alternative
// is an app where nobody can have a profile picture whenever an API is having
// a bad afternoon, and the report path still catches what this misses. A
// moderation system that breaks the product when it breaks gets turned off.
//
// Required secrets:
//   OPENAI_API_KEY             for the moderation endpoint
//   SUPABASE_URL               provided by the platform
//   SUPABASE_ANON_KEY          provided by the platform, to read who is asking
//   SUPABASE_SERVICE_ROLE_KEY  provided by the platform

import { createClient } from 'jsr:@supabase/supabase-js@2';

const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

// The categories that mean a picture cannot be on a profile. Deliberately
// short: harassment and hate are about text and produce noise on images, and
// self-harm on a profile picture is somebody who needs help rather than a
// takedown.
const REFUSE = [
  'sexual',
  'sexual/minors',
  'violence/graphic',
];

type Body = {
  // Ignored for a gallery picture: see below, where the row is asked instead.
  bucket?: string;
  path?: string;
  kind?: 'profile' | 'room_logo' | 'gallery_picture';
  // What the picture belongs to: a profile, a room, or — for a gallery
  // picture (0171) — the `profile_pictures` row itself, because a person has
  // up to eight of them and the profile id does not say which.
  subject?: string;
};

Deno.serve(async (request: Request) => {
  if (request.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  let body: Body;
  try {
    body = await request.json();
  } catch {
    return json({ error: 'bad request' }, 400);
  }

  const kind = body.kind ?? 'profile';
  const subject = body.subject;
  if (!subject) return json({ error: 'missing subject' }, 400);

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  // Who is asking.
  //
  // This function is deployed with JWT verification on, which the public anon
  // key satisfies — so until this block "verified" meant only that the caller
  // had read the key out of the app. Everything below it acts on a row with
  // the service key, which is the one thing a phone must never be able to
  // aim. The migration goes to the length of column-level grants so that a
  // phone cannot set `passed_at`; a function that set `passed_at` on any row
  // named in a POST body would have handed that back.
  const authHeader = request.headers.get('Authorization');
  let caller: string | null = null;
  if (authHeader) {
    const asCaller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: userData } = await asCaller.auth.getUser();
    caller = userData?.user?.id ?? null;
  }

  // What is actually being looked at.
  //
  // For a gallery picture the row decides, not the caller. Taking the bucket
  // and path from the body meant the object that was moderated and the row
  // that was marked could be two different pictures: a harmless one to be
  // looked at, an unexamined one to be passed — or somebody else's picture
  // marked as refused on the strength of an image the reporter uploaded
  // themselves, with a report filed in the victim's name.
  let bucket = body.bucket;
  let path = body.path;
  let owner = subject;

  if (kind === 'gallery_picture') {
    const picture = await supabase
      .from('profile_pictures')
      .select('storage_path, profile_id')
      .eq('id', subject)
      .maybeSingle();
    if (!picture.data?.storage_path) {
      return json({ error: 'no such picture' }, 404);
    }
    owner = picture.data.profile_id as string;
    if (!caller || caller !== owner) return json({ error: 'not yours' }, 403);
    bucket = 'avatars';
    path = picture.data.storage_path as string;
  } else if (kind === 'profile') {
    // The same hole, one row over, and it was here before the gallery was:
    // `subject` is the profile whose `avatar_path` gets cleared and who the
    // automatic report is filed against, so anybody could have had anybody
    // else's face taken off and a report filed in their name by pointing this
    // at a picture of their own. Closed here because this is the request that
    // made the caller readable at all (19 September 2026). A room logo is
    // left as it was: who may set one is a question about room membership
    // rather than about one id matching another, and getting it wrong would
    // silently stop logos being checked at all.
    if (!caller || caller !== subject) return json({ error: 'not yours' }, 403);
  }

  if (!bucket || !path) {
    return json({ error: 'missing bucket or path' }, 400);
  }

  // A gallery picture (0171) is the one kind that is invisible to everybody
  // but its owner until this runs, so every way out of here that is not a
  // refusal has to let it through. Including the ways out where nothing was
  // actually looked at: this function fails open by design — see the note at
  // the top — and a picture left silently invisible because an API had a bad
  // afternoon is the same product failure in a quieter place.
  const letThrough = async () => {
    if (kind !== 'gallery_picture') return;
    await supabase
      .from('profile_pictures')
      .update({ passed_at: new Date().toISOString() })
      .eq('id', subject)
      .is('passed_at', null);
  };

  // Without a key this does nothing and says so, rather than silently
  // reporting every picture as fine — which would be a moderation system
  // that exists only in the release notes.
  if (!OPENAI_API_KEY) {
    console.error('check-picture: OPENAI_API_KEY is not set; nothing checked');
    await letThrough();
    return new Response(JSON.stringify({ checked: false, reason: 'not configured' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Short-lived, because it exists for one HTTP call to one endpoint.
  const signed = await supabase.storage.from(bucket).createSignedUrl(path, 120);
  if (signed.error || !signed.data?.signedUrl) {
    console.error('check-picture: could not sign', path, signed.error?.message);
    await letThrough();
    return new Response(JSON.stringify({ checked: false, reason: 'unreadable' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  let flagged = false;
  let categories: string[] = [];
  try {
    const response = await fetch('https://api.openai.com/v1/moderations', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${OPENAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model: 'omni-moderation-latest',
        input: [{ type: 'image_url', image_url: { url: signed.data.signedUrl } }],
      }),
      signal: AbortSignal.timeout(20_000),
    });

    if (!response.ok) {
      console.error('check-picture: moderation returned', response.status);
      await letThrough();
      return new Response(JSON.stringify({ checked: false, reason: 'upstream' }), {
        status: 200,
        headers: { 'Content-Type': 'application/json' },
      });
    }

    const result = await response.json();
    const first = result?.results?.[0];
    const hits = first?.categories ?? {};
    categories = REFUSE.filter((name) => hits[name] === true);
    flagged = categories.length > 0;
  } catch (error) {
    // Fails open. See the note at the top: a moderation system that takes the
    // product down with it is one that gets switched off.
    console.error('check-picture: moderation failed', String(error));
    await letThrough();
    return new Response(JSON.stringify({ checked: false, reason: 'error' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  if (!flagged) {
    await letThrough();
    return new Response(JSON.stringify({ checked: true, flagged: false }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Unpointed first, so it stops being served while the rest happens. The
  // object itself is left for tools/take_down.py, which is the only thing
  // that can delete it — see 0079.
  //
  // A gallery picture is marked rather than deleted, for 0171's reason: the
  // row is what the report about to be filed points at, and every target on
  // content_reports cascades. `owner` — who the report is filed under — was
  // read further up, from the same row that gave the path.
  if (kind === 'profile') {
    await supabase.from('profiles').update({ avatar_path: null }).eq('id', subject);
  } else if (kind === 'gallery_picture') {
    await supabase
      .from('profile_pictures')
      .update({ taken_down_at: new Date().toISOString() })
      .eq('id', subject);
  } else {
    // The same read, for the same reason, and it fixes a refusal that was
    // already here: `reporter_id` references profiles, so filing a room
    // logo's report under the room's own id was a foreign key violation and
    // the report was never written at all. The logo was unpointed and
    // nobody was told (found while adding the gallery kind, 19 September
    // 2026).
    const room = await supabase
      .from('rooms')
      .select('account_id')
      .eq('id', subject)
      .maybeSingle();
    if (room.data?.account_id) owner = room.data.account_id as string;
    await supabase.from('rooms').update({ logo_path: null }).eq('id', subject);
  }

  // And a report, so a person sees it. `reporter_id` is whoever the picture
  // belonged to, because content_reports requires one and this had no human
  // reporter; the note is what says otherwise.
  await supabase.from('content_reports').insert({
    reporter_id: owner,
    kind,
    reason: categories.includes('sexual/minors') ? 'sexual' : 'abuse',
    detail: `Filed automatically by check-picture. Flagged: ${categories.join(', ')}. ` +
      `Object: ${bucket}/${path}. The picture has been unpointed; the object ` +
      `still needs deleting through the Storage API.`,
    ...(kind === 'profile'
      ? { target_profile: subject }
      : kind === 'gallery_picture'
          ? { target_picture: subject }
          : { target_room: subject }),
  });

  console.error(
    `check-picture: removed ${kind} for ${subject} (${categories.join(', ')})`,
  );

  return new Response(
    JSON.stringify({ checked: true, flagged: true, categories }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  );
});
