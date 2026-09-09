#!/bin/sh
# move-complete.sh <base_path> <finished_dir>
#
# Called by rtorrent's event.download.finished to move a finished download
# into /output/complete[/<tag>]. Wrapped in a script (instead of chaining
# several execute= calls in rtorrent.rc) because rtorrent >= 0.10 only runs
# the first execute in a multi-command event reliably.

SRC="$1"
DST="$2"

[ -n "$SRC" ] || exit 0
[ -n "$DST" ] || exit 0

mkdir -p "$DST" || exit 1
cp -a "$SRC" "$DST" || exit 1
exit 0
