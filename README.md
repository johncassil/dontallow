# dontallow

Auto-dismisses the macOS prompt:

> **Allow "Google Chrome" to find devices on local networks?**
> This will allow the app to discover, connect to, and collect data from devices on your networks.

It presses **Don't Allow** for you, within a fraction of a second, every time. Zero CPU while idle. Survives reboots. One Swift file, no dependencies.

## Why this exists

macOS (Sequoia and later) shows this prompt the first time an app touches the local network. The decision is supposed to be remembered. For many apps it isn't, so the prompt comes back on every launch, often for apps you aren't even using:

- **Chromium browsers** (Chrome, Brave, Edge, Island, Arc) copy their own app bundle into a random temp folder at launch so the code signature survives in-place updates. macOS keys the Local Network decision to that random path, so the next launch looks like a brand-new app. Your Privacy settings fill up with duplicate "Google Chrome.app" rows that no longer point at anything.
- **Apps with versioned install paths** (anything that installs into `.../versions/1.2.3/`) get a new row per update.
- **Misattributed prompts.** macOS pins the dialog on whichever app it decides is "responsible", so you'll see prompts for apps that aren't running.
- Nothing on a typical Mac needs this permission except a printer or scanner utility, a media server, or a LAN-discovery tool, and those you answer once and they're done.

There is no supported way to prune the list, no MDM payload to pre-deny the permission, and `tccutil reset` doesn't cover it. So: a small agent that answers "no" for you.

## Install

```sh
brew install johncassil/tap/dontallow   # or: make && make install
dontallow install
```

`dontallow install` writes a per-user launchd agent and starts it. macOS will ask you to grant the binary **Accessibility** access (System Settings > Privacy & Security > Accessibility). That permission is what lets it press the button. The agent attaches on its own within ten seconds of the grant.

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

## Notes

- Accessibility grants are keyed to the binary's code signature. If you rebuild, remove the `dontallow` row in Accessibility settings and add it again. Homebrew users build once and don't hit this.
- Builds with Apple's Command Line Tools alone; Xcode is not required.
- macOS 13 or later.

## License

MIT
