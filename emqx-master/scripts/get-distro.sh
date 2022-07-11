#!/usr/bin/env bash

## This script prints Linux distro name and its version number
## e.g. macos, el8, ubuntu20.04

set -euo pipefail

UNAME="$(uname -s)"

case "$UNAME" in
    Darwin)
        DIST='macos'
        VERSION_ID="$(sw_vers | grep 'ProductVersion' | cut -d':' -f 2 | cut -d'.' -f1 | tr -d ' \t')"
        SYSTEM="${DIST}${VERSION_ID}"
        ;;
    Linux)
        if grep -q -i 'rhel' /etc/*-release; then
            DIST='el'
            VERSION_ID="$(rpm --eval '%{rhel}')"
        else
            DIST="$(sed -n '/^ID=/p' /etc/os-release | sed -r 's/ID=(.*)/\1/g' | sed 's/"//g')"
            VERSION_ID="$(sed -n '/^VERSION_ID=/p' /etc/os-release | sed -r 's/VERSION_ID=(.*)/\1/g' | sed 's/"//g')"
        fi
        SYSTEM="$(echo "${DIST}${VERSION_ID}" | sed -r 's/([a-zA-Z]*)-.*/\1/g')"
        ;;
    CYGWIN*|MSYS*|MINGW*)
        SYSTEM="windows"
        ;;
esac

echo "$SYSTEM"
