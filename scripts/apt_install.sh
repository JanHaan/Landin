#!/bin/sh
#  Install Ubuntu packages on a GitHub-hosted runner, within a bound.
#
#      scripts/apt_install.sh [APT-GET INSTALL OPTION...] PACKAGE...
#
#  The arguments go to `apt-get install -y` as they are.  The image lists
#  Azure's Ubuntu mirror first (/etc/apt/apt-mirrors.txt); it has taken
#  eighteen minutes to deliver one 57.5 MB archive, and the stock-user job
#  spent its whole budget there before any compiler check ran.  So each
#  attempt is bounded: the index update by LANDIN_APT_UPDATE_LIMIT seconds,
#  120 by default, and the installation by LANDIN_APT_LIMIT, 360 by
#  default.  The first attempt uses the image's mirrors; when it fails or
#  runs out of time, the second uses the official archive alone,
#  archive.ubuntu.com and security.ubuntu.com, with the image's signing
#  keys.  Each attempt says which mirrors it used, how long it took and how
#  it ended, and an attempt that fails lists the partial downloads, so a
#  slow mirror shows as one.  When both fail the script fails.
#
#  It installs only what it is given: the distribution's own packages,
#  whose identity the calling job checks.

set -u

update_limit="${LANDIN_APT_UPDATE_LIMIT:-120}"
install_limit="${LANDIN_APT_LIMIT:-360}"
mirrors=/etc/apt/apt-mirrors.txt

if [ "$#" -eq 0 ]; then
    echo "usage: scripts/apt_install.sh [APT-GET INSTALL OPTION...] PACKAGE..." >&2
    exit 2
fi

say() {
    echo "apt_install: $*"
}

#  What an attempt that ran out of time or failed had got: the archives
#  still partial, with their sizes.
diagnose() {
    say "partial downloads:"
    sudo find /var/cache/apt/archives/partial -type f -printf 'apt_install:   %s bytes %f\n' 2>/dev/null
}

attempt() {
    label="$1"
    shift
    say "attempt: $label"
    if [ -f "$mirrors" ]; then
        sed 's/^/apt_install:   mirror /' "$mirrors"
    fi
    started=$(date +%s)
    #  An attempt cut short in dpkg leaves it half configured.
    sudo dpkg --configure -a
    if sudo timeout "$update_limit" apt-get update -q \
        && sudo timeout "$install_limit" apt-get install -y -q \
            -o Acquire::http::Timeout=30 -o Acquire::Retries=2 "$@"
    then
        status=0
    else
        status=$?
    fi
    elapsed=$(( $(date +%s) - started ))
    if [ "$status" -eq 0 ]; then
        say "$label: installed in ${elapsed}s"
        return 0
    fi
    if [ "$status" -eq 124 ]; then
        say "$label: out of time after ${elapsed}s"
    else
        say "$label: failed with status $status after ${elapsed}s"
    fi
    diagnose
    return 1
}

#  The official archive alone, in place of the image's mirror list or,
#  on an image without one, of every Azure route in its sources.
official() {
    if [ -f "$mirrors" ]; then
        printf '%s\n' 'http://archive.ubuntu.com/ubuntu/	priority:1' \
            'http://security.ubuntu.com/ubuntu/	priority:2' \
            | sudo tee "$mirrors" > /dev/null
    fi
    for sources in /etc/apt/sources.list /etc/apt/sources.list.d/*.sources \
                   /etc/apt/sources.list.d/*.list; do
        if [ -f "$sources" ]; then
            sudo sed -i 's|azure\.archive\.ubuntu\.com|archive.ubuntu.com|g' "$sources"
        fi
    done
    sudo rm -rf /var/cache/apt/archives/partial/*
}

if attempt "the image's mirrors" "$@"; then
    exit 0
fi
official
if attempt "the official Ubuntu archive" "$@"; then
    exit 0
fi
say "both attempts failed; the packages are not installed"
exit 1
