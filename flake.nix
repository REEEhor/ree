{
  description = "gen";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forAllSystems (pkgs:
        let
          # C libraries the project links against (add as needed).
          # For Raylib/GLFW: libGL libxkbcommon wayland libx11 libxcursor libxrandr libxinerama libxi
          libs = with pkgs; [ ];
        in
        {
          default = pkgs.mkShell {
            name = "gen";
            packages = [ pkgs.zig_0_16 pkgs.zls_0_16 pkgs.pkg-config ] ++ libs;
            LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath libs;
          };
        });
    };
}
