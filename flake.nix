{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs?ref=nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";

    process-compose.url = "github:diamondburned/process-compose?ref=better-fps";
    process-compose.inputs = {
      nixpkgs.follows = "nixpkgs";
      flake-utils.follows = "flake-utils";
    };
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      process-compose,
      ...
    }@inputs:
    let
      lib = nixpkgs.lib;
      serverPhoneNumbers = [ "+19876543210" ];
      clientPhoneNumbers = [ "+11234567890" ];
    in
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        lib = nixpkgs.lib;

        pkgs = nixpkgs.legacyPackages.${system}.extend (
          self: super: { inherit (process-compose.packages.${system}) process-compose; }
        );

        mkJSONConfig = name: config: pkgs.writeText name (builtins.toJSON config);

        mkProcessesConfig = (
          {
            twipiURL ? null,
            basePort,
            stateDirectory,
          }:
          with lib;
          with builtins;
          rec {
            twicp = {
              port = basePort;
              command = "task dev";
              healthPath = "/";
              environment = {
                TWIPI_URL =
                  if twipiURL != null then "https://${twipiURL}" else "http://localhost:${toString twipi.port}";
              };
              dependsOn = [ "twipi" ];
            };
            fakesms = {
              port = basePort + 1;
              command = "task dev";
              healthPath = "/";
              environment = {
                WSBRIDGE_URL =
                  if twipiURL != null then
                    "wss://${twipiURL}/sms/ws"
                  else
                    "ws://localhost:${toString twipi.port}/sms/ws";
                WSBRIDGE_NUMBER_SELF = head clientPhoneNumbers;
                WSBRIDGE_NUMBER_SERVER = head serverPhoneNumbers;
              };
              dependsOn = [ "twipi" ];
            };
            twipi = {
              port = basePort + 100;
              command = "task dev";
              healthPath = "/health";
              environment = {
                TWID_CONFIG = mkJSONConfig "twid.json" {
                  listen_addr = "localhost:${toString twipi.port}";
                  twisms = {
                    services = [
                      {
                        module = "wsbridge_server";
                        http_path = "/sms/ws";
                        phone_numbers = serverPhoneNumbers;
                        acknowledgement_timeout = "5s";
                        message_queue = {
                          sqlite = {
                            path = "${stateDirectory}/twipi/wsbridge-queue.sqlite3";
                            max_age = "1400h";
                          };
                        };
                      }
                    ];
                  };
                  twicmd = {
                    parsers = [ { module = "slash"; } ];
                    services = [
                      {
                        module = "http";
                        name = "discord";
                        base_url = "http://localhost:${toString twidiscord.port}";
                      }
                    ];
                  };
                };
              };
              dependsOn = [
                "twipi-generate"
                "twidiscord"
                # twittt
              ];
            };
            twidiscord = {
              port = basePort + 101;
              command = ''
                go run . \
                  -l :${toString twidiscord.port} \
                  -p "${stateDirectory}/twidiscord/state.db"
              '';
              healthPath = "/health";
              after = [ "twipi-generate" ];
            };
            # TODO: twittt

            twipi-generate = {
              workingDirectory = "twipi";
              command = ''
                task generate
              '';
            };
          }
        );

        processComposeFile =
          args:
          mkJSONConfig "process-compose.json" (
            let
              stateDirectory = "/tmp/twipi";
              processesConfig = mkProcessesConfig (
                {
                  basePort = 5000;
                  inherit stateDirectory;
                }
                // args
              );
              mapDependsOn =
                processes: condition:
                builtins.listToAttrs (map (process: lib.nameValuePair process { inherit condition; }) processes);
            in
            {
              version = "0.5";
              processes = lib.mapAttrs' (name: process: {
                inherit name;
                value = (
                  {
                    working_dir = "./" + (process.workingDirectory or name);
                    command =
                      let
                        script = pkgs.writeShellScript "${name}.sh" ''
                          set -ex
                          mkdir -p "$STATE_DIRECTORY"
                          ${process.command}
                        '';
                      in
                      "nix develop -c ${script}";
                    environment = lib.mapAttrsToList (k: v: "${k}=${v}") (
                      (process.environment or { })
                      // (lib.optionalAttrs (process ? "port") { PORT = toString process.port; })
                      // ({ STATE_DIRECTORY = stateDirectory + "/" + name; })
                    );
                    shutdown = {
                      signal = 2; # SIGINT
                      timeout_seconds = 5;
                    };
                    depends_on =
                      { }
                      // (mapDependsOn (process.after or [ ]) "process_completed_successfully")
                      // (mapDependsOn (process.dependsOn or [ ]) "process_healthy");
                  }
                  // (lib.optionalAttrs (process ? "healthPath") {
                    readiness_probe = {
                      http_get = {
                        host = "localhost";
                        port = process.port;
                        path = process.healthPath;
                      };
                      period_seconds = 1;
                      failure_threshold = 300;
                    };
                    availability = {
                      restart = "exit_on_failure";
                      backoff_seconds = 2;
                    };
                  })
                );
              }) processesConfig;
            }
          );

        processCompose =
          args:
          pkgs.writeShellApplication rec {
            name = "twipi-dev";
            meta.mainProgram = "twipi-dev";
            runtimeInputs = [ pkgs.process-compose ];
            text = ''
              exec process-compose up \
                --config ${processComposeFile args} \
                --ref-rate 100ms \
                --no-server \
                --keep-tui \
                --ordered-shutdown
            '';
          };
      in
      {
        packages = rec {
          dev = processCompose { };
          prod = processCompose { twipiURL = "twipi.libdb.so"; };
        };

        devShells.default = pkgs.mkShell {
          packages = [
            self.formatter.${system}
            pkgs.go_1_22
            (pkgs.writeShellScriptBin "run" "nix run .?submodules=1#dev")
          ];
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
