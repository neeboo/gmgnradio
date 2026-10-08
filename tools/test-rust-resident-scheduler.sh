#!/bin/sh
# Runs only a private temporary daemon and synthetic model invocations.
set -eu
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
binary=${1:-"$root/target/debug/gmgn-taskd"}
test -x "$binary"
work=$(mktemp -d /tmp/gmgn-scheduler-harness.XXXXXX)
trap 'if [ -d "$work" ]; then rm -r "$work"; fi' EXIT HUP INT TERM
flags=$(sh tools/world-runtime-harness-flags.sh)
# Helper output is one compiler argument per line, with repository-owned paths.
set -f
IFS='
'
set -- $flags
unset IFS
/usr/bin/swiftc -j1 -swift-version 6 -parse-as-library \
  apps/macos/Sources/GMGNRadio/Presence/RetryBackoff.swift \
  apps/macos/Sources/GMGNRadio/Presence/RustResidentSchedulerClient.swift \
  apps/macos/Sources/GMGNRadio/Presence/RustResidentSchedulerHTTPClient.swift \
  apps/macos/Sources/GMGNRadio/Presence/WorldAuthorityClient.swift \
  apps/macos/Sources/GMGNRadio/Presence/TaskdHTTPTransport.swift \
  apps/macos/Sources/GMGNRadio/Agent/ResidentAgentLoop.swift \
  apps/macos/Sources/GMGNRadio/Agent/ResidentSteeringDelivery.swift \
  apps/macos/Sources/GMGNRadio/Agent/ResidentMemoryStore.swift \
  apps/macos/Sources/GMGNRadio/Agent/ResidentStateClient.swift \
  apps/macos/UnityHost/UnityResidentAgentLoopBridge.swift \
  tools/test-rust-resident-scheduler.swift "$@" -o "$work/acceptance"
"$work/acceptance" "$binary"
