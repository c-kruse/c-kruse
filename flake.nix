{
  description = "c-kruse development environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-23.05";
  };

  outputs = { self, nixpkgs }:
    let
      hugoOverlay = (final: prev: let
        version = "0.88.1";
        src = final.fetchFromGitHub {
          owner = "gohugoio";
          repo = "hugo";
          rev = "v${version}";
          hash = "sha256-yuFFp/tgyziR4SXul2PlMhKmRl7C7OSrW8/kCCUpzI0=";
        };
      in {
        hugo = (prev.hugo.override rec {
          buildGoModule = args: final.buildGoModule (args // {
            inherit src version;
            vendorHash = "sha256-QV8z7A2EB2yORcqWwM2xNsS/y9jtOLqKD+H0wIYBVgw=";
          });
        });
      });

      forAllSystems = fn: nixpkgs.lib.genAttrs [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ] (system: fn (import nixpkgs {
          inherit system;
          overlays = [
            hugoOverlay
          ];
        })
      );
    in {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell{
          packages = with pkgs; [
            stdenv
            hugo
            awscli
          ];
        };
      });
    };
  }
