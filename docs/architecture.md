# Architecture

## The problem, precisely

Two separate mechanisms make audio quiet during a call, and they are usually
confused with each other:

1. **Output ducking.** FaceTime instantiates Apple's
   `kAudioUnitSubType_VoiceProcessingIO` audio unit, and instantiating it makes
   `coreaudiod` attenuate every other audio client on the machine. Measured here:
   **exactly −30.00 dB**, flat, on both RMS and peak. There is no System Settings
   toggle, no `defaults write`, and no supported API. Developer reports of this have
   gone unanswered since 2020.
2. **Media apps pausing themselves.** The call fires a system-wide audio
   interruption and Spotify, browsers and the rest simply stop.

Apple's own answer is SharePlay, which is iPhone/iPad only for Spotify and YouTube.
Existing Mac tools (Loopback, BlackHole, SoundSource) can route or boost audio but
know nothing about calls, and SoundSource's +12 dB ceiling does not cover a 30 dB
duck anyway.

## The approach

macOS 14.4 added public Core Audio process taps
(`AudioHardwareCreateProcessTap`) — per-process capture that can also mute the
source, needing only a TCC grant. No kext, no driver.

Unduck taps every audible source *with muting*, so the only stream reaching the
device is its own mix. The system duck then applies uniformly to that one stream,
and the relative balance between call voice and music becomes Unduck's to set —
which is exactly the control macOS refuses to expose.

Compensation comes from hardware volume first, because that is clean gain applied
after the duck. Digital makeup covers only what the hardware cannot reach, and a
limiter catches the rest. In practice the hardware alone covers all 30 dB, so
nothing is boosted digitally and nothing clips.

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

## File map

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
before anything touches the UI. Leaving a user's system 30 dB high after a crash is
the worst thing this app can do, so the restore path was written before anything
that raises volume, persists its pre-engage state to disk, and reclaims it on the
next launch.

## Signing

`make-cert.sh` creates a self-signed code-signing identity. This is not cosmetic:
TCC keys permissions to the code signature, and an ad-hoc signature's designated
requirement is the cdhash — which changes on every build. Without a stable identity
every grant is silently revoked on each rebuild and no permission-dependent feature
can be tested twice. With a certificate the requirement becomes
`identifier + certificate leaf` and grants persist.

Two traps in that script, both already fixed, both easy to reintroduce:

- The identity is invisible to `security find-identity -v -p codesigning` unless it
  is marked as a trusted root, yet `codesign --sign` uses it happily. Check for it
  with `find-certificate`, and verify it by test-signing something.
- OpenSSL 3 defaults to AES-256-CBC with an SHA-256 MAC for PKCS12, which Apple's
  Security framework cannot read — the import fails with "MAC verification failed
  (wrong password?)" even when the password is right. Legacy algorithms are
  requested explicitly.

To remove: Keychain Access → login keychain → delete "Unduck Self Signed".
