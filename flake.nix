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

      #  The toolchain is assembled once per system and used twice: by the
      #  development shell, and by the compiler derivation a consuming
      #  flake takes as an input.  Every workaround below -- the patched
      #  interpreter, the gprconfig description, the argv[0] exec, the
      #  triplet driver names -- is needed by both, and was needed by the
      #  shell first.
      perSystem = forEachSystem (
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

          #  Stated once, in README.md's status line, the same string
          #  docs/site/render_html.py holds the page to.  A version written
          #  twice is a version that drifts.
          #
          #  Matched one LINE at a time, never the whole file.  The first
          #  version wrapped `(.|\n)*` around the pattern and ran it over
          #  thirty thousand characters; builtins.match backtracks, and an
          #  alternation-based any-character star on that much text does
          #  not finish.  It pegged one core for twenty minutes producing
          #  nothing, and it is what made `nix run` on this flake appear
          #  to hang.
          specification =
            let
              status = lib.findFirst (
                line: lib.hasPrefix "**Status: specification " line
              ) null (lib.splitString "\n" (builtins.readFile ./README.md));
              found =
                if status == null then
                  null
                else
                  builtins.match "[^0-9]*([0-9]+\\.[0-9]+\\.[0-9]+).*" status;
            in
            if found == null then "0" else builtins.head found;

          #  The release the hashes below belong to, and the one refine-bin
          #  fetches.  Not `specification`: a declaration commit moves the
          #  README first, and a tagged tree cannot hold the hashes of assets
          #  built from itself, so the two move in the commit that records
          #  the new hashes and never before.
          releaseVersion = "0.2.1";

          releaseHashes = {
            x86_64-linux =
              "9841a81ed0e7a0d915c014604fd7887fd93cef77756714b885046d0e7dcab327";
            aarch64-darwin =
              "9ec19a8dbeda309ddca1e466e88459c141b69c6e952568e80b2f08557a305b94";
          };

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

            #  The wrapper writes `gcc`, `cc`, `g++` and `cpp`, and prefixes
            #  a driver's name with a GNU triplet only when it is
            #  cross-compiling.  `refine` names its driver by triplet --
            #  `Landin.Backend.Toolchain` says why, and deliberately will not
            #  fall back to a bare `gcc` -- so on this shell it reached the
            #  archive's own `x86_64-pc-linux-gnu-gcc`, which holds no libc
            #  and could not find `Scrt1.o`.  gprbuild was unaffected: it
            #  links through the wrapper's `gcc`, which is why the compiler
            #  built here and the programs it emitted did not.  Every name
            #  the pinned compiler answers to has to reach the wrapper, and
            #  the archive's own bin is what says what those names are.
            extraBuildCommands = ''
              for driver in ${gnatUnwrapped}/bin/*-gcc; do
                [ -e "$driver" ] || continue
                ln -sf gcc "$out/bin/$(basename "$driver")"
              done
            '';
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
          #  The published compiler, fetched rather than built.
          #
          #  Building from source means building the pinned toolchain
          #  first: 383 MB of GNAT to unpack and patch before a line of
          #  Ada compiles, which is where the hour went when this was
          #  first tried.  This fetches a 17 MB archive instead, verified
          #  against the sha256 the release workflow published beside it
          #  -- the same thing environments/pins.sh does with the
          #  toolchain, and the same refusal on mismatch.
          #
          #  The hashes are recorded by hand after a release, from the
          #  publish job's log.  That is the same dance pins.sh asks for,
          #  and it is deliberate: a hash nobody wrote down is a download
          #  nobody checked.

          refineBin = pkgs.stdenvNoCC.mkDerivation {
            pname = "landin-bin";
            version = releaseVersion;

            src = pkgs.fetchurl {
              url =
                "https://github.com/JanHaan/Landin/releases/download/"
                + "v${releaseVersion}/landin-${releaseVersion}-${system}.tar.gz";
              sha256 = releaseHashes.${system};
            };

            sourceRoot = ".";

            #  The Linux asset is built against the runner's glibc and has
            #  no idea the nix store exists, so its interpreter and library
            #  paths are rewritten the same way the toolchain archives are.
            nativeBuildInputs =
              [ pkgs.makeWrapper ]
              ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
                pkgs.autoPatchelfHook
              ];
            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              (lib.getLib pkgs.stdenv.cc.cc)
            ];

            installPhase = ''
              runHook preInstall
              install -Dm755 refine "$out/bin/refine"
            ''
            + lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
              #  refine names its driver by GNU triplet and deliberately
              #  will not fall back to a bare gcc, so the name it asks for
              #  has to exist.  On Darwin it asks for /usr/bin/clang, which
              #  the host already has.
              mkdir -p "$out/libexec/landin"
              ln -s "${pkgs.stdenv.cc}/bin/cc" \
                "$out/libexec/landin/x86_64-pc-linux-gnu-gcc"
              wrapProgram "$out/bin/refine" \
                --prefix PATH : "$out/libexec/landin"
            ''
            + ''
              runHook postInstall
            '';

            meta = {
              description = "The Landin bootstrap compiler, prebuilt";
              homepage = "https://www.701.dev";
              mainProgram = "refine";
            };
          };

          #  The compiler itself, so a project can take Landin as a flake
          #  input instead of cloning this repository and running a build
          #  script.  Release mode: a consumer wants the compiler, not its
          #  assertions.
          refine = pkgs.stdenv.mkDerivation {
            pname = "landin";
            version = specification;

            src = lib.cleanSourceWith {
              src = ./.;
              #  None of the generated trees is an input, and one of them
              #  holds a fixture's deliberately recursive symlinks.
              filter =
                path: type:
                !(builtins.elem (baseNameOf (toString path)) [
                  "build"
                  ".scratch"
                  "site"
                  "node_modules"
                  "__pycache__"
                ]);
            };

            nativeBuildInputs = [
              gnat
              gprbuild
              pkgs.makeWrapper
            ];

            dontConfigure = true;

            #  The project puts its objects under build/$TAG/$MODE, and the
            #  tag is 'nix' here for the same reason the shell sets it: so
            #  these objects cannot be confused with another host's.
            buildPhase = ''
              runHook preBuild
              cd compiler/ada
              LANDIN_BUILD_TAG=nix LANDIN_BUILD_MODE=release \
                gprbuild -p -P refine.gpr -j''${NIX_BUILD_CORES:-1}
              runHook postBuild
            '';

            installPhase = ''
              runHook preInstall
              install -Dm755 build/nix/release/bin/refine "$out/bin/refine"
              #  refine names its assembler and linker by GNU triplet and
              #  deliberately will not fall back to a bare gcc, so the
              #  wrapped compiler has to be on its path: without this the
              #  package can emit assembly and cannot link it.
              wrapProgram "$out/bin/refine" \
                --prefix PATH : "${gnat}/bin"
              runHook postInstall
            '';

            meta = {
              description = "The Landin bootstrap compiler";
              homepage = "https://www.701.dev";
              mainProgram = "refine";
            };
          };

          shell = pkgs.mkShell {
            packages = [
              gnat
              gprbuild
              pkgs.python3 #  check.py and docs/site/render_html.py
            ] ++ lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              #  R4.40's external header frontend.  Selecting the LLVM 19
              #  package set matches Debian stable's versioned clang-19 rather
              #  than following nixpkgs' moving default Clang.
              pkgs.llvmPackages_19.clang
              pkgs.gdb #  scripts/debug.sh; native Linux source debugging
            ];

            #  The binding generator's Linux C model comes from the same
            #  package-set pin as Clang, rather than from host Darwin headers.
            #  R4.30's explicit archive requests also need nixpkgs' separate
            #  static glibc output: the ordinary libc output does not hold
            #  libm.a.  Keep the shared output first so the driver's own -lc
            #  remains dynamic while -l:libm.a can reach the requested archive.
            buildInputs = lib.optionals pkgs.stdenv.hostPlatform.isLinux [
              (lib.getLib pkgs.glibc)
              pkgs.glibc.dev
              pkgs.glibc.static
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
    in
    {
      devShells = builtins.mapAttrs (_: built: { default = built.shell; }) perSystem;

      packages = builtins.mapAttrs (
        _: built: {
          #  The source build is the default, because `nix build` on a
          #  repository is expected to build it.  refine-bin is the fast
          #  path for a consumer who wants the compiler rather than the
          #  toolchain that made it.
          default = built.refine;
          inherit (built) refine;
          refine-bin = built.refineBin;
        }
      ) perSystem;
    };
}
