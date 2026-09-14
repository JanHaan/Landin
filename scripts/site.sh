#!/bin/sh
#  Render the documentation and package it for pages.sr.ht.
#
#  Render the specification, tour, prototypes and the Markdown guides
#  selected by the renderer's DOCS and GUIDES lists. The
#  render is verified word-for-word against its sources, so a page that
#  quietly lost a paragraph fails here rather than going up.
#
#  Usage: scripts/site.sh [--publish]

. "$(dirname -- "$0")/env.sh"

# Both SourceHut and direct publication validate canonical approval before
# rendering, private-font access, or publisher invocation.
if [ "${1:-}" = "--publish" ]; then
    python3 "$LANDIN_ROOT/scripts/ci/approval.py" --root "$LANDIN_ROOT"
    exec python3 "$LANDIN_ROOT/scripts/ci/publish.py" --root "$LANDIN_ROOT"
fi

Site="$LANDIN_ROOT/docs/site/site"
Tarball="$LANDIN_ROOT/docs/site/landin-site.tar.gz"

rm -rf "$Site"
python3 "$LANDIN_ROOT/docs/site/render_html.py" --from "$LANDIN_ROOT" --verify

#  pages.sr.ht accepts directories and regular files of mode 644, and
#  nothing else.
find "$Site" -type d -exec chmod 755 {} +
find "$Site" -type f -exec chmod 644 {} +

rm -f "$Tarball"
tar -C "$Site" -czf "$Tarball" .
echo "packaged: docs/site/landin-site.tar.gz ($(wc -c < "$Tarball") bytes)"
