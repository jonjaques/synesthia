# App Store Connect metadata

Drafts for every text field in the listing, plus the review notes. Character
limits are enforced by `scripts/check-metadata.py`; run it after editing.

Applies to the **`Release`** configuration only — the Mac App Store build,
which has no Music.app source and sends no Apple Events. Nothing here should
describe a feature that build does not have.

---

## Name

```
Synesthia
```

## Subtitle (≤30)

```
See what your Mac is playing
```

## Category

Primary: **Music**. Already set as `LSApplicationCategoryType =
public.app-category.music`. Secondary: Entertainment.

## Promotional text (≤170)

Editable without a new build — use it for release news.

```
Three GPU visualizers driven by a 64-band live FFT. Point it at your system audio, a mic, or a file, and watch the music. Built-in demo track, no permissions needed.
```

## Keywords (≤100)

Comma-separated, no spaces (spaces count against the limit). Avoid repeating
words already in the name or subtitle — Apple indexes those anyway.

```
visualizer,spectrum,equalizer,fft,audio,waveform,metal,gpu,ambient,vj,analyzer,dj,light,screensaver
```

## Description

```
Synesthia turns whatever your Mac is playing into light.

A 64-band FFT runs over the live audio a few dozen times a second, and its
output drives three visualizers rendered on the GPU with Metal. Bass moves
differently from treble. Transients hit. It responds to the music rather than
just wobbling along near it.

THREE VISUALIZERS

Nebula — a particle cloud in orbit, every particle bound to one frequency band
and flaring when its band hits.

Spectrum Tunnel — flight through a tube whose angular slices are the live
spectrum, loud frequencies pushing the walls outward.

Aurora — layered ribbons riding the waveform, each glowing with its own slice
of the spectrum.

Each one has its own palette, sensitivity, speed, and shape controls, and
remembers them separately.

FOUR WAYS TO FEED IT

• Demo track — a loop bundled with the app. Works immediately, needs no
  permission of any kind.
• System audio — anything your Mac plays: a browser tab, a streaming app,
  Apple Music, a game.
• Audio input — a microphone, line-in, or audio interface.
• Audio file — open any audio file from your Mac.

BUILT FOR MACOS

• Universal — Apple silicon and Intel
• Full screen, edge to edge, with controls that fade away when you stop moving
  the pointer
• Renders at your display's full refresh rate, including 120 Hz ProMotion, and
  stops rendering entirely when the window is hidden
• Keeps the display awake while music is playing, and only while it is playing
• Honors Reduce Motion — damps beat-driven flashing and smooths brightness
• Five palettes, keyboard shortcuts, VoiceOver labels throughout

PRIVATE BY DESIGN

No accounts, no analytics, no networking, no third-party SDKs. Audio is
analyzed in memory and never recorded, stored, or transmitted. Nothing leaves
your Mac.
```

## What's New in This Version

```
First release.
```

## Support and marketing URLs

| Field              | Value                           |
| ------------------ | ------------------------------- |
| Support URL        | `https://synesthia.app/support` |
| Marketing URL      | `https://synesthia.app`         |
| Privacy Policy URL | `https://synesthia.app/privacy` |

## Copyright

```
2026 Jon Jaques
```

## Age rating

4+. Nothing in the questionnaire applies: no user content, no web access, no
purchases, no gambling, no contests, no unrestricted web.

## App Privacy answers

**Data Not Collected** — every category. This must stay identical to
`Synesthia/PrivacyInfo.xcprivacy`, which declares no tracking, no collected
data types, and a single `UserDefaults` access (reason `CA92.1`). If one
changes, change both plus the privacy page in the same commit.

## Price

Free, or paid — undecided. Note the site's structured data currently advertises
price `0`; if it ships paid, update `web/src/layouts/Base.astro`.

---

## Review notes

Paste into the "Notes" field of the submission. Written to pre-empt the two
rejections this app is most exposed to: "does not function" from a reviewer who
grants nothing, and questions about why a music visualizer wants screen
recording.

```
Thanks for reviewing Synesthia.

NO PERMISSIONS ARE NEEDED TO SEE THE APP WORK.

Synesthia launches into a welcome sheet explaining the optional audio sources.
Click "Continue" — which grants nothing — and it starts playing a bundled demo
track. The visualizer is animating a second later on a machine that has granted
no permission at all, and the app is fully functional from there.

To verify quickly:
  1. Launch the app. A welcome sheet explains the audio sources.
  2. Click "Continue". The bundled demo track begins playing.
  3. The canvas is animating in time with the audio.
  4. Use the "Visualizer" menu (or Cmd-1 / Cmd-2 / Cmd-3) to switch between
     Nebula, Spectrum Tunnel, and Aurora. All three react to the demo track.
  5. The sliders button opens palette and sensitivity controls.

No account, no network connection, and no content of any kind is required.

WHY THE APP ASKS FOR SCREEN RECORDING (OPTIONAL FEATURE)

If you choose the "System audio" source, macOS asks for Screen & System Audio
Recording. This is not a screen-capture feature.

macOS provides no dedicated API for capturing system audio output. The only
sanctioned route is ScreenCaptureKit, which can attach an audio stream to a
screen capture, and that framework is gated behind the screen-recording
permission. Synesthia therefore configures the capture's video leg at 2x2
pixels, at 5 fps, with showsCursor disabled, registers a screen output purely
because SCStream requires one, and discards every frame it receives without
reading, storing, or transmitting any of it. Only the audio buffers are used,
and only to compute FFT magnitudes for the current video frame.

See SystemAudioCapture in the source: config.width = 2, config.height = 2,
and the stream(_:didOutputSampleBuffer:of:) callback returns immediately for
anything that is not .audio.

MICROPHONE (OPTIONAL FEATURE)

Requested only if you select the "Audio input" source, so a mic or line-in can
drive the visuals. Input is analyzed in memory and never recorded or played
back.

NOW PLAYING NEEDS NO PERMISSION

Synesthia names the track you are listening to in Music or Spotify. It does this
by observing the distributed notifications those apps already broadcast
system-wide — a public API, no entitlement, no prompt, and no request for your
music library. No private frameworks are used; MediaRemote is not linked.

THIS BUILD DOES NOT CONTROL ANY MUSIC PLAYER

Synesthia sends no Apple Events. It has no automation entitlement and no
temporary exception; every line of AppleScript is compiled out of this build,
which the release script verifies against the built archive. Playback control
and album artwork are absent here by design, and nothing in the app asks for
them.

PRIVACY

No data collection, no analytics, no networking, no third-party SDKs. Audio is
never written to disk or transmitted. The only stored data is local
preferences (chosen visualizer, palette, slider values) and a security-scoped
bookmark to a file the user picked themselves, so it reopens next launch.

Happy to answer anything else.
```
