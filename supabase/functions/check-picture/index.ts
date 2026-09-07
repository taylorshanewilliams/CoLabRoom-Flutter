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
//   SUPABASE_SERVICE_ROLE_KEY  provided by the platform

import { createClient } from 'jsr:@supabase/supabase-js@2';

const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

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
  bucket?: string;
  path?: string;
  kind?: 'profile' | 'room_logo';
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
    return new Response(JSON.stringify({ error: 'bad request' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const bucket = body.bucket;
  const path = body.path;
  const kind = body.kind ?? 'profile';
  const subject = body.subject;
  if (!bucket || !path || !subject) {
    return new Response(JSON.stringify({ error: 'missing bucket, path or subject' }), {
      status: 400,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  // Without a key this does nothing and says so, rather than silently
  // reporting every picture as fine — which would be a moderation system
  // that exists only in the release notes.
  if (!OPENAI_API_KEY) {
    console.error('check-picture: OPENAI_API_KEY is not set; nothing checked');
    return new Response(JSON.stringify({ checked: false, reason: 'not configured' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Short-lived, because it exists for one HTTP call to one endpoint.
  const signed = await supabase.storage.from(bucket).createSignedUrl(path, 120);
  if (signed.error || !signed.data?.signedUrl) {
    console.error('check-picture: could not sign', path, signed.error?.message);
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
    return new Response(JSON.stringify({ checked: false, reason: 'error' }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  if (!flagged) {
    return new Response(JSON.stringify({ checked: true, flagged: false }), {
      status: 200,
      headers: { 'Content-Type': 'application/json' },
    });
  }

  // Unpointed first, so it stops being served while the rest happens. The
  // object itself is left for tools/take_down.py, which is the only thing
  // that can delete it — see 0079.
  if (kind === 'profile') {
    await supabase.from('profiles').update({ avatar_path: null }).eq('id', subject);
  } else {
    await supabase.from('rooms').update({ logo_path: null }).eq('id', subject);
  }

  // And a report, so a person sees it. `reporter_id` is the subject
  // themselves because content_reports requires one and this had no human
  // reporter; the note is what says otherwise.
  await supabase.from('content_reports').insert({
    reporter_id: subject,
    kind,
    reason: categories.includes('sexual/minors') ? 'sexual' : 'abuse',
    detail: `Filed automatically by check-picture. Flagged: ${categories.join(', ')}. ` +
      `Object: ${bucket}/${path}. The picture has been unpointed; the object ` +
      `still needs deleting through the Storage API.`,
    ...(kind === 'profile' ? { target_profile: subject } : { target_room: subject }),
  });

  console.error(
    `check-picture: removed ${kind} for ${subject} (${categories.join(', ')})`,
  );

  return new Response(
    JSON.stringify({ checked: true, flagged: true, categories }),
    { status: 200, headers: { 'Content-Type': 'application/json' } },
  );
});
