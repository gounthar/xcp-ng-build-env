#!/bin/sh
# check-layer-repo.sh
# Exit 1 if an installed package is not one the enabled repos hold, compared as
# NAME-EPOCH:VERSION-RELEASE.ARCH.  Meant for --layer-repo builds, where only
# local repos are enabled: a package the base image brought and the package
# list does not name keeps its base version, and dnf says nothing about it.
set -eu
avail=$(mktemp)
inst=$(mktemp)
trap 'rm -f "$avail" "$inst"' EXIT
dnf -q repoquery --available --qf '%{name}-%{epoch}:%{version}-%{release}.%{arch}' | sort -u >"$avail"
rpm -qa --qf '%{NAME}-%{EPOCHNUM}:%{VERSION}-%{RELEASE}.%{ARCH}\n' | grep -v '^gpg-pubkey-' | sort -u >"$inst"
n=$(wc -l <"$inst")
off=$(comm -23 "$inst" "$avail")
if [ -n "$off" ]; then
  printf 'layer repo: installed but not in the local repos:\n%s\n' "$off"
  printf 'layer repo: %s of %s installed packages\n' "$(printf '%s\n' "$off" | wc -l)" "$n"
  exit 1
fi
printf 'layer repo: all %s installed packages come from the local repos\n' "$n"
