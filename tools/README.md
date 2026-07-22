# probe

The measurement CLI behind every number in Unduck. Kept because the constants in the
app — the 30 dB duck, `avconferenced`, "a muted tap keeps full level" — are hardware
and OS-version specific. On different hardware they must be re-measured, not assumed.

```bash
./build.sh
./run-as-app.sh duck --match Spotify --seconds 90
```

Always launch via `run-as-app.sh` (i.e. `open -a`). Run the binary straight from a
shell and the responsible process for TCC becomes the terminal, which has no
audio-capture usage description, so `tccd` refuses to prompt and every tap silently
returns zeros.

## Commands

| Command | Answers |
|---|---|
| `list` | Which processes hold audio input/output right now |
| `perm [--request]` | Audio-capture TCC state: granted / denied / undetermined |
| `selftest` | Do taps work at all? Plays a known tone and taps itself |
| `duck [--vpio] [--match X]` | The main one: reference tone + target + global bus, with call detection |
| `tap --match X [--mute]` | One process, with optional source muting |
| `devices` | All audio devices, for spotting leaked aggregates |
| `devvol [--set N]` | Read/set output device volume, auto-restores |
| `micprobe` | Isolates the `AVAudioEngine.inputNode` hang |

`duck` is the one to reach for. It plays its own steady −20 dBFS sine — a source
that cannot decide to pause, unlike Spotify — taps that plus a target app plus the
global mix, and prints every process holding the mic each second. Start a call while
it runs and the duck shows up as a clean step in `tone-pk`.

Reading a run:

```
 t | tone-rms tone-pk      n | tgt-rms tgt-pk out | glob-rms glob-pk | vol | mic-holders
22s|  -23.01  -20.00   96256 |  -28.79 -18.45 yes |  -21.82  -13.39 | 0.25 | CoreSpeech
24s|  -53.01  -50.00   95232 |    -inf   -inf  NO |  -53.01  -50.00 | 0.25 | avconferenced
```

Three facts in two lines: the duck is exactly 30 dB, it engages when
`avconferenced` takes the mic, and the target app stopped rendering on its own
(`out` → `NO`) rather than being silenced by the system.
