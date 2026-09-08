#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>

/* Same as ax_dump_windows.c but takes a pid directly (via argv, sourced
 * from `ps`) instead of enumerating via Carbon Process Manager's
 * GetNextProcess -- that enumeration produced zero results when run over
 * SSH (possibly the same GUI-session Mach bootstrap issue documented for
 * Process Manager elsewhere in this project), so this isolates whether
 * AXUIElementCreateApplication + kAXWindowsAttribute themselves work over
 * SSH for a known-good pid. */

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s pid\n", argv[0]);
        return 1;
    }
    pid_t pid = atoi(argv[1]);

    Boolean trusted = AXAPIEnabled();
    printf("AXAPIEnabled() = %d\n", trusted);

    AXUIElementRef appElem = AXUIElementCreateApplication(pid);
    printf("AXUIElementCreateApplication(%d) = %p\n", pid, (void *)appElem);
    if (!appElem) return 1;

    CFArrayRef windows = NULL;
    AXError err = AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute, (CFTypeRef *)&windows);
    printf("AXUIElementCopyAttributeValue(kAXWindowsAttribute) err=%d windows=%p\n", (int)err, (void *)windows);

    if (err == kAXErrorSuccess && windows) {
        CFIndex n = CFArrayGetCount(windows);
        printf("window count = %ld\n", (long)n);
        for (CFIndex i = 0; i < n; i++) {
            AXUIElementRef win = (AXUIElementRef)CFArrayGetValueAtIndex(windows, i);
            CFTypeRef posValue = NULL, sizeValue = NULL;
            CGPoint pos = {0, 0};
            CGSize size = {0, 0};

            AXError perr = AXUIElementCopyAttributeValue(win, kAXPositionAttribute, &posValue);
            if (perr == kAXErrorSuccess && posValue) {
                AXValueGetValue((AXValueRef)posValue, kAXValueCGPointType, &pos);
                CFRelease(posValue);
            }
            AXError serr = AXUIElementCopyAttributeValue(win, kAXSizeAttribute, &sizeValue);
            if (serr == kAXErrorSuccess && sizeValue) {
                AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);
                CFRelease(sizeValue);
            }

            CFStringRef title = NULL;
            char titleBuf[256] = "(no title)";
            AXError terr = AXUIElementCopyAttributeValue(win, kAXTitleAttribute, (CFTypeRef *)&title);
            if (terr == kAXErrorSuccess && title) {
                CFStringGetCString(title, titleBuf, sizeof(titleBuf), kCFStringEncodingUTF8);
                CFRelease(title);
            }

            printf("  win[%ld]: poserr=%d sizeerr=%d titleerr=%d pos=(%.1f,%.1f) size=(%.1fx%.1f) title='%s'\n",
                   (long)i, (int)perr, (int)serr, (int)terr, pos.x, pos.y, size.width, size.height, titleBuf);
        }
        CFRelease(windows);
    }
    return 0;
}
