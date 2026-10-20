#!/bin/bash
# The WordPlus RTC client for Swift the calls run on: LiveKit's Swift SDK with WordPlus Mesh's patch, whose module is
# LiveKit. Copied from a build of it into Vendor/rtc-client-swift/ (its Sources, LICENSE, NOTICE, VERSION and the patch
# it was built from), so Swift Package Manager installs it with this package from its tags. Package.swift's targets
# LiveKit and LKObjCHelpers are its sources; its dependencies must be the build's own, which this prints.
#
#   scripts/rtc-client.sh <a build of the client>      (the mesh repository's clients/swift/build.sh makes one)
set -euo pipefail
cd "$(dirname "$0")/.."

from=${1:?usage: scripts/rtc-client.sh <a build of the WordPlus RTC client for Swift>}
if [ ! -f "$from/VERSION" ] || [ ! -d "$from/Sources/LiveKit" ]; then
    echo "$from is no build of the client: it has no VERSION or Sources/LiveKit" >&2
    exit 1
fi

mkdir -p Vendor/rtc-client-swift
rsync -a --delete --exclude Package.swift "$from"/ Vendor/rtc-client-swift/
echo "Vendor/rtc-client-swift: the WordPlus RTC client for Swift $(cat Vendor/rtc-client-swift/VERSION)"
echo "Its dependencies, which Package.swift must have:"
grep '\.package(' "$from/Package.swift" | sed 's/^ */  /'
