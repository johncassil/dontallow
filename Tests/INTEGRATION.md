# Manual integration test

Needs a Mac with `dontallow` installed and Accessibility granted. This provokes a genuine Local Network prompt from a throwaway app and checks that the agent dismisses it.

1. Build a tiny app that sends one multicast UDP packet (macOS prompts on the first local-network attempt by a new executable). Any fresh ad-hoc signed `.app` with an `NSLocalNetworkUsageDescription` in its Info.plist will do. The executable must be newly compiled; macOS silently reuses its decision for an executable it has seen before, even under a new bundle id or path.
2. `tail -f ~/Library/Logs/dontallow.log` in one terminal.
3. `open ThrowawayApp.app` in another.
4. Expect the prompt to flash and the log to show `dismissed Local Network prompt for ThrowawayApp` within about a second, plus a notification.
5. `dontallow pause 5m`, repeat with a freshly compiled executable, and expect `left prompt for ... alone (paused)` with the dialog still on screen. `dontallow resume` re-evaluates it.
6. Afterwards, delete the throwaway rows from System Settings > Privacy & Security > Local Network if you like; they're inert.
