#include <ApplicationServices/ApplicationServices.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>

/* Standalone command-line raw-frame capture tool, no AX/window-click
 * dependency -- captures a fixed screen rect for a fixed duration via the
 * same CGDisplayBaseAddress technique proven in issues #2/#4. Built to test
 * issue #5's encode pipeline via SSH without requiring a physical click
 * (unlike WindowSelectTest.app, which needs AX + Process Manager and must
 * be double-clicked -- see window_select_capture_poc.c's header comment).
 *
 * Usage: raw_capture_cli x y w h seconds output.raw
 * Writes a headerless stream of w*h*4-byte ARGB frames (byte order:
 * pad/alpha, R, G, B -- matches window_select_capture_poc.c's raw format)
 * and prints "frames=N elapsed=S fps=F" to stdout at the end. */

int main(int argc, char **argv) {
    if (argc != 7) {
        fprintf(stderr, "usage: %s x y w h seconds output.raw\n", argv[0]);
        return 1;
    }
    int ox = atoi(argv[1]);
    int oy = atoi(argv[2]);
    int w = atoi(argv[3]);
    int h = atoi(argv[4]);
    double duration = atof(argv[5]);
    const char *outpath = argv[6];

    CGDirectDisplayID display = CGMainDisplayID();
    void *base = CGDisplayBaseAddress(display);
    size_t bpp = CGDisplayBitsPerPixel(display);
    size_t bytesPerRow = CGDisplayBytesPerRow(display);
    printf("display base=%p bpp=%zu bytesPerRow=%zu\n", base, bpp, bytesPerRow);
    fflush(stdout);

    if (!base || bpp != 32) {
        fprintf(stderr, "unexpected display format\n");
        return 1;
    }

    size_t frameBytes = (size_t)w * (size_t)h * 4;
    uint8_t *scratch = (uint8_t *)malloc(frameBytes);
    FILE *raw = fopen(outpath, "wb");
    if (!scratch || !raw) {
        fprintf(stderr, "alloc/open failed\n");
        return 1;
    }

    struct timeval t0, t1;
    gettimeofday(&t0, NULL);
    long frames = 0;
    double elapsed = 0;
    while (elapsed < duration) {
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
    free(scratch);

    printf("frames=%ld elapsed=%.3f fps=%.3f w=%d h=%d frameBytes=%zu\n",
           frames, elapsed, frames / elapsed, w, h, frameBytes);
    fflush(stdout);
    return 0;
}
