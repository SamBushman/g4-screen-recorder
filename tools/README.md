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

- **`raw_capture_cli.c`** — command-line-only variant of the capture half
  of `window_select_capture_poc.c`: captures a fixed screen rect
  (`x y w h seconds output.raw`) via the same `CGDisplayBaseAddress`
  technique, with no AX API / window click / Process Manager dependency.
  Confirmed this runs fine over plain SSH (unlike the AX-dependent PoCs
  above) since it never touches Carbon Process Manager or registers as a
  GUI app — useful for scripted testing (e.g. issue #5's encode pipeline)
  without needing a physical double-click + click. Writes the same
  headerless raw frame format as the other PoCs: a stream of `w*h*4`-byte
  frames, per-pixel byte order `[pad/alpha, R, G, B]`. Build:
  ```
  gcc-7 -isysroot /Developer/SDKs/MacOSX10.4u.sdk -mmacosx-version-min=10.4 \
    -framework ApplicationServices \
    -o raw_capture_cli raw_capture_cli.c
  ```

- **`encode_raw_to_h264.sh`** — issue #5's offline encode pass: takes a raw
  frame file in the format above (`input.raw width height fps output.mp4`)
  and encodes it via ffmpeg's `libx264` encoder. Confirmed this really is
  the same AltiVec x264 build verified in issue #1, not a separate copy
  (same `libx264.146.dylib`, same Tigerbrew `r2555` Cellar path, same real
  AltiVec instructions via `otool -tv`) — and confirmed live at runtime via
  ffmpeg's own `using cpu capabilities: Altivec` log line during a real
  encode, not just static disassembly. **The `fps` argument must be the
  real measured capture fps** (frames actually captured / real elapsed
  seconds), not an assumed 30 — issues #2/#4 already established real
  achieved capture fps varies with window size and is often well under 30;
  passing the wrong value produces a valid-looking .mp4 that plays back at
  the wrong real-world speed. Also crops to even width/height (libx264/
  yuv420p requires both even -- real window sizes aren't guaranteed even,
  hit this live with a real 1280x927 Godot window).

- **`g4recorder.m`** — the real integrated tool (issues #6/#7's actual
  product, not another isolated PoC): a menu-bar app combining click-to-
  select, global hotkey start/stop, background-thread capture-to-disk, and
  auto-triggered offline encode into one continuous flow. See the file's
  own header comment for the full flow and `G4Recorder-Info.plist` for the
  bundle Info.plist. Build:
  ```
  gcc-7 -std=gnu99 -isysroot /Developer/SDKs/MacOSX10.4u.sdk -mmacosx-version-min=10.4 \
    -framework Cocoa -framework Carbon -framework ApplicationServices -lpthread \
    -o g4recorder g4recorder.m
  ```
  **Real bug found and fixed here (2026-09-08):** the original click-to-
  window resolution (carried over from issue #2's PoC) enumerated every
  window of every running app and matched the first one whose AX-reported
  rect geometrically contained the click point — with no regard for real
  on-screen stacking order. When more than one window's bounds overlap the
  same point (common — e.g. a Finder window sitting behind a Godot debug
  window in roughly the same screen region), this can match the WRONG
  window entirely. Live symptom: a real recording showed a completely
  different window's real content than the one whose title got logged as
  the "match" — looked at first like a coordinate/cropping bug (reported
  as "capturing area above the window, cutting off the bottom, not full
  width") but was actually just the wrong window's real, correctly-cropped
  bounds. Root-caused by comparing a screenshot taken at the exact instant
  of a match against the logged position/size (see `resolve_window_at_point()`'s
  own comment in `g4recorder.m` for the full writeup). **Real fix:**
  `AXUIElementCopyElementAtPosition` against the systemwide element (a real
  z-order-aware accessibility hit test, confirmed present in the Tiger
  10.4u SDK), walking up to the owning window via
  `kAXTopLevelUIElementAttribute` — this also eliminated the need for
  Carbon Process Manager's `GetNextProcess` app enumeration entirely
  (`AXUIElementGetPid` gets the pid directly from the resolved window).
  Verified live: re-tested against real, live Godot windows and correctly
  resolved the actual topmost one (`'Dungeon (DEBUG)'`) instead of an
  overlapping Finder window.

- **`ax_dump_windows.c`** / **`ax_dump_pid.c`** — debug tools built while
  root-causing the bug above. Real, useful finding from these: AX window
  queries (`AXUIElementCopyAttributeValue` for `kAXWindowsAttribute`) fail
  with `kAXErrorCannotComplete` (-25204) when run from an SSH-launched
  process with no real GUI session — even with `AXAPIEnabled()` reporting
  true — the same underlying GUI-session limitation documented for Carbon
  Process Manager elsewhere in this project, just failing differently
  (silently wrong data / an explicit error, not a crash or hang). Confirms
  AX-based diagnostics of this kind need a real physically-launched `.app`,
  same as every other AX-dependent tool here.
