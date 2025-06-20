{
  inputs.nix2container.url = "github:nlewo/nix2container";
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs, nix2container }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      nix2containerPkgs = nix2container.packages.x86_64-linux;

      os-release = ''QU5TSV9DT0xPUj0iMDszODsyOzEyNjsxODY7MjI4IgpCVUdfUkVQT1JUX1VSTD0iaHR0cHM6Ly9naXRodWIuY29tL05peE9TL25peHBrZ3MvaXNzdWVzIgpCVUlMRF9JRD0iMjUuMTEuMjAyNTA1MTguMjkyZmE3ZCIKQ1BFX05BTUU9ImNwZTovbzpuaXhvczpuaXhvczoyNS4xMSIKREVGQVVMVF9IT1NUTkFNRT1uaXhvcwpET0NVTUVOVEFUSU9OX1VSTD0iaHR0cHM6Ly9uaXhvcy5vcmcvbGVhcm4uaHRtbCIKSE9NRV9VUkw9Imh0dHBzOi8vbml4b3Mub3JnLyIKSUQ9bml4b3MKSURfTElLRT0iIgpJTUFHRV9JRD0iIgpJTUFHRV9WRVJTSU9OPSIiCkxPR089Im5peC1zbm93Zmxha2UiCk5BTUU9Tml4T1MKUFJFVFRZX05BTUU9Ik5peE9TIDI1LjExIChYYW50dXNpYSkiClNVUFBPUlRfVVJMPSJodHRwczovL25peG9zLm9yZy9jb21tdW5pdHkuaHRtbCIKVkFSSUFOVD0iIgpWQVJJQU5UX0lEPSIiClZFTkRPUl9OQU1FPU5peE9TClZFTkRPUl9VUkw9Imh0dHBzOi8vbml4b3Mub3JnLyIKVkVSU0lPTj0iMjUuMTEgKFhhbnR1c2lhKSIKVkVSU0lPTl9DT0RFTkFNRT14YW50dXNpYQpWRVJTSU9OX0lEPSIyNS4xMSIK'';
      mkTmp = pkgs.runCommand "mkTmp" { } ''
        mkdir -p $out/tmp
      '';
      # Permissions for the temporary directory.
      mkTmpPerms = {
        path = mkTmp;
        regex = ".*";
        mode = "1777";
        uid = 0; # Owned by root.
        gid = 0; # Owned by root.
      };
      # Enable the shebang `#!/usr/bin/env bash`.
      mkEnvSymlink = pkgs.runCommand "mkEnvSymlink" { } ''
        mkdir -p $out/usr/bin
        ln -s /bin/env $out/usr/bin/env
      '';
      mkUser = pkgs.runCommand "mkUser" { } ''
        mkdir -p $out/etc/pam.d
        echo "root:x:0:0::/root:/bin/bash" > $out/etc/passwd
        echo "root:!x:::::::" > $out/etc/shadow
        echo "root:x:0:" > $out/etc/group
        echo "root:x::" > $out/etc/gshadow
        echo ${os-release} | base64 -d > $out/etc/os-release # fuck you prisma
        cat > $out/etc/pam.d/other <<EOF
        account sufficient pam_unix.so
        auth sufficient pam_rootok.so
        password requisite pam_unix.so nullok sha512
        session required pam_unix.so
        EOF
        touch $out/etc/login.defs
        mkdir -p $out/root
      '';
      # Set permissions for the user's home directory.
      mkUserPerms = {
        path = mkUser;
        regex = "/root";
        mode = "0755";
        uid = 0;
        gid = 0;
        uname = "root";
        gname = "root";
      };
    in
    rec {
      packages.x86_64-linux.litellm-pkg = pkgs.litellm.overrideAttrs (
        final: prev: rec {
          postPatch = ''
            sed -i 's/def _verify(self, license_str: str) -> bool:/def _verify(self, license_str: str) -> bool:\n        return True/' "litellm/proxy/auth/litellm_license.py"
          '';
          src = pkgs.fetchFromGitHub {
            owner = "BerriAI";
            repo = "litellm";
            tag = "v1.72.6-stable";
            hash = "sha256-Qs/jmNJx/fztLqce47yd1pzIZyPsz0XhXUyoC1vkp6g=";
          };
          propagatedBuildInputs = prev.propagatedBuildInputs ++ [ pkgs.python312Packages.langfuse ];
        }
      );
      packages.x86_64-linux.supergateway = pkgs.buildNpmPackage rec {
        pname = "supergateway";
        version = "3.1.0";
        src = pkgs.fetchFromGitHub {
          owner = "supercorp-ai";
          repo = pname;
          tag = "v${version}";
          hash = "sha256-z0X+8UPY8Jok126CgIWGvvJK2PQeLB+AjUXNoHquy8E=";
        };

        npmDepsHash = "sha256-aefAvfSiEa+W2SAkItBas+5Qu82RE/+Tz+t724GFmto=";

        # The prepack script runs the build script, which we'd rather do in the build phase.
        npmPackFlags = [ "--ignore-scripts" ];

        NODE_OPTIONS = "--openssl-legacy-provider";
      };
      packages.x86_64-linux.sillytavern-base = nix2containerPkgs.nix2container.buildImage {
        name = "sillytavern-base";
        config = {
          Cmd = [ "/bin/bash" ];
          Env = [
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
          ];
        };
        copyToRoot = [
          (pkgs.buildEnv {
            name = "root";
            paths = with pkgs; [ nodejs pnpm curl wget git tmux vim rsync borgmatic overmind openssh bashInteractive coreutils python3 busybox strace ];
            pathsToLink = [ "/bin" ];
          })
          mkUser
          mkTmp
          mkEnvSymlink # overmind calls /usr/bin/env which is not available in nixos
        ];
        perms = [
          mkTmpPerms
          mkUserPerms
        ];
        maxLayers = 100;
      };
      packages.x86_64-linux.litellm = nix2containerPkgs.nix2container.buildImage {
        name = "litellm";
        config = {
          Cmd = [ "/bin/bash" "-c" ''/bin/echo "$CONFIG_FILE" | /bin/base64 -d > /config.yaml && /bin/litellm -c /config.yaml'' ];
          Env = [
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "PATH=/bin:/usr/bin:/sbin:/usr/sbin"
            "PRISMA_QUERY_ENGINE_LIBRARY=${pkgs.prisma-engines}/lib/libquery_engine.node"
            "PRISMA_QUERY_ENGINE_BINARY=${pkgs.prisma-engines}/bin/query-engine"
            "PRISMA_SCHEMA_ENGINE_BINARY=${pkgs.prisma-engines}/bin/schema-engine"
          ];
        };
        copyToRoot = [
          (pkgs.buildEnv {
            name = "root";
            paths = with pkgs; [ bashInteractive postgresql openssl coreutils packages.x86_64-linux.litellm-pkg nodejs ] ++ packages.x86_64-linux.litellm-pkg.optional-dependencies.proxy ++ packages.x86_64-linux.litellm-pkg.optional-dependencies.extra_proxy;
            pathsToLink = [ "/bin" ];
          })
          mkUser
          mkTmp
          mkEnvSymlink
        ];
        perms = [
          mkTmpPerms
          mkUserPerms
        ];
        maxLayers = 100;
        tag = "${packages.x86_64-linux.litellm-pkg.src.tag}";
      };
      packages.x86_64-linux.mcp-gateway = nix2containerPkgs.nix2container.buildImage {
        name = "mcp-gateway";
        config = {
          Cmd = [ "/bin/bash" "-c" ''/bin/supergateway --stdio "$MCP_COMMAND" --port 8000 --baseUrl http://0.0.0.0:8000 --ssePath /sse --messagePath /message'' ];
          Env = [
            "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
            "PATH=/bin:/usr/bin:/sbin:/usr/sbin"
          ];
        };
        copyToRoot = [
          (pkgs.buildEnv {
            name = "root";
            paths = with pkgs; [ gitMinimal uutils-coreutils-noprefix python3 bashInteractive nodejs uv packages.x86_64-linux.supergateway ];
            pathsToLink = [ "/bin" ];
          })
          mkUser
          mkTmp
          mkEnvSymlink
        ];
        perms = [
          mkTmpPerms
          mkUserPerms
        ];
        maxLayers = 100;
      };
    };
}
