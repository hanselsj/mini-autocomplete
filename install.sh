#!/usr/bin/env bash
# Install (or update) mini-autocomplete.
#
#   curl -fsSL https://raw.githubusercontent.com/hanselsj/mini-autocomplete/main/install.sh | bash
#
# or, from a clone:  ./install.sh
#
# Environment:
#   MINI_AC_HOME   where to install when run via curl (default: ~/.mini-autocomplete)
#   MINI_AC_REPO   git URL to clone from

set -euo pipefail

REPO=${MINI_AC_REPO:-https://github.com/hanselsj/mini-autocomplete.git}
DEFAULT_HOME=${MINI_AC_HOME:-$HOME/.mini-autocomplete}
MARKER="# mini-autocomplete"

bold=$'\e[1m'; green=$'\e[32m'; red=$'\e[31m'; dim=$'\e[2m'; reset=$'\e[0m'
info() { printf '%s==>%s %s\n' "$bold" "$reset" "$*"; }
ok()   { printf '%s✓%s %s\n' "$green" "$reset" "$*"; }
die()  { printf '%s✗ %s%s\n' "$red" "$*" "$reset" >&2; exit 1; }

# ---------- requirements ----------

command -v zsh >/dev/null || die "zsh is required."
command -v git >/dev/null || die "git is required."
command -v node >/dev/null || die "Node.js 20+ is required (https://nodejs.org or 'brew install node')."
command -v npm >/dev/null || die "npm is required (it ships with Node.js)."
node_major=$(node -p 'process.versions.node.split(".")[0]')
(( node_major >= 20 )) || die "Node.js 20+ is required (found $(node -v))."

# ---------- get the code ----------

# Running from inside a clone? Install from there instead of cloning again.
script_dir=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fi

if [[ -n "$script_dir" && -f "$script_dir/dropdown.zsh" ]]; then
  dir=$script_dir
  info "Installing from $dir"
elif [[ -d "$DEFAULT_HOME/.git" ]]; then
  dir=$DEFAULT_HOME
  info "Updating $dir"
  git -C "$dir" pull --ff-only --quiet || die "Couldn't update $dir (local changes?)."
else
  dir=$DEFAULT_HOME
  [[ -e "$dir" ]] && die "$dir already exists and isn't a mini-autocomplete clone. Move it or set MINI_AC_HOME."
  info "Cloning into $dir"
  git clone --quiet --depth 1 "$REPO" "$dir"
fi

# ---------- dependencies ----------

info "Installing the Fig specs (npm)"
(cd "$dir" && npm install --no-audit --no-fund --no-update-notifier --loglevel=error >/dev/null) || die "npm install failed."
ok "$(ls "$dir/node_modules/@withfig/autocomplete/build" | grep -c '\.js$') command specs installed"

# ---------- hook into zsh ----------

zshrc="${ZDOTDIR:-$HOME}/.zshrc"
line="source \"$dir/mini-autocomplete.zsh\""
touch "$zshrc"
if grep -q 'mini-autocomplete\.zsh' "$zshrc"; then
  ok "$zshrc already loads mini-autocomplete"
else
  printf '\n%s (keep this at the end, after oh-my-zsh)\n%s\n' "$MARKER" "$line" >> "$zshrc"
  ok "Added to $zshrc"
fi

# Restart the suggestion server so it picks up new code.
pkill -f "$dir/server.mjs" 2>/dev/null || true

echo
ok "${bold}mini-autocomplete is installed.${reset}"
echo "   Open a new terminal (or run: exec zsh), then type ${bold}cd ${reset} or ${bold}git ${reset} to see the dropdown."
echo "   ${dim}Up/Down select · Tab insert · Enter insert/run · Esc hide${reset}"
