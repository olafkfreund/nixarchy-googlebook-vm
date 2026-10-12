---
status: approved
issue: none (issues are disabled on this repository)
intent: intent/2026-10-12-no-issue-omarchy-plugin.md
---

# Spec: Install, run and manage the Googlebook VM from nixarchy

## Decisions taken from the intent's open questions

The intent was approved without answers, so its proposed defaults apply:

| # | Question | Decision |
|---|---|---|
| 1 | Share mechanism | evaluated below: **virtio-fs**, with a pre-approved fallback |
| 2 | Default share | a dedicated `~/Googlebook`; the whole of `$HOME` is never the default |
| 3 | Guest Mesa | built at **runtime** by `build_guest_mesa.sh`; nixpkgs ships NDK r29 (`androidenv…ndk-bundle` = 29.0.14206865), the script and `ANDROID_API=37` need r30 |
| 4 | Plugin location | this repository; the flake packages only the plugin's files |
| 5 | Id and chord | `nixarchy.googlebook`, `SUPER + ALT + G` (checked free before binding) |
| 6 | Extra scope | guest audio yes, USB passthrough no |

## Facts this design rests on (checked 2026-10-12)

- nixpkgs `qemu` 11.1.1 has `vhost-user-fs-pci`, `virtio-sound-pci`,
  `usb-storage`, `usb-mtp`, `virtio-gpu-gl-pci` and the `pipewire` audiodev.
- nixpkgs `virglrenderer` builds with `-Dvenus=true`.
- nixpkgs `virtiofsd` 1.14.0 has `--translate-uid` / `--translate-gid`
  (mapping done by virtiofsd itself, no root, no user namespace needed).
- `/dev/kvm` is `crw-rw-rw-` on p620; no group change is needed there.
- The image builder already adds vendor init scripts and file contexts:
  `add('etc/init/<x>.rc', TEXT, 'vendor_configs_file')`
  (`make_lapis_security_port.py:401,445,471,488`) and extends
  `etc/selinux/vendor_file_contexts` (`:473-475`).
- **Not checked:** whether the lapis kernel has `CONFIG_VIRTIO_FS`. The CI build
  that supplies the guest's modules does not publish `virtiofs.ko` as its own
  artifact, and the artifact-list API is rate-limited. It may be built in. Plan
  step 1 settles this on a real boot before anything depends on it.

## Design

Four parts: make the scripts installable, give them one CLI, wrap the CLI in an
Omarchy menu plugin, and package all of it in a flake. The shared folder is part
of the CLI and the image.

### 1. Separate code from state (scripts)

The scripts keep their names, arguments and checkout behaviour. One variable is
added:

- `GBOS_STATE` — where every output goes. Default: the script's directory, so a
  checkout behaves exactly as today. The installed CLI sets it to
  `${XDG_DATA_HOME:-$HOME/.local/share}/googlebook-vm`.

Each script reads code (`patches/`, the `.py` files) from `HERE` and writes to
`STATE`. That covers `prepare.sh`, `fetch_*.sh`, `build_guest_mesa.sh`,
`build_security_image.sh` and `boot_vm.sh`. `make_lapis_security_port.py` keeps
its `ROOT` defaults; `build_security_image.sh` passes `--initrd`,
`--venus-lib` and `--virgl-dir` explicitly instead, so the Python changes only
where it has to (one new flag, below).

### 2. Checksums

A new `checksums.sha256` in `sha256sum -c` format pins: the recovery zip's
`.bin`, each kernel module, the donor zip, the NDK r30 zip and the Mesa tarball
(libdrm is already pinned in `build_guest_mesa.sh`). A small `verify` function
in a sourced `lib.sh` checks a file against it and **exits non-zero on a
mismatch or a missing entry**. Values are recorded from one download over HTTPS
from Google's and Mesa's servers (trust on first use, recorded in git so every
later download is held to it). Overrides such as `GBOS_RECOVERY_URL` skip the
check only when `GBOS_UNVERIFIED=1` is also set, and say so.

### 3. `googlebook-vm` CLI

One bash script, installed with `writeShellApplication` so its runtime tools come
from Nix. Subcommands:

| command | does |
|---|---|
| `setup` | runs fetch recovery → modules → donor → NDK → prepare → guest Mesa → build image, skipping steps whose outputs exist; writes `STATE/setup.step` (`N/M name`) for the menu |
| `start` | starts `virtiofsd` (if sharing) and QEMU as **transient systemd user units** (`systemd-run --user --unit=googlebook-vm…`), so closing the menu or terminal does not kill them |
| `stop` | QMP `system_powerdown` (ACPI power button), waits up to 60 s for QEMU to exit |
| `kill` | QMP `quit` after QMP `stop`; the menu asks first, since `/data` may not be clean |
| `status [--json]` | one of `unconfigured`, `setting-up`, `setup-failed`, `stopped`, `running`, `failed`, plus setup step and paths, from the units' state and the files in `STATE` |
| `log [setup\|serial]` | opens the log in `$TERMINAL` with `less +F` |
| `rebuild` | `GBOS_FORCE=1` image rebuild; refuses while running; the menu explains it erases Android's data |

`setup` also runs as a transient unit (`googlebook-vm-setup`), the pattern
nixarchy's own Rebuild panel uses, so a 30-minute download survives the menu
closing. Downloads resume (`curl -C -`, already used for the recovery image).

`boot_vm.sh` changes, all opt-in so `./boot_vm.sh "$PWD" gb-venus 240` is
unchanged:

- `SECS=0` means no timeout;
- `-qmp unix:$GBOS_QMP,server=on,wait=off` when `GBOS_QMP` is set (the
  monitor stays `none`);
- the exit status is preserved instead of `|| true`, except 124 (timeout),
  which stays a success for the existing timed runs;
- two new hooks with defaults: `GBOS_SHARE_ARGS` (empty) and
  `GBOS_AUDIO_ARGS` (`-audiodev pipewire,id=snd0 -device
  virtio-sound-pci,audiodev=snd0`; the guest already loads `virtio_snd.ko`);
- `-name googlebook` so the window has a stable title.

The SPICE socket example in the README moves from `/tmp/gbos-spice` to
`$XDG_RUNTIME_DIR/googlebook-vm/spice`.

### 4. Shared folder: virtio-fs, mounted inside Android's shared storage

**Host.** `virtiofsd --shared-dir ~/Googlebook --socket-path
$XDG_RUNTIME_DIR/googlebook-vm/fs.sock --sandbox none --translate-uid
map:1023:$UID:1 --translate-gid map:1023:$GID:1 --tag host` runs unprivileged
as the user. Every file it creates is owned by the user on the host. Guest uid/gid
1023 (`media_rw`, which Android's MediaProvider uses to reach shared storage)
maps to the user. `--sandbox none` because there is no root to build the
namespace with, and virtiofsd only ever runs as the user. QEMU gets
`-object memory-backend-memfd,id=mem,size=6G,share=on -numa node,memdev=mem
-chardev socket,id=fs0,path=… -device vhost-user-fs-pci,chardev=fs0,tag=host`
through `GBOS_SHARE_ARGS`. The memfd size tracks the existing `-m 6G`.

**Guest.** A new `--hostshare` flag in `make_lapis_security_port.py` adds
`etc/init/vm-hostshare.rc`:

```
on property:sys.user.0.ce_available=true
    mkdir /data/media/0/Host 0770 media_rw media_rw
    mount virtiofs host /data/media/0/Host nosuid nodev noexec context=u:object_r:media_rw_data_file:s0
```

Mounted under `/data/media/0`, the folder appears in Android's Files app as
**Host**, through MediaProvider's own FUSE layer, so every Android app sees it
through the normal storage permissions. If the share is off, there is no device
and the mount fails harmlessly with one line in the log. If the lapis kernel
builds virtio-fs as a module, `virtiofs.ko` is added to the module list
`fetch_kernel_modules.sh` reads.

**Only `~/Googlebook` by default.** The HM option `sharedDir` can point
anywhere, including `$HOME`. Its description warns that every Android app with
storage access can then read `~/.ssh` and `~/.gnupg`.

**Pre-approved fallback** (used only if plan step 1 fails: no virtio-fs in the
kernel, or SELinux refuses the `context=` mount): a USB drive. A sparse 16 GiB
exFAT image at `STATE/shared.img` (made with `mkfs.exfat`), attached as
`-device usb-storage` on the existing xhci bus. Android's vold mounts it as a
removable volume, so Android needs no image change. It is **not live**: the host
reaches it only while the VM is stopped, through a `googlebook-vm files` command
(`udisksctl loop-setup` + mount, and the reverse). That limitation is stated in
the menu. Switching to the fallback is recorded in `plan/` in the same commit.

### 5. Omarchy plugin `nixarchy.googlebook`

Same contract as `nixarchy.winvm`: menu-only, `keepLoaded: true`, no bar widget,
no second Quickshell process.

```
manifest.json            schemaVersion 1, id nixarchy.googlebook, kinds ["menu"],
                         entryPoints.menu = Menu.qml, keepLoaded true
Menu.qml                 fullscreen menu: open(payloadJson), close(), toggle(), opened;
                         focused screen, exclusive keyboard layer, Esc / outside click closes
googlebook-binds.lua     o.bind("SUPER + ALT + G", "Googlebook VM",
                         "omarchy-shell shell toggle nixarchy.googlebook '{}'")
LICENSE
```

`Menu.qml` holds no VM logic. It runs `googlebook-vm status --json` when it
opens and every 2 s **only while it is open**, then shows state, setup step,
share path and the keys that apply in that state:

| key | action | when |
|---|---|---|
| `U` | set up (start or resume) | unconfigured, setup-failed |
| `S` | start | stopped, failed |
| `X` | stop (Android shutdown) | running |
| `K` | force stop, after a second `K` | running |
| `F` | open the shared folder on the host | always |
| `L` | open the log | always |
| `B` | rebuild image, after typing `erase` | stopped |
| `Esc` | close | always |

Imports and colours come from `qs.Commons` / `qs.Ui`, as in `nixarchy.winvm`.

### 6. Flake

```
packages.<system>.googlebook-vm   CLI + scripts (share/googlebook-vm/), wrapped with
                                  qemu, virtiofsd, python3, curl, lz4, erofs-utils,
                                  e2fsprogs, exfatprogs, util-linux, socat, jq, unzip,
                                  meson, ninja, bison, flex, pkg-config, patch, xz, gnutar
packages.<system>.plugin          runCommand + plain cp of the four plugin files
                                  (omarchy-plugin-validate rejects symlinks)
packages.<system>.default         = googlebook-vm
devShells.<system>.default        the same tools, for the checkout workflow
homeManagerModules.default        programs.googlebook-vm.{enable, keybinding, sharedDir}
checks.<system>.default           see Verification
```

The home-manager module, when `enable`d:

- adds the CLI to `home.packages`;
- writes `~/.config/hypr/googlebook-binds.lua` from the shipped file with the
  chord substituted, unless `keybinding = null` (same as
  `nixarchy-microvm`; `strMatching "[A-Z0-9_ +]+"`);
- writes `~/.config/googlebook-vm/env` with `GBOS_SHARE_DIR` (or nothing when
  `sharedDir = null`), which the CLI sources;
- creates the shared directory (`home.activation`, `mkdir -p` only, never
  removes).

Host wiring in `/etc/nixos`, `hosts/common/nixos/omarchy-googlebook.nix`, the
shape of `omarchy-microvm.nix`:

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

One-time steps per machine that a rebuild cannot take, because both files are the
user's (the same caveat as `omarchy-microvm.nix`): add
`pcall(require, "hypr.googlebook-binds")` to `~/.config/hypr/bindings.lua`,
and run `omarchy plugin enable nixarchy.googlebook`.

**Uninstall:** remove the import and the two lines, then rebuild. Images stay in
`~/.local/share/googlebook-vm` until the user deletes them. The README says so.

## Alternatives rejected

- **9p (virtio-9p).** Not in the CI module list either, slower, and it has the
  same SELinux labelling problem as virtio-fs with no benefit.
- **usb-mtp.** It needs no image change, but Android as an MTP *host* is not
  standard; at best an app would be required. A plain USB drive is the safer
  zero-image-change option, so it is the fallback.
- **SMB/WebDAV on `10.0.2.2`.** Needs a client app inside Android and a server
  on the host; the share would only be visible inside that app.
- **adb push/pull.** A user build with `ro.adb.secure`; it is file transfer,
  not a folder.
- **Sharing `$HOME` by default.** Exposes credentials to every Android app.
- **The recovery image as a fixed-output derivation.** 19 GB in the store, and
  it would be redistributable from any binary cache.
- **Guest Mesa as a Nix derivation.** It needs NDK r30, which nixpkgs does not
  have; packaging the NDK is a project of its own. Revisit when nixpkgs has r30.
- **libvirt.** It needs a system daemon and XML for what is one QEMU command;
  rootless transient units do the same.
- **The plugin's HM module setting `programs.nixarchy.plugins` itself.** That
  option exists only with nixarchy's HM module, so the plugin's module would
  break elsewhere. Kept in the host file, as in `nixarchy-microvm`.
- **A bar widget.** Not wanted, the same as `nixarchy.winvm`.

## Risks

| risk | where | mitigation |
|---|---|---|
| lapis kernel has no virtio-fs, or SELinux denies the `context=` mount | guest | plan step 1 probes it on a real boot; the pre-approved USB fallback |
| `media_rw` uid mapping wrong: files readable but not writable in Android | guest/host | step 1 writes from an Android app and checks owner and mode on the host |
| ACPI power button opens Android's power menu instead of shutting down | guest | `stop` waits 60 s then reports "choose Power off in Android, or force stop"; never forces by itself |
| `-no-reboot`: Android's *Restart* exits QEMU | guest | `status` shows `stopped`; documented |
| the memfd backend doubles as guest RAM: 6 GiB locked into shared memory | host | same 6 GiB as today; `-m` and `size=` come from one variable |
| PipeWire audiodev missing or the guest gets no sound | host/guest | `GBOS_AUDIO_ARGS=` (empty) turns it off; verified in step 1 |
| SUPER+ALT+G already bound | p620 | `hyprctl binds -j` before writing; the option allows another chord |
| refactor breaks the checkout workflow | all | `GBOS_STATE` defaults to `HERE`; checks run the scripts from a checkout copy |
| first download pins a wrong hash | supply chain | hashes come from the vendor's HTTPS endpoint, are reviewed in the commit, and the recovery hash is checked against the one `fetch_recovery_image.sh` already prints |
| `kill` corrupts `/data` | guest | asked twice; `stop` is the default path |

All runtime risk is on hosts that import the module; p620 first.

## Verification

1. **Flake:** `nix flake check` passes. The check:
   - `jq` asserts the manifest's id, kinds, `keepLoaded` and that every entry
     point exists in `packages.plugin`;
   - `omarchy plugin validate` on the package, if the tool is available in the
     sandbox (otherwise in the devShell);
   - `bash -n` and `shellcheck` on every `.sh` and the CLI;
   - `python3 -m py_compile` on every `.py`;
   - the CLI's `status --json` with an empty `GBOS_STATE` prints
     `"state":"unconfigured"`;
   - the checksum helper rejects a file with a wrong hash (self-test).
2. **QML:** `qmllint -I $OMARCHY_PATH/shell Menu.qml` clean.
3. **Checkout still works:** `./prepare.sh` and `./boot_vm.sh "$PWD" gb-venus 240`
   in a checkout behave as before (outputs in the repository directory).
4. **End to end on p620** (or the nixarchy QEMU test VM for the UI, per
   `nixarchy.winvm`'s AGENTS.md):
   - `nixos-rebuild switch`, log out and in; the menu row and chord open the
     plugin and `omarchy-shell shell isOpen nixarchy.googlebook` → `true`;
   - `U` runs setup to completion with step progress; interrupting it and
     pressing `U` again resumes;
   - `S` boots to the Android desktop with sound;
   - a file created on the host in `~/Googlebook` shows in Android's Files
     under *Host*, a file created in Android shows on the host owned by the
     user, and edits go both ways;
   - `X` shuts Android down (or the documented power-menu fallback appears);
     status becomes `stopped`;
   - `B` refuses while running and, when stopped, needs `erase`.
5. **Tampered download:** change one byte of a module and run `setup`; it stops
   with a checksum error naming the file.
