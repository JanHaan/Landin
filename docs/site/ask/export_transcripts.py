#!/usr/bin/env python3
"""Export private transcripts as JSONL without printing the administrator key."""
import argparse
import json
from pathlib import Path
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", required=True, help="trusted Worker origin")
    parser.add_argument("--secrets", type=Path, default=Path(__file__).parent / ".dev.vars")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    url = urllib.parse.urlsplit(args.url)
    local = url.hostname in ("localhost", "127.0.0.1", "::1")
    if (url.scheme != "https" and not (local and url.scheme == "http")) or url.username or url.password:
        parser.error("use HTTPS, or HTTP on localhost, without URL credentials")
    if url.path not in ("", "/") or url.query or url.fragment:
        parser.error("--url must be an origin without path, query or fragment")
    secrets = dict(line.split("=", 1) for line in args.secrets.read_text().splitlines()
                   if "=" in line and not line.lstrip().startswith("#"))
    key = secrets.get("ADMIN_KEY", "")
    if len(key) < 32:
        parser.error("configure ADMIN_KEY in the secrets file")
    opener = urllib.request.build_opener(NoRedirect())
    origin = args.url.rstrip("/")
    count, cursor = 0, "0"
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation prevents overwriting a previous review export.
    with args.output.open("x", encoding="utf-8") as output:
        args.output.chmod(0o600)
        while True:
            request = urllib.request.Request(origin + "/api/transcripts?cursor=" + cursor,
                                             headers={"X-Admin-Key": key,
                                                      "User-Agent": "LandinTranscriptExporter/1.0"})
            with opener.open(request, timeout=30) as response:
                raw = response.read(1_000_001)
            if len(raw) > 1_000_000:
                raise SystemExit("export page exceeded its size limit")
            page = json.loads(raw)
            for record in page["records"]:
                output.write(json.dumps(record, ensure_ascii=False) + "\n")
                count += 1
            following = page.get("nextCursor")
            if following is None:
                break
            if not str(following).isdigit() or int(following) <= int(cursor):
                raise SystemExit("export cursor did not advance")
            cursor = str(following)
    print(f"Exported {count} transcripts to {args.output}")


if __name__ == "__main__":
    main()
