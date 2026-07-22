# Unduck

Keep your music audible during FaceTime calls on macOS.

FaceTime attenuates every other audio client by 30 dB and there is no setting to
turn it off. Unduck detects the call, takes over the mix, and puts the 30 dB back —
then gives you separate faders for call voice and music.

macOS 14.4+ · Apple Silicon and Intel · no kernel extension, no driver

## Install

Needs a Swift 6 toolchain — Xcode 16 or `xcode-select --install`. Check with
`swift --version`.

```bash
git clone https://github.com/alecswang/unduck.git
cd unduck
./make-cert.sh    # one-time signing identity
./install.sh      # build, install to /Applications, launch
```

Then, once:

1. Approve the audio-capture prompt on first launch.
2. **System Settings → Privacy & Security → Accessibility** → add
   `/Applications/Unduck.app`, turn it on. macOS does not let an app request this
   one from a dialog. It is what un-pauses your media.
3. Quit and reopen Unduck so it re-reads that grant.
4. Tick **Start Unduck at login**.

Done. It engages when a call connects and restores your volume when you hang up.

## Using it

The window has three faders — **Call voice**, **Music**, **Master** — live during a
call. **Duck compensation** sets how much of the 30 dB to restore; 30 is correct for
built-in speakers. **Restore everything** is the panic button.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Music silent during a call, faders do nothing | Audio capture denied. A denied tap returns zeros rather than failing, so check the status line in the window. |
| Media never un-pauses | Accessibility not granted, or granted to a previous install. Remove the entry, re-add `/Applications/Unduck.app`, relaunch. |
| Music still quiet during a call | Your output device ducks by a different amount. Move **Duck compensation**. |
| Permissions reset on every rebuild | `make-cert.sh` never ran and the build fell back to ad-hoc signing. `./build.sh` warns when this happens. |

Log: `~/Library/Application Support/Unduck/unduck.log` — every engage, every volume
change with before/after scalars, per-bus levels once a second while engaged.

## Known limitations

- **Media apps pause themselves** when a call starts. Unduck un-pauses them with a
  blind play/pause key aimed at whatever owns Now Playing, so with two apps playing
  it can resume the wrong one.
- **Duck depth is calibrated for built-in speakers.** Other devices may differ; the
  slider is the manual correction until per-device calibration exists.
- **Sending your music into the call** — so the far side hears it — is not
  implemented. It needs a virtual input device and Mic Mode set to Wide Spectrum.
- Not sandboxed, so not App Store distributable: process taps and TCC state reads
  require it.

## Docs

- [Architecture](docs/architecture.md) — how it works, file map, and the
  non-obvious behaviour that is easy to reintroduce
- [Measurements](docs/measurements.md) — every constant in this code, how it was
  measured, and the theories that turned out wrong
- [`tools/`](tools/README.md) — the probe that produced those numbers, for
  re-measuring on different hardware

## License

[MIT](LICENSE)
