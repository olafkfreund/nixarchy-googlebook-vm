# Googlebook VM — build & run from scratch (x86_64 / Linux host)

Runs the **Intel Googlebook** (Android 17, device `lapis`, ASUS "Googlebook 14") recovery
image under QEMU/KVM, adapted so it boots on a VM:

- hardware security replaced with **software** (software KeyMint, **no StrongBox / Trusty**);
- virtual GPU via QEMU `virtio-gpu` with **Venus (Vulkan)** for apps and **VirGL (GLES)**
  for SurfaceFlinger/HWUI;
- Cuttlefish **DRM hwcomposer** and **software boot control** (no ChromeOS firmware calls);
- the vendor `userdata` grown to **16 GiB** (the download ships ~4 GiB, which ENOSPCs on
  first boot).

The result is a working Android desktop: login/setup UI, keyboard + mouse, and outbound
network.

## Requirements

- **A CPU with GFNI and VAES**: Intel 11th gen (Tiger Lake) or newer, AMD Zen 4 or newer.
  Google's image is compiled for them (`init`, `libc` and the linker use `vgf2p8affineqb` and
  VAES instructions), so without them the guest dies with an invalid opcode at its first
  instruction. Check your host: `grep -o -w -e gfni -e vaes /proc/cpuinfo | sort -u` must
  print both words. `googlebook-vm setup` and `start` refuse on other CPUs
  (`GBOS_SKIP_CPU_CHECK=1` skips the check, for hosts where `/proc/cpuinfo` lies, for
  example nested virtualisation).
- **KVM** (`/dev/kvm`) and a **Vulkan-capable GPU**.
- About 100 GB of free disk.

## Install on nixarchy

Add the flake as an input of your system flake, then enable the Home Manager module and the
menu plugin for your user:

```nix
# flake.nix
inputs.nixarchy-googlebook-vm = {
  url = "github:olafkfreund/nixarchy-googlebook-vm";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

```nix
{ inputs, ... }:
{
  home-manager.users.<you> = { pkgs, ... }: {
    imports = [ inputs.nixarchy-googlebook-vm.homeManagerModules.default ];
    programs.googlebook-vm.enable = true;
    # programs.googlebook-vm.keybinding = "SUPER + ALT + Y";  # default
    # programs.googlebook-vm.sharedDrive = true;              # default
    programs.nixarchy.plugins."nixarchy.googlebook".src =
      inputs.nixarchy-googlebook-vm.packages.${pkgs.stdenv.hostPlatform.system}.plugin;
  };
}
```

Switch, then log out and in (a running session keeps its old `PATH`). Two one-time steps:

1. Add `pcall(require, "hypr.googlebook-binds")` to `~/.config/hypr/bindings.lua`.
2. Run `omarchy plugin enable nixarchy.googlebook`.

Press **SUPER + ALT + Y** to open the menu. Keys (each is offered only in the states where it
applies):

| key | action |
|-----|--------|
| `U` | set up: download the inputs and build the image (resumable) |
| `S` | start the VM |
| `X` | stop: asks Android to shut down |
| `K` `K` | force stop (press twice within 3 s) |
| `F` | open the shared drive (while it is mounted on the host) |
| `L` | open the setup log (serial log while running) |
| `B` | rebuild the image; type `erase` to confirm (erases Android's data) |
| `Esc` | close |

The same actions are available from a terminal: `googlebook-vm setup | start | stop | kill |
status [--json] | log [setup|serial] | rebuild | files [--done]`. Setup and the VM run as
systemd **user** units (`googlebook-vm-setup`, `googlebook-vm`).

### Shared drive

`setup` creates a sparse 16 GiB exFAT image, `shared.img`, and `start` attaches it to the VM
as a USB drive (Android shows it in Files). It is **not live**: the host and the guest must
never mount one filesystem at once. While the VM is stopped, `googlebook-vm files` mounts it
on the host (at `/run/media/$USER/GOOGLEBOOK`) and opens it; `googlebook-vm files --done`
releases it. `start` refuses while it is mounted. Disable it with
`programs.googlebook-vm.sharedDrive = false` (or `GBOS_SHARE=0` in
`~/.config/googlebook-vm/env`).

A live shared folder (virtio-fs) does not work: Android's vendor SELinux policy cannot label
a virtio-fs mount inside shared storage. See the "Step 2 result" section of
`plan/2026-10-12-no-issue-omarchy-plugin.md`.

### Where things live

All state is in `${XDG_DATA_HOME:-~/.local/share}/googlebook-vm` (`GBOS_STATE`): the recovery
image, kernel modules, the built Android image, `shared.img`, and the logs. Uninstalling the
module does **not** delete it. To delete it (this erases the VM and everything on its
drive): `rm -rf ~/.local/share/googlebook-vm`.

Android's **Restart** exits the VM instead of rebooting it (QEMU runs with `-no-reboot`);
start it again with `S`.

## Building by hand (any Linux)

The rest of this file is the from-scratch pipeline, for non-Nix hosts. In a checkout the
scripts write next to themselves; set `GBOS_STATE` to put outputs elsewhere.

## Pipeline

| step | script | what it does |
|------|--------|--------------|
| recovery image | `fetch_recovery_image.sh` | download + extract Google's recovery zip |
| fetch modules | `fetch_kernel_modules.sh` | download the `*.ko` in `modules/` from CI |
| fetch donor | `fetch_cuttlefish_donor.sh` + `unpack_cuttlefish_donor.py` | software KeyMint, nonsecure Gatekeeper, DRM composer, software boot service |
| prepare | `prepare.sh` | extract boot images (`firmware/`) and build the ramdisk (`initrd`) |
| guest graphics | `build_guest_mesa.sh` | Mesa 26.2.4 for Android x86_64: Venus Vulkan ICD + VirGL GLES |
| build image | `build_security_image.sh` | rebuild `vendor_a`, expand userdata → `image-security/` |
| run | `boot_vm.sh` | launch QEMU with GPU/input/network → `logs/<name>/serial.log` |

Design/background notes are in `SECURITY_PORT.md`.

## 0. Tools

- The requirements above (a software Vulkan ICD such as lavapipe also works for the GPU).
- **QEMU** with virtio-gpu GL + Venus — i.e. built against **virglrenderer** with Vulkan.
- **Mesa** host driver + `virglrenderer`.
- Tools: `python3`, `curl`, `lz4`, `erofs-utils` (`dump.erofs`, `mkfs.erofs`, `fsck.erofs`),
  `e2fsprogs` (`debugfs`), `qemu-img`/`qemu-io`, `meson`, `ninja`, `bison`, `flex`,
  `pkg-config`, a C/C++ toolchain.
- **Android NDK r30** (for the guest Mesa drivers; `build_guest_mesa.sh` downloads it).
- Inputs are checked against `checksums.sha256`; a mismatch or an unpinned file stops the
  script (`GBOS_UNVERIFIED=1` bypasses, with a warning).

With Nix, `nix develop` provides all of this. On Arch (adapt to your distro):

```sh
sudo pacman -S --needed qemu-base qemu-img qemu-ui-gtk virglrenderer mesa \
  vulkan-intel mesa-utils python curl lz4 erofs-utils e2fsprogs meson ninja bison flex
```

Check Venus is available on the host:

```sh
qemu-system-x86_64 -device virtio-gpu-gl-pci,help | grep -E 'xres|yres|venus'
```

## 1. Recovery image

```sh
./fetch_recovery_image.sh
```

Downloads Google's device recovery zip for `lapis-user/16452207` and extracts
`android-desktop_signed_recovery_image.bin` (~19 GB) to the repo root. Override the source
with `GBOS_RECOVERY_URL`, point `GBOS_RAW` at an existing image, or `GBOS_KEEP_ZIP=1` to
keep the archive. (The image is never redistributed by this project.)

## 2. Kernel modules

```sh
./fetch_kernel_modules.sh
```

Downloads the `*.ko` listed in `modules/` (`failover.ko`, `net_failover.ko`,
`virtio_dma_buf.ko`, `virtio-gpu.ko`, `virtio_input.ko`, `virtio_net.ko`, `virtio-rng.ko`,
`virtio_snd.ko`) from `ci.android.com` build `16302624` / `kernel_virt_x86_64`.

## 3. Cuttlefish donor

Needs an x86_64 Cuttlefish image (the lapis image only ships a Trusty-backed KeyMint):

```sh
./fetch_cuttlefish_donor.sh 16373615
python3 unpack_cuttlefish_donor.py aosp_cf_x86_64_only_phone-img-16373615.zip donor
```

## 4. Prepare (offline)

```sh
./prepare.sh
```

Extracts the boot images into `firmware/` and builds the VM ramdisk `initrd`.

## 5. Guest graphics drivers

Download the Android NDK and Mesa source, then build:

```sh
# Android NDK r30: unpack to android-ndk-r30/  (override with ANDROID_NDK)
# Mesa 26.2.4:    unpack to mesa-26.2.4/      (download-only can fetch it)
./build_guest_mesa.sh --download-only   # fetch/cache Mesa + libdrm, no compile
./build_guest_mesa.sh                   # build guest-mesa/{libvulkan_virtio.so,gl/*}
```

`mesa-26.2.4-venus/` gets the `patches/mesa-android-mapper5.patch` applied automatically.
Outputs land in `guest-mesa/`.

## 6. Build the image

```sh
./build_security_image.sh
```

Produces `image-security/`:

- `googlebook-security.bin` — copy of the recovery image with the rebuilt `vendor_a`
  (software KeyMint, nonsecure Gatekeeper, no StrongBox) and a 16 GiB `userdata`;
- `initrd` — first-stage fstab adjusted so the modified vendor is not dm-verified;
- `manifest.json` — what changed.

The original download is never modified.

> **Rebuilding resets the VM.** `build_security_image.sh` regenerates
> `image-security/googlebook-security.bin` from the recovery image, so any state the VM
> saved (it persists `/data` by default) is discarded. It therefore **refuses to overwrite
> an existing image** unless you set `GBOS_FORCE=1`; use `GBOS_SECURITY_DIR=<dir>` to build
> a separate image instead of clobbering one you're using.

## 7. Run

```sh
./boot_vm.sh "$PWD" gb-venus 240
```

Opens an SDL window (1920×1440), grabs the mouse, and logs the serial console to
`logs/<name>/serial.log`. Useful greps:

```sh
grep -c boot_completed logs/gb-venus/serial.log
grep -aE 'SurfaceFlinger|drmhwc|EthernetTracker' logs/gb-venus/serial.log | tail
```

`SECONDS` is the time limit; `0` means no limit (the CLI uses that). A time-out exits 0;
otherwise QEMU's exit status is returned.

Disk changes are **persisted by default** (`GBOS_SNAPSHOT=off`), so the first boot is slow
(fresh 16 GiB userdata → dexopt/package scan) but later boots are fast. For a throwaway run
that discards `/data` when the VM stops, use `GBOS_SNAPSHOT=on`:

```sh
GBOS_SNAPSHOT=on ./boot_vm.sh "$PWD" gb-venus 300
```

## Environment overrides

| var | default | effect |
|-----|---------|--------|
| `GBOS_STATE` | the script's directory (CLI: `~/.local/share/googlebook-vm`) | where every output goes; code is always read from the checkout |
| `GBOS_LIBEXEC` | set by the Nix wrapper | directory holding the scripts, for the `googlebook-vm` CLI |
| `GBOS_SHARE` | `1` | `0` = no shared drive (set in `~/.config/googlebook-vm/env`, which may hold any `GBOS_*` override) |
| `GBOS_UNVERIFIED` | `0` | `1` skips checksum verification, with a warning |
| `GBOS_SKIP_CPU_CHECK` | `0` | `1` skips the GFNI/VAES check; `GBOS_CPUINFO` (default `/proc/cpuinfo`) is the file it reads |
| `GBOS_RAW` | `$GBOS_STATE/android-desktop_signed_recovery_image.bin` | recovery image input |
| `GBOS_RECOVERY_URL` / `GBOS_RECOVERY_ZIP` / `GBOS_KEEP_ZIP` | pinned lapis build / `$GBOS_STATE/recovery.zip` / `0` | recovery download source, cache path, keep the archive |
| `GBOS_DONOR` | `$GBOS_STATE/donor` | Cuttlefish donor dir |
| `GBOS_SECURITY_DIR` | `$GBOS_STATE/image-security` | image output dir |
| `GBOS_IMAGE_NAME` | `googlebook-security.bin` | image file name |
| `GBOS_IMAGE` / `GBOS_INITRD` / `GBOS_KERNEL` | built image / its initrd / `firmware/kernel` | `boot_vm.sh` boot artifacts |
| `GBOS_MEM` | `6G` | guest RAM |
| `GBOS_AUDIO_ARGS` | pipewire audiodev + `virtio-sound-pci` | audio devices; set but empty = no audio |
| `GBOS_SHARE_ARGS` | empty | extra devices for the shared drive (the CLI sets it) |
| `GBOS_QMP` | unset | path of a QMP unix socket (the CLI uses `$XDG_RUNTIME_DIR/googlebook-vm/qmp.sock`) |
| `GBOS_USERDATA_GIB` | `16` | userdata partition size |
| `GBOS_XRES` / `GBOS_YRES` | `1920` / `1440` | guest display size (4:3 matches the wacom tablet) |
| `GBOS_SNAPSHOT` | `off` | `off` = persist `/data` between boots; `on` = throwaway disk |
| `GBOS_FORCE` | `0` | `1` lets `build_security_image.sh` overwrite an existing image |
| `GBOS_DISPLAY_ARGS` | `-display sdl,gl=on` | e.g. `-display none -spice unix=on,addr=$XDG_RUNTIME_DIR/googlebook-vm/spice,gl=es` + a SPICE client (viewer-drawn cursor), `-display egl-headless` (headless), `-display egl-headless -vnc 127.0.0.1:0` (VNC) |
| `GBOS_GPU_ARGS` | virtio-gpu-gl-pci, Venus, 1920×1200 | full GPU device line |
| `GBOS_INPUT_ARGS` | xhci + usb-kbd + usb-mouse | input devices |
| `GBOS_NET_ARGS` | user-mode NAT over virtio-net | set empty for offline |
| `ANDROID_NDK` / `ANDROID_API` | `$GBOS_STATE/android-ndk-r30` / `37` | NDK for `build_guest_mesa.sh` |

## Troubleshooting

- **No display / blank window, `drmhwc: Could not find a suitable encoder/crtc`** — the
  image must be built with the Cuttlefish composer (`--composer`, on by default in
  `build_security_image.sh`).
- **`surfaceflinger` aborts importing gralloc buffers (Venus)** — SurfaceFlinger must run
  on VirGL GLES; ensure `guest-mesa/gl/` exists so `--virgl` is applied, and that
  `build.prop` has `ro.hardware.egl=virgl` + `ro.hwui.use_vulkan=false`.
- **Reboot with `Checkpoint commit failed` / `Unable to set fw boot successful status`** —
  the software boot-control service is needed (`--vmcompat`, on by default).
- **`ENOSPC` flooding the log, black screen after the boot logo** — userdata too small;
  `expand_lapis_userdata.py` runs automatically, or bump `GBOS_USERDATA_GIB`.
- **No network** — the host must have internet; the guest gets it via QEMU slirp NAT
  (`GBOS_NET_ARGS`). If virtio-net isn't picked up, try `usb-net` on xhci.
- **No mouse cursor** — the guest's own cursor sprite is not composited under VirGL (SurfaceFlinger
  draws it, but the pixels never land), so `boot_vm.sh` shows a **host-side cursor** instead:
  `-display sdl,gl=on,show-cursor=on` keeps QEMU's cursor visible. To stop it drifting, the pointer
  is made **absolute** with `usb-wacom-tablet`, and the image ships
  `usr/idc/Vendor_056a_Product_0000.idc` forcing it to a plain pointer (no stylus ink trails). The
  default 1920×1440 (4:3) resolution matches the tablet's raw range so the pointer maps 1:1.

## Credits and licence

Based on [chaitan3/gbos-vm-linux](https://github.com/chaitan3/gbos-vm-linux) by Chaitanya
Talnikar, which has no licence. This fork's additions (the plugin, `bin/`, `lib.sh`,
`flake.nix`, `checksums.sha256` and the planning documents) are MIT; see `LICENSE` for the
exact scope. The upstream files remain under their author's terms. The Google images are
never redistributed by this project.
