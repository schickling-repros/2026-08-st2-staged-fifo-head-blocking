{
  description = "Deterministic reproduction of the st2 staged-FIFO head blocker";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    st2.url = "github:compoundingtech/st2/509ffb4cdcc1805a1ccd566e87b5d373bb4c47d4";
    st2.inputs.nixpkgs.follows = "nixpkgs";
    pty.url = "github:compoundingtech/pty/504ac7332895fe1fa3767b530dcd99f091f56cda";
    pty.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs =
    {
      nixpkgs,
      st2,
      pty,
      ...
    }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      witnessFor =
        system:
        let
          pkgs = import nixpkgs { inherit system; };
          baselineSt2 = st2.packages.${system}.default;
          candidateSource = pkgs.runCommand "st2-unproven-deferred-source" { } ''
            cp -R ${st2.outPath} $out
            chmod -R u+w $out
            test "$(grep -F -c \
              'ReceiptState::RetainedBlocked | ReceiptState::Unproven => Ok(PokeOutcome::Staged),' \
              $out/src/ding/mod.rs)" -eq 1
            substituteInPlace $out/src/ding/mod.rs \
              --replace-fail \
                'ReceiptState::RetainedBlocked | ReceiptState::Unproven => Ok(PokeOutcome::Staged),' \
                'ReceiptState::RetainedBlocked => Ok(PokeOutcome::Staged), ReceiptState::Unproven => Ok(PokeOutcome::Deferred),'
            test "$(grep -F -c \
              'ReceiptState::Unproven => Ok(PokeOutcome::Deferred),' \
              $out/src/ding/mod.rs)" -eq 1
          '';
          candidateSt2 = baselineSt2.overrideAttrs (_: {
            pname = "st2-unproven-deferred-candidate";
            src = candidateSource;
            doCheck = false;
            CLI_BUILD_STAMP = builtins.toJSON {
              type = "nix";
              version = "0.1.0";
              rev = "509ffb4-unproven-deferred";
              commitTs = 1785594716;
              dirty = false;
            };
          });
        in
        pkgs.writeShellApplication {
          name = "st2-staged-fifo-repro";
          runtimeInputs = [
            pty.packages.${system}.default
            pkgs.bash
            pkgs.coreutils
            pkgs.gawk
            pkgs.jq
          ];
          text = ''
            export REPRO_BASELINE_ST2=${nixpkgs.lib.getExe baselineSt2}
            export REPRO_CANDIDATE_ST2=${nixpkgs.lib.getExe candidateSt2}
            ${builtins.readFile ./repro.sh}
          '';
        };
    in
    {
      packages = forAllSystems (system: {
        default = witnessFor system;
      });
      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = nixpkgs.lib.getExe (witnessFor system);
        };
      });
    };
}
