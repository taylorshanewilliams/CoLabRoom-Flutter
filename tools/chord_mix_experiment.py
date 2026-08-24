"""Does ChordMini actually need separated audio, or is the full mix good enough?

The question is worth real money. Every analysis currently runs a Demucs job
on a GPU, and one of the two things that job produces is the harmonic mix
(bass + other + guitar + piano, summed) that ChordMini reads. If ChordMini
gives substantially the same answer on the original recording, then chord
detection doesn't need separation at all — and separation becomes something
to run only when somebody actually wants stems to play along to, instead of
on every single analysis.

Note the pipeline is already split on this question. Beat/downbeat detection
deliberately runs on the *original* mix ("the model was trained on full
mixes"), while key detection deliberately runs on the *harmonic* mix (drums
smear the chroma bins it depends on). Which of those ChordMini resembles has
never been measured — this measures it.

Costs two chord-service calls and no GPU: the stems for an already-analysed
song are sitting in Storage, so the harmonic mix is rebuilt here with the
same ffmpeg recipe the worker uses rather than re-separating anything.

Environment:
  SUPABASE_PROJECT_REF        project ref (already a repo secret)
  SUPABASE_SERVICE_ROLE_KEY   service role key (already a repo secret)
  CHORD_SERVICE_URL           the Cloud Run base URL
  CHORD_SERVICE_API_KEY       (already a repo secret)
  PROJECT_ID                  optional — which project's song to test,
                              otherwise the first one with a full set of stems
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request

# The stems the worker sums into the mix ChordMini reads (handler.py's
# HARMONIC_STEMS). Kept identical on purpose — a different recipe here would
# be measuring a mix the pipeline never actually produces.
HARMONIC_STEMS = ("bass", "other", "guitar", "piano")

# How finely to compare. Chord segments are seconds long, so 100ms is well
# under the resolution either side actually resolves.
SAMPLE_SECONDS = 0.1


def env(name: str) -> str:
    value = (os.environ.get(name) or "").strip()
    if not value:
        print(f"FAIL: {name} is not set.")
        sys.exit(1)
    return value


def request(url: str, *, method: str = "GET", headers: dict, data: bytes | None = None):
    req = urllib.request.Request(url, data=data, method=method)
    for key, value in headers.items():
        req.add_header(key, value)
    try:
        with urllib.request.urlopen(req, timeout=600) as response:
            body = response.read()
            return json.loads(body) if body else None
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"HTTP {error.code} for {method} {url}: {detail[:400]}") from error


def download(url: str, headers: dict, path: str) -> None:
    req = urllib.request.Request(url)
    for key, value in headers.items():
        req.add_header(key, value)
    with urllib.request.urlopen(req, timeout=600) as response, open(path, "wb") as f:
        f.write(response.read())


def send_to_chord_service(base_url: str, api_key: str, path: str, label: str):
    with open(path, "rb") as f:
        audio = f.read()
    boundary = "----colabroomchordexperiment"
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{label}.mp3"\r\n'
        "Content-Type: audio/mpeg\r\n\r\n"
    ).encode() + audio + f"\r\n--{boundary}--\r\n".encode()
    result = request(
        f"{base_url}/analyze",
        method="POST",
        headers={
            "X-API-Key": api_key,
            "Content-Type": f"multipart/form-data; boundary={boundary}",
        },
        data=body,
    )
    return (result or {}).get("chords") or []


def root_of(label: str) -> str:
    """'C:maj' -> 'C', 'A:min/3' -> 'A', 'N' -> 'N'.

    Root-only agreement is reported alongside exact agreement because the two
    failure modes are worth telling apart: hearing G major where the other
    heard G minor is a different (smaller) problem than hearing G where the
    other heard E flat.
    """
    return label.split(":", 1)[0].split("/", 1)[0]


def chord_at(chords: list[dict], when: float) -> str | None:
    for segment in chords:
        if segment["start"] <= when < segment["end"]:
            return segment["chord"]
    return None


def compare(full: list[dict], harmonic: list[dict]) -> None:
    if not full or not harmonic:
        print("One side returned no chords at all — nothing to compare.")
        return

    end = min(full[-1]["end"], harmonic[-1]["end"])
    samples = int(end / SAMPLE_SECONDS)
    if samples <= 0:
        print("Overlapping duration is zero — nothing to compare.")
        return

    exact = 0
    same_root = 0
    compared = 0
    both_no_chord = 0
    for i in range(samples):
        when = i * SAMPLE_SECONDS
        a = chord_at(full, when)
        b = chord_at(harmonic, when)
        if a is None or b is None:
            continue
        compared += 1
        if a == b:
            exact += 1
            if a == "N":
                both_no_chord += 1
        if root_of(a) == root_of(b):
            same_root += 1

    if compared == 0:
        print("No overlapping samples — nothing to compare.")
        return

    print()
    print(f"Compared {round(end)}s of audio at {SAMPLE_SECONDS}s resolution "
          f"({compared} sample points).")
    print()
    print(f"  Exact chord agreement:     {100.0 * exact / compared:.1f}%")
    print(f"  Root-only agreement:       {100.0 * same_root / compared:.1f}%")
    print(f"  (of the exact matches, {100.0 * both_no_chord / max(exact, 1):.1f}% were both "
          f'"no chord" — high values here inflate agreement without meaning much)')
    print()
    print(f"  Segments found — full mix: {len(full)}, harmonic mix: {len(harmonic)}")
    print(f"  Distinct labels — full mix: {len(set(c['chord'] for c in full))}, "
          f"harmonic mix: {len(set(c['chord'] for c in harmonic))}")

    print()
    print("First 20 segments, side by side:")
    print(f"  {'time':>8}  {'full mix':<14}  harmonic mix")
    for i in range(min(20, max(len(full), len(harmonic)))):
        a = full[i] if i < len(full) else None
        b = harmonic[i] if i < len(harmonic) else None
        when = f"{a['start']:.1f}s" if a else (f"{b['start']:.1f}s" if b else "")
        print(f"  {when:>8}  {(a['chord'] if a else ''):<14}  {b['chord'] if b else ''}")


def main() -> int:
    project_ref = env("SUPABASE_PROJECT_REF")
    service_key = env("SUPABASE_SERVICE_ROLE_KEY")
    chord_url = env("CHORD_SERVICE_URL").rstrip("/")
    chord_key = env("CHORD_SERVICE_API_KEY")
    wanted_project = (os.environ.get("PROJECT_ID") or "").strip()

    supabase_url = f"https://{project_ref}.supabase.co"
    rest_headers = {
        "apikey": service_key,
        "Authorization": f"Bearer {service_key}",
        "Content-Type": "application/json",
    }
    storage_headers = {"apikey": service_key, "Authorization": f"Bearer {service_key}"}

    # Find a song that has both its reference recording and a full set of
    # harmonic stems still in Storage.
    refs = request(
        f"{supabase_url}/rest/v1/project_audio_references"
        f"?select=project_id,file_id,duration_ms&file_id=not.is.null",
        headers=rest_headers,
    ) or []
    if wanted_project:
        refs = [r for r in refs if r["project_id"] == wanted_project]
    if not refs:
        print("No analysed songs with a reference recording found.")
        return 1

    chosen = None
    for ref in refs:
        stems = request(
            f"{supabase_url}/rest/v1/project_stems"
            f"?select=stem,storage_path&project_id=eq.{ref['project_id']}",
            headers=rest_headers,
        ) or []
        have = {s["stem"]: s["storage_path"] for s in stems}
        if all(stem in have for stem in HARMONIC_STEMS):
            file_row = request(
                f"{supabase_url}/rest/v1/files?select=storage_path&id=eq.{ref['file_id']}",
                headers=rest_headers,
            ) or []
            if file_row:
                chosen = (ref, have, file_row[0]["storage_path"])
                break

    if not chosen:
        print("No song found with both a reference recording and all four harmonic stems.")
        return 1

    ref, stem_paths, reference_path = chosen
    duration_s = round((ref.get("duration_ms") or 0) / 1000)
    print(f"Testing project {ref['project_id'][:8]}… ({duration_s}s of audio)")
    print(f"  reference recording: {reference_path}")
    print()

    with tempfile.TemporaryDirectory() as tmp:
        full_path = os.path.join(tmp, "full_mix" + os.path.splitext(reference_path)[1])
        print("Downloading the original recording…")
        download(
            f"{supabase_url}/storage/v1/object/room-files/"
            f"{urllib.parse.quote(reference_path, safe='/')}",
            storage_headers,
            full_path,
        )

        print("Downloading the harmonic stems…")
        local_stems = []
        for stem in HARMONIC_STEMS:
            target = os.path.join(tmp, f"{stem}.mp3")
            download(
                f"{supabase_url}/storage/v1/object/room-files/"
                f"{urllib.parse.quote(stem_paths[stem], safe='/')}",
                storage_headers,
                target,
            )
            local_stems.append(target)

        # Identical to handler.py's recipe: amix divides by input count, so
        # volume= multiplies it back to the plain sum these complementary
        # stems are supposed to reconstruct.
        print("Rebuilding the harmonic mix (same ffmpeg recipe as the worker)…")
        harmonic_path = os.path.join(tmp, "harmonic_mix.mp3")
        mix_inputs: list[str] = []
        for path in local_stems:
            mix_inputs.extend(["-i", path])
        subprocess.run(
            ["ffmpeg", "-y", *mix_inputs, "-filter_complex",
             f"amix=inputs={len(local_stems)}:duration=longest,volume={len(local_stems)}",
             "-codec:a", "libmp3lame", "-qscale:a", "4", harmonic_path],
            check=True,
            capture_output=True,
        )

        print("Sending the FULL MIX to the chord service…")
        full_chords = send_to_chord_service(chord_url, chord_key, full_path, "full_mix")
        print(f"  {len(full_chords)} segments")

        print("Sending the HARMONIC MIX to the chord service…")
        harmonic_chords = send_to_chord_service(chord_url, chord_key, harmonic_path, "harmonic_mix")
        print(f"  {len(harmonic_chords)} segments")

        compare(full_chords, harmonic_chords)

    print()
    print("Reading this: high agreement means separation is not buying chord")
    print("accuracy, and could become opt-in. Low agreement means the harmonic")
    print("mix is doing real work and separation stays on the critical path.")
    print("One song is a signal, not a conclusion — run it on a few before deciding.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
