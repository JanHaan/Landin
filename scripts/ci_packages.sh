#!/bin/sh
# Verify installed packages first. Only missing or mismatched packages use apt.
set -eu

packages_ready() {
    for spec do
        package=${spec%%=*}
        status=$(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) || return 1
        [ "$status" = installed ] || return 1
        case "$spec" in
            *=*)
                version=$(dpkg-query -W -f='${Version}' "$package") || return 1
                [ "$version" = "${spec#*=}" ] || return 1
                ;;
        esac
    done
}

[ "$#" -gt 0 ] || { echo 'usage: ci_packages.sh PACKAGE[=VERSION] ...' >&2; exit 2; }
for spec do
    case "$spec" in
        [a-z0-9]*) ;;
        *) echo "invalid package: $spec" >&2; exit 2 ;;
    esac
    case "$spec" in
        *[!a-zA-Z0-9+.~:=_-]*) echo "invalid package: $spec" >&2; exit 2 ;;
    esac
done

if packages_ready "$@"; then
    echo "landin: installed packages verified: $*"
else
    sudo apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        -o Acquire::Retries=3 update -qq
    sudo apt-get -o Acquire::http::Timeout=30 -o Acquire::https::Timeout=30 \
        -o Acquire::Retries=3 install -y --no-install-recommends "$@"
    packages_ready "$@" || { echo 'landin: installed package identity mismatch' >&2; exit 1; }
fi
