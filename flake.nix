{
  description = "A very basic flake";

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
          { basePort, stateDirectory }:
          with lib;
          with builtins;
          rec {
            twicp = {
              command = "task dev";
              port = basePort;
              environment = {
                TWIPI_URL = "http://localhost:${toString (basePort + 100)}";
              };
              healthPath = {
                port = basePort;
                path = "/";
              };
            };
            fakesms = {
              command = "task dev";
              port = basePort + 80;
              healthPath = {
                port = basePort + 80;
                path = "/";
              };
              environment = {
                WSBRIDGE_URL = "ws://localhost:${toString twipi.port}/sms/ws";
                WSBRIDGE_NUMBER_SELF = head clientPhoneNumbers;
                WSBRIDGE_NUMBER_SERVER = head serverPhoneNumbers;
              };
            };
            twipi = {
              command = "task dev";
              port = basePort + 100;
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
            };
            twidiscord = {
              command = ''
                go run . \
                  -l :${toString twidiscord.port} \
                  -p "${stateDirectory}/twidiscord/state.db"
              '';
              port = basePort + 100;
              dependsOn = [ "twipi" ];
              healthPath = "/health";
            };
            # TODO: twittt
          }
        );

        processComposeConfig = (
          let
            stateDirectory = "/tmp/twipi";
            processesConfig = mkProcessesConfig {
              basePort = 5000;
              inherit stateDirectory;
            };
          in
          {
            version = "0.5";
            processes = lib.mapAttrs' (
              name: process:
              (lib.nameValuePair name {
                command = ''
                  mkdir -p ${stateDirectory}/${name}
                  nix develop -c ${process.command}
                '';
                workingDir = "${./.}/${name}";
                environment = (process.environment or { }) // {
                  STATE_DIRECTORY = stateDirectory + "/" + name;
                };
                readinessProbe = {
                  httpGet = {
                    host = "localhost";
                    port = process.port;
                    path = process.healthPath;
                  };
                  periodSeconds = 1;
                  failureThreshold = 300;
                };
                shutdown = {
                  signal = 2; # SIGINT
                  timeoutSeconds = 5;
                };
                dependsOn = lib.optionalAttrs (process ? "dependsOn") (
                  builtins.listToAttrs (
                    map (process: {
                      name = process;
                      value.condition = "process_healthy";
                    }) process.dependsOn
                  )
                );
                availability = {
                  restart = "always";
                  backoff_seconds = 5;
                };
              })
            ) processesConfig;
          }
        );
      in
      {
        packages.default = pkgs.writeShellApplication rec {
          name = "twipi-dev";
          meta.mainProgram = "twipi-dev";
          runtimeInputs = [ pkgs.process-compose ];
          text = ''
            process-compose run \
              --config ${mkJSONConfig "process-compose.json" processComposeConfig} \
              --ref-rate 50ms \
              --no-server \
              --ordered-shutdown
          '';
        };

        devShells.default = pkgs.mkShell {
          packages = [
            self.formatter.${system}
            self.packages.${system}.default
            pkgs.go_1_22
          ];
        };

        formatter = pkgs.nixfmt-rfc-style;
      }
    );
}
