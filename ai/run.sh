#!/bin/bash

cd "$(dirname "$0")/.."
log="/tmp/alttab-run.log"
fifo="/tmp/alttab-run.fifo"
rm -f "$fifo" && mkfifo "$fifo"
# `open` launches through LaunchServices, which makes the app its OWN responsible process. TCC judges the
# responsible process, so a binary started straight from a shell is judged by the TERMINAL's grants: it read
# `accessibility:notGranted screenRecording:notGranted` and never showed the switcher, however it was signed.
#
# `--stdout` needs a real path (/dev/stdout is not connected through), and opening a fifo for writing blocks
# until a reader shows up — hence the background launch, and `tee` both streaming the log here as the app
# writes it and leaving it in "$log" to grep afterwards.
open -n --stdout "$fifo" --stderr "$fifo" -a "$PWD/DerivedData/Build/Products/Debug/AltTab.app" \
  --args --logs=debug --benchmark showUi 3 &
tee "$log" < "$fifo"
