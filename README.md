# g4-screen-recorder

A menu-bar screen-capture tool for a Power Mac G4 (dual 7450, PowerPC) running
Mac OS X 10.4.11 Tiger. Built to record gameplay video of a Godot project
running in windowed mode (see [SamBushman/godot-ports](https://github.com/SamBushman/godot-ports)'s
`Tiger_GL1_2_FF`/GLFF work), but general-purpose for any windowed app.

## Intended workflow

1. Launch the recorder - it runs as a background/menu-bar-only tool, no main
   window.
2. Trigger "select window" (menu item or hotkey) and click the target window.
3. Press the start-recording hotkey.
4. Play/interact normally in the target window.
5. Press the stop-recording hotkey. The tool encodes the capture to H.264 and
   writes the finished file to disk.

## Why offline encoding, not live

Recordings are expected to be short (roughly under ~2 minutes). Rather than
encoding H.264 live (which would compete with the very app being recorded for
the same 2 real CPU cores and risk dropped frames), this tool captures raw/
lightly-compressed frames to a fast local buffer during recording, then runs
the real H.264 encode as a separate offline pass once recording stops. This
protects capture smoothness at the cost of a post-recording wait, which is an
acceptable tradeoff for the expected clip lengths.

## Why no CGWindowListCreateImage

That's the modern macOS window-capture API, but it's Leopard-and-later only
(`CG_AVAILABLE_STARTING(__MAC_10_5, ...)`) - unavailable on this machine's
Tiger (10.4). Capture instead uses an older, Tiger-compatible mechanism (see
issue #2) - direct framebuffer reads via the classic `CGDisplayBaseAddress`-
family Quartz calls, cropped to the selected window's own bounding rect.

## Why offline x264/ffmpeg, and why that needs verifying first (issue #1)

The H.264 encode uses x264 (built from source on-device, targeting this
machine's real PowerPC/AltiVec capability) rather than a pre-existing PPC
ffmpeg fork some other project (e.g. browser ffmpeg forks) might carry - those
typically only carry AltiVec work for *decode* (browsers play video, they
don't encode it), not the encode-side DCT/pixel/quant kernels this project
actually needs. x264 itself does carry real, separate PowerPC AltiVec
optimizations for encode-relevant code.

**However**: this needs to be verified working and CORRECT on real hardware
before the rest of the architecture leans on it - there's a real possibility
of long-standing, only-recently-addressed (or still-unaddressed) PowerPC/
AltiVec correctness bugs in this codepath (this is exactly the kind of thing
that motivated browser ffmpeg forks to sometimes disable/avoid certain PPC
SIMD paths in their own decoders). See issue #1 - this is a hard gate before
anything else in the pipeline depends on AltiVec being enabled. If real
correctness problems turn up, the fallback is a generic-C-only x264 build
(no AltiVec) - slower, but correct, and still acceptable given clips encode
offline with no real-time deadline.

## Status

See the repo's own open issues for current phase/progress. Rough build order:

1. Verify x264 AltiVec encode correctness on real G4 hardware (issue #1)
2. Window-selection + framebuffer capture mechanism (issue #2)
3. Background/menu-bar app shell + global hotkey registration (issue #3)
4. Frame buffering during capture (issue #4)
5. Offline encode pass wiring (issue #5)
6. End-to-end integration test with real Godot gameplay (issue #6)
7. Packaging as a distributable .app (issue #7)

## Target hardware / environment

- Power Mac G4, dual 7450, Mac OS X 10.4.11 Tiger (single-boot)
- Toolchain: Tigerbrew, gcc-7 (via `apple-gcc42` bootstrap), `ld64` (not the
  stock linker), matching the toolchain already proven for this account's
  `godot-ports` Tiger builds.
