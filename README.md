# Unduck

**Keep your music audible during FaceTime calls on macOS.**

Start a FaceTime call and everything else drops to a whisper. That is macOS turning
every other app down by 30 dB, and there is no setting to stop it. Unduck notices the
call, takes over the audio, and puts the 30 dB back, then gives you a **Music**
fader and a **Call voice** fader so you can set the balance yourself.

macOS 14.4 or later. No driver, no kernel extension.

## Install

**Read this first.** If you download the DMG and double-click it, macOS blocks it and
says "Apple could not verify Unduck-0.1.dmg is free of malware." That is expected.
Unduck is signed, but not notarized by Apple, and notarization requires a paid
developer membership. macOS blocks anything without it.

The block happens twice, once on the disk image and again on the app, because the
quarantine flag is copied along when you drag the app out. One command clears both:

```bash
xattr -d com.apple.quarantine ~/Downloads/Unduck-0.1.dmg
```

Then:

1. Download `Unduck-0.1.dmg` from [Releases](https://github.com/alecswang/unduck/releases).
2. Run the command above.
3. Open the DMG and drag Unduck to Applications.
4. Open Unduck and follow the setup checklist in the window.

The checklist asks for two things. **Audio capture**, so Unduck can hear other apps
in order to rebalance them. Press Allow when macOS asks. And **Accessibility**, used
only to un-pause the music your call interrupted. That one is optional, and skipping
it costs nothing else. macOS does not let an app request Accessibility, so Unduck
opens the right settings pane for you.

Then turn on **Start Unduck at login** and forget about it.

<details>
<summary>If you would rather not run a terminal command</summary>

You can click through it instead, but macOS asks twice.

1. Double-click the DMG. It gets blocked.
2. Open **System Settings, Privacy and Security**, scroll to the Security section,
   and press **Open Anyway** next to the message about the DMG.
3. Double-click the DMG again. It mounts.
4. Drag Unduck to Applications.
5. Open Unduck. It gets blocked, this time as the app.
6. Return to Privacy and Security and press **Open Anyway** again.

After that it launches normally and never asks again.
</details>

Building from source avoids all of this, because the app is then signed on your own
machine. See [Build it yourself](#build-it-yourself).

## Using it

Unduck engages by itself when a call connects and restores your volume when you hang
up. You only need the window if you want to change the balance.

| Control | What it does |
|---|---|
| **Music**, **Call voice**, **Master** | Live balance during a call |
| **Duck compensation** | How much of the 30 dB to restore. 30 is right for built-in speakers; raise or lower it if your headphones or interface sound off. |
| **Restore everything** | Panic button. Puts your volume back immediately. |

Your volume is always restored on hang-up, on quit, and even after a crash. Unduck
saves it to disk before touching it.

## Known limitations

- **Music apps pause themselves** when a call starts. Unduck un-pauses them, but it
  does so with a blind play/pause key, so with two apps playing it can resume the
  wrong one.
- **Duck depth is calibrated for built-in speakers.** Other output devices may duck
  by a different amount; the Duck compensation slider is the manual correction.
- **The other person cannot hear your music.** Sending audio into the call needs a
  virtual input device and is not implemented.

## Build it yourself

```bash
git clone https://github.com/alecswang/unduck.git
cd unduck
./make-cert.sh    # one-time local signing identity
./install.sh      # build, install to /Applications, launch
```

Needs a Swift 6 toolchain: Xcode 16, or `xcode-select --install`.

Building locally avoids the Gatekeeper warning, because the app is signed by a
certificate created on your own machine.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Music is silent during a call and the faders do nothing | Audio capture was denied. A denied capture returns silence rather than an error, so check the status line in the window. |
| Music never un-pauses | Accessibility is off, or was granted to an older copy of the app. Remove the entry, re-add Unduck, relaunch. |
| Music is still too quiet during a call | Your output device ducks by a different amount. Move **Duck compensation**. |

Log: `~/Library/Application Support/Unduck/unduck.log`

## Docs

- [Architecture](docs/architecture.md), how it works, and the non-obvious macOS
  behaviour behind each design choice
- [Measurements](docs/measurements.md), every constant in this code, how it was
  measured, and the theories that turned out wrong
- [Releasing](docs/releasing.md), signing, notarization, and what cannot be automated
- [`tools/`](tools/README.md), the probe that produced those numbers

## License

[MIT](LICENSE)
