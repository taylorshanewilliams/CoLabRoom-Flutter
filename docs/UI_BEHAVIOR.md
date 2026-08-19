# Music Beta UI Behavior

## Navigation

- The bottom navigation is borderless: Home, Rooms, Invites, and Account.
- The current destination turns cyan and receives a feathered bloom behind the icon.
- At desktop widths the same four destinations move into a compact side rail.

## Home

- Home has one industry and one primary action: **Start a New Song**.
- Starting a song first asks where it should live.
- The user may select an existing Room or create a new Room without abandoning the flow.
- Recent Rooms are presented as quick-entry tiles.

## Rooms

- Rooms opens to user-named folder-style tiles, not a flat project list.
- Room search is always near the top.
- Capitalization is preserved in Room names.
- Users select a music icon when creating a Room; custom uploaded artwork is supported by
  the data model and private storage path but remains a follow-on UI task.
- Opening a Room reveals that Room's song-project tiles.

## Project workspace

- The header is compact and the editor receives the majority of the viewport.
- Tapping the project title opens rename immediately.
- The first tester build shows only working contributions; Comments, Files, and History
  return as each interaction is completed and verified.
- Writing color and auto-scroll live in a single workspace-tools sheet.
- The composer stays above the keyboard and supports up to four visible lines.
- Talk to Text is a 44-pixel circular control beside the composer. Recognized words are
  written into the visible composer before submission.

## Motion and bloom

- Touch feedback uses two low-opacity, high-blur shadows with feathered edges.
- It must never replace the surface with an opaque blue pressed state.
- Motion is brief (roughly 180–280 ms) and respects platform accessibility settings in
  the production hardening pass.
