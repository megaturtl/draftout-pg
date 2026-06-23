{
  description = "Local Postgres devshell that loads the a draftout pgdump";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };

        # --- Config ---
        pgUser = "dev";
        pgPassword = "dev";
        pgDatabase = "draftout";
        pgPort = "5432";
        # Manifest listing the available dumps.
        manifestUrl = "https://deepdive-datadump.mittens.site/manifest.json";
        # SQL file to apply after every load (set to "" to skip).
        viewsFile = "views.sql";
        # ---------------

        # Setup script packaged with runtime deps.
        # SC2154: PG*/MANIFEST_URL/... arrive via the env exported by the devshell below
        # so shellcheck can't see them assigned.
        setup-db = pkgs.writeShellApplication {
          name = "setup-db";
          runtimeInputs = with pkgs; [ postgresql_17 curl gzip jq coreutils gnugrep ];
          excludeShellChecks = [ "SC2154" ];
          text = builtins.readFile ./setup-db.sh;
        };
      in
      {
        devShells.default = pkgs.mkShell {
          # Cli tools for the devshell, the script carries its own build deps.
          packages = [ pkgs.postgresql_17 pkgs.jq setup-db ];

          # Export env variables for setup-db and for interactive psql use.
          PGUSER = pgUser;
          PGPASSWORD = pgPassword;
          PGDATABASE = pgDatabase;
          PGPORT = pgPort;
          MANIFEST_URL = manifestUrl;
          VIEWS_FILE = viewsFile;

          shellHook = ''
            # The imperative setup lives in this packaged setup-db script.
            setup-db

            # Stop the server when the shell exits.
            trap 'pg_ctl stop -D "$PWD/.pg/data" -m fast >/dev/null 2>&1 || true' EXIT
          '';
        };
      });
}
