#!/bin/bash
###############################################################################
# SSDv2 — prérequis du mode natif macOS.
#
# Idempotent : chaque étape vérifie avant d'installer. Lancé automatiquement par
# install_common() sur Darwin (includes/functions.sh), ou à la main :
#
#   ./includes/nativeapps/bootstrap.sh
#
# Étapes sans privilège : Xcode CLT, Homebrew, formules brew.
# Étapes avec sudo (demandées, jamais silencieuses) : cask macFUSE, /etc/hosts.
# Sauté proprement (avec un rappel) si pas de terminal interactif ou
# SSD_SKIP_SUDO=1. Une étape optionnelle qui échoue n'interrompt pas le reste.
###############################################################################
set -uo pipefail

YELLOW="${YELLOW:-\033[0;33m}"; GREEN="${GREEN:-\033[0;32m}"
RED="${RED:-\033[0;31m}"; BLUE="${BLUE:-\033[0;36m}"; NC="${NC:-\033[0m}"

say()  { echo -e "${BLUE}==>${NC} $*"; }
ok()   { echo -e " ${GREEN}✓${NC} $*"; }
warn() { echo -e " ${YELLOW}!${NC} $*" >&2; }

if [ "$(uname -s)" != "Darwin" ]; then
  echo "bootstrap.sh : macOS uniquement." >&2; exit 1
fi

INTERACTIVE=0
[ -t 0 ] && [ -z "${SSD_SKIP_SUDO:-}" ] && INTERACTIVE=1

# Formules Homebrew : seedbox.sh (bash>=4, getopt --long, gettext, dialog),
# builds (git, go), runtimes des apps natives (node@22, python@3.12),
# smartmontools (temp NVMe du dashboard). node@/python@ sont aussi posés à la
# demande par install_native_app.sh — ici on prend de l'avance.
BREW_FORMULAE="bash gnu-getopt gettext dialog git go node@22 python@3.12 smartmontools"

# ---------------------------------------------------------------------------
# 1. Xcode Command Line Tools (compilateurs — go, node-gyp, better-sqlite3…)
# ---------------------------------------------------------------------------
say "Xcode Command Line Tools"
if xcode-select -p >/dev/null 2>&1; then
  ok "déjà présents"
else
  warn "absents — lancement de l'installeur graphique Apple"
  xcode-select --install 2>/dev/null || true
  echo -e "${YELLOW}   Terminez l'installation dans la fenêtre Apple puis relancez ce script.${NC}"
  exit 1
fi

# ---------------------------------------------------------------------------
# 2. Homebrew
# ---------------------------------------------------------------------------
say "Homebrew"
if command -v brew >/dev/null 2>&1; then
  ok "$(brew --version | head -1)"
else
  if [ "${INTERACTIVE}" -eq 1 ]; then
    warn "absent — installation via le script officiel (demandera le mot de passe admin)"
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  else
    warn "absent. Installez-le : https://brew.sh puis relancez."
    exit 1
  fi
fi
# S'assurer que brew est dans le PATH de ce shell (Apple Silicon)
[ -x /opt/homebrew/bin/brew ] && eval "$(/opt/homebrew/bin/brew shellenv)"

# ---------------------------------------------------------------------------
# 3. Formules Homebrew
# ---------------------------------------------------------------------------
say "Formules Homebrew"
MISSING=""
for f in ${BREW_FORMULAE}; do
  brew list --versions "${f}" >/dev/null 2>&1 && ok "${f}" || MISSING="${MISSING} ${f}"
done
if [ -n "${MISSING}" ]; then
  say "installation :${MISSING}"
  # shellcheck disable=SC2086
  brew install ${MISSING} || warn "certaines formules ont échoué — vérifiez ci-dessus"
fi

# ---------------------------------------------------------------------------
# 4. macFUSE (optionnel — requis uniquement par decypharr). Cask -> sudo +
#    approbation d'une extension système + redémarrage.
# ---------------------------------------------------------------------------
say "macFUSE (mount decypharr — optionnel)"
if [ -d /Library/Filesystems/macfuse.fs ] || [ -d /Library/Filesystems/osxfuse.fs ]; then
  ok "déjà installé"
elif [ "${INTERACTIVE}" -eq 1 ]; then
  printf "   Installer macFUSE maintenant ? (extension système + redémarrage requis) [o/N] "
  read -r rep
  case "${rep}" in
    o|O|oui|y|Y)
      brew install --cask macfuse \
        && echo -e "${YELLOW}   → Réglages Système > Confidentialité et sécurité : autorisez « Benjamin Fleischer », puis REDÉMARREZ.${NC}" \
        || warn "échec de l'installation de macFUSE"
      ;;
    *) warn "sauté — decypharr ne pourra pas monter tant que macFUSE n'est pas installé" ;;
  esac
else
  warn "sauté (non interactif). Pour decypharr : brew install --cask macfuse (+ redémarrage)"
fi

# ---------------------------------------------------------------------------
# 5. /etc/hosts : ssd.local -> 127.0.0.1 (WebUI via Traefik). sudo.
# ---------------------------------------------------------------------------
if [ -f "$(dirname "$0")/vars/webui.yml" ]; then
  say "/etc/hosts : ssd.local"
  if grep -qE '^\s*127\.0\.0\.1\s+.*\bssd\.local\b' /etc/hosts; then
    ok "déjà présent"
  elif [ "${INTERACTIVE}" -eq 1 ]; then
    printf "   Ajouter '127.0.0.1 ssd.local' à /etc/hosts ? (sudo) [o/N] "
    read -r rep
    case "${rep}" in
      o|O|oui|y|Y)
        echo "127.0.0.1 ssd.local" | sudo tee -a /etc/hosts >/dev/null && ok "ajouté" \
          || warn "échec — ajoutez la ligne manuellement" ;;
      *) warn "sauté — accédez au WebUI via http://localhost:8000" ;;
    esac
  else
    warn "sauté (non interactif). WebUI : http://localhost:8000, ou ajoutez 'ssd.local' à /etc/hosts"
  fi
fi

say "Prérequis natifs : terminé."
echo -e "${YELLOW}Rappel : lancer seedbox.sh avec le bash de Homebrew — /opt/homebrew/bin/bash ./seedbox.sh${NC}"
