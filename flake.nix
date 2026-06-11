{
  description = "materwelon — Zig 0.16 shell, targets RP2350 mango brick";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
      in
      {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Zig toolchain
            zig
            zls
            # RP2350 firmware build
            pico-sdk
            cmake
            gcc-arm-embedded
            picotool
            # Serial communication + flash pipeline
            picocom
            just
            (python3.withPackages (ps: [ ps.pyserial ]))
          ];

          shellHook = ''
            echo "zig $(zig version)"
            export PICO_SDK_PATH="${pkgs.pico-sdk}/lib/pico-sdk"
          '';
        };
      }
    );
}
