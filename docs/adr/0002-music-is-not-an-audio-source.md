# Music is not an audio Source

There is no "Music app" Source and there will not be one. Recognizing what a Player is
playing is a layer over the system-audio Source, not a Source of its own — so the user picks
_where the sound comes from_, and the badge fills in on its own when Synesthia recognizes the
Player producing it.

## Considered options

A `musicApp` Source existed and was removed. It was never a distinct audio path: Music
exposes no audio stream, so it went through the same ScreenCaptureKit tap as system audio and
differed only in the label. What it did do was force the user to know which of two
identical-sounding options to pick, and pick wrong.

## Consequences

`AppState.migrated(_:)` rewrites a stored `musicApp` selection to `systemAudio`, and must
stay for as long as anyone might launch a version predating the change. Detection is scoped
to the system-audio Source deliberately — a Spotify badge over a live microphone feed would
be a lie, so `detectedPlayer` returns nil for every other Source.

See `docs/macos-integration.md` for the three layers of Player integration.
