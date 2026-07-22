# Measurements

Every constant in Unduck's source comes from this document. It records what was
measured, on what, and — as importantly — the theories that turned out to be wrong,
because several of them are plausible enough to be re-derived by the next person.

The probe in `tools/` reproduces all of it.

Machine: MacBook Pro, macOS 15.7.3 (24G419), Apple Silicon, Xcode 16.2.
Probe: `tools/`, built + ad-hoc signed by `tools/build.sh` into `tools/build/UnduckProbe.app`.

## Settled before any call was placed

### Process objects work, and they are enough for call detection
`kAudioHardwarePropertyProcessObjectList` enumerates every audio client with
`kAudioProcessPropertyPID`, `kAudioProcessPropertyBundleID`,
`kAudioProcessPropertyIsRunningInput` / `IsRunningOutput`. Verified live:
Spotify (pid 12432) reports `runningOutput = yes` while playing; the probe itself
flips to `runningInput = yes` the moment a tap starts.

This is the whole of `CallDetector` — public API, no polling of window state, no
Accessibility grant. **Plan item 1 is confirmed feasible.**

### Default output device
```
MacBook Pro Speakers   uid BuiltInSpeakerDevice   2 output channels
volume scalar 0.1875  =  -36.0 dB
```
Two channels ⇒ one stereo pair ⇒ per the [pair-count attenuation
quirk](https://developer.apple.com/forums/thread/806799) this device should show
~0 dB of tap attenuation. Calibration still gets written, but built-in speakers are
the easy case; a multi-output interface is where it will matter.

Relevant to S5 / Design A: resting volume sits at −36 dB, i.e. there is a large
amount of upward headroom on the hardware volume control. Design A's compensation
move (raise device volume by the duck amount, attenuate each source digitally) has
room to work here.

### Taps: created successfully, but deliver silence under the agent harness — TCC, not code
`AudioHardwareCreateProcessTap` succeeds, the private aggregate device is created,
the IO proc runs and delivers correctly-sized buffers (96 000 samples/sec for
48 kHz stereo) — and every sample is zero.

Ruled out, in order:

| Hypothesis | How it was eliminated |
|---|---|
| Target app was silent | `selftest` plays its own known −20 dBFS sine and taps itself *and* the global mix. Process object confirms `runningOutput = yes` while it runs. Still all zeros. |
| Wrong buffer / bad frame math | Buffer sizes are exactly right; only the contents are zero. |
| Wrong aggregate-device setup | Dictionary matches `insidegui/AudioCap` key for key: `MainSubDevice` = output UID, `IsPrivate` = true, `IsStacked` = false, `TapAutoStart` = true, `SubDeviceList` = [output UID], `TapList` = [{ `SubTapUID` = tap UUID, `SubTapDriftCompensation` = true }]. |
| Unsigned binary | Fixed: `Info.plist` with `NSAudioCaptureUsageDescription` embedded via `-sectcreate __TEXT __info_plist`, ad-hoc signed with hardened runtime, `Identifier=com.unduck.probe`. Then re-wrapped as a proper `.app` bundle. Behaviour unchanged. |

Remaining cause: **no TCC audio-capture grant, and no prompt is reachable.** The
responsible process for anything the agent launches is `claude`, not Terminal or a
GUI app (`ps` on the shell's ancestry confirms it), so tccd suppresses the prompt
and the tap silently returns zeros — with nothing written to the tccd log, which is
itself the tell.

**Consequence for the real app:** this is not a probe artifact. It is the shipping
constraint. Unduck must be a signed, bundled `.app` that the user launches
normally, and it must handle the denied/undetermined state explicitly rather than
showing a dead mixer — silent zeros are indistinguishable from silence, so the app
has to detect "granted but all-zero" and say so. Plan item 6 gets promoted from
housekeeping to a first-class state machine.

## Permission: solved

`TCCAccessPreflight` reported **UNDETERMINED**, not denied — nobody had ever
answered, because **creating a tap does not trigger the prompt**. It just returns
zeros. The grant has to be requested explicitly (`TCCAccessRequest`), and *who asks*
decides whether a prompt is even possible:

| Launcher | Responsible process | `kTCCServiceAudioCapture` |
|---|---|---|
| agent Bash tool | `claude` | request **refused, stays UNDETERMINED** — never prompted |
| `./probe` from Terminal | Terminal | same |
| `open -a UnduckProbe.app` | the app itself | **GRANTED** |

tccd refuses to prompt when the responsible process's bundle has no
`NSAudioCaptureUsageDescription`, and it says nothing about it. Microphone behaved
differently (granted from the shell), which is what made this confusing: two
services, same call site, opposite outcomes.

**For the shipping app:** it must be a launched `.app`, it must call the request
explicitly at onboarding rather than waiting for the first tap, and it must
distinguish granted / denied / undetermined in the UI. A tap that returns silence is
indistinguishable from silence.

Note: ad-hoc signing keys the grant to the cdhash, so **every rebuild can void it**.
Verified it survived one rebuild; if taps go quiet after a build, re-run the
`open -a` grant step before assuming a regression.

## Verified: taps are sample-exact on this hardware

−20 dBFS sine, tapped: **peak −20.00 dBFS, RMS −23.01 dBFS** (= −20 − 3.01, exactly
right for a sine). Zero attenuation. The [pair-count attenuation
quirk](https://developer.apple.com/forums/thread/806799) does not bite on a
2-channel device, as predicted. Multi-pair interfaces still need calibration.

## First live call — 2026-07-22 00:15

Spotify playing steadily, call placed ~15 s in, per `docs/measurement-run.log`.

**Baseline, no call** — target and global agree, Spotify is the only source:
```
proc rms ≈ -27.0   peak ≈ -19.0     global rms ≈ -27.0   peak ≈ -19.0   (rock steady, 15s)
```

**During the call, 30 s** — the per-process tap on Spotify reads **exact digital
silence**, while the global tap shows speech-shaped audio swinging −23 to −66 dB:
```
proc rms  -inf   peak  -inf         global rms -24 .. -66   peak -3.6 .. -51
```
Operator confirms: *"I could hear the sound playing, then I got on FaceTime and no
Spotify at all."*

**This is not ducking.** A 20 dB duck leaves a reduced but nonzero signal. This is
zero. Something stopped Spotify's stream outright, and the whole plan turns on which
thing it was:

- **If Spotify paused itself** — an app-level reaction to the call — then the duck
  was never measured, S1 is still unanswered, and Design A is untouched.
- **If macOS hard-muted the stream upstream of the tap point** — then tapping media
  during a call yields zeros, and **Design A cannot work at all**, because there is
  nothing left to re-render.

Cannot tell these apart from a media app, since both look like silence. Resolved by
using a source that cannot pause — see the `duck` command below.

### S2 — FaceTime tap creation: PASSED
```
mute=false: TAP OK, 48000 Hz x2
mute=true:  TAP OK, 48000 Hz x2
```
Both succeeded. This was the main gate for Design A and it cleared. The
"0 samples" in that log line is **my bug, not a FaceTime limitation**:
`AudioDeviceCreateIOProcIDWithBlock` with a nil queue dispatches to the main queue,
and that test blocked main with `Thread.sleep`, starving its own callbacks. Fixed —
every tap now gets a dedicated serial queue.

### S3 — invalid, needs a redo
Killed mid-run (`Terminated: 15`) by a stray `pkill` of mine while the operator's
script was live. No data.

### S5 — device volume is settable during a call: PASSED
```
0.375 (-24.6 dB)  ->  0.500 (-18.6 dB)   applied and restored cleanly, call up
```
The control works while ducked. Whether it buys real headroom for ducked media is
still unknown, because the media was silent for the entire test.

## Second live call — the duck, measured

`duck --match Spotify`, reference tone at −20 dBFS peak / −23.01 dBFS RMS.

```
 t | tone-rms tone-pk      n | tgt-rms tgt-pk out | glob-rms glob-pk
22s|  -23.01  -20.00   96256 |  -28.79 -18.45 yes |  -21.82  -13.39   <- before
23s|  -30.31  -20.00   69632 |    -inf   -inf yes |  -30.61  -20.00   <- transition
24s|  -53.01  -50.00   95232 |    -inf   -inf  NO |  -53.01  -50.00   <- call up
35s|  -53.01  -50.00   95232 |    -inf   -inf  NO |  -53.01  -50.00
36s|  -53.01  -50.00   96256 |  -73.63 -50.63 yes |  -32.21  -11.85   <- call ending
40s|  -23.01  -20.00   96256 |  -26.72 -18.70 yes |  -21.43  -13.34   <- restored
```

### S1 — the duck is exactly 30.00 dB
```
peak  -20.00  ->  -50.00     = -30.00 dB
rms   -23.01  ->  -53.01     = -30.00 dB
```
Identical on both statistics, stable for twelve consecutive seconds, and it returns
to exactly −20.00 / −23.01 afterwards. This is a clean fixed gain, not compression
and not the ~20 dB the reports describe. **Every dB figure in the plan should be
30, and it still must be measured per device rather than hardcoded.**

### S4 — the duck lands upstream of the tap, and hits our own output
The ducked value appears *in the tap*, so a tap does not see pre-duck audio. And the
tone is our own rendered output, so anything Unduck plays is ducked by the same
30 dB. Both halves of the naive Design A are affected:

- tapped media arrives 30 dB down
- re-rendering it loses another 30 dB

**Compensation is not optional, and pure digital gain cannot do it alone.** Restoring
30 dB digitally needs 30 dB of headroom below 0 dBFS in the tapped signal; loud
music has almost none. The device volume control supplies the rest: it sits at 0.38
= −24.6 dB, leaving **+24.6 dB** of hardware headroom. Digital headroom plus hardware
headroom covers 30 dB comfortably for normal material, and for material mastered near
0 dBFS a limiter absorbs the shortfall. Design A survives — with a limiter promoted
from "Design B only" to mandatory.

### Spotify pauses itself — a second, unrelated problem
`tgt-out` flips `yes -> NO` at 24 s and back at 36 s. Spotify stops rendering entirely
when the call starts; the system did not silence it. That is why the first run showed
digital silence and why you hear nothing at all rather than something quiet.

This is outside Unduck's reach — no mixer can un-pause a player that has decided to
stop. Worth confirming whether it is Spotify reacting to the mic being taken, and
whether other sources (browser audio, local files) do the same. If it is universal to
Spotify, the honest answer is that Unduck fixes browser/YouTube/local audio and
Spotify needs a manual un-pause.

### Call detection via FaceTime.app is wrong
The `call` column read `no` for the entire call. `FaceTime.app` never opens audio
input — a daemon does (`avconferenced` is the likely owner; the process list shows it
resident). **Plan item 1 must watch the daemon, not the app.** The `duck` command now
prints every process holding input each second so the next run names it outright.

## Working end to end — 2026-07-22 01:57

First successful real call with the app, `docs/` log excerpt:

```
01:57:10  volume 0.25 -> 0.9456       engaged (compensate=true) hardware=30dB digital=0dB
01:58:19  media in  -27.0/ -18.9      out  -27.2/ -18.9
01:58:22  disengaging → volume restored to 0.25 (now 0.25)
```

Operator: "sounded chill during call", "volume after is chill".

### The duck is applied on output only — not to a muted tap's copy

`media in` during the call reads **−27.0 dBFS rms / −18.9 peak**. The pre-call
baseline for the same source measured **−27.4 / −18.5**. Identical, so a muted tap
receives full unducked audio *while a call is running*.

This settles a real scare: after the first attempt sounded far too quiet, the
leading theory was that the duck applies twice — once to the captured source and
once to Unduck's own render — which would have needed ~60 dB of makeup and forced
a redesign. It does not. The quiet result was simply the compensation slider sitting
at 13 dB against a 30 dB duck.

**Gain structure, confirmed:** source → tap at full level → Unduck mix → output
ducked 30 dB → hardware volume +30 dB → back to the user's chosen level. Digital
makeup stays at 0 whenever the hardware has the range, so nothing touches the
limiter and there is no clipping risk on loud material.

### Safety: the hangup blast, and the fix

The first real call ended with everything at near-maximum volume. The restore itself
was correct — the log showed the volume returned — but the **call detector polled
once a second**, so up to a full second elapsed between the duck lifting at hangup
and Unduck dropping the volume back. Compensation only makes sense while the duck
is applied; outside it, that same setting is 30 dB of blast.

Three changes:

1. Poll interval 1 s → **50 ms**. This is a safety timer, not a UI timer. Its cost
   is one property read 20x a second; its benefit is not hurting someone wearing
   headphones. Attachment retry stays at 1 s because that path spawns `pgrep`.
2. `silenceOutput()` — disengage kills Unduck's own render *first*, then restores
   the volume, then un-mutes sources. Whatever gap remains is now silent rather than
   loud, because during compensation our output is the loudest thing on the machine.
3. Same ordering applied to the engage error path and the panic button.

### Media apps pause themselves on call start — both of them

Spotify and browser/YouTube audio both stop when a call begins. It is a system-wide
media interruption, not a Spotify quirk, so recommending a different source was bad
advice. In the successful run the media was silent for only ~4 s of a 72 s call, so
this is less fatal than first assumed, but Unduck cannot un-pause a player that has
decided to stop.

## S3 — source muting works, and the tap keeps full level: PASSED

```
tap --match Spotify --mute --seconds 8
  peak -17.5 dBFS captured, all 8 seconds
  operator: Spotify audibly silent, recovered afterwards
```

The best possible outcome. `muteBehavior = .muted` silences the source at the device
while the tap still receives it at **full, unducked level** — the −30 dB duck is not
applied to a muted-and-tapped stream. So Unduck can take a source over completely:
mute the original, keep pristine audio, re-render on its own terms.

This also improves the compensation math from the S1/S4 section. Tapped audio comes
in at full scale, not 30 dB down, so the only loss to make up is the 30 dB applied to
Unduck's own output — recoverable from digital headroom plus the +24.6 dB of
hardware volume range, with a limiter for hot material.

## S6 — blocked by a local audio-environment fault, not by the design

The test never ran. Three bugs fixed along the way, then a wall:

1. `setVoiceProcessingEnabled(true)` called on **both** nodes fails with −10875 at
   `kAUInitialize`. Enabling either side turns on the other; call it once, on input.
2. A throw from top-level Swift aborts with `EXC_BREAKPOINT` and a crash log instead
   of a message. The probe now wraps its command switch in `do/catch`.
3. Output piped to `head` is block-buffered, so a killed process loses everything it
   printed. The `--log` path writes through `synchronize()` and survives.

The wall: **`AVAudioEngine.inputNode` hangs indefinitely on plain access**, before
voice processing is requested at all. Sampled stack:

```
main.swift -> TonePlayer.start -> -[AVAudioEngine inputNode]
  -> AVAudioEngineImpl::UpdateInputNode -> dispatch_sync
    -> AVAudioIOUnit_OSX::BindToDeviceInternal
      -> AudioDeviceCreateIOProcID -> HALC_ProxyIOContext::_TellServerAboutStreamUsage
        -> mach_msg  (never returns)
```

Ruled out: the default input device resolves fine (`MacBook Pro Microphone`, id 79);
there are no leaked aggregate devices (4 devices, all legitimate); tccd logs no
microphone decision at all, so it is blocking rather than being denied; it hangs
identically whether launched from a shell or as the app bundle.

Two remaining suspects, both environmental: a wedged `coreaudiod`, or a third-party
HAL plugin misbehaving during device reconciliation — this machine has two
(`Lorax🥸 Microphone`, `Microsoft Teams Audio`), and the earlier crash's own stack
was sitting in `HALC_ShellPlugIn::_ReconcileDeviceList` against a proxy object.

**S6 is parked, not failed.** It is an optimization that could delete the entire
compensation layer; the compensation path is fully proven and gets built regardless.
Retry S6 after `sudo killall coreaudiod` or a reboot. Note that **feature 2 needs
microphone input too**, so this fault has to be resolved before that milestone even
if S6 stays unanswered.

## S6 — the promising shortcut

FaceTime's own audio is audibly not ducked while it ducks everyone else. If the
exemption comes from being a VoiceProcessingIO client, Unduck can render its mix
through that same unit and skip the entire gain-compensation apparatus — no 30 dB
restoration, no limiter, no touching the user's hardware volume.

`duck --vpio` renders the reference tone through `setVoiceProcessingEnabled(true)`
and measures it across a call:

| tone-pk during call | Meaning |
|---|---|
| stays −20.00 | voice clients are exempt — **compensation is unnecessary, redesign around this** |
| −50.00 | no exemption, proceed with gain compensation as above |

## Still open — needs a live FaceTime call

S1, S2, S4, S5 all require a call up, and S1/S4 additionally require the tap grant
above. Protocol is in the next section.

| # | Question | Status |
|---|---|---|
| S0 | Do taps work / permission | **PASSED** — bit-exact; granted only via `open -a` |
| S1 | Duck depth in dB | **PASSED** — exactly **−30.00 dB**, flat and repeatable |
| S2 | Can `FaceTime.app` be tapped | **PASSED** — creation OK, muted and unmuted |
| S3 | Does `.muted` silence the source | **PASSED** — silenced, and tap keeps full level |
| S4 | Is our own output ducked too | **PASSED** — yes, same 30 dB; compensation required |
| S5 | Device volume settable while ducked | **PASSED** — +24.6 dB of headroom available |
| S6 | Do VoiceProcessingIO clients escape the duck | **PARKED** — mic input hangs, environmental |
| S7 | Which process signals an active call | **OPEN** — not FaceTime.app; needs one call |

Phase 0 has answered enough to build. The one remaining blocker for `CallDetector`
is S7, and it needs a single call with the current build:

```
cd ~/Desktop/Unduck/tools && ./run-as-app.sh duck --match Spotify --seconds 90
```

The `mic-holders` column names every process holding audio input each second;
whichever appears when the call connects is the signal `CallDetector` watches.
