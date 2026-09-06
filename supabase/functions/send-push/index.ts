// Delivers a notification to somebody's phone.
//
// 0018 built the whole notification system and opened with "No push/FCM/APNs
// here — in-app only". That made every notification a message left on a desk
// nobody is sitting at: it appears when you next open the app, which for the
// asks added in 0049 is barely better than not asking at all. The reason a
// room of willing people leaves a song untouched is almost never
// unwillingness — it is that nobody knew it was wanted.
//
// Invoked by a trigger on `notifications` (0051), one call per row, with the
// row itself as the body. Nothing that writes a notification has to change:
// the row already carries who it is for, the title and the body.
//
// Required secret:
//   FIREBASE_SERVICE_ACCOUNT  - the whole service-account JSON, as one string
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided automatically.

import { createClient } from 'jsr:@supabase/supabase-js@2';

const FIREBASE_SERVICE_ACCOUNT = Deno.env.get('FIREBASE_SERVICE_ACCOUNT');
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

// Shared with the trigger in 0051. Without it this endpoint would let anybody
// on the internet send a push to any user id they could guess.
const PUSH_HOOK_SECRET = Deno.env.get('PUSH_HOOK_SECRET');

const FCM_SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const TOKEN_URL = 'https://oauth2.googleapis.com/token';

interface ServiceAccount {
  readonly client_email: string;
  readonly private_key: string;
  readonly project_id: string;
}

interface NotificationRow {
  readonly id?: string;
  readonly user_id?: string;
  readonly type?: string;
  readonly title?: string;
  readonly body?: string;
  readonly project_id?: string;
  readonly room_id?: string;
}

/// Google's token endpoint wants a JWT signed by the service account, so the
/// key has to be turned into something crypto.subtle will sign with. The JSON
/// carries it as a PEM with literal \n escapes, which JSON.parse turns back
/// into real newlines — but a key pasted through a form somewhere along the
/// way may not have, so strip whichever arrives.
function pemToPkcs8(pem: string): Uint8Array {
  const body = pem
    .replace(/\\n/g, '\n')
    .replace(/-----BEGIN PRIVATE KEY-----/, '')
    .replace(/-----END PRIVATE KEY-----/, '')
    .replace(/\s+/g, '');
  const binary = atob(body);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function base64url(input: Uint8Array | string): string {
  const bytes = typeof input === 'string'
    ? new TextEncoder().encode(input)
    : input;
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

/// An OAuth access token for FCM, cached for as long as it is good for.
///
/// Minting one costs a signature and a round trip to Google, and a token is
/// valid for an hour. A room where four people are told about the same ask
/// would otherwise pay that four times in the same second.
let cachedToken: { value: string; expiresAt: number } | null = null;

async function accessToken(account: ServiceAccount): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  // A minute of headroom, so a token that expires mid-flight is not handed to
  // FCM as though it were fresh.
  if (cachedToken && cachedToken.expiresAt > now + 60) return cachedToken.value;

  const header = base64url(JSON.stringify({ alg: 'RS256', typ: 'JWT' }));
  const claims = base64url(JSON.stringify({
    iss: account.client_email,
    scope: FCM_SCOPE,
    aud: TOKEN_URL,
    iat: now,
    exp: now + 3600,
  }));

  const key = await crypto.subtle.importKey(
    'pkcs8',
    pemToPkcs8(account.private_key),
    { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const signature = new Uint8Array(await crypto.subtle.sign(
    'RSASSA-PKCS1-v1_5',
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  ));

  const response = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body: new URLSearchParams({
      grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      assertion: `${header}.${claims}.${base64url(signature)}`,
    }),
  });
  if (!response.ok) {
    throw new Error(
      `Google refused the service account (${response.status}): ${await response.text()}`,
    );
  }
  const payload = await response.json() as {
    access_token: string;
    expires_in: number;
  };
  cachedToken = {
    value: payload.access_token,
    expiresAt: now + payload.expires_in,
  };
  return payload.access_token;
}

Deno.serve(async (request: Request) => {
  if (request.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }
  if (!PUSH_HOOK_SECRET) {
    // Refuse rather than run unauthenticated. A push sender anybody can call
    // is a way to put arbitrary text on a stranger's lock screen.
    return new Response('Not configured', { status: 503 });
  }
  if (request.headers.get('x-push-secret') !== PUSH_HOOK_SECRET) {
    return new Response('Forbidden', { status: 403 });
  }
  if (!FIREBASE_SERVICE_ACCOUNT) {
    return new Response('Not configured', { status: 503 });
  }

  let row: NotificationRow;
  try {
    row = await request.json() as NotificationRow;
  } catch {
    return new Response('Bad request', { status: 400 });
  }
  if (!row.user_id) return new Response('No recipient', { status: 400 });

  const account = JSON.parse(FIREBASE_SERVICE_ACCOUNT) as ServiceAccount;
  const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { data: devices, error } = await supabase
    .from('device_tokens')
    .select('token, platform')
    .eq('user_id', row.user_id);
  if (error) {
    return new Response(`Could not read devices: ${error.message}`, {
      status: 500,
    });
  }
  // Nobody has this app on a phone yet, or they turned notifications off.
  // Not a failure — the in-app notification still landed.
  if (!devices || devices.length === 0) {
    return Response.json({ sent: 0, reason: 'no devices' });
  }

  const token = await accessToken(account);
  const endpoint =
    `https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`;

  let sent = 0;
  const dead: string[] = [];

  for (const device of devices) {
    const message = {
      message: {
        token: device.token,
        notification: {
          title: row.title ?? 'CoLabRoom',
          body: row.body ?? '',
        },
        // Carried so the app can open the thing being talked about rather
        // than dumping somebody on Home and making them find it.
        data: {
          type: row.type ?? '',
          project_id: row.project_id ?? '',
          room_id: row.room_id ?? '',
          notification_id: row.id ?? '',
        },
        apns: {
          payload: { aps: { sound: 'default', badge: 1 } },
        },
        android: {
          priority: 'HIGH',
          notification: { sound: 'default' },
        },
      },
    };

    const response = await fetch(endpoint, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${token}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify(message),
    });

    if (response.ok) {
      sent += 1;
      continue;
    }

    // A token dies when the app is uninstalled, and FCM says so with a 404
    // or UNREGISTERED. Keeping it means paying for a request per notification
    // forever to reach a phone that no longer has the app.
    const detail = await response.text();
    if (response.status === 404 || detail.includes('UNREGISTERED')) {
      dead.push(device.token);
      continue;
    }
    console.error(`FCM refused ${response.status}: ${detail}`);
  }

  if (dead.length > 0) {
    await supabase.from('device_tokens').delete().in('token', dead);
  }

  return Response.json({ sent, pruned: dead.length });
});
