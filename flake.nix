{
  description = "Googlebook (Android desktop) VM for nixarchy: CLI, scripts and menu plugin";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      # The flake's own nixpkgs instance does the licence check, so a consumer's allowUnfree
      # cannot reach it: allow exactly this one unfree package here.
      forAll =
        f:
        nixpkgs.lib.genAttrs systems (
          system:
          f system (
            import nixpkgs {
              inherit system;
              config.allowUnfreePredicate = p: nixpkgs.lib.getName p == "googlebook-vm";
            }
          )
        );

      # Mesa's meson build imports these at configure time.
      pythonEnv =
        pkgs:
        pkgs.python3.withPackages (ps: [
          ps.mako
          ps.pyyaml
          ps.packaging
        ]);

      runtimeDeps =
        pkgs: with pkgs; [
          qemu
          (pythonEnv pkgs)
          curl
          lz4
          erofs-utils
          e2fsprogs
          exfatprogs
          util-linux
          socat
          jq
          unzip
          meson
          ninja
          bison
          flex
          pkg-config
          glslang
          patch
          xz
          gnutar
          coreutils
          gnugrep
          gnused
          gawk
          findutils
          file
          systemd
          udisks
          glib
          less
        ];
    in
    {
      packages = forAll (
        system: pkgs:
        let
          lib = pkgs.lib;
        in
        rec {
          googlebook-vm = pkgs.stdenvNoCC.mkDerivation {
            pname = "googlebook-vm";
            version = "1.0.0";
            src = self;
            nativeBuildInputs = [ pkgs.makeWrapper ];
            dontBuild = true;
            installPhase = ''
              share=$out/share/googlebook-vm
              mkdir -p $share $out/bin
              cp *.sh *.py checksums.sha256 $share/
              cp -r patches bin $share/
              makeWrapper $share/bin/googlebook-vm $out/bin/googlebook-vm \
                --set GBOS_LIBEXEC $share \
                --prefix PATH : ${lib.makeBinPath (runtimeDeps pkgs)}
            '';
            meta = {
              description = "Set up and run the Googlebook Android VM";
              mainProgram = "googlebook-vm";
              # Bundles scripts from chaitan3/gbos-vm-linux, which has no licence (all rights
              # reserved), so it is marked unfree; forAll allows only this package in the flake.
              license = {
                fullName = "Unlicensed upstream (chaitan3/gbos-vm-linux) + MIT";
                free = false;
                redistributable = false;
              };
            };
          };

          # Plain cp, not symlinkJoin: a plugin folder must hold no symlinks.
          plugin = pkgs.runCommand "nixarchy-googlebook-1.0.0" { meta.license = lib.licenses.mit; } ''
            mkdir -p $out
            cp ${self}/manifest.json ${self}/Menu.qml ${self}/googlebook-binds.lua ${self}/LICENSE $out/
          '';

          default = googlebook-vm;
        }
      );

      devShells = forAll (
        _: pkgs: {
          default = pkgs.mkShell {
            packages = runtimeDeps pkgs ++ [
              pkgs.shellcheck
              pkgs.setools
              pkgs.qt6Packages.qtdeclarative
            ];
          };
        }
      );

      homeManagerModules.default =
        {
          config,
          lib,
          pkgs,
          ...
        }:
        let
          cfg = config.programs.googlebook-vm;
          binds = builtins.replaceStrings [ "SUPER + ALT + Y" ] [ cfg.keybinding ] (
            builtins.readFile ./googlebook-binds.lua
          );
        in
        {
          options.programs.googlebook-vm = {
            enable = lib.mkEnableOption "the Googlebook Android VM CLI and its Hypr key binding";
            keybinding = lib.mkOption {
              type = lib.types.nullOr (lib.types.strMatching "[A-Z0-9_ +]+");
              default = "SUPER + ALT + Y";
              description = "Hyprland chord that opens the menu; null installs no key binding.";
            };
            sharedDrive = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Attach a 16 GiB exFAT shared drive to the VM. It is not live: open it on the
                host with `googlebook-vm files` while the VM is stopped.
              '';
            };
          };

          config = lib.mkIf cfg.enable {
            home.packages = [ self.packages.${pkgs.stdenv.hostPlatform.system}.googlebook-vm ];
            xdg.configFile."googlebook-vm/env".text = "GBOS_SHARE=${if cfg.sharedDrive then "1" else "0"}\n";
            xdg.configFile."hypr/googlebook-binds.lua" = lib.mkIf (cfg.keybinding != null) { text = binds; };
          };
        };

      checks = forAll (
        system: pkgs: {
          default =
            pkgs.runCommand "googlebook-vm-checks"
              {
                nativeBuildInputs = with pkgs; [
                  bash
                  shellcheck
                  jq
                  python3
                  coreutils
                  gawk
                  gnugrep
                  findutils
                ];
              }
              ''
                plugin=${self.packages.${system}.plugin}
                # Sandbox has no /usr/bin/env: check a writable copy with patched shebangs.
                cp -r ${self} src && chmod -R u+w src && cd src && patchShebangs .

                jq -e '.id == "nixarchy.googlebook" and .kinds == ["menu"] and .keepLoaded == true' manifest.json
                test -f "$plugin/$(jq -r .entryPoints.menu manifest.json)"
                test -z "$(find "$plugin" -type l)"

                for f in *.sh dev/*.sh lib.sh bin/*; do bash -n "$f"; done
                shellcheck bin/* lib.sh
                python3 -c 'import sys; [compile(open(f).read(), f, "exec") for f in sys.argv[1:]]' *.py

                bash bin/googlebook-vm-selftest

                # lib.sh verify: a pinned file passes, a tampered or unpinned one fails.
                t=$(mktemp -d); mkdir $t/code $t/st
                echo good > $t/st/a.bin
                (cd $t/st && sha256sum a.bin) > $t/code/checksums.sha256
                v() { HERE=$t/code GBOS_STATE=$t/st bash -c '. ${self}/lib.sh; verify "$1"' _ "$1" 2>/dev/null; }
                v $t/st/a.bin
                echo bad > $t/st/a.bin
                if v $t/st/a.bin; then echo "verify accepted a tampered file"; exit 1; fi
                echo x > $t/st/b.bin
                if v $t/st/b.bin; then echo "verify accepted an unpinned file"; exit 1; fi

                touch $out
              '';
        }
      );
    };
}
