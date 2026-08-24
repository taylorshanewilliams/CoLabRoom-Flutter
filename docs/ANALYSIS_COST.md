# What an analysis costs, and how to make it cost less

Written 2026-08-24. Part measurement, part proposal — the two are labelled,
because one is evidence and the other is a plan.

## What one analysis costs today

Measured from `usage_events` on a real 5m28s song, priced against published
vendor rates:

| Step | Measured usage | Cost |
|---|---|---|
| Lyrics (OpenAI Whisper, `whisper-1`) | 5.46 min of audio | **$0.033** |
| Separation (Demucs `htdemucs_6s`, RunPod GPU) | 227s compute | $0.017 – $0.044 |
| Chords (ChordMini, Cloud Run 2 vCPU/2GiB) | 75.5s | $0.006 |

Separation's range is because the GPU tier isn't recorded anywhere in this
repo — it's a RunPod dashboard setting. At the cheap end (A5000, $0.27/hr)
**Whisper is the single largest line item**, which matters because Whisper
is a fixed per-minute API price: no amount of buying hardware reduces it.

GPU time scales with song length, so cost per song does too. The 40-second
health-check clip uses ~18s of GPU; the 5m28s song used 227s.

Storage is a separate shape of cost — not paid once but every month, and
unbounded until `tools/expire_stems.py` was added. See that file for the
retention reasoning.

## Finding: ChordMini does not need separated audio

**This part is measured.** `tools/chord_mix_experiment.py` sends the same
song twice to the live chord service — once as the original recording, once
as the harmonic mix (bass + other + guitar + piano) the GPU worker currently
builds for it — and compares the results. It uses stems already in Storage
and rebuilds the mix with `handler.py`'s exact ffmpeg recipe, so it costs two
CPU calls and no GPU.

Four songs from the beta project:

| Song | Length | Exact agreement | Root-only | Segments (full / harmonic) |
|---|---|---|---|---|
| e54bc276 | 237s | 94.1% | 95.8% | 123 / 123 |
| 5451ff6e | 328s | 92.3% | 98.0% | 187 / 186 |
| 67d039b8 | 252s | 96.8% | 98.3% | 125 / 123 |
| f15a9921 | 152s | 89.8% | 96.7% | 87 / 84 |
| **mean** | | **93.3%** | **97.2%** | |

Two details that make this more than a headline number. The agreement is not
inflated by silence — "both sides said no chord" was 0.0–0.7% across all
four. And the segment counts are nearly identical, so separation isn't
changing how the model carves the song up, only occasionally disagreeing on
a label. Where they differ it is mostly major/minor quality rather than root:
root-only agreement is 97.2%.

**What this does not prove.** Neither side is ground truth, so this measures
*agreement*, not *accuracy*. In principle both could be wrong the same way,
or the ~7% where they differ could be exactly where the harmonic mix is
right. Establishing that the full mix is as *good* rather than merely as
*similar* needs human-verified chords on a few songs. The counter-argument is
just that if separation were doing heavy lifting here you would expect it to
change the answer by much more than 7%. Also: four songs, one person's
catalogue, likely similar production style.

## What that unlocks, and what it doesn't

Chords aren't separation's only consumer, so removing it from their path only
helps if the other consumers can live without it too. Traced:

| Consumer | Needs separation? |
|---|---|
| Beat / downbeat detection | **No** — already runs on the original mix by design ("the model was trained on full mixes", `handler.py`) |
| Structure detection | **No** — runs on the original mix |
| Chords | **No** — the finding above |
| Key | **Not necessarily** — currently uses the harmonic mix, but `estimateKeyFallback()` in `analyze-chords/index.ts` already derives key from the chord sequence and is wired as a fallback. It would become the primary path. |
| Lyrics | **Yes** — Whisper is given the isolated vocal stem. On a full mix, transcription quality drops materially. This is the real remaining tie. |
| Stems for play-along | **Yes**, obviously |

So the honest conclusion is not "separation is unnecessary" — it is that
separation is only necessary for **lyrics and stems**, and is currently paid
for on every analysis regardless of whether either was wanted.

## Proposal: triage the upload, then decide

**This part is design, not measurement. Nothing below has been tested.**

The observation that makes this worth doing: the pipeline *already* decides
what instruments are present — `_stem_presence()` in `handler.py` — but it
does so by measuring the RMS of each **separated stem**, which is to say
after the GPU has already been paid for. The same question asked *before*
separation would route the work instead of merely describing it.

Someone capturing a solo acoustic guitar idea needs chords, tempo and
structure. There is nothing to separate — the drum and bass stems would come
back near-silent — and if nobody sang, there is nothing for Whisper to
transcribe either. A full band production is a different job. Today both pay
the same price.

Cheap signals, all computable on CPU from the full mix before any GPU is
touched:

- **Vocal presence** — the highest-value signal, because it gates the single
  most expensive step. A small VAD, or spectral energy in vocal formant
  ranges. Note singing is not speech, so a speech-tuned VAD needs checking
  against real sung audio rather than assumed.
- **Percussion presence** — HPSS (librosa) gives a harmonic/percussive energy
  ratio cheaply. No drums is a strong hint at a sparse idea capture.
- **Stereo width** — a phone recording of one guitar is near-mono; a produced
  master is wide.
- **Crest factor / dynamic range** — masters are compressed, phone captures
  are not.
- **Duration** — a 30-second riff is not a finished song.

Natural home: the chord service. It is already CPU-only Cloud Run, already
receives the audio file, and — if chords stop needing separation — becomes
the *first* thing that touches an upload rather than something downstream of
the GPU. One call could return chords and the routing decision together.

### The rule that keeps this safe

**Detection should set the default, never silently skip what someone wanted.**
The app already has an analysis-depth chooser (`analysis_depth_sheet.dart`),
so the pattern exists: triage picks the pre-selected option and says why
("this looks like a solo idea — quick pass"), and the full pass is always one
tap away.

This matters most for the vocal check. Wasting $0.03 transcribing an
instrumental is a rounding error. *Failing* to transcribe a song someone sang
on, because a detector was confident and wrong, is a bug they feel. Bias
toward running it; only skip when confidently instrumental; always allow
"transcribe anyway".

## Other cost levers, unmeasured

Roughly in order of expected value:

1. **Self-host Whisper on the GPU already being rented.** When separation
   does run, the worker has the audio and a warm GPU. `faster-whisper` there
   instead of the API could cut the largest line item several-fold.
2. **`htdemucs_6s` → `htdemucs`.** The 6-source model exists to split guitar
   and piano out separately; the conventional stem set is vocals/drums/bass/
   other. One-word change, measurable with the existing load test.
3. **Load the model once.** Separation shells out to `python -m demucs` per
   job, paying interpreter startup, torch import and model load every time —
   even on a warm worker.
4. **Quick mode doesn't currently save GPU.** It sends fewer `stem_uploads`
   and skips structure, but the worker still runs full 6-source separation.
   Worth either making it actually cheaper or renaming it.
5. **Cheaper GPU tier.** A5000 vs 4090 is ~2.5x on price and Demucs fits
   comfortably in either. Dashboard setting, no code.

## Owned hardware, briefly

Asked and answered: at 50,000 songs/month you'd need ~3,150 GPU-hours, or
4–5 GPUs at perfect utilisation and realistically 6–8. That is a cluster
(~$15–25k capex, $200–400/mo power, colocation, and hardware failure becoming
your outage). It converts a variable cost into a fixed cost **plus a
permanent operations job**, which is the wrong trade for one person
pre-revenue. The practical version is committed cloud pricing — RunPod active
workers or spot instances, typically 30–50% off flex rates, no capex.

CPU separation is not a path: roughly 36x worse than GPU per song, being both
more expensive per second and an order of magnitude slower.
