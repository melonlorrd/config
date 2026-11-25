{
  description = "dotfiles";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      lib = nixpkgs.lib;
      systems = [ "aarch64-darwin" "x86_64-darwin" "x86_64-linux" "aarch64-linux" ];
      forAll = f: lib.genAttrs systems (s:
        f (import nixpkgs { system = s; config.allowUnfree = true; }));

      profiles = lib.pipe (builtins.readDir self) [
        (lib.filterAttrs (n: t: t == "directory" && lib.hasPrefix "dots-" n))
        builtins.attrNames
        (map (lib.removePrefix "dots-"))
        (lib.filter (n: n != "common"))
      ];

      tools = pkgs: {
        ganymede = with pkgs; [ claude-code glow tmux direnv nix-direnv];
      };

      mkDots = pkgs: p: pkgs.runCommand "dots-${p}" { } ''
        mkdir -p $out/share/dots
        ${lib.optionalString (builtins.pathExists (self + "/dots-common"))
          "cp -r --no-preserve=mode ${self + "/dots-common"}/. $out/share/dots/"}
        cp -rf --no-preserve=mode ${self + "/dots-${p}"}/. $out/share/dots/
      '';

      mkApp = pkgs: name: text:
        let
          dots = lib.genAttrs profiles (mkDots pkgs);
          prelude = ''
            detect_host() {
              if command -v scutil >/dev/null 2>&1; then
                scutil --get LocalHostName 2>/dev/null && return
              fi
              hostname -s
            }

            profile="''${1:-''${DOTS_PROFILE:-$(detect_host | tr '[:upper:]' '[:lower:]')}}"
            profile="''${profile#dots-}"

            case "$profile" in
            ${lib.concatMapStrings (p: ''
              ${p}) src="${dots.${p}}/share/dots" ;;
            '') profiles}
              *)
                echo "no profile '$profile'. available:" >&2
                ${lib.concatMapStrings (p: ''
                  echo "  ${p}" >&2
                '') profiles}
                exit 1
                ;;
            esac

            target="$HOME/.nix-profile/share/dots"
          '';
        in {
          type = "app";
          program = lib.getExe (pkgs.writeShellApplication {
            inherit name;
            runtimeInputs = with pkgs; [ coreutils findutils hostname ];
            text = prelude + text;
          });
        };
    in {
      packages = forAll (pkgs:
        lib.genAttrs profiles (p: pkgs.buildEnv {
          name = p;
          paths = (tools pkgs).${p} or [ ] ++ [ (mkDots pkgs p) ];
        }));

      apps = forAll (pkgs: {
        default = self.apps.${pkgs.stdenv.hostPlatform.system}.link;

        link = mkApp pkgs "link-dots" ''
          echo "profile: $profile"
          if [ ! -e "$target" ]; then
            echo "warning: $target does not exist yet; run: nix profile add github:melonlorrd/config#$profile" >&2
          fi
          ( cd "$src"
            find . -type f -print0 | while IFS= read -r -d "" f; do
              f="''${f#./}"
              dst="$HOME/$f"
              mkdir -p "$(dirname "$dst")"
              if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$target/$f" ]; then
                echo "ok      $dst"
              elif [ -e "$dst" ] || [ -L "$dst" ]; then
                echo "SKIP    $dst (already exists)"
              else
                ln -s "$target/$f" "$dst"
                echo "linked  $dst"
              fi
            done
          )
        '';

        unlink = mkApp pkgs "unlink-dots" ''
          echo "profile: $profile"
          ( cd "$src"
            find . -type f -print0 | while IFS= read -r -d "" f; do
              f="''${f#./}"
              dst="$HOME/$f"
              if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$target/$f" ]; then
                rm "$dst"
                echo "removed $dst"
              fi
            done
          )
        '';
      });
    };
}
