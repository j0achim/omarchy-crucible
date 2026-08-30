#!/bin/bash
#
# Crucible scenario (not upstream omarchy-iso): deploys a third-party Omarchy
# plugin into a throwaway overlay of the base image, exercises the same
# install → enable → restart → IPC path a real end user goes through, and
# captures a screenshot. Configured entirely by environment variables set by
# ../../../../bin/crucible, so this file has no plugin-specific logic in it —
# see that script for the CLI surface.
#
# Required:
#   CRUCIBLE_PLUGIN_DIR   Path to the plugin's working tree (must contain manifest.json)
# Optional:
#   CRUCIBLE_MODE         everyday (default, copies the working tree as-is,
#                         sees uncommitted changes) | fidelity (commits must
#                         already exist; goes through the real `omarchy
#                         plugin add file://...` path)
#   CRUCIBLE_SECTION      left | center | right (default: right)
#   CRUCIBLE_HANDOFF      true to leave the VM running with a VNC display
#                         exported for manual inspection instead of tearing
#                         down after the automated checks (default: false)

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"

base_image_ready || { echo "No base image; run this through ./test/integration" >&2; exit 1; }

PLUGIN_DIR="${CRUCIBLE_PLUGIN_DIR:?CRUCIBLE_PLUGIN_DIR must be set}"
MODE="${CRUCIBLE_MODE:-everyday}"
SECTION="${CRUCIBLE_SECTION:-right}"
HANDOFF="${CRUCIBLE_HANDOFF:-false}"

[[ -f "$PLUGIN_DIR/manifest.json" ]] || { echo "No manifest.json under $PLUGIN_DIR" >&2; exit 1; }
PLUGIN_ID=$(jq -r '.id' "$PLUGIN_DIR/manifest.json")
[[ -n $PLUGIN_ID && $PLUGIN_ID != null ]] || { echo "manifest.json has no id" >&2; exit 1; }

STAGING=/tmp/crucible-plugin-src

if [[ $HANDOFF == "true" ]]; then
  log "Booting with a VNC display exported (handoff mode)"
  start_vm_from_base -vnc :0

  # Print the connect command the instant the VNC server actually accepts
  # connections — not after the automated checks finish minutes later. It's
  # listening from boot, well before deploy even starts, so there's no
  # reason to make anyone wait for it.
  vnc_wait=0
  until timeout 1 bash -c "echo >/dev/tcp/127.0.0.1/5900" 2>/dev/null; do
    if ! vm_running; then
      echo "VM exited before the VNC server ever came up" >&2
      exit 1
    fi
    ((vnc_wait += 1))
    if ((vnc_wait > 30)); then
      echo "VNC server never started listening on 127.0.0.1:5900" >&2
      exit 1
    fi
    sleep 1
  done
  log "VNC ready — connect now: \`remote-viewer vnc://127.0.0.1:5900\` or \`vncviewer 127.0.0.1:0\` (no password). Deploying in the background; the session updates live."
else
  start_vm_from_base
fi
wait_for_ssh 120

if [[ -x "$PLUGIN_DIR/test/provision.sh" ]]; then
  log "Running plugin-declared test/provision.sh"
  scp_to_guest "$PLUGIN_DIR/test/provision.sh" /tmp/crucible-provision.sh
  check "test/provision.sh (plugin-declared dependencies)" \
    ssh_sudo "bash /tmp/crucible-provision.sh"
fi

log "Deploying $PLUGIN_ID ($MODE mode)"
check "copy plugin working tree to the guest" \
  scp_to_guest "$PLUGIN_DIR" "$STAGING"

case "$MODE" in
  everyday)
    check "install into ~/.config/omarchy/plugins/$PLUGIN_ID" \
      ssh_guest "mkdir -p ~/.config/omarchy/plugins && rm -rf ~/.config/omarchy/plugins/$PLUGIN_ID && cp -r $STAGING ~/.config/omarchy/plugins/$PLUGIN_ID"
    check "omarchy-plugin-validate" \
      ssh_guest "omarchy-plugin-validate ~/.config/omarchy/plugins/$PLUGIN_ID"
    check "rescanPlugins" \
      omarchy_cli "omarchy-shell shell rescanPlugins"
    check "plugin enable" \
      omarchy_cli "omarchy plugin enable $PLUGIN_ID --section $SECTION"
    ;;
  fidelity)
    [[ -d "$PLUGIN_DIR/.git" ]] || { echo "fidelity mode needs a git repo (commit first, even to a throwaway branch)" >&2; exit 1; }
    # `add` doesn't take --section, and --yes skips its own interactive
    # placement picker with no override — so add un-enabled, then enable
    # explicitly, same as everyday mode, for consistent placement control.
    check "omarchy plugin add file://... --yes" \
      omarchy_cli "omarchy plugin add file://$STAGING --yes"
    check "plugin enable" \
      omarchy_cli "omarchy plugin enable $PLUGIN_ID --section $SECTION"
    ;;
  *)
    echo "Unknown CRUCIBLE_MODE: $MODE" >&2
    exit 1
    ;;
esac

check "omarchy restart shell" \
  omarchy_cli "omarchy restart shell"

if [[ -x "$PLUGIN_DIR/test/check.sh" ]]; then
  log "Running plugin-declared test/check.sh"
  scp_to_guest "$PLUGIN_DIR/test/check.sh" /tmp/crucible-check.sh
  check "test/check.sh (plugin-declared IPC smoke checks)" \
    omarchy_cli "bash /tmp/crucible-check.sh"
fi

if ((FAILURES == 0)); then
  capture_console "success-$PLUGIN_ID"
else
  capture_console "failure-$PLUGIN_ID"
fi

if [[ $HANDOFF == "true" && $FAILURES == 0 ]]; then
  read -r -p "All automated checks passed. Press Enter here when you're done inspecting the VM to tear it down... "
fi

finish
