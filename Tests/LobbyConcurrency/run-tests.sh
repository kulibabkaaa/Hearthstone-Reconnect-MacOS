#!/bin/zsh
set -euo pipefail

project_dir="${0:A:h:h:h}"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/hs-reconnect-lobby-tests.XXXXXX")"
trap 'rm -rf -- "${build_dir}"' EXIT

xcrun swiftc \
  -swift-version 5 \
  -D DEBUG \
  -o "${build_dir}/LobbyConcurrencyTests" \
  "${project_dir}/Shared/AppCore/LobbyInfoCore.swift" \
  "${project_dir}/Shared/AppCore/LobbyReconnectCore.swift" \
  "${project_dir}/Shared/AppCore/ReconnectButtonCore.swift" \
  "${project_dir}/Shared/AppCore/ReconnectButtonVisibility.swift" \
  "${project_dir}/App/LobbyLeaderboardStore.swift" \
  "${project_dir}/App/LobbyReader.swift" \
  "${project_dir}/App/LobbyCoordinator.swift" \
  "${project_dir}/App/HearthstoneWindowTracker.swift" \
  "${project_dir}/Tests/LobbyConcurrency/main.swift"

"${build_dir}/LobbyConcurrencyTests"
