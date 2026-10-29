# dontallow

Auto-dismisses the macOS prompt:

> **Allow "Google Chrome" to find devices on local networks?**
> This will allow the app to discover, connect to, and collect data from devices on your networks.

It presses **Don't Allow** for you, within a fraction of a second, every time. Zero CPU while idle. Survives reboots. Two short Swift files, no dependencies.

## Why this exists

macOS (Sequoia and later) shows this prompt the first time an app touches the local network. The decision is supposed to be remembered. For many apps it isn't, so the prompt comes back on every launch, often for apps you aren't even using:

- **Chromium browsers** (Chrome, Brave, Edge, Island, Arc) copy their own app bundle into a random temp folder at launch so the code signature survives in-place updates. macOS keys the Local Network decision to that random path, so the next launch looks like a brand-new app. Your Privacy settings fill up with duplicate "Google Chrome.app" rows that no longer point at anything.
- **Apps with versioned install paths** (anything that installs into `.../versions/1.2.3/`) get a new row per update.
- **Misattributed prompts.** macOS pins the dialog on whichever app it decides is "responsible", so you'll see prompts for apps that aren't running.
- Some apps do legitimately use this permission: Chromecast and AirPlay discovery in browsers and media players, LAN multiplayer in games, printer and scanner utilities. If you use one of those features, answer Allow for that app (`dontallow pause 10m` while you do), and it's remembered as long as the app's path is stable. If you never use them, you never need to be asked.

There is no supported way to prune the list, no MDM payload to pre-deny the permission, and `tccutil reset` doesn't cover it. So: a small agent that answers "no" for you.

## Install

```sh
brew install johncassil/tap/dontallow   # or: make && make install
dontallow install
```

`dontallow install` writes a per-user launchd agent, starts it, opens System Settings > Privacy & Security > Accessibility, and prints the exact path to add if macOS doesn't prompt you. Accessibility is the permission that lets it press the button. It waits for the grant and confirms when the agent is active. `dontallow status` repeats the instructions any time the grant is missing.

## Use

| Command | What it does |
|---|---|
| `dontallow status` | Agent state, pause state, allowlist, recent dismissals |
| `dontallow pause [1h]` | Leave prompts alone for a while (`30m`, `2h`, `1d`, `forever`) |
| `dontallow resume` | Dismiss again |
| `dontallow rules` | Decode the system's Local Network rule store and show what each Privacy row really is, including orphans |
| `dontallow uninstall` | Stop and remove the agent |
| `dontallow run --dry-run` | Foreground, log what it would do, press nothing |

Each dismissal posts a notification naming the app and the `pause` command, so you never have to remember how to turn it off. Mute the notification in System Settings if you'd rather not see it.

### When an app really does need local network access

Three options, pick whichever fits:

- `dontallow pause 10m`, then launch the app and click Allow yourself.
- Add the app's name to `~/.config/dontallow/allowlist` (one per line, case-insensitive substring). Prompts for it are never touched.
- Flip the toggle in System Settings > Privacy & Security > Local Network. A dismissed prompt records a deny, which you can reverse there.

Set `~/.config/dontallow/grace` to a number of seconds if you want a window to click Allow before the agent does (default `0.25`).

## How it works

The prompt is a window owned by the system process `UserNotificationCenter`. `dontallow` registers an Accessibility observer for window creation on that process and sleeps until one fires. It reads the dialog text, confirms it's a local network prompt and not something else, checks pause and allowlist, and performs the Accessibility press action on the **Don't Allow** button. If the press is refused it falls back to a synthetic click at the button's location.

It never modifies system files, never disables protections, and never chooses Allow.

## Managed Macs

Local Network cannot be pre-set by MDM, but Accessibility can. For a fleet: build once, sign with a Developer ID, ship the binary plus a PPPC (Privacy Preferences Policy Control) profile granting Accessibility to its code requirement, and run `dontallow install` per user. No manual Settings step.

## After upgrading

macOS keys the Accessibility grant to the binary's code signature, and every build (including `brew upgrade`) produces a new one. After an upgrade run `dontallow status`. If it says the grant is missing, remove the `dontallow` row in Accessibility settings and add it back from the path it prints. The agent re-attaches on its own within ten seconds. A future release signed with a Developer ID will remove this step.

## Tests

```sh
make test
```

Unit tests cover the pure logic (dialog text parsing, duration and pause parsing, allowlist matching, launchd plist generation, and the Local Network rule decoder against a fixture archive). They build with plain `swiftc` and need no Xcode or SwiftPM. The end-to-end path (a real prompt, a real press) can only be checked on a Mac with Accessibility granted; the manual recipe is in `Tests/INTEGRATION.md`.

## Compatibility

- Builds with Apple's Command Line Tools alone. Xcode is not required.
- Apple Silicon and Intel: Homebrew compiles natively on each.
- macOS 13 or later to build; the prompt itself only exists on macOS 15 Sequoia and later.
- Tested so far: Intel, macOS 26.6. Reports from other versions welcome.
- English-localized macOS only for now. The matcher keys on the dialog text and the "Don't Allow" button title; localized strings are planned.

## License

MIT
