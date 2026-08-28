#!/bin/sh
#  Render the documentation and package it for pages.sr.ht.
#
#  Every document in the repository that a reader might want is rendered:
#  the specification, the four prototypes, and the Markdown guides.  The
#  render is verified word-for-word against its sources, so a page that
#  quietly lost a paragraph fails here rather than going up.
#
#  Usage: scripts/site.sh [--publish]

. "$(dirname -- "$0")/env.sh"

Site="$LANDIN_ROOT/docs/site/site"
Tarball="$LANDIN_ROOT/docs/site/landin-site.tar.gz"
Domain="${LANDIN_PAGES_DOMAIN:-www.701.dev}"
#  pages.sr.ht serves one site per domain and cannot redirect,
#  so the bare name is published too rather than going stale.
Alias="${LANDIN_PAGES_ALIAS:-701.dev}"

rm -rf "$Site"
python3 "$LANDIN_ROOT/docs/site/render_html.py" --from "$LANDIN_ROOT" --verify

#  pages.sr.ht accepts directories and regular files of mode 644, and
#  nothing else.
find "$Site" -type d -exec chmod 755 {} +
find "$Site" -type f -exec chmod 644 {} +

rm -f "$Tarball"
tar -C "$Site" -czf "$Tarball" .
echo "packaged: docs/site/landin-site.tar.gz ($(wc -c < "$Tarball") bytes)"

if [ "${1:-}" = "--publish" ]; then
    if ! command -v hut >/dev/null 2>&1; then
        echo "landin: hut is not installed; see docs/site/README.md" >&2
        exit 127
    fi
    #  A render without the licensed code face is a render, and a page
    #  published without it is the site quietly set in a fallback.  The
    #  checkout it comes from is private; see assets/fonts/README.md.
    if ! python3 "$LANDIN_ROOT/assets/fonts.py" --require; then
        echo "landin: not publishing without every face; see assets/fonts/README.md" >&2
        exit 1
    fi
    hut pages publish -d "$Domain" "$Tarball"
    echo "published: https://$Domain"
    if [ -n "$Alias" ]; then
        hut pages publish -d "$Alias" "$Tarball"
        echo "published: https://$Alias"
    fi
fi
