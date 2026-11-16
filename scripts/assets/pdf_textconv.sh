#!/bin/sh
# git textconv filter for PDFs.
#
# Without it `git diff` on an asset says "Binary files differ" and stops. qpdf's QDF
# mode rewrites the file with every stream decompressed and one token per line, so a
# moved arrow or a changed stroke width shows up as an ordinary text hunk.
#
# --no-original-object-ids drops the "%% Original object ID" comments, which otherwise
# renumber on every re-export and bury the real change in noise.
#
# Wired up by .gitattributes (*.pdf diff=pdf) plus a one-time, per-clone:
#   git config diff.pdf.textconv scripts/assets/pdf_textconv.sh
# It is per-clone because git will not let a repo ship code that it then executes.
exec qpdf --qdf --decode-level=all --object-streams=disable --no-original-object-ids "$1" - 2>/dev/null
