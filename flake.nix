{
  description = "Landin — a development shell holding the pinned toolchain";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
  };

  outputs =
    inputs:
    let
      #  environments/pins.sh is the one place a toolchain version or a
      #  checksum is written.  Reading it here, rather than naming a
      #  nixpkgs attribute, keeps this shell from becoming a fourth place
      #  to be wrong -- and gets the pinned compiler rather than whichever
      #  one nixpkgs happens to carry.  At the time of writing those are
      #  not the same: nixpkgs has GNAT 16.2.0 and GPRbuild 25.0.0, and
      #  the pin is GNAT 16.1.0 with GPRbuild 26.0.0.
      pins = builtins.readFile ./environments/pins.sh;

      #  Only the platforms the pins carry a checksum for.  A system with
      #  no recorded checksum is a system this shell cannot honestly
      #  provide, so it is absent rather than broken.
      systems = [
        "x86_64-linux"
        "aarch64-darwin"
      ];

      forEachSystem =
        build:
        builtins.listToAttrs (
          map (system: {
            name = system;
            value = build system;
          }) systems
        );
    in
    {
      devShells = forEachSystem (
        system:
        let
          pkgs = inputs.nixpkgs.legacyPackages.${system};
          lib = pkgs.lib;

          lines = lib.splitString "\n" pins;

          pin =
            name:
            let
              prefix = name + "=";
              found = lib.findFirst (line: lib.hasPrefix prefix line) null lines;
            in
            if found == null then
              throw "landin: ${name} is not set in environments/pins.sh"
            else
              lib.removePrefix prefix found;

          #  x86_64-linux -> X86_64_LINUX, which is how the checksums are
          #  named.  The archive names use the nix system string as it is.
          suffix = lib.toUpper (builtins.replaceStrings [ "-" ] [ "_" ] system);

          releases = pin "LANDIN_RELEASES";
          gnatVersion = pin "LANDIN_GNAT_VERSION";
          gprbuildVersion = pin "LANDIN_GPRBUILD_VERSION";

          #  The archives are prebuilt, so on Linux they need their
          #  interpreter and libraries patched to the store; on Darwin they
          #  link against the system libraries and need nothing.
          fromArchive =
            {
              pname,
              version,
              url,
              sha256,
            }:
            pkgs.stdenvNoCC.mkDerivation {
              inherit pname version;

              src = pkgs.fetchurl { inherit url sha256; };

              nativeBuildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.autoPatchelfHook
              ];
              buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                (lib.getLib pkgs.stdenv.cc.cc)
                pkgs.expat
                pkgs.ncurses
                pkgs.xz
                pkgs.zlib
                pkgs.zstd
              ];

              dontConfigure = true;
              dontBuild = true;
              dontStrip = true;

              installPhase = ''
                runHook preInstall
                mkdir -p "$out"
                cp -R . "$out"
                runHook postInstall
              '';
            };

          gnatUnwrapped =
            (fromArchive {
              pname = "landin-gnat";
              version = gnatVersion;
              url = "${releases}/gnat-${gnatVersion}/gnat-${system}-${gnatVersion}.tar.gz";
              sha256 = pin "LANDIN_GNAT_SHA256_${suffix}";
            }).overrideAttrs (previous: {
              #  GCC otherwise finds the archive's linker before the nixpkgs
              #  wrapper that supplies libc, its start files and interpreter.
              postPatch = (previous.postPatch or "") + ''
                rm -f bin/ld */bin/ld
              '';

              passthru = (previous.passthru or { }) // {
                langC = true;
                langCC = false;
                langFortran = false;
                langAda = true;
                isGNU = true;
              };
            });

          #  This still executes the pinned compiler.  The wrapper gives that
          #  compiler the target libraries and tools from the nix store.
          gnat = pkgs.wrapCCWith {
            cc = gnatUnwrapped;
            isAlireGNAT = true;
          };

          gprbuild =
            (fromArchive {
              pname = "landin-gprbuild";
              version = gprbuildVersion;
              url = "${releases}/gprbuild-${gprbuildVersion}/gprbuild-${system}-${gprbuildVersion}.tar.gz";
              sha256 = pin "LANDIN_GPRBUILD_SHA256_${suffix}";
            }).overrideAttrs (previous: {
              #  The archive ships the standard compiler database, and the
              #  standard GNAT description reports the prefix the pinned
              #  gnatls names -- the archive, not the wrapper -- so gprbuild
              #  would build with a compiler that cannot link.  This
              #  description recognizes the wrapper instead, while taking the
              #  Ada runtime path from the pinned compiler's own GCC report.
              postInstall = (previous.postInstall or "") + ''
                mkdir -p "$out/share/landin-gprconfig"
                substitute \
                  ${inputs.nixpkgs}/pkgs/development/ada-modules/gprbuild/nixpkgs-gnat.xml \
                  "$out/share/landin-gprconfig/nixpkgs-gnat.xml" \
                  --replace-fail \
                    '<external>readlink -n ''${PATH}/../nix-support/gprconfig-gnat-unwrapped</external>' \
                    '<external>''${PREFIX}gcc -v</external>
                     <grep regexp="^COLLECT_GCC=(.*)/bin/gcc" group="1"></grep>'
              '';

              #  The description has to be named on the command line, and
              #  makeWrapper cannot be the one to name it: it runs the real
              #  program with argv[0] still pointing at the wrapper script,
              #  and gprbuild 26 dies with a segmentation fault when argv[0]
              #  is not the executable that is running.  That is exactly the
              #  crash this shell reported, so these wrappers exec the real
              #  program under its own name.
              postFixup = (previous.postFixup or "") + ''
                for tool in gprbuild gprconfig; do
                  mv "$out/bin/$tool" "$out/bin/.$tool-real"
                  printf '#!%s\nexec "%s" --db "%s" "$@"\n' \
                    "${pkgs.runtimeShell}" \
                    "$out/bin/.$tool-real" \
                    "$out/share/landin-gprconfig" \
                    > "$out/bin/$tool"
                  chmod +x "$out/bin/$tool"
                done
              '';
            });
        in
        {
          default = pkgs.mkShell {
            packages = [
              gnat
              gprbuild
              pkgs.python3 #  check.py and docs/site/render_html.py
              pkgs.hut #  scripts/site.sh --publish
            ];

            #  The Ada project asks GNAT for its stack checking.  GCC disables
            #  that option, with a warning, if the wrapper also adds its
            #  conflicting stack-clash protection.
            hardeningDisable = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              "stackclashprotection"
            ];

            #  The build tag keeps this shell's object files out of the
            #  ones the macOS loop and the linux/amd64 container leave in
            #  the same checkout.
            shellHook = ''
              export LANDIN_GNAT_HOME="${gnat}"
              export LANDIN_GPRBUILD_HOME="${gprbuild}"
              export LANDIN_BUILD_TAG=nix
              echo "landin: GNAT ${gnatVersion}, GPRbuild ${gprbuildVersion}, build tag 'nix'"
              echo "landin: ./scripts/toolchain.sh prints what is actually on PATH"
            '';
          };
        }
      );
    };
}
