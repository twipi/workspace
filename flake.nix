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
      twipiPublicHost = "twipi.libdb.so";
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
            basePort,
            production ? false,
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
                HOST = if production then "0.0.0.0" else "localhost";
                TWIPI_URL =
                  if production then "https://${twipiPublicHost}" else "http://localhost:${toString twipi.port}";
              };
              dependsOn = [ "twipi" ];
            };
            fakesms = {
              port = basePort + 1;
              command = "task dev";
              healthPath = "/";
              environment = {
                HOST = if production then "0.0.0.0" else "localhost";
                WSBRIDGE_URL =
                  if production then
                    "wss://${twipiPublicHost}/api/fakesms/ws"
                  else
                    "ws://localhost:${toString twipi.port}/api/fakesms/ws";
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
                        http_path = "/api/fakesms/ws";
                        phone_numbers = serverPhoneNumbers;
                        acknowledgement_timeout = "1s";
                        # TODO: figure out why SQLite is shitting the bed.
                        # message_queue = {
                        #   sqlite = {
                        #     path = "${stateDirectory}/twipi/wsbridge-queue.sqlite3";
                        #     max_age = "1400h";
                        #   };
                        # };
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
                      {
                        module = "http";
                        name = "ttt";
                        base_url = "http://localhost:${toString twittt.port}";
                      }
                    ];
                  };
                };
              };
              dependsOn = [
                "twidiscord"
                "twittt"
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
            twittt = {
              port = basePort + 102;
              command = "go run . -l :${toString twittt.port}";
              healthPath = "/health";
              after = [ "twipi-generate" ];
            };
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
                      backoff_seconds = 10;
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
                --keep-tui
            '';
          };
      in
      {
        packages = rec {
          dev = processCompose { };
          prod = processCompose { production = true; };
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
