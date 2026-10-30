# shellcheck shell=bash
# The distro tests' container images, from the settings the launcher passes.

[[ -n ${_IT_IMAGES_SH:-} ]] && return 0
_IT_IMAGES_SH=1

################################################################################
# An image.
# Globals:
#   IT_IMAGE_FEDORA, IT_IMAGE_DEBIAN, IT_IMAGE_VERSITYGW
# Outputs:
#   The image on stdout.
################################################################################
images__fedora() { echo "$IT_IMAGE_FEDORA"; }
images__debian() { echo "$IT_IMAGE_DEBIAN"; }
images__versitygw() { echo "$IT_IMAGE_VERSITYGW"; }
