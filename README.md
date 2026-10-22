# CmdTab

A window-level replacement for the macOS ⌘⇥ app switcher. One flat, scannable list of
`App Name: Window Title` — no icons, no thumbnails, no animations.

## Behaviour

| Key | Action |
| --- | --- |
| ⌘⇥ | Open the list (alphabetical: first row selected; MRU: second row, like the system switcher) |
| ⌘⇥ again / ⇥ | Move down |
| ⇧⌘⇥ / ⇧⇥ | Move up |
| ↑ / ↓ | Move |
| type | Filter the list live |
| ⌫ | Delete a character of the query |
| ⏎ / Enter | Open the selected window and close the panel |
| esc | Dismiss without switching |
| click a row | Open that window |

The panel is **sticky**: it stays open after you let go of ⌘, so typing a search term
is a normal keypress and not a ⌘-shortcut. It closes on Enter, Escape, a click
outside the panel, or after 15 seconds of no keyboard activity.
Sort order is **alphabetical by app, then window title** (the default), or front-to-back
window stacking (most recently used first) — switchable from the menu bar icon.

## Why Swift

The hot path is a `CGEventTap` at the session level, which is the only place early
enough to swallow ⌘⇥ before `Dock.app` sees it. Everything after that — enumerating
windows, drawing the panel — happens on the same main run loop with no IPC except the
Accessibility queries, so the panel appears in one frame.

Window titles come from the Accessibility API rather than `CGWindowListCopyWindowInfo`,
so **Screen Recording permission is not required**. Only Accessibility is.

## Requirements

macOS 13 or later, plus the Xcode command line tools (Swift 5.9+). No third-party
dependencies and no SwiftPM packages — `swift build` compiles the whole thing.

## Build & install

```sh
make sign-setup     # once: creates the local "CmdTab Local Signing" identity
make app-bundle     # -> ./CmdTab.app
make install        # -> ~/Applications/CmdTab.app
open ~/Applications/CmdTab.app
```

`make install` targets `~/Applications` so it needs no admin rights. A system-wide
install works too: `cp -R CmdTab.app /Applications/`.

### Why the signing identity matters

The app signs itself with a **stable self-signed identity**, not ad-hoc. macOS keys the
Accessibility grant to the code-signing identity, and an ad-hoc signature changes hash on
every build — which silently voids the grant and makes the app ask for permission again
after each rebuild. With the identity in place the designated requirement is

```
identifier "com.faucher.cmdtab" and certificate leaf = H"…"
```

which stays constant across rebuilds, so you grant access once. `make sign-setup` puts the
identity in the login keychain (generated key material lives in
`~/Library/Application Support/CmdTab/signing`); it is idempotent.

The app appears in System Settings → Privacy & Security → Accessibility as
**CmdTab Local**, deliberately distinct from any other app named CmdTab.

On first launch it asks for **Accessibility** access
(System Settings → Privacy & Security → Accessibility). Toggle CmdTab on; it starts
working within ~2 seconds, no relaunch needed.

`Start at Login` is in the menu bar icon's menu.

### Rebuilding

Rebuilds are safe now that the identity is stable — `make install` replaces the app and
the Accessibility grant carries over because macOS matches on the signing identity, not
the binary hash.

If you ever lose the identity (new keychain, new machine), `make sign-setup` recreates
it — but a *regenerated* certificate is a different identity, so you would have to grant
access once more. `make reset-permissions` clears the stale rows.

## Diagnostics

```sh
tail -f ~/Library/Logs/CmdTab.log   # launch, trust state, event-tap state
./.build/release/CmdTab --dump      # print the window list + enumeration time
open ./CmdTab.app --args --demo     # render the panel without the hotkey
open ./CmdTab.app --args --demo --text=term   # ...with a pre-typed query
open ./CmdTab.app --args --logkeys  # log every keypress the tap sees (noisy)
```

By default the log records ⌘⇥ presses and any key pressed while the panel is open —
enough to tell whether the tap is alive, without logging ordinary typing.

The menu bar icon's menu shows a live `Accessibility: On/Off` line and has
**Open Log**. A slashed icon means the event tap is not running.

Note that running `--dump` from a terminal reports the *terminal's* permission, not the
app's — macOS attributes TCC checks to the responsible parent process. Trust the log
written by the app itself.

## Layout

```
Sources/CmdTab/
  main.swift        entry point + --dump
  EventTap.swift    session-level CGEventTap; returns nil to swallow ⌘⇥
  AX.swift          Accessibility helpers (window list, raise/focus, app activate)
  WindowList.swift  CGWindowList (order) x AX (titles) merge + background cache
  Switcher.swift    state machine, filtering, commit
  ListView.swift    hand-drawn text list
  AppDelegate.swift permissions, status item, login item
```

## Known limits

- Windows on other Spaces and minimised windows are not listed (on-screen only).
- Releasing ⌘ does not commit. If you want the classic hold-⌘ and release-to-switch
  behaviour back, add a `flagsChanged` case in `EventTap` that calls `commit()`.
- **Secure Keyboard Entry kills it, by design.** When any app enables secure input,
  macOS disables every keyboard event tap process-wide, so ⌘⇥ falls through to the
  system switcher. Terminal enables it whenever *Secure Keyboard Entry* is ticked in
  its menu (check with `ioreg -l -w 0 | grep -i kCGSSessionSecureInputPID`). Turn it
  off in Terminal, or accept that the switcher is inactive while Terminal has focus.
  No event-tap app (AltTab included) can work around this.
- A tap can also be silently disabled by the system (secure input ending, a stuck
  callback). A 3-second health check re-enables it and logs when it does.
