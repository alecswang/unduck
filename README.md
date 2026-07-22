# Unduck

Keeps your music at a normal volume during FaceTime calls on macOS.

## The problem

Start a FaceTime call on a Mac and everything else gets quiet. Two separate
mechanisms cause it, and they are usually confused with each other:

1. **Output ducking.** FaceTime instantiates Apple's `kAudioUnitSubType_VoiceProcessingIO`
   audio unit, and instantiating it makes `coreaudiod` attenuate every other audio
   client on the machine. Measured here: **exactly −30.00 dB**, flat, on both RMS and
   peak. There is no System Settings toggle, no `defaults write`, and no supported
   API. Developer reports of this have gone unanswered since 2020.
2. **Media apps pausing themselves.** The call fires a system-wide audio
   interruption and Spotify, browsers and the rest simply stop.

Apple's own answer is SharePlay, which is iPhone/iPad only for Spotify and YouTube.
Existing Mac tools (Loopback, BlackHole, SoundSource) can route or boost audio but
know nothing about calls, and SoundSource's +12 dB ceiling does not cover a 30 dB
duck anyway.

## What Unduck does

- Detects a call starting, automatically
- Captures every audio source with a muted Core Audio process tap, so it owns the
  mix rather than competing with it
- Re-renders that mix and restores the 30 dB, mostly via hardware volume so nothing
  is boosted digitally and nothing clips
- Un-pauses the media the interruption stopped
- Gives you independent **Call voice** and **Music** faders — the control macOS
  refuses to expose
- Puts your volume back the instant you hang up

Requires macOS 14.4+ (Core Audio process taps). Built and measured on macOS 15.7.3,
Apple Silicon.

## Install

```bash
./make-cert.sh     # one-time: stable signing identity, see "Signing" below
./install.sh       # build, install to /Applications, launch
```

Then, once:

1. **System Settings → Privacy & Security → Accessibility** → add
   `/Applications/Unduck.app` and turn it on. This is the media-key permission used
   to un-pause media; it is the one grant macOS will not let an app request from a
   dialog.
2. Quit and reopen Unduck so it re-reads that grant.
3. Tick **Start Unduck at login**.

Audio-capture permission is requested on first launch.

## How it works

```
                    avconferenced starts running input
                                  │
                                  ▼
   ┌─────────────┐        ┌───────────────┐        ┌──────────────┐
   │ CallDetector│───────►│  Controller   │───────►│  VolumeGuard │
   │  (50ms)     │        │ engage/restore│        │  +30 dB, and │
   └─────────────┘        └───────┬───────┘        │  puts it back│
                                  │                └──────────────┘
                                  ▼
   Spotify ──tap(muted)──┐  ┌───────────┐
   Chrome  ──tap(muted)──┼─►│ MixEngine │──► output ──(system ducks 30 dB)──► ears
   avconferenced ─tap────┘  │  2 buses  │
                            └───────────┘
```

| File | Role |
|---|---|
| `Call/CallDetector.swift` | Watches `avconferenced` for active audio input |
| `Call/MediaResumer.swift` | Un-pauses interrupted media via media-key injection |
| `Mixer/MixEngine.swift` | Muted taps → ring buffers → gains → limiter → output |
| `Mixer/VolumeGuard.swift` | Owns every hardware volume change, guarantees restore |
| `Mixer/RingBuffer.swift` | Lock-light SPSC buffer between tap and render threads |
| `CoreAudio/ProcessTap.swift` | `AudioHardwareCreateProcessTap` + private aggregate device |
| `CoreAudio/AudioCapturePermission.swift` | TCC state for `kTCCServiceAudioCapture` |
| `App/Controller.swift` | Lifecycle, gain-split policy, safety ordering |
| `tools/` | The measurement probe every constant in this code came from |

Full measurement record, including the experiments that failed:
[`docs/measurements.md`](docs/measurements.md).

## Things that are non-obvious

Each of these cost real debugging time and is easy to reintroduce.

**Watch `avconferenced`, not FaceTime.app.** FaceTime.app never opens audio input
during a call — a daemon does. A detector watching the app reads "no call" for the
entire call. `CoreSpeech` holds input almost permanently for always-on Siri, so
"someone is using the mic" is not a usable signal either.

**A muted tap still receives full, unducked audio.** The duck is applied on output.
So captured audio needs no correction; only Unduck's own render does. Getting this
backwards suggests a 60 dB makeup and a redesign that isn't needed.

**Process taps never prompt for permission.** They succeed, deliver correctly-sized
buffers, and fill every one with zeros. Silence and denial are indistinguishable, so
the grant must be requested explicitly and its state surfaced.

**`IsRunningOutput` is not "is it playing".** Spotify clears it when paused; Chrome
keeps its audio IO open over a paused video. Judge by level.

**Never touch `AVAudioEngine.inputNode`.** On this machine it blocks forever inside
`AudioDeviceCreateIOProcID`. Unduck is output-only and never needs capture.

**`AEDeterminePermissionToAutomateTarget` blocks indefinitely** — even with
`askUserIfNeeded: false`. Called from a timer on the main thread, it froze the app
mid-call and prevented the volume restore, turning a cosmetic feature into a 30 dB
safety failure. The AppleScript path was removed for this reason; see the header of
`MediaResumer.swift` before reviving it.

**Safety work must not sit behind the main thread.** `CallDetector` fires a
synchronous callback on its own queue the moment a call ends, restoring the volume
before anything touches the UI.

## Signing

`make-cert.sh` creates a self-signed code-signing identity. This is not cosmetic:
TCC keys permissions to the code signature, and an ad-hoc signature's designated
requirement is the cdhash — which changes on every build. Without a stable identity
every grant is silently revoked on each rebuild and no permission-dependent feature
can be tested twice. With a certificate the requirement becomes
`identifier + certificate leaf` and grants persist.

To remove: Keychain Access → login keychain → delete "Unduck Self Signed".

## Known limitations

- Duck depth is calibrated for built-in speakers. Other output devices may differ;
  the **Duck compensation** slider is the manual correction until per-device
  calibration exists.
- Media resume uses a blind play/pause toggle aimed at whatever owns Now Playing.
  If two apps were playing and only one paused, it may resume the wrong one.
- Sending your music *into* the call, so the far side hears it, is not implemented.
  It needs a virtual input device (an `AudioServerPlugIn`) plus Mic Mode set to
  **Wide Spectrum**, and is blocked behind the `inputNode` hang above.
- Not sandboxed, not App Store distributable: process taps and TCC state reads
  require it.
