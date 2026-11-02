# mini-autocomplete: Tab completion for zsh driven by Fig's autocomplete specs.
# Source this at the END of ~/.zshrc (after oh-my-zsh / compinit).

typeset -g MINI_AC_DIR=${${(%):-%x}:A:h}
typeset -g MINI_AC_SPECS=$MINI_AC_DIR/node_modules/@withfig/autocomplete/build
typeset -g MINI_AC_NODE=${commands[node]}

_mini_ac() {
  [[ -n $MINI_AC_NODE && $compstate[context] == command ]] || return 1
  (( CURRENT > 1 )) || return 1

  local -a w
  w=("${(@Q)words[1,CURRENT-1]}")
  # Resolve an alias in command position, e.g. `g` -> `git`.
  if (( $+aliases[$w[1]] )); then
    local -a expanded
    expanded=("${(@Q)${(z)aliases[$w[1]]}}")
    w=("${(@)expanded}" "${(@)w[2,-1]}")
  fi
  local cmd=${w[1]:t}
  [[ -f $MINI_AC_SPECS/$cmd.js ]] || return 1

  local out
  out=$("$MINI_AC_NODE" "$MINI_AC_DIR/complete.mjs" "$cmd" "${(@)w[2,-1]}" -- "${(Q)PREFIX}" 2>/dev/null) || return 1

  local -a subs opts args
  local files= line kind name desc entry
  for line in "${(@f)out}"; do
    case $line in
      @files)   files=files ;;
      @folders) files=${files:-folders} ;;
      ?$'\t'*)
        kind=${line[1]}
        line=${line[3,-1]}
        name=${line%%$'\t'*}
        desc=${line#*$'\t'}
        entry=${name//:/\\:}${desc:+:$desc}
        case $kind in
          s) subs+=("$entry") ;;
          o) opts+=("$entry") ;;
          a) args+=("$entry") ;;
        esac ;;
    esac
  done

  local ret=1
  (( $#args )) && _describe -t mini-arguments 'argument' args && ret=0
  (( $#subs )) && _describe -t mini-subcommands 'subcommand' subs && ret=0
  (( $#opts )) && _describe -t mini-options 'option' opts && ret=0
  case $files in
    files)   _files && ret=0 ;;
    folders) _files -/ && ret=0 ;;
  esac
  # Nothing from the spec (e.g. a free-text argument): fall back to zsh's own completion.
  return ret
}

# Run before the existing completers so commands without a spec keep working as before.
() {
  local -a current
  zstyle -a ':completion:*' completer current
  (( $#current )) || current=(_complete _ignored)
  (( ${current[(I)_mini_ac]} )) || zstyle ':completion:*' completer _mini_ac "${(@)current}"
}

# Show descriptions and group headings in the menu.
zstyle ':completion:*:mini-*' group-name ''
zstyle ':completion:*:mini-*' format '%F{yellow}-- %d --%f'

# Kiro/Fig-style dropdown
source "$MINI_AC_DIR/dropdown.zsh"
