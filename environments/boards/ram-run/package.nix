{ pkgs }:
let
  rev = "6f9946fe748edd0e55604dc42bc0f7ea3e7485da";
  src = pkgs.fetchFromGitHub {
    owner = "JanHaan";
    repo = "probe-rs";
    inherit rev;
    hash = "sha256-rBfdAi7ne5RKXwOyjVX6HpRCS1FOnodh0iJv1wwjfZo=";
  };
in
pkgs.probe-rs-tools.overrideAttrs (old: {
  pname = "landin-ram-run";
  version = "0.1-${builtins.substring 0 8 rev}";
  inherit src;
  buildAndTestSubdir = "probe-rs-tools";
  cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
    inherit src;
    name = "probe-rs-tools-0.32.0-unstable-janhaan-6f9946fe";
    hash = "sha256-d9RsDjBEefCdFYBAwAckHdnh+XsJyLTWiHh3c73CJck=";
  };
  postPatch = ''
    mkdir -p probe-rs-tools/src/bin
    cp ${./main.rs} probe-rs-tools/src/bin/landin-ram-run.rs
  '';
  cargoBuildFlags = [ "--package" "probe-rs-tools" "--bin" "landin-ram-run" ];
  cargoTestFlags = [ "--package" "probe-rs-tools" "--bin" "landin-ram-run" ];
  doCheck = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
  installPhase = ''
    runHook preInstall
    install -Dm755 target/${pkgs.stdenv.hostPlatform.rust.rustcTarget}/release/landin-ram-run $out/bin/landin-ram-run
    runHook postInstall
  '';
  meta = old.meta // { mainProgram = "landin-ram-run"; };
})
