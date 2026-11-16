#!/bin/sh
# External diff tool for PDFs, driven from IntelliJ.
#
# IntelliJ materialises each side of a diff into a temp file and hands us the two
# paths. We answer with the two things its own viewer can't show for a binary:
#
#   1. a side-by-side render at device resolution, plus the byte sizes, as an image tab
#   2. the decompressed PDF source of both sides, in IntelliJ's own diff viewer
#      (git textconv only applies to git's internal diff, never to an external tool)
#
# Setup, Settings > Tools > Diff & Merge > External Diff Tools:
#   1. Enable external tools, then add a tool in the "diff" group
#        Program path:      <repo>/scripts/assets/pdf_diff_intellij.sh
#        Argument pattern:  %1 %2
#   2. In "Configure external diff/merge tools associated with a file type", add a row
#        File Type: Native     Diff Tool: pdf_diff_intellij.sh
#      Native is where IntelliJ files .pdf by default (with doc, docx, hlp, mdb, odt,
#      ppt, pptx, vsd). That association is what makes a plain Show Diff / double-click
#      in the Git log open this instead of "Cannot show file". Leave "use by default"
#      off so ordinary code diffs keep the built-in viewer.
#
# Because Native is broader than PDF, anything that is not a PDF falls through to a
# plain text diff of the two files rather than failing.
#
# Requires: mutool, qpdf, python3 + pillow.
set -u

LEFT="$1"
RIGHT="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
# Override for a Toolbox install, a different IDE, or a test stub.
IDEA="${IDEA_LAUNCHER:-/Applications/IntelliJ IDEA.app/Contents/MacOS/idea}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/pdfdiff.XXXXXX")"

open_in_idea() {
  if [ -x "$IDEA" ]; then "$IDEA" "$@"; else open "$@"; fi
}

is_pdf() { [ "$(head -c 4 "$1" 2>/dev/null)" = "%PDF" ]; }

if ! is_pdf "$LEFT" && ! is_pdf "$RIGHT"; then
  open_in_idea diff "$LEFT" "$RIGHT"
  exit 0
fi

# Decompressed source of both sides. Suffixed .txt so IntelliJ treats them as text
# rather than handing them back to this same tool.
dump() {
  qpdf --qdf --decode-level=all --object-streams=disable --no-original-object-ids \
       "$1" - > "$2" 2>/dev/null || echo "(not readable as a PDF)" > "$2"
}
dump "$LEFT" "$OUT/before.pdf.txt"
dump "$RIGHT" "$OUT/after.pdf.txt"

# The render is best-effort: a broken or non-PDF side must not cost us the text diff.
if python3 "$HERE/pdf_visual_diff.py" "$LEFT" "$RIGHT" -o "$OUT/visual.png" >/dev/null 2>&1; then
  open_in_idea "$OUT/visual.png"
fi
open_in_idea diff "$OUT/before.pdf.txt" "$OUT/after.pdf.txt"
