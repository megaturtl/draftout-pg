## Using this repo:

Running `nix develop` will fetch the latest pgdump from https://draftout.mittens.site/data-dump and load it into a local Postgres DB which will close when the nix devshell is exited.

It only re-downloads when the dump has changed, and removes the zip after loading. Once loaded, `views.sql` is applied automatically.

All db state is kept in the `.pg` folder, delete this to fully reset.

Configure the database (dump URL, db name, views file) using with the `# --- Config ---` block in `flake.nix`. 

Defaults:
- user = dev
- password = dev
- database = draftout
- host = localhost:5432
