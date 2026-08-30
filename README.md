# Crucible

A disposable-VM test harness for Omarchy plugins. Point it at any plugin
directory; it deploys the plugin into a QEMU VM that starts identically
blank every run — installed and enabled the way a real end user's machine
would, not your own already-tweaked desktop — and hands you back a
screenshot and a pass/fail.

```bash
crucible fetch-iso              # download + checksum-verify the official Omarchy ISO
crucible build-golden           # unattended install once, produces a reusable base image
crucible test ~/path/to/plugin  # deploy + validate + enable + restart + IPC check + screenshot
```

## Why

A plugin can ship full unit-test coverage and a clean `omarchy plugin
validate` and still break the moment a real stranger installs it, because it
only ever ran on its author's own desktop — a first-run state pure-logic
tests structurally can't see. Two real bugs in
[Bolt](https://github.com/j0achim/omarchy-bolt) (an invisible sparkline, a
history panel that looked empty) were both like this: every existing check
passed, and the bug was only visible by eye, on a fresh install.

## Automated vs. manual

- `--headless` (default, CI-safe): boot → provision → deploy → enable →
  restart → IPC checks → screenshot → tear down.
- `--handoff`: the same automated gate, but on success the VM is left
  running with a VNC display exported (`vncviewer 127.0.0.1:0` or
  `remote-viewer vnc://127.0.0.1:5900`, no password) instead of torn down,
  so you can walk
  [Omarchy's own pre-publish checklist](https://omarchyplugins.com/develop.html)
  by hand against a guaranteed-fresh session. CI never uses this mode —
  there's no one there to look.

Automating the checks doesn't remove the need for a human to actually look;
it removes the excuse not to, by making "fresh VM" free instead of a chore.

## Adopting Crucible in a plugin repo

Nothing plugin-specific is hardcoded in Crucible. It reads the plugin's
`id` from its own `manifest.json`, and looks for three optional,
convention-named scripts in the plugin repo:

| File | Runs | Purpose |
|---|---|---|
| `test/provision.sh` | via sudo, on the guest, before deploy | Install OS packages the plugin needs beyond stock Omarchy |
| `test/check.sh` | as the guest user, after `omarchy restart shell` | Plugin-specific IPC smoke checks (e.g. `omarchy-shell <verb> list`) |
| `test/run.sh` | on the host, no VM | Fast pure-logic tests / `omarchy plugin validate` — run this in CI on every push; it needs no VM |

None are required. A plugin with no `test/` directory at all still gets
validated, deployed, enabled, and screenshotted using Omarchy's own defaults.

## Two deploy modes

- `--mode everyday` (default): copies the plugin's working tree as-is —
  fast, sees uncommitted changes, but skips the real `omarchy plugin add`
  path (URL safety check, clone-then-validate-then-move).
- `--mode fidelity`: commits must already exist (even on a throwaway branch
  — `git clone file://` only ever sees committed refs); goes through the
  real `omarchy plugin add file://...` path a real installer uses. Run this
  once before tagging a release, not on every iteration.

## How it works

`vendor/omarchy-iso-harness/` is a vendored copy of
[omacom/omarchy-iso](https://github.com/omacom/omarchy-iso)'s own official
QEMU test harness (MIT-licensed; see `vendor/omarchy-iso-harness/LICENSE`)
— the same tooling the Omarchy team uses to test the ISO itself. It already
does everything the "disposable VM" half of this problem needs: unattended
`cidata` autoinstall (see
[omarchy.org/manual/unattended-installs](https://omarchy.org/manual/unattended-installs/)),
a reusable base image with a throwaway per-run overlay, QMP-screendump
screenshots, and SSH via an ed25519 key. `base-test.sh` carries a few small,
clearly-marked additions on top (a `scp_to_guest` helper, autologin baked
into the base image — a normal install deliberately doesn't autologin, which
is correct for a real machine and wrong for a disposable always-fresh test
VM; see `kb/systems/omarchy-cidata-autologin.md` in the project vault for
why). `plugin-deploy-test.sh` and `install-only-test.sh` are Crucible's own
scenarios, added via the same `test/integration.d/<name>-test.sh` convention
the upstream tool defines for extension.

The base image and every QEMU artifact are local build outputs, cached
under `~/.cache/crucible/` and `vendor/omarchy-iso-harness/test-runs/` —
never committed, never distributed as a binary. Delete them any time;
`crucible fetch-iso`/`build-golden` regenerate what's missing, unattended.
