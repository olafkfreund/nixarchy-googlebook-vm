---
status: draft
issue: none (issues are disabled on this repository)
spec: spec/2026-10-12-no-issue-omarchy-plugin.md
---

# Plan: Install, run and manage the Googlebook VM from nixarchy

Branch `feat/no-issue-omarchy-plugin`. Name the step you are executing in every
commit message (`feat(cli): step 6 — googlebook-vm CLI`). A deviation updates
this file in the same commit as the code.

## Approved decisions (from the spec, self-contained)

- **State vs code.** New `GBOS_STATE`: every output goes there. The default is
  the script's own directory (`HERE`), so a checkout behaves exactly as today.
  The installed CLI sets `GBOS_STATE=${XDG_DATA_HOME:-$HOME/.local/share}/googlebook-vm`.
  Code (`*.py`, `patches/`) is still read from `HERE`.
- **Checksums.** `checksums.sha256` (`sha256sum -c` format, paths relative to
  `GBOS_STATE`) pins the recovery `.bin`, each kernel module, the donor zip, the
  NDK r30 zip and the Mesa tarball. A mismatch or a missing entry exits
  non-zero. `GBOS_UNVERIFIED=1` is the only bypass and prints a warning.
- **CLI `googlebook-vm`:** `setup | start | stop | kill | status [--json] | log
  [setup|serial] | rebuild | files` (`files` only in the fallback). Setup and the
  VM run as transient systemd **user** units (`googlebook-vm-setup`,
  `googlebook-vm`, `googlebook-vm-fs`). Status values: `unconfigured`,
  `setting-up`, `setup-failed`, `stopped`, `running`, `failed`.
- **`boot_vm.sh`**, all opt-in: `SECS=0` means no timeout; `GBOS_QMP` adds
  `-qmp unix:$GBOS_QMP,server=on,wait=off`; the exit status is kept except 124;
  `GBOS_SHARE_ARGS` (default empty); `GBOS_AUDIO_ARGS` (default
  `-audiodev pipewire,id=snd0 -device virtio-sound-pci,audiodev=snd0`);
  `GBOS_MEM` (default `6G`) feeds both `-m` and the memfd size; `-name googlebook`.
- **Share: virtio-fs.** Host:
  `virtiofsd --shared-dir DIR --socket-path $XDG_RUNTIME_DIR/googlebook-vm/fs.sock
  --sandbox none --tag host --translate-uid map:1023:$UID:1 --translate-gid map:1023:$GID:1`.
  QEMU: `-object memory-backend-memfd,id=mem,size=$GBOS_MEM,share=on -numa node,memdev=mem
  -chardev socket,id=fs0,path=… -device vhost-user-fs-pci,chardev=fs0,tag=host`.
  Guest: `--hostshare` adds `etc/init/vm-hostshare.rc` mounting `host` at
  `/data/media/0/Host` with `context=u:object_r:media_rw_data_file:s0` when
  `sys.user.0.ce_available=true`. The default shared directory is `~/Googlebook`. `$HOME`
  is never the default.
- **Pre-approved fallback** (only if step 2 says so): a sparse 16 GiB exFAT
  `GBOS_STATE/shared.img` on `-device usb-storage,bus=xhci.0`. It is not live; the
  host reaches it with `googlebook-vm files` only while the VM is stopped.
- **Plugin `nixarchy.googlebook`:** menu-only, `keepLoaded: true`, files
  `manifest.json`, `Menu.qml`, `googlebook-binds.lua`, `LICENSE`. Keys `U` setup,
  `S` start, `X` stop, `K`+`K` force stop, `F` shared folder, `L` log, `B` +
  typing `erase` rebuild, `Esc` close. It polls `googlebook-vm status --json`
  every 2 s **only while open**.
- **Flake:** `packages.{googlebook-vm,plugin,default=googlebook-vm}`,
  `devShells.default`, `homeManagerModules.default`
  (`programs.googlebook-vm.{enable,keybinding,sharedDir}`), `checks.default`.
  Guest Mesa stays a runtime build (nixpkgs NDK is r29; r30 is needed).
- **Not in scope:** USB passthrough, clipboard, dynamic resize, libvirt, a bar
  widget, packaging the NDK or recovery image in Nix.

## Corrections to the spec found while planning

1. The spec says the guest "already loads `virtio_snd.ko`". It does not:
   `make_initrd_x86.py:53` (`added = [...]`) omits it, although
   `fetch_kernel_modules.sh:32` fetches it. Step 4 adds it.
2. `make_lapis_security_port.py:337` reads `ROOT/firmware/gpt.json`, so besides
   `--hostshare` it needs a `--firmware DIR` flag (default `ROOT/firmware`).
3. The repository has **no LICENSE**. The plugin package needs one. **Decision
   needed at plan approval:** which licence (the `nixarchy.winvm` precedent is
   MIT). Step 7 is blocked until it is given; do not invent one.

## Steps

### 1. Fetch the inputs and record checksums (operator, network, ~40 GB)

In a checkout with the existing scripts, unchanged:
`./fetch_recovery_image.sh`, `./fetch_kernel_modules.sh`,
`./fetch_cuttlefish_donor.sh 16373615`, `./build_guest_mesa.sh --download-only`,
and download NDK r30 (`android-ndk-r30-linux.zip` from dl.google.com).
Write `checksums.sha256` with `sha256sum` over:
`android-desktop_signed_recovery_image.bin`, `modules/*.ko`,
`aosp_cf_x86_64_only_phone-img-16373615.zip`, `android-ndk-r30-linux.zip`,
`mesa-26.2.4.tar.xz`.
→ verify: the recovery hash equals the `sha256 …` line `fetch_recovery_image.sh`
printed; `sha256sum -c checksums.sha256` passes.
Traps: the 19 GB `.bin` and zips are gitignored. Commit only `checksums.sha256`.
`GBOS_KEEP_ZIP=1` is not needed: the `.bin` is what gets pinned, not the zip.

### 2. Probe virtio-fs, SELinux and audio support (static, no boot)

Then run `./prepare.sh` (it produces `firmware/` and `initrd`). Write the probe
as `dev/probe-guest.sh` (kept, so the decision can be re-checked on a new
recovery build). It reports:

- **(a) Kernel:** built-in if `strings firmware/kernel | grep -qx virtiofs`
  (the filesystem registers that name; if the kernel is compressed, decompress it
  first with `extract_lapis.py`'s output or `scripts/extract-vmlinux` logic). As a
  module if `virtiofs.ko` is in `system_dlkm_a:/lib/modules` (reuse the `find()`
  walk in `make_initrd_x86.py:42-48`) or downloadable by
  `fetch_kernel_modules.sh` (add `virtiofs.ko` to its list and see whether it
  resolves). Same for `virtio_snd.ko` in system_dlkm.
- **(b) Policy:** extract `vendor_a:/etc/selinux/precompiled_sepolicy` with
  `dump.erofs --cat` (offsets as `make_lapis_security_port.py` computes them).
  With `setools` from nixpkgs:
  `seinfo --genfscon precompiled_sepolicy | grep virtiofs`, and
  `sesearch -A -s init -c filesystem -p relabelfrom,relabelto,mount precompiled_sepolicy`
  and `sesearch -A -t media_rw_data_file -c filesystem -p associate`.
  The mount needs init to be allowed `mount`+`relabelfrom` on the virtiofs label
  and `relabelto` on `media_rw_data_file`'s filesystem.

Record the result **in this file** under a new `## Step 2 result` heading:
- (a) and (b) both pass → **virtio-fs** path (step 4a);
- either fails → **USB fallback** (step 4b). Do not attempt sepolicy surgery.

→ verify: the probe's output is pasted into the result section, and the chosen
path is stated.
Traps: do not boot anything yet. The runtime proof is step 11.

### 3. Scripts: `GBOS_STATE` and checksum verification

- New `lib.sh` (sourced): `STATE=${GBOS_STATE:-$HERE}` and
  `verify FILE` → `(cd "$STATE" && grep -F "  ${FILE#$STATE/}" "$HERE/checksums.sha256" | sha256sum -c --status)`,
  failing with `checksum mismatch or unpinned: FILE` unless `GBOS_UNVERIFIED=1`.
- `prepare.sh:9,17,19,22-24,29,32`: `$HERE/firmware|initrd|modules` → `$STATE/…`;
  the `.bin` default → `$STATE/…`.
- `fetch_recovery_image.sh:11,13`: defaults → `$STATE`; call `verify` on `OUT`
  after extraction (line 49).
- `fetch_kernel_modules.sh:17`: `OUT` default → `$STATE/modules`; after the
  Python finishes, `verify` each `*.ko`. The `exec python3` at line 19 must become
  a plain call so the verify can run after it.
- `fetch_cuttlefish_donor.sh:13`: `OUT` default → `$STATE`; `verify` the zip.
- `build_guest_mesa.sh:21,24-26,57-67,119,138,144,158-195`: `$HERE` → `$STATE`,
  **except** `PATCH` (line 28), which stays in `HERE`. `verify` the Mesa tarball
  after download.
- `build_security_image.sh:6-8,25,49-58,67`: `$HERE` → `$STATE` for data, and
  pass `--initrd "$STATE/initrd" --firmware "$STATE/firmware"
  --venus-lib "$STATE/guest-mesa/libvulkan_virtio.so" --virgl-dir "$STATE/guest-mesa/gl"`
  at line 61.
- Add the NDK fetch to `build_guest_mesa.sh`: if `$NDK` is missing, download
  `android-ndk-r30-linux.zip` to `$STATE`, `verify`, and unzip.

→ verify: `bash -n *.sh lib.sh`; `shellcheck *.sh lib.sh`; in a checkout with the
step 1 inputs, `./prepare.sh` still writes `./firmware` and `./initrd`; with
`GBOS_STATE=/tmp/x` it writes there; flipping one byte of a `.ko` makes the
module fetch's verify fail with the file named.
Traps: `HERE` must keep meaning "where the code is". Outputs never go to `HERE`
when `GBOS_STATE` is set. Keep every existing error message and guard. The
`GBOS_FORCE` refusal (`build_security_image.sh:32-46`) is untouched.

### 4. Guest image: modules and share

Common:
- `make_initrd_x86.py:53`: append `'virtio_snd.ko'` to `added` (no deps).
- `make_lapis_security_port.py`: add `ap.add_argument('--firmware', default=str(ROOT / 'firmware'))`
  next to line 315, and use `Path(a.firmware) / 'gpt.json'` at line 337.

**4a (virtio-fs path):**
- If step 2 found virtiofs as a module: add `'virtiofs.ko'` to `added`
  (`make_initrd_x86.py:53`) and to `DEFAULT` (`fetch_kernel_modules.sh:32`),
  and pin it in `checksums.sha256`.
- `make_lapis_security_port.py`: `HOSTSHARE_RC = b'''…'''` beside the other
  `*_RC` constants (line 46 onwards), with the exact text:
  ```
  # Mount the host's shared folder (virtio-fs tag "host") inside shared storage.
  on property:sys.user.0.ce_available=true
      mkdir /data/media/0/Host 0770 media_rw media_rw
      mount virtiofs host /data/media/0/Host nosuid nodev noexec context=u:object_r:media_rw_data_file:s0
  ```
  `ap.add_argument('--hostshare', action='store_true', help='mount the virtio-fs tag "host" at /data/media/0/Host')`
  and, after line 488,
  `if a.hostshare: add('etc/init/vm-hostshare.rc', HOSTSHARE_RC, 'vendor_configs_file')`.
- `build_security_image.sh:61-63`: add `--hostshare` to the flags.

**4b (USB fallback):** no image change. Record it under "Step 2 result".

→ verify: `python3 -m py_compile make_lapis_security_port.py make_initrd_x86.py`;
`GBOS_STATE=… GBOS_FORCE=1 ./build_security_image.sh` completes. Then
`image-security/manifest.json` lists `etc/init/vm-hostshare.rc` (4a), and
`initrd.json` lists `virtio_snd.ko`.
Traps: a rebuild erases the VM's `/data`. Use a separate `GBOS_SECURITY_DIR` if an
image you care about exists. `added` modules must come from the same kernel build
(`16302624`), or vermagic fails at boot.

### 5. `boot_vm.sh`

- After line 31: `: "${GBOS_MEM:=6G}"`, `: "${GBOS_AUDIO_ARGS:=-audiodev pipewire,id=snd0 -device virtio-sound-pci,audiodev=snd0}"`,
  `: "${GBOS_SHARE_ARGS:=}"`.
- Line 55: `-m 6G` → `-m "$GBOS_MEM"`; add `-name googlebook`.
- Line 59: add `$GBOS_AUDIO_ARGS $GBOS_SHARE_ARGS`, and
  `${GBOS_QMP:+-qmp unix:$GBOS_QMP,server=on,wait=off}`.
- Replace `timeout "$SECS" qemu… || true` with: run under `timeout` only when
  `SECS` ≠ 0; capture the status; `exit 0` on 124, else exit with it. Keep the
  final `wc -l`.
- Line 35-44: `X` stays the workdir argument (the CLI passes `GBOS_STATE`).
- README: the SPICE example's `/tmp/gbos-spice` → `$XDG_RUNTIME_DIR/googlebook-vm/spice`.

→ verify: `bash -n boot_vm.sh`; `GBOS_AUDIO_ARGS= ./boot_vm.sh "$PWD" t 60` behaves
as before; with `GBOS_QMP=$XDG_RUNTIME_DIR/gb.qmp`, `echo
'{"execute":"qmp_capabilities"}{"execute":"query-status"}' | socat - UNIX-CONNECT:$XDG_RUNTIME_DIR/gb.qmp`
answers `running`.
Traps: `GBOS_*_ARGS` are word-split on purpose; keep them unquoted. It is POSIX
`sh` (`#!/bin/sh`), not bash: no arrays, no `[[`.

### 6. `googlebook-vm` CLI (`bin/googlebook-vm`, bash)

- Reads `${XDG_CONFIG_HOME:-~/.config}/googlebook-vm/env` if present
  (`GBOS_SHARE_DIR`). `SHARE=$GBOS_SHARE_DIR`; empty means no share.
- `GBOS_STATE` default as above. The code directory is
  `GBOS_LIBEXEC` (set by the Nix wrapper to `$out/share/googlebook-vm`; from a
  checkout, `$(dirname "$0")/..`).
- `RUN=$XDG_RUNTIME_DIR/googlebook-vm` (mkdir 0700), with `qmp.sock` and `fs.sock`.
- `setup`: `systemd-run --user --unit=googlebook-vm-setup --collect
  --property=StandardOutput=append:$GBOS_STATE/setup.log …` running an inner
  `googlebook-vm _setup`, which runs the steps in order. Before each it writes
  `N/7 name` to `setup.step`, skips the step if its output exists, and writes
  `setup.ok` at the end. On failure it writes `setup.failed` with the step.
- `start`: refuses unless `setup.ok`. If sharing and 4a: `mkdir -p "$SHARE"`,
  `systemd-run --user --unit=googlebook-vm-fs --collect virtiofsd …` (decisions
  above), wait up to 5 s for `fs.sock`, set `GBOS_SHARE_ARGS`. If 4b: create
  `shared.img` once (`truncate -s 16G` + `mkfs.exfat -L GOOGLEBOOK`) and set
  `GBOS_SHARE_ARGS=-drive if=none,id=usbshare,format=raw,file=$GBOS_STATE/shared.img
  -device usb-storage,bus=xhci.0,drive=usbshare`. Then `systemd-run --user
  --unit=googlebook-vm --collect --setenv=…` for `boot_vm.sh "$GBOS_STATE" googlebook 0`,
  with `GBOS_QMP=$RUN/qmp.sock`, `BindsTo=`-style cleanup:
  `--property=ExecStopPost=systemctl --user stop googlebook-vm-fs`.
- `stop`: QMP `system_powerdown`; poll `systemctl --user is-active googlebook-vm`
  for 60 s; if still active, print
  `Android may be showing its power menu: choose Power off, or run googlebook-vm kill`
  and exit 1.
- `kill`: QMP `stop` then `quit`; `systemctl --user stop googlebook-vm` if still active.
- `status --json`: one line,
  `{"state":…,"step":…,"share":…,"shareMode":"virtiofs|usb|off","log":…,"state_dir":…}`,
  built with `jq -n --arg`. State order: active `googlebook-vm` → `running`; active
  `googlebook-vm-setup` → `setting-up`; `setup.failed` → `setup-failed`; no
  `setup.ok` → `unconfigured`; last `googlebook-vm` result failed → `failed`;
  else `stopped`.
- `log setup|serial`: `$TERMINAL -e less +F <file>` (`xdg-terminal-exec` if
  `$TERMINAL` is unset).
- `rebuild`: refuses while running; `GBOS_FORCE=1 build_security_image.sh` in
  the setup unit.
- `files` (4b only): refuses while running; `udisksctl loop-setup -f shared.img`
  and `udisksctl mount`; `files --done` unmounts and deletes the loop device.
- Self-test `bin/googlebook-vm-selftest` (run by the flake check): with an
  empty temporary `GBOS_STATE` and a stub `systemctl` on PATH, `status --json`
  → `unconfigured`; with `setup.ok` → `stopped`; with `setup.failed` → `setup-failed`.

→ verify: `shellcheck bin/googlebook-vm`; the selftest passes.
Traps: never pass user-controlled strings through `sh -c`; build argv arrays.
The QMP socket is in `$XDG_RUNTIME_DIR` (0700), never `/tmp`. `kill` is the only
path that does not let Android shut down.

### 7. Plugin files (blocked on the licence decision)

- `manifest.json`: `{"schemaVersion":1,"id":"nixarchy.googlebook","name":"Googlebook VM",
  "version":"1.0.0","author":"olafkfreund","license":"<decided>","description":"Set up, start and stop the Googlebook Android VM",
  "homepage":"https://github.com/olafkfreund/nixarchy-googlebook-vm","kinds":["menu"],
  "entryPoints":{"menu":"Menu.qml"},"keepLoaded":true}`.
- `Menu.qml`: copy the window and keyboard skeleton of
  `nixarchy.winvm/Menu.qml` (imports lines 1-6, `opened`/`open`/`close`/`toggle`
  44-52, `focusedScreen()` 35-43, `PanelWindow` with `WlrLayershell` overlay and
  exclusive keyboard 190-200, `Keys.onPressed` 231) — read it at
  `~/.config/omarchy/plugins/nixarchy.winvm/Menu.qml`. Replace the content with:
  a state line, the setup step, the share path and mode, and the key list for the
  current state (table in the decisions). Use one `Process` running
  `googlebook-vm status --json`, started on open and by a 2 s `Timer` whose
  `running: root.opened`. Actions are `Quickshell.execDetached(["googlebook-vm", …])`.
  `K` needs a second `K` within 3 s; `B` opens a text field and runs only on the
  exact text `erase`. Colours and controls come from `qs.Commons`/`qs.Ui` only.
- `googlebook-binds.lua`: the header comment of `nixarchy.microvm`'s
  `microvm-binds.lua` with names changed, then
  `o.bind("SUPER + ALT + G", "Googlebook VM", "omarchy-shell shell toggle nixarchy.googlebook '{}'")`.
- `LICENSE`.

→ verify: `omarchy plugin validate <dir with the four files>`;
`qmllint -I "$OMARCHY_PATH/shell" Menu.qml` clean;
`hyprctl binds -j | jq '.[] | select(.modmask==72 and .key=="G")'` is empty on
p620 (SUPER=64 + ALT=8).
Traps: no bar widget kind. No polling while closed. The plugin folder must hold
no symlinks. Do not test UI in the host's running shell: use the nixarchy QEMU
test VM as `nixarchy.winvm`'s AGENTS.md describes, or the host only after
validation.

### 8. `flake.nix`

- Inputs: `nixpkgs` (`github:NixOS/nixpkgs/nixos-unstable`) only.
- `packages.googlebook-vm`: `stdenvNoCC.mkDerivation` copying `*.sh *.py lib.sh
  checksums.sha256 patches/ bin/` to `$out/share/googlebook-vm`, and
  `makeWrapper $out/share/googlebook-vm/bin/googlebook-vm $out/bin/googlebook-vm
  --set GBOS_LIBEXEC $out/share/googlebook-vm --prefix PATH : <runtime deps>`.
  Runtime deps: `qemu virtiofsd python3 curl lz4 erofs-utils e2fsprogs exfatprogs
  util-linux socat jq unzip meson ninja bison flex pkg-config patch xz gnutar
  coreutils gnugrep gnused findutils file systemd udisks`.
- `packages.plugin`: `runCommand` with `cp` of exactly `manifest.json Menu.qml
  googlebook-binds.lua LICENSE` (comment why not `symlinkJoin`, as in
  `nixarchy-microvm`).
- `packages.default = googlebook-vm`.
- `devShells.default`: `mkShell` with the same deps plus `shellcheck setools qt6Packages.qtdeclarative`.
- `homeManagerModules.default`: options `enable` (bool), `keybinding`
  (`nullOr (strMatching "[A-Z0-9_ +]+")`, default `"SUPER + ALT + G"`), `sharedDir`
  (`nullOr str`, default `"Googlebook"`, relative to home; the description warns
  about sharing `$HOME`). When enabled: `home.packages`; the binds file via
  `builtins.replaceStrings` (microvm pattern); `xdg.configFile."googlebook-vm/env".text`
  with `GBOS_SHARE_DIR=${config.home.homeDirectory}/${sharedDir}` (empty when null);
  `home.activation.googlebookShare = lib.hm.dag.entryAfter ["writeBoundary"] "mkdir -p …"`.
  The package is taken from `self.packages.${pkgs.stdenv.hostPlatform.system}`.
- `checks.default`: `jq` asserts the manifest (id, kinds = ["menu"], keepLoaded,
  entry point present in `packages.plugin`); no symlinks in `packages.plugin`
  (`find -type l` empty); `bash -n` + `shellcheck` on all scripts; `py_compile`
  on all `.py`; `googlebook-vm-selftest`; `lib.sh`'s `verify` rejects a file
  with a wrong hash.

→ verify: `nix flake check` passes; `nix build .#plugin .#googlebook-vm`;
`nix develop -c qemu-system-x86_64 --version`; commit `flake.lock`.
Traps: `omarchy plugin validate` is not in nixpkgs. Run it in step 7 and step 11,
not in the sandboxed check. `.gitignore` ignores `*.bin` and `*.zip`, so make sure
no input file is needed in the source; the flake uses only tracked files.

### 9. README

Add "Install on nixarchy" first: the flake input, the host module snippet below,
the two one-time steps, the keys, where state lives, "uninstall keeps your
images" and how to delete them, and the share warning. Replace the Arch
`pacman` line with `nix develop` (keep the Arch line for non-Nix users).
Document `GBOS_STATE`, `GBOS_MEM`, `GBOS_AUDIO_ARGS`, `GBOS_SHARE_ARGS`,
`GBOS_QMP`, `GBOS_UNVERIFIED`, `SECS=0`, and the "Restart exits the VM"
(`-no-reboot`) note.

→ verify: every env var in the scripts appears in the README's table
(`grep -o 'GBOS_[A-Z_]*' *.sh bin/* | sort -u` vs the table).
Traps: none.

### 10. Host wiring in `/etc/nixos` (separate repository)

A separate change in `/etc/nixos`, which follows its own intent/spec/plan
workflow. Open it there with this plan linked. Its content:

- `flake.nix` input: `nixarchy-googlebook-vm = { url = "github:olafkfreund/nixarchy-googlebook-vm"; inputs.nixpkgs.follows = "nixpkgs"; };`
- `hosts/common/nixos/omarchy-googlebook.nix`:
  ```nix
  { inputs, ... }:
  {
    home-manager.users.olafkfreund = { pkgs, ... }: {
      imports = [ inputs.nixarchy-googlebook-vm.homeManagerModules.default ];
      programs.googlebook-vm.enable = true;
      programs.nixarchy.plugins."nixarchy.googlebook".src =
        inputs.nixarchy-googlebook-vm.packages.${pkgs.stdenv.hostPlatform.system}.plugin;
    };
  }
  ```
  imported for p620 only.

→ verify: `nixos-rebuild build --flake /etc/nixos#p620` succeeds.
Traps: needs this branch pushed (or a `path:` input while testing). The user
runs `switch`, not the agent. After switching, log out and in: a running session
keeps its old `PATH`/`OMARCHY_PATH`.

### 11. End to end on p620 (operator + agent)

One-time: `pcall(require, "hypr.googlebook-binds")` in `~/.config/hypr/bindings.lua`,
then `omarchy plugin enable nixarchy.googlebook`.

1. `SUPER+ALT+G` → `omarchy-shell shell isOpen nixarchy.googlebook` = `true`.
2. `U`: setup runs with step progress. Stop it mid-download
   (`systemctl --user stop googlebook-vm-setup`), press `U` again: it resumes.
3. `S`: Android desktop appears; a YouTube or system sound plays on the host.
4. Share (4a): `echo hi > ~/Googlebook/from-host.txt` shows in Android
   Files ▸ Host. A file saved there from an Android app shows on the host
   owned by the user (`stat -c %U`), mode readable and writable. Edits go both
   ways. `grep -a avc logs/googlebook/serial.log | grep -i virtiofs` is empty.
   (4b: the drive shows in Android Files; after stop, `googlebook-vm files` mounts
   it on the host.)
5. `X`: Android shuts down, or the power-menu message appears; status → `stopped`.
6. `B` while running: refused. When stopped: needs `erase`.
7. Tamper: change one byte of `modules/virtio_net.ko` in `GBOS_STATE`, delete
   `initrd`, run setup: it fails naming the file.

→ verify: each item above, with the command output pasted into the PR.
Traps: **a 4a failure here (avc denials, files not writable) is a deviation**:
switch to 4b, update this plan in the same commit, and say so in the PR.

## Tests

| command | expected |
|---|---|
| `nix flake check` | passes |
| `nix build .#plugin && find result -type l` | builds; no output |
| `omarchy plugin validate result` | valid |
| `qmllint -I "$OMARCHY_PATH/shell" Menu.qml` | no warnings |
| `bin/googlebook-vm-selftest` | all pass |
| checkout `./prepare.sh` | outputs in the checkout, as before |
| step 11 list | each item as stated |

## Rollback

- Code: everything is on `feat/no-issue-omarchy-plugin`. Do not merge, or
  `git revert` the merge. The checkout scripts keep their old behaviour by
  default, so nothing that uses them now breaks.
- Host: remove the import from `/etc/nixos` and switch, or
  `sudo nixos-rebuild --rollback switch`. Then `omarchy plugin disable
  nixarchy.googlebook` and remove the `pcall` line (harmless if left).
- Data: `~/.local/share/googlebook-vm` and `~/Googlebook` are never deleted by
  any step. Remove them by hand if wanted.

## Who does what (model split)

The plan has more than three file-editing steps, so the `coder` agent
implements steps 3-9, one step per message, on the same agent. Steps 1, 2 and 11
need network, a 19 GB download and a real desktop; the session model and the
operator run them. Step 10 is a separate `/etc/nixos` change. A fresh Opus
reviewer checks `git diff` against this plan before the PR.
