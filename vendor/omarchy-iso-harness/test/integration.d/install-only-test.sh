#!/bin/bash
#
# Crucible scenario (not upstream omarchy-iso): a no-op scenario whose only
# purpose is to drive install_phase (via ./test/integration's own "run
# install unless --reuse-base finds a base image" logic) without also
# running an unrelated scenario. `crucible build-golden` targets this.

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

check "base image exists after install_phase" base_image_ready
finish
