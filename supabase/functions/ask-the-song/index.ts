// Ask the app about this song.
//
// The app already knows a great deal about a song it has analysed: the key,
// the chords in the order they come, the sections, the words, the tempo,
// who has played what on it and what it is asking for. Until now the only
// way to ask it anything was to tap a chord. This is the question box in
// front of all of it.
//
// Three rules, in order of how much they matter:
//
//   1. The model is handed only what the app worked out, and told to answer
//      from that. Theory that has one right answer (which chords belong to
//      the key, which the song has not used) is computed here and handed
//      over as fact, not left to the model.
//   2. Every answer ends in "or ask somebody". The response names a part the
//      question was about that the song does not have, and the app turns
//      that into the ask sheet. The app is not the band.
//   3. Every question is recorded with its answer (0116), so a wrong answer
//      somebody acted on can be found, and the cost is bounded: thirty
//      questions per person per hour.
//
// Which model: Anthropic when ANTHROPIC_API_KEY is set, otherwise OpenAI
// through the OPENAI_API_KEY that transcription already has. The answer
// says which, so a quality difference can be traced to its source.
//
// The words of a song go to the model provider with the question. That is
// the point of the feature and it is said in the app.

import { createClient, type SupabaseClient } from 'jsr:@supabase/supabase-js@2';

import { degreeOf, describeKey, displayChord, untouchedChords } from '../_shared/theory.ts';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY')!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANTHROPIC_API_KEY = Deno.env.get('ANTHROPIC_API_KEY');
const OPENAI_API_KEY = Deno.env.get('OPENAI_API_KEY');

const ANTHROPIC_MODEL = 'claude-sonnet-5';
const OPENAI_MODEL = 'gpt-4o-mini';
const QUESTIONS_PER_HOUR = 30;
const MODEL_TIMEOUT_MS = 40_000;
const MAX_LYRIC_LINES = 60;
const MAX_LYRIC_CHARS = 2400;

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

/// The stored word for a part somebody asked about, or null. Mirrors the
/// vocabulary in lib/domain/musical_roles.dart -- the words in `plays`,
/// `song_layers.part` and `project_asks.part`.
const PART_WORDS: Array<[RegExp, string]> = [
  [/\b(harmon(y|ies))\b/, 'harmony'],
  [/\b(singer|vocals?|voice|sing)\b/, 'vocal'],
  [/\b(drums?|drummer|kit)\b/, 'drums'],
  [/\b(bass|bassist)\b/, 'bass'],
  [/\b(keys|piano|synth|organ|keyboard)\b/, 'keys'],
  [/\b(lead|solo)\b/, 'lead'],
  [/\b(rhythm|strum|acoustic)\b/, 'rhythm'],
  [/\b(rap|rapper)\b/, 'rap'],
  [/\b(lyrics?|words)\b/, 'lyrics'],
  [/\b(percussion|shaker|tambourine|congas?)\b/, 'percussion'],
  [/\b(beat|beats)\b/, 'beat'],
  [/\b(produc(er|tion|e))\b/, 'producer'],
  [/\b(mix|mixing)\b/, 'mix'],
  [/\b(master|mastering)\b/, 'master'],
  [/\b(engineer)\b/, 'engineer'],
  [/\b(topline|melody)\b/, 'topline'],
];

const PART_LABELS: Record<string, string> = {
  vocal: 'a singer', harmony: 'a harmony', drums: 'drums', bass: 'bass',
  keys: 'keys', lead: 'a lead part', rhythm: 'rhythm guitar', rap: 'a rap verse',
  lyrics: 'lyrics', percussion: 'percussion', beat: 'a beat', producer: 'a producer',
  mix: 'a mix', master: 'a master', engineer: 'an engineer', topline: 'a topline',
};

function partAskedAbout(question: string, partsOnIt: Set<string>, openAsks: string[]): string | null {
  const lower = question.toLowerCase();
  for (const [pattern, part] of PART_WORDS) {
    if (pattern.test(lower) && !partsOnIt.has(part)) return part;
  }
  return openAsks.length > 0 ? openAsks[0] : null;
}

function askLabelFor(part: string | null): string {
  if (part === null) return 'Or ask somebody: the room, for what it needs';
  return `Or ask somebody: the room, for ${PART_LABELS[part] ?? part}`;
}

function clock(ms: number): string {
  const seconds = Math.round(ms / 1000);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, '0')}`;
}

interface Facts {
  text: string;
  partsOnIt: Set<string>;
  openAsks: string[];
  analysed: boolean;
}

/// Everything the app knows about the song, as lines a model can read.
async function gatherFacts(
  // deno-lint-ignore no-explicit-any
  admin: SupabaseClient<any>,
  projectId: string,
  title: string,
): Promise<Facts> {
  const lines: string[] = [`Song: ${title}`];

  const { data: reference } = await admin
    .from('project_audio_references')
    .select('musical_key, bpm, beats_per_bar, duration_ms, structure_sections, analysis_state')
    .eq('project_id', projectId)
    .maybeSingle();

  const { data: cues } = await admin
    .from('chord_cues')
    .select('chord, start_ms')
    .eq('project_id', projectId)
    .order('start_ms', { ascending: true })
    .limit(400);
  // As a musician writes them, not as ChordMini stores them: the model
  // echoes whatever it is shown, and "A:min7" in an answer somebody reads
  // aloud is the app's plumbing showing. Silences (N) are left out.
  const chordList = (cues ?? [])
    .map((c: { chord: string }) => displayChord(c.chord))
    .filter((chord: string) => chord.length > 0);
  const firstSeen: string[] = [];
  for (const chord of chordList) {
    if (!firstSeen.includes(chord)) firstSeen.push(chord);
  }

  const key = describeKey((reference?.musical_key as string | null) ?? null);
  const analysed = reference?.analysis_state === 'ready';
  if (key) {
    lines.push(
      `Key: ${key.display} (relative: ${key.relative}). Chords that belong to it, in degree order: ${key.diatonic.join(', ')}.`,
    );
  } else if (reference?.musical_key) {
    lines.push(`Key: ${reference.musical_key}.`);
  }
  if (typeof reference?.bpm === 'number') {
    const beats = typeof reference.beats_per_bar === 'number' ? `${reference.beats_per_bar}/4` : 'time signature unknown';
    lines.push(`Tempo: ${Math.round(reference.bpm)} bpm, ${beats}.`);
  }
  if (typeof reference?.duration_ms === 'number') {
    lines.push(`Length: ${clock(reference.duration_ms)}.`);
  }
  if (firstSeen.length > 0) {
    const named = firstSeen.slice(0, 24).map((chord) => {
      const degree = key ? degreeOf(key, chord) : null;
      return degree ? `${chord} (the ${degree})` : `${chord} (outside the key)`;
    });
    lines.push(`Chords the song uses, in order of first appearance: ${named.join(', ')}.`);
    lines.push(`The progression, first ${Math.min(chordList.length, 24)} changes: ${chordList.slice(0, 24).join(' ')}.`);
    if (key) {
      const untouched = untouchedChords(key, firstSeen);
      lines.push(
        untouched.length > 0
          ? `Chords of the key the song has not used yet: ${untouched.join(', ')}.`
          : 'The song already uses every chord of its key.',
      );
    }
  } else if (analysed) {
    lines.push('No chords were detected.');
  } else {
    lines.push('The song has not been analysed yet, so there are no chords, key or tempo to go on.');
  }

  const sections = (reference?.structure_sections as Array<{ label?: string; start_ms?: number; end_ms?: number }> | null) ?? [];
  if (sections.length > 0) {
    lines.push(
      'Sections: ' +
        sections
          .slice(0, 16)
          .map((s) => `${s.label ?? 'section'} ${clock(s.start_ms ?? 0)}–${clock(s.end_ms ?? 0)}`)
          .join(', ') +
        '.',
    );
  }

  const { data: layers } = await admin
    .from('song_layers')
    .select('part, recorded_by, profiles:profiles!song_layers_recorded_by_fkey(display_name)')
    .eq('project_id', projectId)
    .not('shared_at', 'is', null);
  const partsOnIt = new Set<string>();
  const played: string[] = [];
  for (const layer of (layers ?? []) as Array<{ part: string; profiles?: { display_name?: string } | null }>) {
    const part = (layer.part ?? '').toLowerCase();
    if (!part) continue;
    partsOnIt.add(part);
    const who = layer.profiles?.display_name;
    played.push(who ? `${part} (${who})` : part);
  }
  lines.push(played.length > 0 ? `Parts recorded on it: ${played.join(', ')}.` : 'No parts have been recorded on it yet.');

  const { data: asks } = await admin
    .from('project_asks')
    .select('part')
    .eq('project_id', projectId)
    .eq('status', 'open');
  const openAsks = ((asks ?? []) as Array<{ part: string | null }>)
    .map((a) => (a.part ?? '').toLowerCase())
    .filter((p) => p.length > 0);
  if ((asks ?? []).length > 0) {
    lines.push(
      openAsks.length > 0
        ? `The song is asking for: ${openAsks.join(', ')}.`
        : 'The song is open to ideas (an open ask with no part named).',
    );
  }

  const { data: lyricRows } = await admin
    .from('contributions')
    .select('body')
    .eq('project_id', projectId)
    .eq('kind', 'lyric')
    .is('deleted_at', null)
    .order('created_at', { ascending: true })
    .limit(MAX_LYRIC_LINES);
  const lyrics = ((lyricRows ?? []) as Array<{ body: string }>)
    .map((r) => r.body.trim())
    .filter((b) => b.length > 0)
    .join('\n')
    .slice(0, MAX_LYRIC_CHARS);
  if (lyrics.length > 0) {
    lines.push(`Lyrics, as written in the app:\n${lyrics}`);
  } else {
    lines.push('No lyrics have been written in the app.');
  }

  return { text: lines.join('\n'), partsOnIt, openAsks, analysed };
}

const SYSTEM = [
  'You help a musician with one of their own songs, inside an app that has analysed it.',
  'Answer only from the facts you are given about the song. If the facts do not cover the question, say what is missing in one sentence rather than guessing.',
  'Chords and keys: use the ones named in the facts. When suggesting a chord, prefer the chords of the key the song has not used yet, and say why in a few words.',
  'Be concrete and short: at most 120 words, plain words, no headings, no bullet lists longer than four items, no emoji.',
  'Never claim to have listened to the audio; you have the analysis, not the sound.',
  'Do not end with an offer to help further; the app adds its own line after you.',
].join(' ');

async function askAnthropic(facts: string, question: string, signal: AbortSignal): Promise<string> {
  const response = await fetch('https://api.anthropic.com/v1/messages', {
    method: 'POST',
    signal,
    headers: {
      'x-api-key': ANTHROPIC_API_KEY!,
      'anthropic-version': '2023-06-01',
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      model: ANTHROPIC_MODEL,
      max_tokens: 400,
      system: SYSTEM,
      messages: [{ role: 'user', content: `What the app knows about the song:\n${facts}\n\nThe question: ${question}` }],
    }),
  });
  if (!response.ok) {
    throw new Error(`Anthropic ${response.status}: ${(await response.text()).slice(0, 300)}`);
  }
  const data = await response.json();
  const text = (data?.content ?? [])
    .filter((block: { type?: string }) => block.type === 'text')
    .map((block: { text?: string }) => block.text ?? '')
    .join('')
    .trim();
  if (!text) throw new Error('Anthropic returned no text');
  return text;
}

async function askOpenAi(facts: string, question: string, signal: AbortSignal): Promise<string> {
  const response = await fetch('https://api.openai.com/v1/chat/completions', {
    method: 'POST',
    signal,
    headers: {
      Authorization: `Bearer ${OPENAI_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      model: OPENAI_MODEL,
      max_tokens: 400,
      temperature: 0.3,
      messages: [
        { role: 'system', content: SYSTEM },
        { role: 'user', content: `What the app knows about the song:\n${facts}\n\nThe question: ${question}` },
      ],
    }),
  });
  if (!response.ok) {
    throw new Error(`OpenAI ${response.status}: ${(await response.text()).slice(0, 300)}`);
  }
  const data = await response.json();
  const text = (data?.choices?.[0]?.message?.content ?? '').trim();
  if (!text) throw new Error('OpenAI returned no text');
  return text;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);
  if (!ANTHROPIC_API_KEY && !OPENAI_API_KEY) {
    return json({ error: 'No model is configured (ANTHROPIC_API_KEY or OPENAI_API_KEY)' }, 500);
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return json({ error: 'Missing Authorization header' }, 401);

  let projectId: string;
  let question: string;
  try {
    const body = await req.json();
    projectId = typeof body.projectId === 'string' ? body.projectId : '';
    question = typeof body.question === 'string' ? body.question.trim() : '';
    if (!projectId) return json({ error: 'projectId is required' }, 400);
    if (!question) return json({ error: 'Ask something first.' }, 400);
    if (question.length > 500) return json({ error: 'Keep the question under 500 characters.' }, 400);
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }

  const caller = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: userData, error: userError } = await caller.auth.getUser();
  if (userError || !userData?.user) return json({ error: 'Unauthorized' }, 401);
  const userId = userData.user.id;

  // Read the song under the caller's own reach: a song they cannot see is
  // a song they cannot ask about, and RLS is the one place that rule lives.
  const { data: project } = await caller
    .from('projects')
    .select('id, title')
    .eq('id', projectId)
    .maybeSingle();
  if (!project) return json({ error: 'That song is not yours to ask about.' }, 403);

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY);

  const { count } = await admin
    .from('song_questions')
    .select('id', { count: 'exact', head: true })
    .eq('asked_by', userId)
    .gte('created_at', new Date(Date.now() - 3600_000).toISOString());
  if ((count ?? 0) >= QUESTIONS_PER_HOUR) {
    return json({ error: 'That is a lot of questions for one hour. Ask the room one, and try here again later.' }, 429);
  }

  const facts = await gatherFacts(admin, projectId, (project.title as string) ?? 'this song');
  const askPart = partAskedAbout(question, facts.partsOnIt, facts.openAsks);

  const started = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), MODEL_TIMEOUT_MS);
  let answer: string;
  let model: string;
  try {
    if (ANTHROPIC_API_KEY) {
      model = ANTHROPIC_MODEL;
      answer = await askAnthropic(facts.text, question, controller.signal);
    } else {
      model = OPENAI_MODEL;
      answer = await askOpenAi(facts.text, question, controller.signal);
    }
  } catch (error) {
    clearTimeout(timer);
    console.error('ask-the-song model call failed', error);
    return json({ error: 'The app could not think about that just now. Try again in a moment, or ask the room.' }, 502);
  }
  clearTimeout(timer);

  // Best-effort. The answer reaches the person whether or not it could be
  // filed; a record that fails must not become a failure somebody sees.
  try {
    await admin.from('song_questions').insert({
      project_id: projectId,
      asked_by: userId,
      question,
      answer,
      model,
      took_ms: Date.now() - started,
    });
  } catch (error) {
    console.error('ask-the-song could not record the question', error);
  }

  return json({
    answer,
    ask: { part: askPart, label: askLabelFor(askPart) },
    model,
    analysed: facts.analysed,
  });
});
