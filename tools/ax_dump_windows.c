#include <ApplicationServices/ApplicationServices.h>
#include <Carbon/Carbon.h>
#include <stdio.h>

/* Debug tool: dumps every window's AX-reported title/position/size for
 * every running process, no click required -- lets us compare AX-reported
 * geometry directly against a screencapture -x screenshot's real pixel
 * coordinates, to isolate whether the bug is in AX geometry itself vs.
 * window selection/matching. */

int main(void) {
    Boolean trusted = AXAPIEnabled();
    printf("AXAPIEnabled() = %d\n", trusted);

    CGDirectDisplayID display = CGMainDisplayID();
    printf("main display bounds: %.0fx%.0f\n",
           CGDisplayPixelsWide(display), CGDisplayPixelsHigh(display));

    ProcessSerialNumber psn = { kNoProcess, kNoProcess };
    while (GetNextProcess(&psn) == noErr) {
        pid_t pid;
        if (GetProcessPID(&psn, &pid) != noErr) continue;

        AXUIElementRef appElem = AXUIElementCreateApplication(pid);
        if (!appElem) continue;

        CFArrayRef windows = NULL;
        if (AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute, (CFTypeRef *)&windows) == kAXErrorSuccess && windows) {
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
                if (size.width < 1 && size.height < 1) continue;

                CFStringRef title = NULL;
                char titleBuf[256] = "(no title)";
                if (AXUIElementCopyAttributeValue(win, kAXTitleAttribute, (CFTypeRef *)&title) == kAXErrorSuccess && title) {
                    CFStringGetCString(title, titleBuf, sizeof(titleBuf), kCFStringEncodingUTF8);
                    CFRelease(title);
                }

                printf("pid=%-6d pos=(%.0f,%.0f) size=(%.0fx%.0f) title='%s'\n",
                       pid, pos.x, pos.y, size.width, size.height, titleBuf);
            }
            CFRelease(windows);
        }
        CFRelease(appElem);
    }
    return 0;
}
