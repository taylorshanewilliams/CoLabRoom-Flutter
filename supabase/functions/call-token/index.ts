// A ticket into a room's call.
//
// Calls run on LiveKit Cloud (decided with Taylor, 16 September 2026). LiveKit
// lets in anybody holding a token signed with the project's secret, so this is
// the only door, and it opens only for somebody the database says may be in
// the call (0134):
//
//   * a member of the room,
//   * who has given a birth month and is 18 or over -- stage A; stage B lets
//     13-17 in through a parent or guardian,
//   * who has not blocked, and is not blocked by, anybody already connected.
//
// The last check reads LiveKit's own list of who is connected rather than the
// app's heartbeat (call_presence), because the heartbeat is only as honest as
// the phone sending it.
//
// Nothing is recorded: no egress is ever started, and the token grants none.
//
// Required secrets:
//   LIVEKIT_URL         wss://<project>.livekit.cloud
//   LIVEKIT_API_KEY
//   LIVEKIT_API_SECRET
//   SUPABASE_URL, SUPABASE_ANON_KEY   provided by the platform

import { createClient } from 'jsr:@supabase/supabase-js@2';
import { AccessToken, RoomServiceClient } from 'npm:livekit-server-sdk@2.19.0';

const LIVEKIT_URL = Deno.env.get('LIVEKIT_URL') ?? '';
const LIVEKIT_API_KEY = Deno.env.get('LIVEKIT_API_KEY') ?? '';
const LIVEKIT_API_SECRET = Deno.env.get('LIVEKIT_API_SECRET') ?? '';
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;

// A band fits; a lesson is two. Enough that a group rehearsal works, few
// enough that the free tier is not one call.
const MOST_PEOPLE = 8;

// Long enough for a lesson and the chat after it. The app asks again to rejoin.
const TICKET_SECONDS = 3 * 60 * 60;

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// The web app at app.colabroom.com calls this from a browser, which asks first.
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

/** The LiveKit room a CoLabRoom room's call lives in. */
export function callRoomName(roomId: string): string {
  return `room-${roomId.toLowerCase()}`;
}

/** Who a LiveKit identity belongs to: identities are `<user id>:<device>`. */
export function personOf(identity: string): string | null {
  const id = identity.split(':')[0] ?? '';
  return UUID.test(id) ? id.toLowerCase() : null;
}

/** The REST host for a wss:// project URL. */
export function restHost(url: string): string {
  return url.replace(/^wss:/, 'https:').replace(/^ws:/, 'http:');
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  if (!LIVEKIT_URL || !LIVEKIT_API_KEY || !LIVEKIT_API_SECRET) {
    return json({ error: 'Calls are not switched on yet.' }, 503);
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Sign in first.' }, 401);

  let roomId = '';
  let device = '';
  try {
    const body = await req.json();
    roomId = typeof body.room_id === 'string' ? body.room_id.trim() : '';
    device = typeof body.device === 'string' ? body.device.trim().slice(0, 64) : '';
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }
  if (!UUID.test(roomId)) return json({ error: 'room_id is required' }, 400);
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(device)) return json({ error: 'device is required' }, 400);

  const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await caller.auth.getUser();
  if (userError || !userData?.user) return json({ error: 'Sign in first.' }, 401);
  const me = userData.user.id.toLowerCase();

  const { data: verdict, error: verdictError } = await caller.rpc('may_join_call', { in_room: roomId });
  if (verdictError) return json({ error: 'Could not check the room.' }, 500);
  if (verdict === 'birth_month_needed') {
    return json({ reason: 'birth_month_needed', error: 'Your birth month first.' }, 409);
  }
  if (verdict !== 'ok') return json({ error: String(verdict) }, 403);

  const name = callRoomName(roomId);
  const rooms = new RoomServiceClient(restHost(LIVEKIT_URL), LIVEKIT_API_KEY, LIVEKIT_API_SECRET);

  let connected: string[] = [];
  try {
    const participants = await rooms.listParticipants(name);
    connected = participants.map((p) => p.identity);
  } catch {
    // No such room yet: nobody is connected, which is the first caller.
  }
  const people = [...new Set(connected.map(personOf).filter((p): p is string => p !== null))];
  const others = people.filter((p) => p !== me);

  if (others.length > 0) {
    const { data: blocked, error: blockError } = await caller.rpc('blocked_with_any', { in_people: others });
    if (blockError) return json({ error: 'Could not check the call.' }, 500);
    // The same words for either direction: saying who blocked whom is what a
    // block exists to withhold.
    if (blocked === true) return json({ error: 'You cannot join this call.' }, 403);
  }
  if (!people.includes(me) && people.length >= MOST_PEOPLE) {
    return json({ error: 'This call is full.' }, 403);
  }

  try {
    await rooms.createRoom({ name, maxParticipants: MOST_PEOPLE * 2, emptyTimeout: 120, departureTimeout: 60 });
  } catch {
    // Already open, or LiveKit will make it on the first join.
  }

  const { data: profile } = await caller.from('profiles').select('display_name').eq('id', me).maybeSingle();
  const displayName = (profile?.display_name ?? '').trim() || 'Somebody';

  const token = new AccessToken(LIVEKIT_API_KEY, LIVEKIT_API_SECRET, {
    identity: `${me}:${device}`,
    name: displayName,
    ttl: TICKET_SECONDS,
    metadata: JSON.stringify({ user_id: me }),
  });
  token.addGrant({
    room: name,
    roomJoin: true,
    canPublish: true,
    canSubscribe: true,
    canPublishData: true,
    // Explicitly none of: roomRecord, roomAdmin, recorder, hidden.
  });

  return json({ url: LIVEKIT_URL, token: await token.toJwt(), room: name, identity: `${me}:${device}` });
});
