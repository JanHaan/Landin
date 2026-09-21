#!/bin/sh
#  Render the documentation and package it.
#
#  Render the specification, tour, prototypes and the Markdown guides
#  selected by the renderer's DOCS and GUIDES lists. The
#  render is verified word-for-word against its sources, so a page that
#  quietly lost a paragraph fails here rather than going up.
#
#  This renders and packages; it does not publish.  Publication is
#  .github/workflows/pages.yml, which deploys www.701.dev from GitHub
#  Pages on every push to main.  The --publish option that uploaded to
#  pages.sr.ht went with the SourceHut gate: its approval guard cannot
#  pass a revision no gate accepted, so from 0.2.0 it could only refuse.
#
#  Usage: scripts/site.sh

. "$(dirname -- "$0")/env.sh"

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
