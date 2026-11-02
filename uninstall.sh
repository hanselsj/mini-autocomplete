#!/usr/bin/env bash
# Remove mini-autocomplete: unhooks it from ~/.zshrc, stops the server and,
# if it was installed via curl, deletes ~/.mini-autocomplete.
#
#   ~/.mini-autocomplete/uninstall.sh

set -euo pipefail

dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
default_home=${MINI_AC_HOME:-$HOME/.mini-autocomplete}
zshrc="${ZDOTDIR:-$HOME}/.zshrc"

if [[ -f "$zshrc" ]] && grep -q 'mini-autocomplete' "$zshrc"; then
  cp "$zshrc" "$zshrc.mini-ac.bak"
  grep -v -e '^# mini-autocomplete' -e 'mini-autocomplete\.zsh' "$zshrc.mini-ac.bak" > "$zshrc"
  echo "✓ Removed from $zshrc (backup: $zshrc.mini-ac.bak)"
fi

pkill -f "$dir/server.mjs" 2>/dev/null || true
rm -f "${TMPDIR:-/tmp}/mini-ac-$(id -u).sock"

if [[ "$dir" == "$default_home" ]]; then
  rm -rf "$dir"
  echo "✓ Deleted $dir"
else
  echo "  Left the code in $dir (delete it yourself if you like)."
fi
echo "✓ Uninstalled. Open a new terminal to finish."
