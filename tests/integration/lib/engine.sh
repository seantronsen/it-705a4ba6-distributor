# shellcheck shell=bash
# The container engine, podman or docker: on the host directly, and from inside the tools
# container through the host engine's socket (sibling containers, never nested ones).

[[ -n ${_IT_ENGINE_SH:-} ]] && return 0
_IT_ENGINE_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/log.sh"

#######################################
# Runs a transient container: removed on exit, SELinux relabeling off (mounts are shared
# between the host and containers).
# Globals:
#   IT_ENGINE: the engine command (podman or docker; podman-remote inside the tools container)
# Arguments:
#   The rest of the run command line: options, image, command.
# Returns:
#   The container's exit status.
#######################################
engine__run() {
  "$IT_ENGINE" run --rm --security-opt label=disable "$@"
}
