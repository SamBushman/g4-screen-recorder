#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>

/* RESOLVED proof-of-concept for issue #3. Verified live on real G4/Tiger
 * hardware (launched as a real double-clicked .app -- see
 * MenuBarHotkeyTest-Info.plist): a real background/menu-bar-only app
 * (LSUIElement, no Dock icon) with a real NSStatusItem that visibly
 * updates between "[idle]" and "[REC]", and two real global hotkeys
 * (RegisterEventHotKey -- the classic, purpose-built Carbon mechanism for
 * exactly this, distinct from and NOT gated by the AXAPIEnabled()/
 * Accessibility permission issue #2 hit for raw keyboard event taps) that
 * fire while a DIFFERENT app has keyboard focus -- confirmed by the user
 * both visually (menu bar changed) and via this program's own log.
 *
 * Real finding worth keeping: the first attempt used Cmd+Opt+F1 (start) /
 * Cmd+Opt+F2 (stop) (virtual keycodes 0x7A/0x78). RegisterEventHotKey
 * returned noErr for both (real, successful registration) but neither
 * ever actually fired on a real key press -- on a DESKTOP G4 with no
 * obvious laptop-style hardware Fn/brightness binding to explain it. Not
 * root-caused (not worth the time for a working alternative); routed
 * around by switching to ordinary alphanumeric keys instead:
 * Cmd+Opt+Shift+9 (start, keycode 0x19) / Cmd+Opt+Shift+0 (stop, keycode
 * 0x1D) -- both fired correctly and reliably on retest. Worth remembering
 * for any future hotkey choice on this hardware: don't assume F-keys work
 * for global hotkey registration just because the API reports success;
 * verify the actual keypress fires, and prefer ordinary letter/number
 * keys with multiple modifiers if in doubt. */

#define LOG_PATH "/tmp/menubar_hotkey_test.log"

static NSStatusItem *gStatusItem = nil;
static BOOL gRecording = NO;

static void updateStatusItem(void) {
    [gStatusItem setTitle:gRecording ? @"[REC]" : @"[idle]"];
}

static OSStatus hotKeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
    EventHotKeyID hkID;
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof(hkID), NULL, &hkID);

    FILE *f = fopen(LOG_PATH, "a");
    if (hkID.id == 1) {
        gRecording = YES;
        if (f) fprintf(f, "START hotkey pressed\n");
        NSLog(@"START hotkey pressed");
    } else if (hkID.id == 2) {
        gRecording = NO;
        if (f) fprintf(f, "STOP hotkey pressed\n");
        NSLog(@"STOP hotkey pressed");
    }
    if (f) { fclose(f); }
    updateStatusItem();
    return noErr;
}

int main(int argc, const char *argv[]) {
    freopen(LOG_PATH, "w", stdout);
    freopen(LOG_PATH, "a", stderr);
    setvbuf(stdout, NULL, _IOLBF, 0);
    printf("menubar_hotkey_poc starting\n");

    NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
    [NSApplication sharedApplication];

    gStatusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
    updateStatusItem();

    EventHotKeyID startID = { 'gscr', 1 };
    EventHotKeyID stopID = { 'gscr', 2 };
    EventHotKeyRef startRef, stopRef;

    /* Switched from F1/F2 (0x7A/0x78) to ANSI_9/ANSI_0 (0x19/0x1D) after
     * F1/F2 registered without error (RegisterEventHotKey returned noErr)
     * but never actually fired -- real, unexplained on a desktop G4 (no
     * obvious hardware brightness/Fn binding like a laptop would have),
     * not yet root-caused, just routed around with more conventional keys. */
    OSStatus s1 = RegisterEventHotKey(0x19, cmdKey | optionKey | shiftKey, startID, GetApplicationEventTarget(), 0, &startRef);
    OSStatus s2 = RegisterEventHotKey(0x1D, cmdKey | optionKey | shiftKey, stopID, GetApplicationEventTarget(), 0, &stopRef);
    printf("RegisterEventHotKey start=%d stop=%d\n", (int)s1, (int)s2);
    fflush(stdout);

    EventTypeSpec spec = { kEventClassKeyboard, kEventHotKeyPressed };
    InstallApplicationEventHandler(NewEventHandlerUPP(hotKeyHandler), 1, &spec, NULL, NULL);

    printf("Ready. Press Cmd+Opt+Shift+9 to start, Cmd+Opt+Shift+0 to stop.\n");
    fflush(stdout);

    [NSApp run];

    [pool release];
    return 0;
}
