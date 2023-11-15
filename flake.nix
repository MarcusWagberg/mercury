{
  inputs.zig.url = "github:mitchellh/zig-overlay";

  outputs = { self, nixpkgs, zig }: let
    forAllSystems = f: nixpkgs.lib.genAttrs [ "x86_64-linux" "aarch64-linux" ] (system: f (
      import nixpkgs {
    	inherit system;
    	overlays = [ zig.overlays.default ];
      }
    ));
  in {
    devShells = forAllSystems (pkgs: {
      default = pkgs.mkShell {
      	packages = [ pkgs.zigpkgs."0.11.0" ];
      	shellHook = ''
            alias build="zig build -Dcpu=baseline -Dtarget=${pkgs.system}"
            alias run="zig build run -Dtarget=${pkgs.system}"
            alias dev="zig build dev -Dtarget=${pkgs.system}"

            echo "Commands:"
            echo "build	- 	build and install a release version"
            echo "run	- 	build and run a release version"
            echo "dev	- 	build and run a dev version"
        '';
      };
    });
  };
}
