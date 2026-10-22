# Release notes

[Overview](../README.md) · [Usage guide](USAGE.md) · [Developer guide](../DEVELOPMENT.md)

## 0.2.0 (2026-10-22)

### Added

- **Loop playback:** press **L** to repeat the selected take until **S** or
  **Esc** stops it. The countdown runs once, the screen shows elapsed time, and
  timing samples do not accumulate indefinitely. **P** still plays once.
- **Recording browser:** use **Up/Down** to select from saved takes, newest
  first. Two recordings are visible at a time, with **>** marking the selection.
  Playback preserves the selected take; a new saved recording becomes selected.
- **Confirmed deletion:** **Backspace/Delete** opens **"Let this take go?"** for
  the selected recording. **Y** deletes that file permanently; **N** or **Esc**
  keeps it. Other takes and verification reports are untouched.

### Fixed

- Resizing the terminal clears the old layout and repaints the visible view,
  including when only the terminal height changes. Selection and active
  playback survive shrinking and expanding the window.
- Arrow and function-key escape sequences are decoded as keys rather than
  leaking their bytes into menu shortcuts.

### Compatibility and limits

- Still requires macOS 15+ and Swift 6+ for a source build. No new dependencies,
  permission requirements, or recording-format changes.
- Existing recordings and direct-command `play --loop N` behavior are preserved.
- Replay still sends real input at recorded screen coordinates. Looping does
  not restore the target app's state between passes.
- Controlled stops attempt held-button and scroll cleanup. Crashes, forced
  termination, and revoked permissions cannot guarantee cleanup.
- Automated and synthetic terminal checks do not certify physical input fidelity
  or identical target-app behavior.

### Upgrade

```sh
brew update
brew upgrade Just-Jan/cursor-replay-cli/cursor-replay
cursor-replay --version
```

The version should report `cursor-replay 0.2.0`. Quit old running instances and
reopen the app after upgrading. Your saved recordings remain in place.

For a local source checkout, rebuild and run:

```sh
./scripts/build.sh
./bin/cursor-replay
```
