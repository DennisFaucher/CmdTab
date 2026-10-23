# AGENTS.md

Guidance for agents working in this repo. Read this before changing anything; the design
has a few non-obvious constraints that are easy to "fix" into a regression.

## What this is

CmdTab is a menu-bar-only (LSUIElement) macOS app that replaces ⌘⇥ with a flat,
filterable list of `App Name: Window Title` rows. No icons, no thumbnails, no animations.

- No third-party dependencies, no SwiftPM targets beyond the one executable.
- macOS 13+, Swift 5.9+.
- Everything is AppKit/ApplicationServices C APIs. There is no SwiftUI, no storyboards,
  no Xcode project — the `.app` is assembled by the Makefile.

## Build, run, verify

```sh
swift build -c release          # or: make build
make run                        # debug run from .build
make app-bundle                 # -> ./CmdTab.app (signs it)
make install                    # -> ~/Applications/CmdTab.app
make dist                       # universal arm64+x86_64 zip in dist/
make shot                       # regenerate the README screenshots
```

There is **no unit-test framework**. The only automated check is the ordering contract:

```sh
swift build -c release && ./.build/release/CmdTab --history-test
```

It prints `PASS`/`FAIL` per check and exits non-zero on failure. Run it after touching
`AppHistory.swift`, the `recent` sort path in `WindowList.swift`,
`Switcher.initialSelection()`, or the 1–9 shortcut map in `Switcher.swift`. If you change
the MRU rules or the numbering, add a case to `HistoryTest.swift` rather than testing by
hand.

Useful diagnostics (all documented in `README.md`):

```sh
./.build/release/CmdTab --dump           # window list + enumeration time
./.build/release/CmdTab --fake --out=x.png
open ./CmdTab.app --args --demo          # show the panel without the hotkey
open ./CmdTab.app --args --demo --text=term
tail -f ~/Library/Logs/CmdTab.log
```

`--dump` run from a terminal reports the *terminal's* TCC status, not the app's. Trust the
log the app writes, not the terminal.

## Architecture

One process, one main run loop, no IPC except Accessibility queries.

```
⌘⇥ ── EventTap (session CGEventTap, head insert) ── AppDelegate.wireTap
        └─ Switcher.handleKeyDown ── show()
             └─ WindowCache.refreshBlocking
                  └─ WindowList.current
                       ├─ CGWindowListCopyWindowInfo  → z-order + window rects (no permission)
                       └─ AX.windows(for: pid)        → titles + AXUIElement (needs Accessibility)
             └─ ListView.draw
   ⏎ ── Switcher.commit ── AppHistory.record + SwitchWindow.focus ── AX.focus
```

| File | Responsibility |
| --- | --- |
| `main.swift` | Entry point. Handles `--dump`, `--dump-history`, `--fake`, `--history-test`, then the single-instance guard, then `app.run()`. |
| `EventTap.swift` | Session-level `CGEventTap`. Returning `nil` from the callback swallows the event. Also handles `tapDisabledByTimeout`/`ByUserInput` re-enable. |
| `AX.swift` | Thin, allocation-light wrappers over the Accessibility C API; app/hung-app messaging timeout. |
| `WindowList.swift` | `SwitchWindow`, `SortMode`, the CGWindowList × AX merge, and `WindowCache` (the warm snapshot). |
| `AppHistory.swift` | Real per-app MRU order, observed via `NSWorkspace.didActivateApplicationNotification`. |
| `Switcher.swift` | The panel (`SwitcherPanel`), state machine, key handling (including the 1–9 row shortcuts), filtering/scoring, commit. Also holds `Preferences.sortMode`. |
| `ListView.swift` | Hand-drawn `NSView`. Sizing, the 1–9 number gutter, rows, selection pill, hint footer, row click hit-testing. |
| `AppDelegate.swift` | Status item + menu, permission prompting/retry, tap health check, login item, cache warming, `--selftest`. |
| `FakeShot.swift` | `--fake`: renders the panel from fixture titles to a PNG. |
| `HistoryTest.swift` | `--history-test`: the ordering-contract smoke test. |
| `Log.swift` | Append-only `~/Library/Logs/CmdTab.log`, rotated at 256 KB. |

## Invariants — do not break these

**Sort the stack before the panel is frontmost.** `Switcher.show()` calls
`WindowCache.refreshBlocking` *before* `panel.orderFrontRegardless()`. The panel is a
window, so once it is up it tops the front-to-back z-order. Enumerating after that ranks
the previously-focused window wrongly and quietly falsifies "row 1 is where you came
from". Do not move enumeration after presentation, and do not "optimise" the hot path by
switching `show()` to `refreshAsync`.

**The panel must never become key.** `SwitcherPanel.canBecomeKey`/`canBecomeMain` return
`false` and it is a `.nonactivatingPanel`. All keystrokes arrive through the event tap and
are dispatched manually by `Switcher.handleKeyDown`. Making it key breaks the
non-activating behaviour that lets it float over full-screen apps.

**The panel is sticky, and ⌘ release does not commit.** It stays open after ⌘ is let go so
typing filters normally; it closes on ⏎, esc, click-outside, or 15 s idle. Adding
`flagsChanged`-commits is a deliberate feature change, not a bug fix — see "Known limits"
in the README.

**`WindowList.current` must never require Screen Recording.** Window *rects* come from
`CGWindowListCopyWindowInfo` (permission-free) and *titles* from Accessibility. Never read
`kCGWindowName` from the CGWindow dictionary: that is what forces the Screen Recording
prompt.

**`--fake` must not touch the system.** It builds rows from the hard-coded `samples` array
in `FakeShot.swift` and exits before the instance guard. No window enumeration, no AX, no
tap. This is what makes it safe to regenerate the README screenshots on a machine with
real, private windows open. Keep it that way — no "make the screenshot realistic by
reading the current windows" changes.

**Per-app history, not per-window.** `AppHistory` records `pid` only and caps at 40
entries. Window-level focus tracking was rejected as too noisy (needs AX on every app,
fires constantly while typing between panes). Unknown pids sort after all known ones and
keep their incoming stacking order.

**Row 0 is "where I am", row 1 is "where I came from".** In `.recent` mode
`Switcher.initialSelection()` returns `1` so the first ⏎ bounces you back. In
`.alphabetical` mode it returns `0` (there is no "previous"). `HistoryTest` asserts this.

**1–9 are shortcuts, not filter characters.** `Switcher.handleKeyDown` maps the digit key
codes to a zero-based row and calls `commit()`, so a number closes the panel and focuses
that window. Consequences to preserve:

- The map is keyed by **physical key code** (number row and numeric keypad both), not by
  the character produced, so the shortcut does not move on non-US layouts. Add new codes
  to `shortcutKeyCodes`, not to the `characters` path.
- Numbers are **positional**: they follow a row's rank in `shown`, never a visible slot,
  so the same digit means the same row after filtering or scrolling. `ListView` draws the
  number only for `index < 9`; the gutter is reserved for every row so app names stay on
  one left edge.
- A digit with no matching row is swallowed and does nothing. Do not fall through to the
  filter, and do not let a digit reach the `default:` branch that appends to `query`.
- Filtering first then pressing a digit ("doc", then `2`) is an intended flow; do not gate
  the shortcut on `query.isEmpty`.

**`ListView` sizing must include `numberGutter`.** `desiredSize()` adds it to the measured
text width; dropping it clips the number column or shifts every row.

**`commit()` records history explicitly.** Switching to a window of an already-active app
does not always fire `didActivateApplicationNotification`, so `commit()` calls
`AppHistory.record(target.pid)` itself before focusing.

**Threading.** `WindowCache.windows`, `WindowCache.current`, and `AppHistory.order` are
main-thread-only by contract (there is no lock). Cross-process enumeration belongs on
`WindowCache.queue` inside `refreshAsync` only. `refreshBlocking` deliberately runs on the
main thread; it costs ~10–30 ms warm and that is inside one frame.

**Keep the single-instance guard.** Two copies would install two event taps and fight over
⌘⇥. Diagnostic modes are checked *before* the guard so they work while the app is running.

**Do not switch to an ad-hoc signature.** macOS keys the Accessibility grant to the
code-signing identity. Ad-hoc hashes change on every build, silently voiding the grant.
`make app-bundle` falls back to ad-hoc with a warning when `CmdTab Local Signing` is
missing; that fallback is a degraded mode, not the intended one.

## Bumping the version

Version lives in three places; update all of them together:

1. `Makefile` → `VERSION :=`
2. `Resources/Info.plist` → `CFBundleShortVersionString`
3. `README.md` → the `make dist` example path (`dist/CmdTab-<version>.zip`)

`CFBundleIdentifier` is `com.faucher.cmdtab` and is referenced by the Makefile's
`codesign --identifier` and `make reset-permissions`; changing it invalidates existing
signing and TCC state.

## Style

- Follow the surrounding code: 4-space indent, ~100 column soft wrap, `// MARK: -` section
  dividers in larger types, `final class` for reference types, `enum` as a namespace for
  stateless helpers.
- Comments explain *why* (a constraint, a race, a rejected alternative), not *what*. This
  codebase is heavily commented in that style; match it. Do not add narration like
  "increment the counter".
- Force-unwrapping is used only where an invariant guarantees non-nil (e.g.
  `value as! AXValue` after a `CFGetTypeID` check). Do not add new ones without the same
  guard.
- New user-facing strings are English, sentence case; UI labels stay short enough for the
  single-line footer in `ListView`.
- Run `swift build -c release` and `--history-test` before declaring work done. Warnings
  are not acceptable; the tree builds clean today.
- Do not commit `.build/`, `CmdTab.app/`, `dist/`, or `.DS_Store` (already in
  `.gitignore`).

## Known rough edges

- Digits are spent on the 1–9 jump, so a filter query cannot contain one. That is the
  deliberate tradeoff; if digit filtering ever becomes a requirement, hide the number
  gutter at the same time the shortcut is gated — never leave visible numbers that are not
  live.
- `WindowCache.refreshAsync`'s doc comment claims it is "the hot path"; it is not — `show()`
  uses the blocking path deliberately (see invariants). Treat the comment as stale.
- `AppDelegate.showPermissionAlert()` has a statement on the closing-brace line; normalise
  it if you touch that function.
- Enumeration only sees on-screen, unminimised windows on the current Space. That is
  intentional; do not add `.optionAll` without deciding how off-Space windows should rank.
- Secure Keyboard Entry disabling the tap is an OS behaviour with no workaround, not a bug
  to fix in this repo.
