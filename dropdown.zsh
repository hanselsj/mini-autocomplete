# mini-autocomplete dropdown: a Kiro/Fig-style suggestion box drawn under the cursor.
#
#   type `cd ` / `git ` ...  the box opens and filters as you type
#   Up / Down                move the selection
#   Tab                      insert the selection
#   Enter                    insert the selection; runs the line when you
#                            haven't picked anything, or what you typed already
#                            matches the selection exactly
#   Esc                      hide the box until the next word
#
# Sourced by mini-autocomplete.zsh; expects MINI_AC_DIR / MINI_AC_NODE / MINI_AC_SPECS.

[[ -o interactive && -n $MINI_AC_NODE ]] || return 0
zmodload zsh/net/socket zsh/zselect 2>/dev/null || return 0

typeset -gi MINI_AC_ROWS=${MINI_AC_ROWS:-8}
typeset -g  _mac_sock=${TMPDIR:-/tmp}/mini-ac-$UID.sock
typeset -gi _mac_open=0 _mac_drawn=0 _mac_sel=1 _mac_top=1 _mac_nav=0 _mac_dismiss=-1 _mac_pw=0
typeset -g  _mac_key= _mac_files= _mac_prefix= _mac_lastprefix= _mac_buf= _mac_cur=
typeset -ga _mac_items _mac_view _mac_words

# ---------- talking to the completion server ----------

_mac_start_server() {
  rm -f -- $_mac_sock
  ( cd / && exec "$MINI_AC_NODE" "$MINI_AC_DIR/server.mjs" "$_mac_sock" ) &>/dev/null &!
  local i
  for i in {1..40}; do
    [[ -S $_mac_sock ]] && return 0
    zselect -t 5
  done
  return 1
}

# _mac_request <prefix> <words...>  ->  $reply (one entry per line)
_mac_request() {
  local req="$PWD"$'\x1f'"$1" line fd
  shift
  req+=$'\x1f'"${(pj:\x1f:)@}"
  reply=()
  if ! zsocket $_mac_sock 2>/dev/null; then
    _mac_start_server && zsocket $_mac_sock 2>/dev/null || return 1
  fi
  fd=$REPLY
  print -rn -u $fd -- "$req"$'\n'
  while IFS= read -r -u $fd line; do reply+=("$line"); done
  exec {fd}>&-
  return 0
}

mini-ac-restart() {
  pkill -f "$MINI_AC_DIR/server.mjs" 2>/dev/null
  rm -f -- $_mac_sock
}

# ---------- reading the command line ----------

# Sets _mac_words (unquoted words of the current command before the cursor word)
# and _mac_prefix (the raw word under the cursor). Fails when there's nothing to suggest.
_mac_context() {
  setopt localoptions extendedglob
  [[ -z $RBUFFER || $RBUFFER == [[:space:]]* ]] || return 1
  local -a z
  z=(${(z)LBUFFER})
  local prefix=
  if [[ -n $LBUFFER && $LBUFFER != *[[:space:]] ]]; then
    prefix=${z[-1]}
    z[-1]=()
  fi
  local -a seps=(';' '&&' '||' '|' '|&' '&' '(' '{' '!' 'then' 'do' 'else' 'elif' 'if' 'while' 'until')
  (( ${seps[(Ie)$prefix]} )) && return 1
  local i
  for (( i = $#z; i > 0; i-- )); do
    (( ${seps[(Ie)$z[i]]} )) && break
  done
  z=("${(@)z[i+1,-1]}")
  # Skip leading VAR=value assignments.
  while (( $#z )) && [[ $z[1] == [A-Za-z_][A-Za-z0-9_]#=* ]]; do z[1]=(); done
  (( $#z )) || return 1   # still typing the command name

  _mac_words=("${(@Q)z}")
  if (( $+aliases[$_mac_words[1]] )); then
    local -a expanded
    expanded=("${(@Q)${(z)aliases[$_mac_words[1]]}}")
    _mac_words=("${(@)expanded}" "${(@)_mac_words[2,-1]}")
  fi
  _mac_words[1]=${_mac_words[1]:t}
  _mac_prefix=$prefix
}

_mac_fetch() {
  local key=$PWD$'\x1f'${(pj:\x1f:)_mac_words}
  [[ $key == $_mac_key ]] && return 0
  _mac_key=$key
  _mac_items=()
  _mac_files=
  _mac_request "" "${_mac_words[@]}" || return 1
  local line
  for line in "${reply[@]}"; do
    case $line in
      @files|@nospec) _mac_files=files ;;
      @folders)       _mac_files=${_mac_files:-folders} ;;
      ?$'\t'*)        _mac_items+=("$line") ;;
    esac
  done
  # Generators like cd's only list ./ — when every argument looks like a path,
  # list from disk instead so `cd Repos/<...>` works.
  local -a args=(${(M)_mac_items:#a$'\t'*})
  local -a dirs=(${(M)args:#a$'\t'*/$'\t'*})
  if (( $#args && $#dirs == $#args )); then
    _mac_items=(${_mac_items:#a$'\t'*})
    _mac_files=${_mac_files:-folders}
  fi
}

# ---------- filtering ----------

# _mac_score <lowercased name> <lowercased query> <fuzzy pattern>
# Sets REPLY to a sortable rank (tier + score) or fails when there's no match:
#   0 starts with the query   1 query starts a word (after - _ . / : @ space)
#   2 contains the query      3 fuzzy: query letters in order (tightest first)
_mac_score() {
  local n=$1 lq=$2 fpat=$3 p
  if [[ -z $lq || $n == ${lq}* ]]; then
    REPLY=0000
  elif [[ $n == *[-_./:@\ ]${lq}* ]]; then
    p=${n%%[-_./:@ ]${lq}*}
    REPLY=1${(l:3::0:)${#p}}
  elif [[ $n == *${lq}* ]]; then
    p=${n%%${lq}*}
    REPLY=2${(l:3::0:)${#p}}
  elif [[ $n == *${~fpat}* ]]; then
    p=${(SM)n#${~fpat}}
    REPLY=3${(l:3::0:)${#p}}
  else
    return 1
  fi
}

# Builds _mac_view, best match first: entries "kind<TAB>name<TAB>description<TAB>text-to-insert".
_mac_filter() {
  setopt localoptions extendedglob
  local raw=$_mac_prefix q=${(Q)_mac_prefix}
  local lq=${(L)q} item kind rest name desc pass ins
  local fpat=${(j:*:)${(@b)${(s::)lq}}}
  local -a ranked ents
  local -i idx=0

  for pass in 0 1; do
    ranked=()
    local want_opts=$pass
    [[ $q == -* ]] && want_opts=1
    for item in "${_mac_items[@]}"; do
      kind=${item[1]}
      rest=${item[3,-1]}
      name=${rest%%$'\t'*}
      desc=${rest#*$'\t'}
      if (( want_opts )); then [[ $kind == o ]] || continue
      else [[ $kind == o ]] && continue; fi
      (( idx++ ))
      _mac_score "${(L)name}" "$lq" "$fpat" || continue
      # $VARS are inserted as-is, everything else shell-quoted.
      if [[ $name == \$* ]]; then ins=$name; else ins=${(q)name}; fi
      ranked+=("$REPLY${(l:5::0:)idx}"$'\x1f'"$kind"$'\t'"$name"$'\t'"$desc"$'\t'"$ins")
    done

    if [[ -n $_mac_files && $q != -* ]] && (( pass == 0 )); then
      local dir= base=$q rawdir=
      if [[ $q == */* ]]; then dir=${q%/*}/; base=${q##*/}; rawdir=${raw%/*}/; fi
      local gdir=${dir/#\~/$HOME}
      local bq=${(L)base}
      local bpat=${(j:*:)${(@b)${(s::)bq}}}
      local qual=N
      [[ $base == .* ]] && qual+=D
      [[ $_mac_files == folders ]] && qual+=-/
      ents=( ${gdir:-./}*(${~qual}) )
      local e n
      for e in ${ents[1,1000]}; do
        n=${e:t}
        (( idx++ ))
        _mac_score "${(L)n}" "$bq" "$bpat" || continue
        if [[ -d $e ]]; then
          ranked+=("$REPLY${(l:5::0:)idx}"$'\x1f'"d"$'\t'"$n/"$'\t'$'\t'"$rawdir${(q)n}/")
        else
          ranked+=("$REPLY${(l:5::0:)idx}"$'\x1f'"f"$'\t'"$n"$'\t'$'\t'"$rawdir${(q)n}")
        fi
      done
    fi

    # With nothing else to show, fall back to the options.
    (( $#ranked )) && break
    [[ $q == -* ]] && break
  done
  ranked=(${(o)ranked})
  _mac_view=("${(@)ranked#*$'\x1f'}")
}

# ---------- drawing ----------

_mac_prompt_width() {
  setopt localoptions extendedglob
  local p=${(%)${(e)PS1}}
  p=${p//$'\e'\[[0-9;?]#[a-zA-Z]/}
  p=${p##*$'\n'}
  _mac_pw=${(m)#p}
}

_mac_clear() {
  (( _mac_drawn )) || return 0
  print -rn -- $'\e7\e[1B\r\e[J\e8' > /dev/tty
  _mac_drawn=0
}

_mac_render() {
  local n=$#_mac_view
  (( n )) || { _mac_clear; return }
  local h=$(( n < MINI_AC_ROWS ? n : MINI_AC_ROWS ))
  (( _mac_sel > n )) && _mac_sel=n
  (( _mac_sel < 1 )) && _mac_sel=1
  (( _mac_sel < _mac_top )) && _mac_top=$_mac_sel
  (( _mac_sel >= _mac_top + h )) && _mac_top=$(( _mac_sel - h + 1 ))
  (( _mac_top + h - 1 > n )) && _mac_top=$(( n - h + 1 ))
  (( _mac_top < 1 )) && _mac_top=1

  local i e kind rest name desc
  local -i nw=0 dw=0
  local -a vk vn vd
  for (( i = _mac_top; i < _mac_top + h; i++ )); do
    e=$_mac_view[i]
    kind=${e[1]}
    rest=${e[3,-1]}
    name=${rest%%$'\t'*}
    rest=${rest#*$'\t'}
    desc=${rest%%$'\t'*}
    vk+=("$kind"); vn+=("$name"); vd+=("$desc")
    (( ${(m)#name} > nw )) && nw=${(m)#name}
    (( ${(m)#desc} > dw )) && dw=${(m)#desc}
  done
  (( nw > 40 )) && nw=40
  (( dw > 60 )) && dw=60
  # inner = icon + space + name [+ 2 spaces + desc]
  local -i maxinner=$(( COLUMNS - 4 ))
  local -i inner=$(( 2 + nw + (dw ? 2 + dw : 0) ))
  if (( inner > maxinner )); then
    dw=$(( maxinner - 4 - nw ))
    (( dw < 8 )) && dw=0
    inner=$(( 2 + nw + (dw ? 2 + dw : 0) ))
    (( inner > maxinner )) && { nw=$(( maxinner - 2 )); inner=$maxinner; }
  fi
  local footer=" $_mac_sel/$n "
  (( inner < ${#footer} + 2 )) && inner=$(( ${#footer} + 2 ))
  local -i W=$(( inner + 4 ))

  local line=${LBUFFER##*$'\n'}
  local -i pw=$_mac_pw
  [[ $LBUFFER == *$'\n'* ]] && pw=0
  local -i col=$(( (pw + ${(m)#line} - ${(m)#_mac_prefix}) % COLUMNS ))
  (( col + W > COLUMNS )) && col=$(( COLUMNS - W ))
  (( col < 0 )) && col=0

  local -i rows=$(( h + 2 ))
  local mv=$'\r'
  (( col )) && mv+=$'\e['${col}C
  local o=$'\e[?7l' r icon nm ds sel empty=
  repeat $rows o+=$'\eD'
  # Save the cursor once, clear everything below it, then draw row by row going down.
  o+=$'\e['${rows}A$'\e7\e[1B\r\e[J'
  o+=$mv$'\e[2m┌'${(l:inner+2::─:)empty}$'┐\e[0m'
  for (( r = 1; r <= h; r++ )); do
    [[ $vn[r] == */ ]] && vk[r]=d
    case $vk[r] in
      s) icon=$'\e[36m›' ;;
      o) icon=$'\e[33m-' ;;
      a) icon=$'\e[32m•' ;;
      d) icon=$'\e[34m▸' ;;
      *) icon=$'\e[2m·' ;;
    esac
    nm=$vn[r]
    (( ${(m)#nm} > nw )) && nm=${nm[1,nw-1]}…
    nm=${(mr:nw:)nm}
    ds=
    if (( dw )); then
      ds=$vd[r]
      (( ${(m)#ds} > dw )) && ds=${ds[1,dw-1]}…
      ds="  "$'\e[2m'${(mr:dw:)ds}$'\e[22m'
    fi
    sel=
    (( _mac_top + r - 1 == _mac_sel )) && sel=$'\e[7m'
    o+=$'\e[1B'$mv$'\e[2m│\e[0m '$sel$icon$'\e[39m '$nm$ds$'\e[0m \e[2m│\e[0m'
  done
  o+=$'\e[1B'$mv$'\e[2m└'${(r:inner+2::─:)footer}$'┘\e[0m'
  o+=$'\e8\e[?7h'
  print -rn -- "$o" > /dev/tty
  _mac_drawn=$rows
  _mac_buf=$BUFFER
  _mac_cur=$CURSOR
}

# ---------- state ----------

_mac_close() {
  _mac_clear
  _mac_open=0
  _mac_nav=0
}

_mac_update() {
  if (( PENDING || KEYS_QUEUED_COUNT )); then _mac_close; return; fi
  _mac_context || { _mac_close; return; }
  local -i start=$(( ${#LBUFFER} - ${#_mac_prefix} ))
  (( start == _mac_dismiss )) && { _mac_close; return; }
  _mac_dismiss=-1
  _mac_fetch || { _mac_close; return; }
  if [[ $_mac_prefix != $_mac_lastprefix ]]; then
    _mac_sel=1 _mac_top=1 _mac_nav=0
  fi
  _mac_lastprefix=$_mac_prefix
  _mac_filter
  (( $#_mac_view )) || { _mac_close; return; }
  zle -R            # (the pre-redraw hook clears the old box here)
  # Measure the prompt now, not at line start: async prompts (oh-my-zsh's git
  # info) fill in a moment after the prompt appears.
  _mac_prompt_width
  _mac_open=1
  _mac_render
}

_mac_accept() {
  local e=$_mac_view[_mac_sel]
  local insert=${e##*$'\t'}
  LBUFFER=${LBUFFER[1,$(( ${#LBUFFER} - ${#_mac_prefix} ))]}$insert
  [[ $insert == */ || $insert == *= ]] || LBUFFER+=' '
  _mac_lastprefix=$'\0'
  _mac_update
}

# ---------- widgets ----------

_mac_self_insert() {
  zle _mac_orig_self_insert -- "$@"
  _mac_update
}

_mac_space() {
  zle ${_mac_orig_space:-self-insert} -- "$@"
  _mac_update
}

_mac_backward_delete_char() {
  zle .backward-delete-char -- "$@"
  _mac_update
}

_mac_up() {
  if (( _mac_open )); then
    (( _mac_sel = _mac_sel > 1 ? _mac_sel - 1 : $#_mac_view ))
    _mac_nav=1
    _mac_render
  else
    zle ${_mac_orig_up:-up-line-or-history}
  fi
}

_mac_down() {
  if (( _mac_open )); then
    (( _mac_sel = _mac_sel < $#_mac_view ? _mac_sel + 1 : 1 ))
    _mac_nav=1
    _mac_render
  else
    zle ${_mac_orig_down:-down-line-or-history}
  fi
}

_mac_tab() {
  if (( _mac_open )); then
    _mac_accept
  else
    zle ${_mac_orig_tab:-expand-or-complete}
  fi
}

_mac_enter() {
  if (( _mac_open )); then
    local e=$_mac_view[_mac_sel]
    local name=${${e[3,-1]}%%$'\t'*}
    local kind=${e[1]} q=${(Q)_mac_prefix}
    # Files and folders are matched on the part after the last "/".
    [[ $kind == [df] ]] && q=${q##*/}
    # Insert on a deliberate pick: arrows used, or a match for something typed
    # that isn't already complete. Any match counts for subcommands, options,
    # files and folders; free-text values (env vars, branches...) need a prefix
    # match, so `echo hi` + Enter still runs instead of being swapped out.
    if (( _mac_nav )) || [[ -n $q && $name != $q && $name != $q/ &&
          ( $kind == [sodf] || ${(L)name} == ${(L)q}* ) ]]; then
      _mac_accept
      return
    fi
  fi
  _mac_close
  zle ${_mac_orig_enter:-accept-line}
}

_mac_escape() {
  (( _mac_open )) || return 0
  _mac_dismiss=$(( ${#LBUFFER} - ${#_mac_prefix} ))
  _mac_close
}

_mac_line_init() {
  _mac_open=0 _mac_drawn=0 _mac_dismiss=-1 _mac_nav=0
  _mac_key= _mac_lastprefix=$'\0'
  _mac_prompt_width
}

_mac_line_finish() { _mac_close; }

# Anything else that changes the line (Ctrl-W, Ctrl-U, history, arrows) hides the box.
_mac_pre_redraw() {
  (( _mac_drawn )) || return 0
  [[ $BUFFER == $_mac_buf && $CURSOR == $_mac_cur ]] || _mac_close
}

# ---------- install ----------

_mac_bound() { local b=$(bindkey -- "$1" 2>/dev/null); b=${b##* }; [[ $b == undefined-key || $b == _mac_* ]] || print -r -- $b; }

if [[ $widgets[self-insert] != user:_mac_self_insert ]]; then
  zle -A self-insert _mac_orig_self_insert
  zle -N self-insert _mac_self_insert
fi
zle -N backward-delete-char _mac_backward_delete_char
zle -N _mac_space
zle -N _mac_up
zle -N _mac_down
zle -N _mac_tab
zle -N _mac_enter
zle -N _mac_escape
zle -N _mac_line_init
zle -N _mac_line_finish
zle -N _mac_pre_redraw

typeset -g _mac_orig_up=${_mac_orig_up:-$(_mac_bound '^[[A')}
typeset -g _mac_orig_down=${_mac_orig_down:-$(_mac_bound '^[[B')}
typeset -g _mac_orig_tab=${_mac_orig_tab:-$(_mac_bound '^I')}
typeset -g _mac_orig_space=${_mac_orig_space:-$(_mac_bound ' ')}
typeset -g _mac_orig_enter=${_mac_orig_enter:-$(_mac_bound '^M')}

bindkey '^[[A' _mac_up   '^[OA' _mac_up
bindkey '^[[B' _mac_down '^[OB' _mac_down
bindkey '^I'   _mac_tab
bindkey ' '    _mac_space
bindkey '^M'   _mac_enter
bindkey '^['   _mac_escape

autoload -Uz add-zle-hook-widget
add-zle-hook-widget line-init       _mac_line_init
add-zle-hook-widget line-finish     _mac_line_finish
add-zle-hook-widget line-pre-redraw _mac_pre_redraw
