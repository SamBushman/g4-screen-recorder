#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#include <ApplicationServices/ApplicationServices.h>
#include <CoreVideo/CoreVideo.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <sys/stat.h>
#include <unistd.h>

/* g4recorder: the real integrated tool for issue #6/#7. Combines the
 * separately-verified pieces from issues #2-#5 into one continuous
 * flow, since none of the individual PoCs alone satisfy issue #6's own
 * success criteria ("use THIS tool" - singular, real app):
 *
 *   1. Press the START hotkey (Cmd+Opt+Shift+9, per issue #3's real
 *      finding that F-keys silently don't fire on this hardware) -- arms
 *      a click listener, menu bar shows "[click a window]".
 *   2. Click the target window (same Quartz event tap as issue #2, but a
 *      REAL, z-order-aware hit test for window resolution -- see
 *      resolve_window_at_point()'s own comment for a real bug this
 *      corrected: issue #2's original "does any window's AX rect contain
 *      the click point" approach can match the wrong window when more
 *      than one window's bounds overlap the same screen point, which is
 *      common and was caught live) -- selects AND immediately starts
 *      recording that window in one motion, menu bar shows
 *      "[REC <title>]".
 *   3. Capture runs on a dedicated pthread (NOT the main thread/CFRunLoop
 *      -- issue #4's PoC blocked the runloop for a fixed 90s inside the
 *      tap callback, which would make the STOP hotkey undeliverable
 *      during a real recording; here the main thread stays free to
 *      process the STOP hotkey at any time) writing raw frames straight
 *      to a temp file exactly as issue #4 established (disk buffering,
 *      not RAM -- this machine's 2GB RAM can't hold more than a few
 *      seconds of raw frames at any real window size).
 *   4. Press the STOP hotkey (Cmd+Opt+Shift+0) -- signals the capture
 *      thread to stop. Menu bar shows "[encoding...]" while that same
 *      background thread (not main thread) shells out to ffmpeg's
 *      libx264 (confirmed in issue #5 to be the real AltiVec build
 *      verified in issue #1) using the REAL measured fps (frames/real
 *      elapsed seconds -- issue #2/#4 established real achieved fps
 *      varies with window size and is often well under the 30fps
 *      target, so this must never be hardcoded to 30). Output goes to
 *      ~/Movies/G4Recording_<timestamp>.mp4. Menu bar returns to
 *      "[idle]" when done; the raw temp file is deleted.
 *
 * Same AXAPIEnabled() / physical-.app-launch requirements as issue #2's
 * PoC -- see window_select_capture_poc.c's own header comment for why.
 * Logs to a fixed path so results can be read back over SSH.
 *
 * Two user-configurable capture modes, both off by default (identical to
 * the original always-on behavior unless a user opts in via the status
 * menu), added to work around the real, measured, bandwidth-bound
 * bottleneck window_select_capture_poc.c's own header documents (real
 * VRAM reads run ~16x slower than an identical-size RAM copy here, cost
 * roughly linear in pixel count, AltiVec doesn't help since it's a bus
 * limit not a compute one):
 *
 *   - Interlaced capture: each frame after the first only re-reads HALF
 *     the scanlines from VRAM (alternating which half every capture),
 *     leaving the other half holding whatever the previous capture wrote
 *     there ("weave") -- halves the real per-capture VRAM-read bandwidth,
 *     which per the linear-in-pixel-count model should roughly double
 *     the achievable capture rate at a given resolution. Every frame
 *     written to disk is still a full WxH image, so the existing
 *     rawvideo encode step needs no changes to read it -- the trade-off
 *     shows up as combing on vertical motion between fields, the same
 *     real visual artifact classic broadcast-TV field interlacing always
 *     had, not a different file format or a broken encode.
 *
 *   - Refresh-synced capture: instead of the original free-running tight
 *     loop (which reads VRAM at arbitrary moments uncorrelated with the
 *     display's own scanout, i.e. exactly the condition that produces
 *     visible tearing -- a capture can land mid-buffer-swap), a
 *     CVDisplayLink ties each capture to the display's real vertical
 *     refresh, optionally only every Nth tick ("a fraction of the
 *     refresh") for content that doesn't need every single vsync
 *     captured. This is a best-effort mitigation, not a guarantee --
 *     there's still no hardware genlock between the capture read and the
 *     GPU's own buffer swap, just a much better-timed guess at when a
 *     swap has just settled.
 *
 * Both are independent, orthogonal toggles -- either, both, or neither
 * can be active for a given recording. */

#define LOG_PATH "/tmp/g4recorder.log"
#define RAW_TMP_PATH "/tmp/g4recorder_capture.raw"
#define DEFAULTS_KEY_INTERLACED @"G4RecorderInterlacedCapture"
#define DEFAULTS_KEY_SYNC_DIVISOR @"G4RecorderRefreshSyncDivisor"

static NSStatusItem *gStatusItem = nil;

static volatile int gArmed = 0;
static volatile int gRecording = 0;
static volatile int gShouldStop = 0;

/* Both default to 0 (off/unsynced) -- identical to this tool's original,
 * always-on-at-full-speed behavior until a user opts in via the status
 * menu. Loaded from NSUserDefaults at startup, persisted on every menu
 * change, so a choice survives across relaunches. */
static volatile int gInterlacedEnabled = 0;
static volatile int gRefreshSyncDivisor = 0;

static char gWinTitle[256] = "";
static int gWinX, gWinY, gWinW, gWinH;

static void set_menu_title(NSString *title) {
    [gStatusItem performSelectorOnMainThread:@selector(setTitle:) withObject:title waitUntilDone:NO];
}

/* Refresh-sync gate: a plain pthread mutex/condvar pair, not GCD dispatch
 * semaphores (not available -- GCD is a Snow Leopard/10.6+ addition, this
 * targets 10.4) and not POSIX sem_init() (Darwin's unnamed-semaphore
 * support has a real history of being unreliable/unsupported -- see
 * `man sem_init` on any real macOS box -- named sem_open() would work but
 * pthread condvars are simpler here and have been solid on this OS since
 * 10.0). The CVDisplayLink callback runs on its own internal high-
 * priority thread and signals this gate; the capture loop waits on it
 * instead of spinning, only when refresh sync is actually enabled. */
static pthread_mutex_t gGateMutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gGateCond = PTHREAD_COND_INITIALIZER;
static volatile int gGateSignaled = 0;
static volatile int gSyncTickCounter = 0;

static CVReturn display_link_callback(CVDisplayLinkRef displayLink,
                                       const CVTimeStamp *inNow,
                                       const CVTimeStamp *inOutputTime,
                                       CVOptionFlags flagsIn,
                                       CVOptionFlags *flagsOut,
                                       void *displayLinkContext) {
    (void)displayLink;
    (void)inNow;
    (void)inOutputTime;
    (void)flagsIn;
    (void)flagsOut;
    (void)displayLinkContext;
    /* Fires once per real vertical refresh. gRefreshSyncDivisor of 1 (or
     * anything <=0, shouldn't happen while a display link is even
     * running) signals every tick; N>1 only signals every Nth tick --
     * this is what "a fraction of the screen refresh" means here. Read
     * live each call (not cached at thread start) so a divisor change
     * made mid-recording via the status menu takes effect on the next
     * tick, not just the next recording. */
    int divisor = gRefreshSyncDivisor > 0 ? gRefreshSyncDivisor : 1;
    gSyncTickCounter++;
    if (gSyncTickCounter >= divisor) {
        gSyncTickCounter = 0;
        pthread_mutex_lock(&gGateMutex);
        gGateSignaled = 1;
        pthread_cond_signal(&gGateCond);
        pthread_mutex_unlock(&gGateMutex);
    }
    return kCVReturnSuccess;
}

/* Blocks until the display link signals it's time for the next capture,
 * with a 200ms timeout so a STOP request is never undeliverable even if
 * the display link stalls (display sleep, a display reconfiguration
 * mid-recording, etc.) -- mirrors this file's own existing rule
 * (capture runs on its own thread, specifically so the main thread/STOP
 * hotkey is never blocked by capture timing). No real timespec math
 * helper is used here on purpose: this target OS (Tiger) predates
 * clock_gettime() entirely (Apple only added it in Sierra/10.12), so the
 * timeout is built from gettimeofday() like every other timing in this
 * file. Returns 0 if it should proceed with a capture, 1 if it woke up
 * because gShouldStop was set instead. */
static int wait_for_refresh_gate(void) {
    struct timeval tv;
    struct timespec ts;
    pthread_mutex_lock(&gGateMutex);
    while (!gGateSignaled && !gShouldStop) {
        gettimeofday(&tv, NULL);
        ts.tv_sec = tv.tv_sec;
        ts.tv_nsec = (tv.tv_usec * 1000L) + 200000000L; /* +200ms */
        if (ts.tv_nsec >= 1000000000L) {
            ts.tv_sec += 1;
            ts.tv_nsec -= 1000000000L;
        }
        pthread_cond_timedwait(&gGateCond, &gGateMutex, &ts);
    }
    gGateSignaled = 0;
    pthread_mutex_unlock(&gGateMutex);
    return gShouldStop ? 1 : 0;
}

static void *capture_thread_main(void *arg) {
    (void)arg;

    CGDirectDisplayID display = CGMainDisplayID();
    void *base = CGDisplayBaseAddress(display);
    size_t bytesPerRow = CGDisplayBytesPerRow(display);

    int w = gWinW, h = gWinH, ox = gWinX, oy = gWinY;
    size_t frameBytes = (size_t)w * (size_t)h * 4;
    uint8_t *scratch = (uint8_t *)malloc(frameBytes);
    FILE *raw = fopen(RAW_TMP_PATH, "wb");

    /* Snapshot both mode toggles once at recording start. gInterlacedEnabled
     * is still re-read live every iteration below (cheap, and lets a
     * mid-recording toggle take effect immediately); useSync controls
     * whether a CVDisplayLink gets created at all, which is NOT
     * revisited mid-recording -- toggling refresh sync fully on/off only
     * takes effect on the next recording, though the DIVISOR value
     * itself (read live by display_link_callback) can still be changed
     * while one is already running. See this file's header comment for
     * why both toggles default off/unsynced (identical to the original
     * behavior) and are independent of each other. */
    int useSync = gRefreshSyncDivisor > 0;
    CVDisplayLinkRef displayLink = NULL;
    if (useSync) {
        gSyncTickCounter = 0;
        gGateSignaled = 0;
        CVReturn dlErr = CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
        if (dlErr == kCVReturnSuccess && displayLink) {
            CVDisplayLinkSetOutputCallback(displayLink, display_link_callback, NULL);
            CVDisplayLinkStart(displayLink);
        } else {
            printf("capture_thread: CVDisplayLinkCreateWithActiveCGDisplays failed (err=%d) -- falling back to unsynced capture\n", (int)dlErr);
            fflush(stdout);
            useSync = 0;
            displayLink = NULL;
        }
    }

    printf("capture_thread: started, window=%dx%d @ (%d,%d) interlaced=%d sync_divisor=%d\n",
           w, h, ox, oy, gInterlacedEnabled, useSync ? gRefreshSyncDivisor : 0);
    fflush(stdout);

    long frames = 0;
    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    double elapsed = 0;
    int fieldParity = 0;
    int firstFrame = 1;

    if (scratch && raw) {
        while (!gShouldStop) {
            if (useSync) {
                if (wait_for_refresh_gate()) {
                    break; /* woke up for gShouldStop, not a real tick */
                }
            }

            if (gInterlacedEnabled && !firstFrame) {
                /* Real bandwidth optimization, not a visual-quality
                 * feature: only re-read every OTHER scanline this
                 * capture (alternating which half each time), leaving
                 * the untouched half exactly as the previous capture
                 * left it ("weave"). Halves the real per-capture
                 * VRAM-read volume -- the actual measured bottleneck
                 * (see this file's header comment) -- so this should
                 * roughly double the achievable capture rate at this
                 * window size, at the cost of real combing artifacts on
                 * any vertical motion between the two fields. The output
                 * file format doesn't change at all: this still writes
                 * one full WxH frame per iteration, same as always. */
                for (int y = fieldParity; y < h; y += 2) {
                    uint8_t *row = (uint8_t *)base + (size_t)(oy + y) * bytesPerRow + (size_t)ox * 4;
                    memcpy(scratch + (size_t)y * w * 4, row, (size_t)w * 4);
                }
                fieldParity ^= 1;
            } else {
                /* Full read: either interlacing is off, or this is the
                 * very first frame of the recording -- always do a full
                 * read for frame 1 specifically so the weave buffer
                 * starts as real captured content on both parities
                 * instead of half of it being uninitialized malloc()
                 * garbage. */
                for (int y = 0; y < h; y++) {
                    uint8_t *row = (uint8_t *)base + (size_t)(oy + y) * bytesPerRow + (size_t)ox * 4;
                    memcpy(scratch + (size_t)y * w * 4, row, (size_t)w * 4);
                }
                firstFrame = 0;
            }

            fwrite(scratch, 1, frameBytes, raw);
            frames++;
            gettimeofday(&t1, NULL);
            elapsed = (t1.tv_sec - t0.tv_sec) + (t1.tv_usec - t0.tv_usec) / 1000000.0;
        }
        fclose(raw);
    }
    if (scratch) free(scratch);

    if (displayLink) {
        CVDisplayLinkStop(displayLink);
        CVDisplayLinkRelease(displayLink);
    }

    double fps = frames > 0 && elapsed > 0 ? frames / elapsed : 1.0;
    printf("capture_thread: stopped. frames=%ld elapsed=%.2fs fps=%.3f\n", frames, elapsed, fps);
    fflush(stdout);

    set_menu_title(@"[encoding...]");

    const char *home = getenv("HOME");
    if (!home) home = "/tmp";
    char outdir[512];
    snprintf(outdir, sizeof(outdir), "%s/Movies", home);
    mkdir(outdir, 0755);

    time_t now = time(NULL);
    struct tm *tmv = localtime(&now);
    char outpath[600];
    snprintf(outpath, sizeof(outpath), "%s/G4Recording_%04d%02d%02d_%02d%02d%02d.mp4",
              outdir, tmv->tm_year + 1900, tmv->tm_mon + 1, tmv->tm_mday,
              tmv->tm_hour, tmv->tm_min, tmv->tm_sec);

    char cmd[1024];
    /* libx264/yuv420p requires even width+height; real window sizes are
     * not guaranteed even (hit this for real: a live 1280x927 Godot
     * window failed to encode with "height not divisible by 2" before
     * this crop filter was added). Crop 1px off the odd edge rather than
     * pad, to avoid introducing synthetic border pixels. */
    snprintf(cmd, sizeof(cmd),
             "/usr/local/bin/ffmpeg -y -f rawvideo -pixel_format argb -video_size %dx%d -framerate %.4f "
             "-i '%s' -vf \"crop=trunc(iw/2)*2:trunc(ih/2)*2\" "
             "-c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p -movflags +faststart '%s' "
             ">> \"%s\" 2>&1",
             w, h, fps, RAW_TMP_PATH, outpath, LOG_PATH);

    printf("capture_thread: encoding via: %s\n", cmd);
    fflush(stdout);

    struct timeval e0, e1;
    gettimeofday(&e0, NULL);
    int rc = system(cmd);
    gettimeofday(&e1, NULL);
    double encodeSecs = (e1.tv_sec - e0.tv_sec) + (e1.tv_usec - e0.tv_usec) / 1000000.0;

    printf("capture_thread: encode rc=%d in %.1fs -> %s\n", rc, encodeSecs, outpath);
    fflush(stdout);

    unlink(RAW_TMP_PATH);

    gRecording = 0;
    gShouldStop = 0;
    set_menu_title(@"[idle]");

    return NULL;
}

/* Resolves the REAL topmost window at a screen point via a proper
 * z-order-aware accessibility hit test, instead of a naive "does any
 * window's AX-reported rect contain this point" search across every
 * running app. That naive approach was tried first and is a REAL,
 * confirmed bug (found 2026-09-08 during live integration testing): with
 * multiple windows on screen, more than one AX-reported rect can
 * geometrically contain the same click point (e.g. an app window sitting
 * behind/underneath others whose bounds still overlap that point), and a
 * plain enumeration returns whichever one comes first in iteration
 * order -- NOT necessarily the window actually visible on top there. The
 * raw-framebuffer capture then faithfully captures whatever pixels are
 * REALLY on screen in that wrong window's rect, which is a different,
 * unrelated region -- producing exactly the symptom seen live: the
 * recorded video showed a completely different window's real on-screen
 * content (a Godot editor + separate floating debug window boundary)
 * than the one whose title/pid got logged as the "match".
 * AXUIElementCopyElementAtPosition against the systemwide element does a
 * real hit test respecting actual window stacking order -- confirmed
 * present in the Tiger 10.4u SDK's AXUIElement.h. It typically returns a
 * leaf control (a button, a text view) under the click, not the window
 * itself, so this walks up to the owning window via
 * kAXTopLevelUIElementAttribute (falling back to walking kAXParentAttribute
 * checking kAXRoleAttribute==kAXWindowRole, in case some element doesn't
 * support the direct shortcut). */
static int resolve_window_at_point(CGPoint loc, pid_t *outPid, char *outTitle, size_t titleSize,
                                    int *outX, int *outY, int *outW, int *outH) {
    AXUIElementRef systemWide = AXUIElementCreateSystemWide();
    AXUIElementRef hit = NULL;
    AXError err = AXUIElementCopyElementAtPosition(systemWide, (float)loc.x, (float)loc.y, &hit);
    CFRelease(systemWide);
    if (err != kAXErrorSuccess || !hit) {
        if (hit) CFRelease(hit);
        return 0;
    }

    AXUIElementRef winElem = NULL;
    CFTypeRef topLevel = NULL;
    if (AXUIElementCopyAttributeValue(hit, kAXTopLevelUIElementAttribute, &topLevel) == kAXErrorSuccess && topLevel) {
        winElem = (AXUIElementRef)topLevel;
    } else {
        AXUIElementRef cur = hit;
        CFRetain(cur);
        for (int i = 0; i < 10 && cur; i++) {
            CFTypeRef roleVal = NULL;
            int isWindow = 0;
            if (AXUIElementCopyAttributeValue(cur, kAXRoleAttribute, &roleVal) == kAXErrorSuccess && roleVal) {
                isWindow = CFEqual(roleVal, kAXWindowRole);
                CFRelease(roleVal);
            }
            if (isWindow) { winElem = cur; break; }
            CFTypeRef parent = NULL;
            AXError perr = AXUIElementCopyAttributeValue(cur, kAXParentAttribute, &parent);
            CFRelease(cur);
            cur = (perr == kAXErrorSuccess && parent) ? (AXUIElementRef)parent : NULL;
        }
        if (!winElem && cur) CFRelease(cur);
    }
    CFRelease(hit);

    if (!winElem) return 0;

    pid_t pid = 0;
    AXUIElementGetPid(winElem, &pid);

    CGPoint pos = {0, 0};
    CGSize size = {0, 0};
    CFTypeRef posValue = NULL, sizeValue = NULL;
    if (AXUIElementCopyAttributeValue(winElem, kAXPositionAttribute, &posValue) == kAXErrorSuccess && posValue) {
        AXValueGetValue((AXValueRef)posValue, kAXValueCGPointType, &pos);
        CFRelease(posValue);
    }
    if (AXUIElementCopyAttributeValue(winElem, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess && sizeValue) {
        AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);
        CFRelease(sizeValue);
    }
    CFStringRef title = NULL;
    outTitle[0] = '\0';
    if (AXUIElementCopyAttributeValue(winElem, kAXTitleAttribute, (CFTypeRef *)&title) == kAXErrorSuccess && title) {
        CFStringGetCString(title, outTitle, titleSize, kCFStringEncodingUTF8);
        CFRelease(title);
    }
    CFRelease(winElem);

    *outPid = pid;
    *outX = (int)pos.x;
    *outY = (int)pos.y;
    *outW = (int)size.width;
    *outH = (int)size.height;
    return 1;
}

static CGEventRef tap_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *refcon) {
    if (type != kCGEventLeftMouseDown) return event;
    if (!gArmed || gRecording) return event;

    CGPoint loc = CGEventGetLocation(event);
    printf("tap_callback: click at (%.0f,%.0f) while armed\n", loc.x, loc.y);
    fflush(stdout);

    pid_t pid;
    int x, y, w, h;
    if (!resolve_window_at_point(loc, &pid, gWinTitle, sizeof(gWinTitle), &x, &y, &w, &h)) {
        printf("tap_callback: hit-test failed to resolve a window at click point\n");
        fflush(stdout);
        return event;
    }

    gWinX = x; gWinY = y; gWinW = w; gWinH = h;
    printf("tap_callback: MATCH pid=%d '%s' (%d,%d %dx%d) -- starting capture\n",
           pid, gWinTitle, gWinX, gWinY, gWinW, gWinH);
    fflush(stdout);

    gArmed = 0;
    gRecording = 1;
    gShouldStop = 0;

    NSString *title2 = [NSString stringWithFormat:@"[REC %s]", gWinTitle[0] ? gWinTitle : "window"];
    set_menu_title(title2);

    pthread_t th;
    pthread_create(&th, NULL, capture_thread_main, NULL);
    pthread_detach(th);

    return event;
}

static OSStatus hotkey_handler(EventHandlerCallRef nextHandler, EventRef theEvent, void *userData) {
    EventHotKeyID hkID;
    GetEventParameter(theEvent, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hkID), NULL, &hkID);

    if (hkID.id == 1) {
        /* START */
        if (!gRecording && !gArmed) {
            gArmed = 1;
            printf("hotkey: START pressed -- armed, click a window\n");
            fflush(stdout);
            set_menu_title(@"[click a window]");
        }
    } else if (hkID.id == 2) {
        /* STOP */
        if (gRecording) {
            printf("hotkey: STOP pressed -- signaling capture thread\n");
            fflush(stdout);
            gShouldStop = 1;
        } else if (gArmed) {
            gArmed = 0;
            printf("hotkey: STOP pressed while armed -- disarming\n");
            fflush(stdout);
            set_menu_title(@"[idle]");
        }
    }
    return noErr;
}

@interface G4RecorderMenuTarget : NSObject
- (void)quit:(id)sender;
- (void)toggleInterlaced:(id)sender;
- (void)setSyncDivisor:(id)sender;
@end

@implementation G4RecorderMenuTarget
- (void)quit:(id)sender {
    printf("menu: Quit selected\n");
    fflush(stdout);
    [NSApp terminate:nil];
}

- (void)toggleInterlaced:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    gInterlacedEnabled = !gInterlacedEnabled;
    [item setState:gInterlacedEnabled ? NSOnState : NSOffState];
    [[NSUserDefaults standardUserDefaults] setBool:(gInterlacedEnabled ? YES : NO) forKey:DEFAULTS_KEY_INTERLACED];
    printf("menu: Interlaced Capture -> %d\n", gInterlacedEnabled);
    fflush(stdout);
}

- (void)setSyncDivisor:(id)sender {
    NSMenuItem *item = (NSMenuItem *)sender;
    int divisor = (int)[item tag]; /* 0 = unsynced, 1..N = every Nth refresh */
    gRefreshSyncDivisor = divisor;
    [[NSUserDefaults standardUserDefaults] setInteger:divisor forKey:DEFAULTS_KEY_SYNC_DIVISOR];
    /* Plain NSMenuItems have no built-in radio-group behavior -- walk the
     * submenu by hand so exactly one choice shows a checkmark.
     * NSEnumerator, not "for...in" fast enumeration -- the latter is an
     * Objective-C 2.0 feature (Leopard/10.5+) this 10.4-targeted legacy
     * runtime doesn't have. */
    NSEnumerator *siblings = [[[item menu] itemArray] objectEnumerator];
    NSMenuItem *sibling;
    while ((sibling = [siblings nextObject]) != nil) {
        [sibling setState:(sibling == item) ? NSOnState : NSOffState];
    }
    printf("menu: Refresh sync divisor -> %d\n", divisor);
    fflush(stdout);
}
@end

int main(void) {
    freopen(LOG_PATH, "w", stdout);
    freopen(LOG_PATH, "a", stderr);
    setvbuf(stdout, NULL, _IOLBF, 0);

    printf("g4recorder starting, uid=%d euid=%d\n", getuid(), geteuid());
    fflush(stdout);

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];

    NSStatusBar *bar = [NSStatusBar systemStatusBar];
    gStatusItem = [[bar statusItemWithLength:NSVariableStatusItemLength] retain];
    [gStatusItem setTitle:@"[idle]"];
    [gStatusItem setHighlightMode:YES];

    /* Load persisted capture-mode choices. Both keys default to 0/NO if
     * never set (NSUserDefaults' own documented behavior for a missing
     * key), which is exactly "off/unsynced" -- so a first launch with no
     * defaults file yet behaves identically to this tool's original,
     * always-on-at-full-speed capture loop. */
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    gInterlacedEnabled = [defaults boolForKey:DEFAULTS_KEY_INTERLACED] ? 1 : 0;
    gRefreshSyncDivisor = (int)[defaults integerForKey:DEFAULTS_KEY_SYNC_DIVISOR];

    /* LSUIElement apps have no Dock icon and no app menu, so without this
     * there is literally no in-UI way to quit -- clicking the status item
     * now shows a dropdown with a real Quit item. */
    G4RecorderMenuTarget *menuTarget = [[G4RecorderMenuTarget alloc] init];
    NSMenu *statusMenu = [[NSMenu alloc] init];

    NSMenuItem *interlacedItem = [[NSMenuItem alloc] initWithTitle:@"Interlaced Capture"
                                                             action:@selector(toggleInterlaced:)
                                                      keyEquivalent:@""];
    [interlacedItem setTarget:menuTarget];
    [interlacedItem setState:gInterlacedEnabled ? NSOnState : NSOffState];
    [statusMenu addItem:interlacedItem];

    NSMenu *syncSubmenu = [[NSMenu alloc] init];
    NSArray *syncLabels = [NSArray arrayWithObjects:
        @"Unsynced (fastest, original behavior)",
        @"Every Refresh (1/1)",
        @"Every 2nd Refresh (1/2)",
        @"Every 3rd Refresh (1/3)",
        @"Every 4th Refresh (1/4)", nil];
    for (int i = 0; i < 5; i++) {
        NSMenuItem *syncItem = [[NSMenuItem alloc] initWithTitle:[syncLabels objectAtIndex:i]
                                                           action:@selector(setSyncDivisor:)
                                                    keyEquivalent:@""];
        [syncItem setTarget:menuTarget];
        [syncItem setTag:i];
        [syncItem setState:(gRefreshSyncDivisor == i) ? NSOnState : NSOffState];
        [syncSubmenu addItem:syncItem];
        [syncItem release];
    }
    NSMenuItem *syncParentItem = [[NSMenuItem alloc] initWithTitle:@"Sync to Display Refresh"
                                                             action:NULL
                                                      keyEquivalent:@""];
    [syncParentItem setSubmenu:syncSubmenu];
    [statusMenu addItem:syncParentItem];

    [statusMenu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit G4Recorder"
                                                        action:@selector(quit:)
                                                 keyEquivalent:@""];
    [quitItem setTarget:menuTarget];
    [statusMenu addItem:quitItem];
    [gStatusItem setMenu:statusMenu];

    Boolean trusted = AXAPIEnabled();
    printf("AXAPIEnabled() = %d\n", trusted);
    fflush(stdout);
    if (!trusted) {
        [gStatusItem setTitle:@"[AX disabled]"];
        printf("Accessibility API access is NOT enabled system-wide -- window click-select won't work until it is.\n");
        fflush(stdout);
    }

    /* Global hotkeys: Cmd+Opt+Shift+9 = start, Cmd+Opt+Shift+0 = stop
     * (per issue #3's real finding -- F-keys registered without error
     * but never actually fired on this desktop G4). */
    EventTypeSpec eventSpec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallApplicationEventHandler(&hotkey_handler, 1, &eventSpec, NULL, NULL);

    EventHotKeyID startID = { 'STRT', 1 };
    EventHotKeyID stopID = { 'STOP', 2 };
    EventHotKeyRef startRef, stopRef;
    UInt32 modifiers = cmdKey | optionKey | shiftKey;
    RegisterEventHotKey(0x19 /* '9' */, modifiers, startID, GetApplicationEventTarget(), 0, &startRef);
    RegisterEventHotKey(0x1D /* '0' */, modifiers, stopID, GetApplicationEventTarget(), 0, &stopRef);

    /* Click-to-select tap, same mechanism as issue #2's PoC -- only acts
     * on real clicks while armed (see tap_callback). */
    CFMachPortRef tap = CGEventTapCreate(
        kCGSessionEventTap,
        kCGHeadInsertEventTap,
        kCGEventTapOptionListenOnly,
        CGEventMaskBit(kCGEventLeftMouseDown),
        tap_callback,
        NULL);
    if (tap) {
        CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
        CGEventTapEnable(tap, true);
    } else {
        printf("Failed to create event tap.\n");
        fflush(stdout);
    }

    printf("g4recorder ready. Cmd+Opt+Shift+9=start, Cmd+Opt+Shift+0=stop.\n");
    fflush(stdout);

    [NSApp run];
    [pool release];
    return 0;
}
