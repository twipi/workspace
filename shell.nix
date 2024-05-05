{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
	packages = with pkgs; [
		process-compose
	];

	PC_PORT_NUM = "28754";
}
