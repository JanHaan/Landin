#!/bin/sh
# Install Debian's Git package into the runner account, without sudo or
# changing its image. Re-running verifies the existing installation.
set -eu
Tools="$HOME/.local/share/landin-ci-tools"
if [ -x "$Tools/usr/bin/git" ]; then
    "$Tools/usr/bin/git" --version
    exit 0
fi
Stage="$(mktemp -d)"
trap 'rm -rf "$Stage"' EXIT
mkdir -p "$Tools"
cd "$Stage"
mkdir -p "$Tools/lists/partial"
printf '#clear APT::Update::Post-Invoke;\n' > "$Stage/apt.conf"
apt-get -c "$Stage/apt.conf" -o Dir::State::lists="$Tools/lists" update
apt-get -o Dir::State::lists="$Tools/lists" download git
for Package in ./*.deb; do
    dpkg-deb -x "$Package" "$Tools"
    sha256sum "$Package" >> "$Tools/packages.sha256"
    dpkg-deb -f "$Package" Package Version >> "$Tools/packages.txt"
done
"$Tools/usr/bin/git" --version
