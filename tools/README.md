# tools/

Standalone proof-of-concept programs, kept as real reference code (not
throwaway) since each one resolved a genuine open question with real
findings worth preserving.

- **`window_select_capture_poc.c`** — issue #2 (and #4)'s PoC: click-to-
  select a window (Quartz event tap + Accessibility API window
  enumeration) and capture a real frame from it (direct framebuffer read,
  since `CGWindowListCreateImage` doesn't exist on Tiger); also runs a
  real ~90-second integrated capture+disk-write test once a window is
  selected (issue #4). See the file's own header comment for the full set
  of real findings (`AXAPIEnabled()` flakiness, synthetic-vs-real click
  visibility, measured capture throughput and why it's bandwidth-capped,
  real disk-buffering throughput vs. why RAM buffering was ruled out).
  Build:
  ```
  gcc-7 -isysroot /Developer/SDKs/MacOSX10.4u.sdk -mmacosx-version-min=10.4 \
    -framework ApplicationServices -framework Carbon \
    -o window_select_capture_poc window_select_capture_poc.c
  ```
  Must be run as a real double-clicked `.app` (see
  `WindowSelectTest-Info.plist` for a minimal bundle `Info.plist` — set
  `CFBundleExecutable` to the compiled binary's name and drop both into a
  `WindowSelectTest.app/Contents/{MacOS,}` layout), not launched via SSH —
  see the file's own comment for why. Logs to `/tmp/window_select_test.log`
  so results can still be read back over SSH after a physical launch.

- **`synthclick.c`** — minimal synthetic-mouse-click injector
  (`CGEventCreateMouseEvent`/`CGEventPost`), built while debugging the
  Universal Access checkbox during issue #2. Confirmed real synthetic
  clicks are NOT seen by a listen-only `CGEventTap` on this OS (see the
  PoC's own header comment) — kept as a reference utility, not because it
  solved that specific problem.

- **`menubar_hotkey_poc.m`** — issue #3's PoC: a real background/menu-bar-
  only app (`LSUIElement`, no Dock icon) with a live `NSStatusItem` and two
  real global hotkeys (`RegisterEventHotKey`) that fire while a different
  app has keyboard focus. See the file's own header comment for a real,
  worth-remembering finding: F-key hotkeys (F1/F2) registered without error
  but never actually fired on this desktop G4 — switched to ordinary
  alphanumeric keys (Cmd+Opt+Shift+9/0), which worked reliably. Build:
  ```
  gcc-7 -isysroot /Developer/SDKs/MacOSX10.4u.sdk -mmacosx-version-min=10.4 \
    -framework Cocoa -framework Carbon \
    -o menubar_hotkey_poc menubar_hotkey_poc.m
  ```
  Same real-`.app`-launch requirement as the other PoCs here (see
  `MenuBarHotkeyTest-Info.plist`). Logs to `/tmp/menubar_hotkey_test.log`.
