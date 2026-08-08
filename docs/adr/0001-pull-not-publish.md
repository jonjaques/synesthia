# Audio data is pulled, never published

Analyzed audio does not flow through the app's observable state: the Analyzer holds the
latest Snapshot behind a lock, and the render loop asks for it once per frame. Control state
(which Source is active, which Visualizer is selected, what is playing) is observable and
changes at human speed; audio features change at 60–120 Hz and would invalidate every view
that touched them, at frame rate, forever.

## Considered options

Publishing the Snapshot through `@Observable` is the SwiftUI-native instinct and is what a
reader will assume was tried. It was rejected on cost: the visuals are the only consumer that
needs per-frame data, and it already runs its own display-linked loop, so making SwiftUI
carry the same data buys nothing and costs a re-render per frame.

## Consequences

The Analyzer is the one object shared across threads, and it is the only place that needs
locking. Everything else is main-actor, and background work has to opt out explicitly — which
is why `nonisolated` appears on the analyzer, the Snapshot value type, and every audio-thread
callback. Under Swift 6 that is enforced rather than conventional: a closure built in a
main-actor context and handed to AVFAudio traps on its first buffer.

See `docs/architecture.md` for the component map and `docs/audio-pipeline.md` for the funnel.
