#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <stdio.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

/* RESOLVED proof-of-concept for issue #2. Verified live on real G4/Tiger
 * hardware (launched as a real double-clicked .app -- see
 * WindowSelectTest-Info.plist):
 *
 * 1. Click-to-select: a real Quartz Event Services event tap
 *    (kCGSessionEventTap, listen-only) reliably catches real physical
 *    mouse-down clicks. CGEventPost-synthesized clicks do NOT reach a
 *    listen-only tap on this OS/hardware (confirmed via direct testing --
 *    a well-positioned synthetic click, verified via screenshot to land
 *    exactly on target, produced zero tap callbacks) -- fine for the real
 *    product (a real human will really click), but means this exact
 *    click-detection path can only be tested with a real physical click,
 *    not scripted.
 * 2. Window resolution: CGWindowListCopyWindowInfo/CGWindowListCreateImage
 *    (the modern approach) do not exist at all in the Tiger SDK (confirmed:
 *    no CGWindow.h header anywhere in it) -- resolved via the Accessibility
 *    API instead: enumerate every running app's windows
 *    (AXUIElementCreateApplication + kAXWindowsAttribute) and point-in-rect
 *    test each window's real kAXPositionAttribute/kAXSizeAttribute bounds.
 *    Requires "Enable access for assistive devices" (Universal Access pref
 *    pane) checked -- AXAPIEnabled() gates this. Observed real flakiness
 *    during development (AXAPIEnabled() intermittently read false even
 *    with the checkbox visibly checked and the underlying preference
 *    correctly true) that resolved itself without a clear single cause --
 *    if the real shipped app ever needs to handle this, don't treat a
 *    single AXAPIEnabled()==false check as fatal/permanent; a short
 *    retry-with-backoff would be more robust than this PoC's one-shot check.
 * 3. Frame capture: no CGWindowListCreateImage means no ready-made
 *    per-window image API either -- captures directly from the live
 *    display framebuffer instead (CGDisplayBaseAddress/BytesPerRow/
 *    BitsPerPixel), cropped to the resolved window's rect. Read-only, no
 *    CGDisplayCapture() needed. Verified visually correct (real captured
 *    pixel content, correct RGB channel order once channel 0 -- alpha/pad
 *    -- is skipped). Real, unavoidable caveat: this reads whatever is
 *    actually on screen at that rect, including any OTHER window that
 *    happens to overlap the target -- fine for the intended workflow
 *    (recording a frontmost, unobstructed game window), not a true
 *    isolated-window capture.
 * 4. REAL measured throughput, and why it's capped: a naive per-row copy
 *    of a 785x443 rect straight from CGDisplayBaseAddress achieved only
 *    ~22fps -- below the 30fps target for a window this size. Isolated
 *    the real cause via two comparison benchmarks (not assumed): a
 *    same-byte-count contiguous copy from regular malloc'd RAM hit ~406fps,
 *    and the SAME row-by-row structure against regular RAM (not the real
 *    framebuffer) hit ~368fps -- meaning the row-by-row loop itself costs
 *    barely anything (368 vs 406fps). The real bottleneck is specifically
 *    CPU-side reads of actual video memory (~16x slower than reading
 *    regular RAM here), a genuine, well-known hardware characteristic
 *    (VRAM is optimized for GPU-side access, not CPU readback) -- not a
 *    fixable software inefficiency, and AltiVec doesn't help (it
 *    accelerates compute, not raw memory-bus-bound copies, which is also
 *    why Apple's own vImage framework has no bulk rect-copy fast path).
 *    Real, useful consequence: since this is bandwidth-bound (roughly
 *    linear in pixel count), throughput scales with window AREA -- the
 *    measured ~7.72M pixel-fps budget means a roughly 507x507-or-smaller
 *    (or equivalent area) window should sustain a real 30fps; meaningfully
 *    larger windows won't, and that's a real, physical constraint of this
 *    capture technique on this hardware, not a bug to keep chasing.
 * 5. Issue #4 (frame buffering strategy): this same program's own capture
 *    handler also runs a real integrated ~90-second capture+disk-write
 *    test (not just the isolated benchmarks above) once a window is
 *    selected -- writes raw frames straight to /tmp/capture_buffer_test.raw
 *    as they're captured. Confirmed live on a real 1047x680 browser
 *    window: 694 frames in 90.01s = 7.7fps, 1884.8MB written, no crash, no
 *    OOM -- consistent with #2's own area-based bandwidth model (predicts
 *    ~10.8fps capture-only at this size; the real combined number is a
 *    bit lower once real disk-write time is added in). A separate `dd`
 *    test measured real sustained disk write throughput at ~87MB/s, far
 *    above what capture alone can even produce (this integrated test's
 *    own ~21MB/s average) -- confirms disk write is NOT the bottleneck,
 *    same conclusion as #2's own capture-side finding. This is also why
 *    a RAM ring buffer was ruled out instead of disk: this machine only
 *    has 2GB total RAM, nowhere near enough for more than a few seconds
 *    of raw frames at any real window size, while 231GB of free disk and
 *    87MB/s real write throughput comfortably covers a full short clip.
 *
 * Must be launched as a real double-clicked .app, not via SSH -- Carbon
 * Process Manager's GetNextProcess() needs a real GUI-session Mach
 * bootstrap namespace to register its own CFMessagePort, which an SSH
 * session doesn't have (same root cause as this project's documented
 * CoreDrag/tiger-ssh deadlock class of issue). Logs to a fixed path so
 * results can still be read back over SSH after a physical launch. */

#define LOG_PATH "/tmp/window_select_test.log"

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type != kCGEventLeftMouseDown) {
        return event;
    }

    CGPoint loc = CGEventGetLocation(event);
    printf("Click at (%.0f, %.0f)\n", loc.x, loc.y);
    fflush(stdout);

    ProcessSerialNumber psn = { kNoProcess, kNoProcess };
    OSErr err;
    int found = 0;

    while (GetNextProcess(&psn) == noErr) {
        pid_t pid;
        err = GetProcessPID(&psn, &pid);
        if (err != noErr) continue;

        AXUIElementRef appElem = AXUIElementCreateApplication(pid);
        if (!appElem) continue;

        CFArrayRef windows = NULL;
        AXError axerr = AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute, (CFTypeRef *)&windows);
        if (axerr == kAXErrorSuccess && windows) {
            CFIndex n = CFArrayGetCount(windows);
            for (CFIndex i = 0; i < n; i++) {
                AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);

                CFTypeRef posValue = NULL, sizeValue = NULL;
                CGPoint pos = {0, 0};
                CGSize size = {0, 0};

                if (AXUIElementCopyAttributeValue(win, kAXPositionAttribute, &posValue) == kAXErrorSuccess && posValue) {
                    AXValueGetValue((AXValueRef)posValue, kAXValueCGPointType, &pos);
                    CFRelease(posValue);
                }
                if (AXUIElementCopyAttributeValue(win, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess && sizeValue) {
                    AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);
                    CFRelease(sizeValue);
                }

                if (loc.x >= pos.x && loc.x <= pos.x + size.width &&
                    loc.y >= pos.y && loc.y <= pos.y + size.height) {
                    CFStringRef title = NULL;
                    AXUIElementCopyAttributeValue(win, kAXTitleAttribute, (CFTypeRef *)&title);
                    char titleBuf[256] = "(no title)";
                    if (title) {
                        CFStringGetCString(title, titleBuf, sizeof(titleBuf), kCFStringEncodingUTF8);
                        CFRelease(title);
                    }
                    printf("  MATCH: pid=%d window='%s' bounds=(%.0f,%.0f %.0fx%.0f)\n",
                           pid, titleBuf, pos.x, pos.y, size.width, size.height);
                    fflush(stdout);
                    found = 1;

                    /* Capture one real frame from the main display's raw
                     * framebuffer, cropped to this window's bounds, and
                     * write it out as a PPM for visual verification. Real
                     * Tiger-compatible mechanism (CGWindowListCreateImage
                     * doesn't exist pre-Leopard) -- reads directly, no
                     * display capture/takeover needed since we only read. */
                    CGDirectDisplayID display = CGMainDisplayID();
                    void *base = CGDisplayBaseAddress(display);
                    size_t bpp = CGDisplayBitsPerPixel(display);
                    size_t bytesPerRow = CGDisplayBytesPerRow(display);
                    printf("  display base=%p bpp=%zu bytesPerRow=%zu\n", base, bpp, bytesPerRow);
                    fflush(stdout);

                    if (base && bpp == 32) {
                        int w = (int)size.width;
                        int h = (int)size.height;
                        int ox = (int)pos.x;
                        int oy = (int)pos.y;
                        FILE *ppm = fopen("/tmp/window_capture_test.ppm", "wb");
                        if (ppm) {
                            fprintf(ppm, "P6\n%d %d\n255\n", w, h);
                            for (int y = 0; y < h; y++) {
                                uint8_t *row = (uint8_t *)base + (size_t)(oy + y) * bytesPerRow + (size_t)ox * 4;
                                for (int x = 0; x < w; x++) {
                                    uint8_t b0 = row[x * 4 + 0];
                                    uint8_t r = row[x * 4 + 1];
                                    uint8_t g = row[x * 4 + 2];
                                    uint8_t b = row[x * 4 + 3];
                                    (void)b0;
                                    fputc(r, ppm);
                                    fputc(g, ppm);
                                    fputc(b, ppm);
                                }
                            }
                            fclose(ppm);
                            printf("  wrote /tmp/window_capture_test.ppm (%dx%d)\n", w, h);
                            fflush(stdout);
                        }

                        /* Issue #4 real integrated test: capture AND
                         * sequentially write raw frames straight to disk
                         * for a real ~90 seconds -- not just the separate
                         * capture-only (issue #2) and disk-write-only (dd)
                         * benchmarks, a real combined measurement, since
                         * disk buffering was the real chosen design
                         * (2GB total RAM can't hold more than a few
                         * seconds of raw frames at any real window size;
                         * 231GB free disk and a real measured 87MB/s dd
                         * write throughput comfortably covers it instead).
                         * No compression, no encoding here -- that's
                         * issue #5's own deliberately-separate offline
                         * pass. */
                        size_t frameBytes = (size_t)w * (size_t)h * 4;
                        uint8_t *scratch = (uint8_t *)malloc(frameBytes);
                        FILE *raw = fopen("/tmp/capture_buffer_test.raw", "wb");
                        if (scratch && raw) {
                            struct timeval t0, t1;
                            gettimeofday(&t0, NULL);
                            long frames = 0;
                            double elapsed = 0;
                            while (elapsed < 90.0) {
                                for (int y = 0; y < h; y++) {
                                    uint8_t *row = (uint8_t *)base + (size_t)(oy + y) * bytesPerRow + (size_t)ox * 4;
                                    memcpy(scratch + (size_t)y * w * 4, row, (size_t)w * 4);
                                }
                                fwrite(scratch, 1, frameBytes, raw);
                                frames++;
                                gettimeofday(&t1, NULL);
                                elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_usec - t0.tv_usec) / 1000000.0;
                            }
                            fclose(raw);
                            printf("  issue #4 integrated test: %ld capture+write frames in %.2fs = %.1f fps (%dx%d, %zu bytes/frame, %.1f MB total)\n",
                                   frames, elapsed, frames / elapsed, w, h, frameBytes, (frames * (double)frameBytes) / (1024.0 * 1024.0));
                            fflush(stdout);
                            free(scratch);
                        } else {
                            if (raw) fclose(raw);
                            printf("  issue #4 test: failed to allocate scratch buffer or open output file\n");
                            fflush(stdout);
                        }
                    }
                }
            }
            CFRelease(windows);
        }
        CFRelease(appElem);
    }

    if (!found) {
        printf("  no window matched this click point\n");
        fflush(stdout);
    }

    return event;
}

int main(void) {
    freopen(LOG_PATH, "w", stdout);
    freopen(LOG_PATH, "a", stderr);
    setvbuf(stdout, NULL, _IOLBF, 0);

    printf("uid=%d euid=%d\n", getuid(), geteuid());
    CFPropertyListRef v = CFPreferencesCopyValue(CFSTR("AXEnabled"), CFSTR("com.apple.universalaccess"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    printf("CFPreferencesCopyValue AXEnabled (current user) = %p", (void *)v);
    if (v && CFGetTypeID(v) == CFBooleanGetTypeID()) {
        printf(" boolValue=%d", CFBooleanGetValue((CFBooleanRef)v));
    }
    printf("\n");
    if (v) CFRelease(v);
    CFPropertyListRef v2 = CFPreferencesCopyValue(CFSTR("AXEnabled"), CFSTR("com.apple.universalaccess"), kCFPreferencesAnyUser, kCFPreferencesCurrentHost);
    printf("CFPreferencesCopyValue AXEnabled (any user) = %p\n", (void *)v2);
    if (v2) CFRelease(v2);
    fflush(stdout);

    Boolean trusted = AXAPIEnabled();
    printf("AXAPIEnabled() = %d\n", trusted);
    fflush(stdout);
    if (!trusted) {
        printf("Accessibility API access is NOT enabled system-wide.\n");
        fflush(stdout);
        return 1;
    }

    CFMachPortRef tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly,
        CGEventMaskBit(kCGEventLeftMouseDown),
        tap_callback,
        NULL);

    if (!tap) {
        printf("Failed to create event tap.\n");
        fflush(stdout);
        return 1;
    }

    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(tap, true);

    printf("Listening for clicks...\n");
    fflush(stdout);
    CFRunLoopRun();
    return 0;
}
