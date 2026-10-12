---
status: approved
issue: none (issues are disabled on this repository)
author: olafkfreund
---

# Intent: Install, run and manage the Googlebook VM from nixarchy

## Problem

The Googlebook (lapis) VM works, but only as a checkout of shell and Python
scripts run by hand, in order, from the repository root. On a nixarchy machine
that falls short in five ways:

1. **Nothing is installed declaratively.** The README's prerequisites are an
   Arch `pacman` line. On NixOS the tools (QEMU with Venus, virglrenderer,
   erofs-utils, lz4, e2fsprogs, Python, the NDK and Meson for guest Mesa) have
   to be found and put on `PATH` by hand, and nothing survives as config.
2. **Code and state are the same directory.** Every script writes its outputs
   next to itself (`HERE`, and `ROOT = Path(__file__).parent` in
   `make_lapis_security_port.py` for `--initrd`, `--venus-lib`, `--virgl-dir`).
   Installed into `/nix/store`, which is read-only, none of it can run.
3. **It is not a desktop app.** `boot_vm.sh` needs three positional arguments,
   kills the VM after `SECS` seconds (`timeout`), hides QEMU's exit status
   (`|| true`), and runs with `-monitor none`, so nothing can ask whether the VM
   is up or shut it down cleanly. There is no menu row, no keybinding, no status.
4. **The VM cannot see host files.** There is no way to move a file between the
   host and Android apps other than the network.
5. **Downloads are not verified.** The recovery image, the CI kernel modules
   (loaded into the guest kernel) and the Cuttlefish donor binaries (KeyMint,
   Gatekeeper) are fetched over HTTPS and used without a pinned checksum. The
   recovery script prints a sha256 but never compares it.

## Proposed outcome

On a nixarchy machine, the user can:

- add one flake input and one line of config, rebuild, and have every tool the
  pipeline needs and the Omarchy plugin installed — no `pacman`, no manual
  `PATH`;
- open the plugin from the Omarchy menu (and a key chord) and see one of:
  *not set up*, *building (step N of M)*, *stopped*, *running*, *failed (log)*;
- run first-time setup from there: download, verify, prepare, build the image,
  with progress and a log, resumable after an interruption;
- start, stop (graceful Android shutdown), and force-stop the VM, and open its
  serial log;
- reach a shared host folder from inside Android with an Android file manager,
  reading and writing, and see changes on the host side;
- rebuild the image on purpose, with the existing "this discards your VM data"
  guard kept intact;
- remove it all by deleting the config line and the state directory.

The existing scripts keep working from a plain checkout for non-Nix users.

## Affected users and systems

- This repository: scripts, Python tools, README.
- nixarchy hosts that opt in (p620 first; it has KVM and a Vulkan GPU).
- `/etc/nixos`: one flake input and one host module, in the shape of
  `hosts/common/nixos/omarchy-microvm.nix`.
- The user's `~/.config/omarchy/plugins/`, `~/.config/hypr/` and an XDG state
  directory for the ~40 GB of images.

## Constraints

- **Follow the existing nixarchy plugin pattern**, as in `nixarchy-microvm` and
  `nixarchy-winvm`: the flake exposes `packages.default` (plain file copies —
  `omarchy-plugin-validate` rejects symlinks), a `homeManagerModules.default`,
  and `checks`; the host wires it with
  `programs.nixarchy.plugins."<id>".src`. Enabling the plugin stays runtime
  state (`omarchy plugin enable`); keybindings go in a `pcall(require, ...)`
  fragment, never a bare `require`.
- **Menu-first and keyboard-driven**, with no second Quickshell process, the
  same as `nixarchy.winvm`.
- **Google's recovery image is never put in the Nix store or redistributed.**
  It is downloaded at runtime into the user's state directory. The same goes for
  the donor and kernel modules (their licences and size).
- **Never destroy VM state silently.** Rebuilding the image keeps the
  `GBOS_FORCE` guard; uninstalling the flake does not delete images.
- **The shared folder must not expose the whole home directory by default.**
  Every Android app with storage permission can read whatever is shared,
  including `~/.ssh`, `~/.gnupg` and browser profiles. The default is a
  dedicated folder (for example `~/Googlebook`); sharing more is an explicit,
  documented opt-in.
- **Checksums are pinned** for every download whose content is fixed by a build
  number, and a mismatch stops the pipeline.
- Rootless: no `libvirtd`, no setuid; the user needs only `/dev/kvm` access
  (the `kvm` group).
- The checkout workflow (README steps 1–7) keeps working.

## What "100% without problems" can and cannot mean

Stating these now so the spec does not promise them:

- This is a proprietary *user* build with hardware security replaced by
  software. Play Integrity / SafetyNet strong attestation, StrongBox, and DRM
  that needs hardware keys will not pass, by design.
- There is no guest agent in Android for QEMU, so **host↔guest clipboard and
  dynamic resize are not expected** in this task.
- First boot is slow (dexopt on a fresh 16 GiB userdata); later boots are fast.

## Open questions

1. **Shared folder mechanism.** Candidates for the spec to evaluate on the real
   guest, in order of how little they change the image:
   - QEMU `usb-mtp` (host directory exposed as an MTP device) — no image change,
     but Android as an MTP *host* is not a given;
   - virtio-fs (`virtiofsd` on the host + a mount in an init `.rc` under the
     shared storage) — best semantics, needs the guest module and SELinux
     labels, and a vendor-image change;
   - 9p over virtio — as above, slower, simpler host side;
   - an SMB or WebDAV share on the host's slirp address `10.0.2.2` — no image
     change, but needs a client app inside Android.
   Approve the intent with the evaluation left to the spec, or name a preferred
   mechanism now?
2. **What is shared by default?** A dedicated `~/Googlebook` folder (proposed),
   or `~/Downloads`, or the whole of `$HOME`? (The last is discouraged above.)
3. **Guest Mesa.** Build `libvulkan_virtio.so` and the VirGL GLES libraries as a
   Nix derivation (reproducible, cached, needs NDK r30 packaged in Nix), or keep
   building them at runtime with `build_guest_mesa.sh` as now?
4. **Where the plugin lives.** In this repository (the flake ships only the
   plugin files, like `nixarchy-microvm`), or a separate `nixarchy-googlebook`
   repository with this one as its input? Proposed: this repository.
5. **Plugin id and chord.** Proposed id `nixarchy.googlebook`, chord
   `SUPER + ALT + G` (to be checked free with `hyprctl binds -j` on p620).
6. **Also in scope?** Guest audio via the existing `virtio_snd` module and
   PipeWire, and USB passthrough. Proposed: audio yes (small), USB no.
