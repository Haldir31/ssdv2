# Native app secrets

This repo is a **public fork**, so no credential ever goes in
`includes/nativeapps/vars/<name>.yml` or in any tracked script.

## How it works

In a `vars/<name>.yml` `env:` block, a value of exactly `__SECRET__` is
resolved at install time from:

    ${SSD_SECRETS_DIR:-~/.config/ssd/native-secrets}/<name>.env

a `chmod 600` file of `KEY=VALUE` lines (same key name as in the yml). A
missing file, or a missing/empty key, aborts the install — an app is never
installed with a blank password.

`traefik` is special: the dashboard basic-auth comes from
`native-secrets/traefik.env` (`DASHBOARD_AUTH=user:password`), or the env var
`SSD_TRAEFIK_DASHBOARD_AUTH`, or is auto-generated and written there on first
`install_native_app.sh traefik`.

## Setup on a new machine

    mkdir -p ~/.config/ssd/native-secrets && chmod 700 ~/.config/ssd/native-secrets
    umask 077

Then create the files you need:

### u2p.env
    ATHANOR_DATABASE_POSTGRES_PASSWORD=<postgres role "athanor" password>
    ATHANOR_MEILISEARCH_API_KEY=<meilisearch master/api key>
    ATHANOR_SERVER_ADMIN_PASSWORD=<u2p dashboard password>   # user is haldir; "-" disables auth

### proxymon.env
    PROXYMON_PASSWORD=<proxymon web login password>          # user is haldir
    PROXYMON_SECRET=<cookie signing secret, openssl rand -hex 32>

### slicksync.env
    SLICKSYNC_PRIVATE_PASSWORD=<slicksync web login password>
    AIOSTREAMS_AUTH_PASSWORD=<must match aiostreams.env password>

### placeholdarr.env
    TMDB_API_KEY=<themoviedb v3 api key>
    DB_PASS=<postgres role "placeholdarr" password>

### reborn-catalog.env
    RC_PG_PASS=<postgres role "streamfusion" password>

### aiostreams.env
    AIOSTREAMS_AUTH=haldir:<password>                        # user:pass, comma-separate for more users

### traefik.env
    DASHBOARD_AUTH=haldir:<password>
