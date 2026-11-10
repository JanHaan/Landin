"""One download, asked again while its server says to wait.

Every pinned download is verified by its hash after it arrives, so what
this module adds is only how a failure reads and whether it is final: a
server that answers 408, 429 or 5xx, or a connection that drops, is asked
again a bounded number of times, and anything else, 404 among them, ends
at once.  The failure names the archive, its URL, the HTTP status and the
attempts made, so an upstream outage is told from a broken pin without
reading the caller.  A hash mismatch is the caller's to refuse and is
never retried: the bytes arrived, and they are not the pinned ones.
"""
import time
import urllib.error
import urllib.request

#  Four attempts over 2 + 4 + 8 seconds: long enough for a gateway's
#  hiccup, short beside a job that would otherwise be rerun whole.
ATTEMPTS = 4
DELAY = 2.0
TRANSIENT = frozenset({408, 429, 500, 502, 503, 504})


class DownloadError(OSError):
    """A download that failed; its text is the whole report."""


def status_of(error):
    """The HTTP status ERROR carries, or None for a failure below HTTP."""
    return error.code if isinstance(error, urllib.error.HTTPError) else None


def download(url, name, consume, *, opener=None, timeout=60, attempts=ATTEMPTS,
             delay=DELAY, sleep=time.sleep, report=None):
    """CONSUME's result over the opened URL, which is the archive NAME.

    CONSUME takes the response and reads all of it; a connection lost
    while it reads counts as a failed attempt, so it must start its
    output afresh each time it is called.
    """
    opener = opener or urllib.request.urlopen
    said = []
    for attempt in range(1, attempts + 1):
        try:
            with opener(url, timeout=timeout) as response:
                return consume(response)
        except OSError as error:
            status = status_of(error)
            if status is not None:
                #  An HTTPError is the refused response, still open.
                error.close()
            said.append('HTTP %d %s' % (status, error.reason) if status is not None
                        else '%s: %s' % (type(error).__name__, error))
            final = status is not None and status not in TRANSIENT
            if final or attempt == attempts:
                raise DownloadError(
                    '%s: cannot fetch %s: %s%s' % (
                        name, url, said[-1],
                        '' if attempt == 1 else ' after %d attempts (%s)' % (attempt, '; '.join(said)))
                    + ('' if final else '; the server or the connection failed, not the pin:'
                       ' the same command may pass later')) from error
            wait = delay * 2 ** (attempt - 1)
            if report:
                report('%s: %s from %s; attempt %d of %d in %g s'
                       % (name, said[-1], url, attempt + 1, attempts, wait))
            sleep(wait)
