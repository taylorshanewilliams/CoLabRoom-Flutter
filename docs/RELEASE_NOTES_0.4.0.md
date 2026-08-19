# CoLabRoom 0.4.0 Beta Hardening

## Import Song restored and expanded

- Import is now the first visible songwriting toolbar action and is also present in the song overflow menu.
- Supports pasted lyrics/chords, public Google Sheets, PDF, `.xlsx`, OpenDocument spreadsheets, DOCX, CSV, TSV, RTF, TXT, and Markdown.
- Detects full lyric phrases, common section labels, chord-over-lyric layouts, `[G]inline` chord notation, and guitar-tab rows.
- Adds a review screen before changing a Room.
- Offers Add to End and Replace Song modes with clear destructive warnings.
- Imported chord placements become editable Song Sheet chords when replacing a song or importing into an empty song.

## Editing and navigation stability

- Pending lyric edits are flushed before leaving a song, importing, opening analysis, opening Live, printing, or sharing.
- Active/saving voice notes block accidental navigation until the operation is safe.
- Live mode protects unfinished Tap Sync and in-progress chord/timing saves from accidental closure.
- Replacing a song clears stale chord and timing data so old analysis cannot silently attach to new lyrics.

## Song Sheet and Live polish

- Song Sheet is usable with manual/imported lyrics and chords before a reference recording is added.
- Live mode remains available without reference audio; Synced mode starts only when reference timing exists.
- The UI distinguishes estimated timing from reviewed Tap Sync timing.
- Imported chords can be corrected in Song Sheet and Live.

## Beta testing readiness

- Added a one-time beta welcome and an in-app tester guide.
- Added song-specific beta feedback from the song menu.
- Updated privacy wording for imports, Google Sheets, voice notes, reference tracks, and on-device analysis.
- Version: 0.4.0, Android version code 16.
