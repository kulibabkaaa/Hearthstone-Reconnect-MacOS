# Sourced by Scripts/build-local.sh (not run directly).
#
# HearthSim's closed HearthMirror runtime may only be built into a private, local
# prototype, and only when the owner asks for it on purpose. Default: off.
#
#   HS_RECONNECT_ALLOW_HEARTHMIRROR_LOCAL=YES   explicit opt-in
#
# Sets HearthMirror mode in the environment for xcodegen:
#   off -> HS_RECONNECT_HEARTHMIRROR is unset (the lobby helper is not generated)
#   on  -> HS_RECONNECT_HEARTHMIRROR=YES, a loud warning is printed
# and sets `hearthmirror_local_build` to "true" or "false".
#
# Usage: configure_hearthmirror_for_local_build PROJECT_DIR

hearthmirror_warning() {
  cat >&2 <<'WARNING'

################################################################################
#  WARNING: this build contains HearthSim's closed HearthMirror runtime.       #
#  HearthSim asked us to stop distributing it. This build is for YOUR OWN      #
#  Mac only. NEVER share it: no ZIP, DMG, PKG, GitHub upload, or update feed.  #
################################################################################

WARNING
}

configure_hearthmirror_for_local_build() {
  local project_dir="$1"

  # Never inherit the switch from the shell: only the explicit opt-in turns it on.
  unset HS_RECONNECT_HEARTHMIRROR
  hearthmirror_local_build=false

  [[ "${HS_RECONNECT_ALLOW_HEARTHMIRROR_LOCAL:-}" == "YES" ]] || return 0

  if [[ ! -d "${project_dir}/Vendor/HearthMirror" ]]; then
    echo "HS_RECONNECT_ALLOW_HEARTHMIRROR_LOCAL=YES is set, but Vendor/HearthMirror does not exist on this Mac." >&2
    return 1
  fi

  export HS_RECONNECT_HEARTHMIRROR=YES
  hearthmirror_local_build=true
  hearthmirror_warning
}
