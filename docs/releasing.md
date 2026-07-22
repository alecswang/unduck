# Releasing

```bash
./make-dmg.sh          # -> build/Unduck-<version>.dmg
```

The script picks the best signing identity on the machine and tells you which tier
it used. The tier is the whole story, because it decides what a stranger sees when
they double-click the download.

## The three tiers

| Tier | Requires | First launch on someone else's Mac |
|---|---|---|
| Notarized Developer ID | Apple Developer Program, $99/yr | Opens. No warning. |
| Developer ID, un-notarized | Same membership | Blocked: "Apple could not verify…" |
| Self-signed or ad-hoc | Nothing | Blocked: same message |

There is no free path to the first row, and the gap between rows one and two is not
cosmetic. On macOS 15 an unnotarized app cannot be opened by right-click → Open
any more; the user has to go to **System Settings → Privacy & Security**, scroll to
a message about the blocked app, and press **Open Anyway**. Most people read
"Apple could not verify this app is free from malware" and delete it, which is the
correct instinct and exactly what that screen is designed to produce.

So: distributing to anyone who is not already a developer effectively requires the
membership. Everything else in this repo works without it.

## Setting up the notarized path

Once, after joining the Apple Developer Program:

1. **Create a Developer ID Application certificate.** Xcode → Settings → Accounts →
   Manage Certificates → + → Developer ID Application. It lands in your login
   keychain and `make-dmg.sh` finds it automatically.

2. **Create an app-specific password** at <https://appleid.apple.com> → Sign-In and
   Security → App-Specific Passwords. Notarization will not accept your Apple ID
   password, and this keeps your real credentials out of the keychain profile.

3. **Store the notary credentials** under the profile name the script looks for:

   ```bash
   xcrun notarytool store-credentials unduck-notary \
     --apple-id "you@example.com" \
     --team-id "YOURTEAMID" \
     --password "abcd-efgh-ijkl-mnop"
   ```

   Team ID is in the top right of <https://developer.apple.com/account>.

Then `./make-dmg.sh` signs, submits, waits, staples, and packages in one run. It
adds a few minutes for Apple's service to respond.

Stapling matters: it writes the notarization ticket into the app and the DMG so they
validate without a network round-trip. Skip it and someone opening the app offline —
or during an Apple outage — sees the unverified-developer block anyway.

## Publishing

```bash
gh release create v0.1 build/Unduck-0.1.dmg \
  --title "Unduck 0.1" --notes "…"
```

Bump `CFBundleShortVersionString` in `Info.plist` first; `make-dmg.sh` takes the
version from there and it is what the DMG filename shows.

## What still cannot be automated

**Accessibility.** macOS does not let an app grant itself this, and does not let an
app add itself to the list. The user must open the pane and flip a switch. Unduck's
setup panel opens the right pane and explains why, which is as far as it can go.
This is deliberate on Apple's part — an app that could grant itself Accessibility
could silently drive every other app on the machine.

**Audio capture** can prompt, so the setup panel triggers it directly.

Because Accessibility only powers auto-resume, Unduck treats it as optional: setup
reads as complete without it, and the app does its main job regardless.
