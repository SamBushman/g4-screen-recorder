#!/bin/bash
# Issue #5: offline H.264 encode pass.
#
# Takes the headerless raw ARGB frame stream produced by the capture
# technique from issues #2/#4 (window_select_capture_poc.c /
# raw_capture_cli.c -- same byte layout: each frame is w*h*4 bytes, byte
# order per pixel is [pad/alpha, R, G, B]) and encodes it to a real,
# playable H.264-in-.mp4 file.
#
# Uses ffmpeg's rawvideo demuxer (-f rawvideo -pixel_format argb) piped
# straight into ffmpeg's own libx264 encoder. CONFIRMED (2026-09-08) this
# is the SAME AltiVec x264 build verified correct in issue #1, not a
# separate/different copy: `otool -L` on the Tigerbrew ffmpeg binary shows
# it dynamically links /usr/local/lib/libx264.146.dylib, which resolves to
# the identical Tigerbrew x264 r2555 :tiger_altivec bottle Cellar path
# used directly in issue #1's own A/B test, and `otool -tv` on that dylib
# shows the same real AltiVec instructions (1434 vaddu/vperm/vmladd/vmsum
# hits) confirmed there. No need to re-derive AltiVec correctness here --
# issue #1 already did that against this exact library.
#
# The real fps must be measured at capture time (frames / real elapsed
# seconds), NOT assumed to be a flat 30 -- issue #2/#4 already established
# that real achieved fps depends on window size and is usually well under
# 30 for anything much larger than ~507x507. Passing the wrong framerate
# here would produce a real, played-back-perfectly-fine .mp4 that just runs
# at the wrong real-world speed (too fast if you assume 30 but it was
# really, say, 8) -- so this script requires the real measured fps as an
# explicit argument rather than defaulting it.
#
# Usage: encode_raw_to_h264.sh input.raw width height fps output.mp4

set -e

if [ "$#" -ne 5 ]; then
    echo "usage: $0 input.raw width height fps output.mp4" >&2
    exit 1
fi

RAW="$1"
W="$2"
H="$3"
FPS="$4"
OUT="$5"

FFMPEG=/usr/local/bin/ffmpeg

START=$(date +%s)
"$FFMPEG" -y -f rawvideo -pixel_format argb -video_size "${W}x${H}" -framerate "$FPS" \
    -i "$RAW" \
    -c:v libx264 -preset medium -crf 20 -pix_fmt yuv420p \
    -movflags +faststart \
    "$OUT"
END=$(date +%s)

echo "encode_seconds=$((END - START))"
