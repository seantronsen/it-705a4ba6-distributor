# shellcheck shell=bash
# Every suite lib, for test files to source in one line. Each lib still sources what it needs
# itself (and has an include guard), so sourcing one lib alone keeps working.

[[ -n ${_IT_HARNESS_SH:-} ]] && return 0
_IT_HARNESS_SH=1

source "$(dirname "${BASH_SOURCE[0]}")/github.sh"
source "$(dirname "${BASH_SOURCE[0]}")/git.sh"
source "$(dirname "${BASH_SOURCE[0]}")/wait.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/crafted.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/distributor.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/install.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/keys.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/lifecycle.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/poll.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/state.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/suite.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/target.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/workflow.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../pipeline/lib/keyring.sh"
source "$(dirname "${BASH_SOURCE[0]}")/../pipeline/lib/service.sh"
source "$(dirname "${BASH_SOURCE[0]}")/suite/s3.sh"
