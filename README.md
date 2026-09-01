<br /><img src="https://user-images.githubusercontent.com/64525827/107496602-ceddbb80-6b91-11eb-9a05-ac311eedf150.png" width="450">
<br />

[Documentation](https://projetssd.github.io/ssdv2_docs/)

[![Discord: https://discord.gg/ZhWvKVmTuh](https://img.shields.io/badge/Discord-gray.svg?style=for-the-badge)](https://discordapp.com/invite/ZhWvKVmTuh)

## JetBrains
merci à  [<img src="/images/jetbrains-training-partner.svg" alt="JetBrains" width="32"> JetBrains](http://www.jetbrains.com/) pour les licences open source qui nous permettent de travailler sur ce projet.

* [<img src="/images/icon-phpstorm.svg" alt="PhpStorm" width="32"> PhpStorm](http://www.jetbrains.com/phpstorm/)
* [<img src="/images/icon-webstorm.svg" alt="WebStorm" width="32"> WebStorm](http://www.jetbrains.com/webstorm/)
* [<img src="/images/icon-pycharm.svg" alt="Pycharm" width="32"> Pycharm](http://www.jetbrains.com/pycharm/)
***

> Ce script est proposé à des fins d'expérimentation uniquement, le téléchargement d’oeuvre copyrightées est illégal.
Merci de vous conformer à la législation en vigueur en fonction de vos pays respectifs en faisant vos tests sur des fichiers libres de droits
***

## Mode natif macOS (fork expérimental)

Sur macOS, SSDv2 bascule automatiquement en **mode natif** : pas de Docker, chaque
application tourne comme un processus macOS géré par un **LaunchAgent**. Le flux Linux
d'origine (Docker + Ansible) est inchangé.

### Prérequis macOS

```sh
brew install bash gnu-getopt gettext dialog git go
# lancer seedbox.sh avec le bash de Homebrew (le /bin/bash système est en 3.2) :
/opt/homebrew/bin/bash ./seedbox.sh
```

`get_os_type` (dans `includes/variables.sh`) détecte `Darwin` et pose `SSD_OS=Darwin` +
`NATIVE_MODE=1`. Docker, UFW, logrotate et le rôle Ansible `geerlingguy.docker` sont alors
ignorés (avec un message, pas une erreur silencieuse).

### Comment ça marche

| Docker (Linux)                                   | Natif (macOS)                                             |
|--------------------------------------------------|----------------------------------------------------------|
| `includes/dockerapps/vars/<app>.yml` (image + env) | `includes/nativeapps/vars/<app>.yml` (source + build + env) |
| rôle Ansible générique → module `docker_container` | `includes/nativeapps/install_native_app.sh <app>`        |
| conteneur                                        | LaunchAgent `~/Library/LaunchAgents/com.ssd.<app>.plist`  |
| réseau `traefik_proxy` + labels                  | Traefik natif (`brew`), file provider (`dynamic/apps.yml`) |

`launch_service <app>` (dans `includes/functions.sh`) dispatche automatiquement : si
`includes/nativeapps/vars/<app>.yml` existe → installation native ; sinon message
« non supporté en mode natif (nécessite Docker) ».

### Ajouter une application au catalogue natif

Créer `includes/nativeapps/vars/<app>.yml` (sous-ensemble YAML **volontairement
restreint** — pas de Jinja2 : `clé: valeur` à plat + un bloc `env:` indenté de 2 espaces ;
le jeton `__APP_DATA_DIR__` est remplacé par le dossier de données de l'appli) :

```yaml
name: monapp
kind: node          # node | go | brew
repo: https://github.com/org/monapp.git
ref: main
node_version: 22            # kind: node
build_cmd: npm ci && npm run build
start_cmd: node dist/server.js
formula: monapp             # kind: brew (au lieu de repo/build)
config_render: render_xxx.sh # optionnel, kind: brew
port: 9000
health_path: /health
data_dir: monapp            # -> <SETTINGS_STORAGE>/native/monapp
env:
  PORT: 9000
```

Puis : `./includes/nativeapps/install_native_app.sh monapp`.

### Premier lot porté (validé sur macOS 27 / Apple Silicon)

| App            | kind | port  | notes |
|----------------|------|-------|-------|
| **gethomepage** (dashboard) | node | 3050  | Next.js standalone ; config sous `<storage>/native/gethomepage/src/.next/standalone/config/` ; ajouter votre domaine à `HOMEPAGE_ALLOWED_HOSTS` |
| **decypharr** (symlinks/AllDebrid) | go | 8282 | build CGO ; nécessite **macFUSE** ; éditer `<storage>/native/decypharr/config.json` (token debrid) puis `launchctl kickstart -k gui/$(id -u)/com.ssd.decypharr` |
| **traefik** (reverse proxy) | brew | 8000 / 8443 / 8080 | dashboard+API sur :8080 ; config générée depuis `render_traefik_config.sh` ; entrypoints en `127.0.0.1:80xx` (LaunchAgent sans root) — pour `:80/:443`, éditer `traefik.yml` et charger en LaunchDaemon |

Les ~180 autres applications restent **Docker uniquement** pour l'instant et l'indiquent
clairement. En ajouter au catalogue natif = un fichier `nativeapps/vars/<app>.yml` de plus,
en connaissant la façon de builder/lancer l'appli hors conteneur.

### Hors périmètre en mode natif

Authelia, OAuth2 Proxy, crowdsec, UFW, logrotate — piliers Linux non portés. Le tunnel
Cloudflare / un reverse-proxy TLS externe couvrent le besoin d'accès distant.
***
