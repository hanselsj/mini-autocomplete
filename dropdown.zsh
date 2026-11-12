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
# Typing never waits on suggestions: each keystroke sends the line to the
# background server (server.mjs) and returns straight away; the box is drawn
# when the reply arrives (zle -F), and replies that are already out of date
# are thrown away.
#
# Sourced by mini-autocomplete.zsh; expects MINI_AC_DIR / MINI_AC_NODE / MINI_AC_SPECS.

[[ -o interactive && -n $MINI_AC_NODE ]] || return 0
zmodload zsh/net/socket zsh/zselect zsh/system 2>/dev/null || return 0

typeset -gi MINI_AC_ROWS=${MINI_AC_ROWS:-8}
# Versioned so a server left running by an older release is never asked.
typeset -g  _mac_sock=${TMPDIR:-/tmp}/mini-ac-$UID-v2.sock
typeset -gi _mac_open=0 _mac_drawn=0 _mac_sel=1 _mac_top=1 _mac_nav=0 _mac_dismiss=-1 _mac_pw=0
typeset -gi _mac_reqid=0
typeset -g  _mac_key= _mac_prefix= _mac_lastprefix= _mac_buf= _mac_cur= _mac_fd= _mac_rbuf=
typeset -ga _mac_view _mac_words

# ---------- talking to the suggestion server ----------

# Start the server in the background. With "wait", block (briefly, once) until it's listening.
_mac_start_server() {
  [[ -S $_mac_sock ]] && zsocket $_mac_sock 2>/dev/null && { exec {REPLY}>&-; return 0; }
  rm -f -- $_mac_sock
  ( cd / && exec "$MINI_AC_NODE" "$MINI_AC_DIR/server.mjs" "$_mac_sock" ) &>/dev/null &!
  [[ $1 == wait ]] || return 0
  local i
  for i in {1..40}; do
    [[ -S $_mac_sock ]] && return 0
    zselect -t 5
  done
  return 1
}

# Drop the request in flight, if any.
_mac_cancel() {
  [[ -n $_mac_fd ]] || return 0
  zle -F $_mac_fd 2>/dev/null
  exec {_mac_fd}>&- 2>/dev/null
  _mac_fd= _mac_rbuf=
}

# Send the current line to the server without waiting for the answer.
_mac_send() {   # $1: 1 = new word, re-run the spec's generators
  _mac_cancel
  if ! zsocket $_mac_sock 2>/dev/null; then
    _mac_start_server wait && zsocket $_mac_sock 2>/dev/null || return 1
  fi
  _mac_fd=$REPLY
  (( ++_mac_reqid ))
  print -rn -u $_mac_fd -- "$_mac_reqid"$'\x1f'"$1"$'\x1f'"$PWD"$'\x1f'"$_mac_prefix"$'\x1f'"${(pj:\x1f:)_mac_words}"$'\n'
  zle -F -w $_mac_fd _mac_on_reply
}

# zle -F handler: collect the reply as it arrives; draw it once complete.
_mac_on_reply() {
  local fd=$1 chunk
  if [[ $fd != $_mac_fd ]]; then   # a reply nobody is waiting for any more
    zle -F $fd 2>/dev/null
    exec {fd}>&- 2>/dev/null
    return 0
  fi
  if sysread -i $fd -s 65536 chunk; then
    _mac_rbuf+=$chunk
    return 0
  fi
  _mac_show_reply
}

# For keys that act on the list (Tab/Enter/arrows): if a reply is still on its
# way, wait for it (it's usually a millisecond or two) so they act on fresh results.
_mac_settle() {
  [[ -n $_mac_fd ]] || return 0
  local chunk
  while sysread -i $_mac_fd -s 65536 -t 1 chunk; do _mac_rbuf+=$chunk; done
  _mac_show_reply
}

_mac_show_reply() {
  local -a lines
  lines=("${(@f)_mac_rbuf}")
  _mac_cancel
  [[ $lines[1] == "#$_mac_reqid" ]] || return 0
  _mac_view=("${(@)lines[2,-1]}")
  _mac_view=(${_mac_view:#})
  if (( ! $#_mac_view )); then
    _mac_close
    return 0
  fi
  # Measure the prompt now, not at line start: async prompts (oh-my-zsh's git
  # info) fill in a moment after the prompt appears.
  _mac_prompt_width
  _mac_open=1
  _mac_render
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

# ---------- drawing ----------

_mac_prompt_width() {
  setopt localoptions extendedglob
  local p=${(%)${(e)PS1}}
  # Invisible escape codes take no columns: OSC sequences (VS Code / iTerm2
  # shell-integration markers like ESC]633;A BEL, window titles) and CSI colors.
  p=${p//$'\e]'[^$'\a\e']#$'\a'/}
  p=${p//$'\e]'[^$'\a\e']#$'\e\\'/}
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

# Called after every edit: work out the word being typed and ask for suggestions.
# Never waits — the reply is drawn by _mac_on_reply.
_mac_update() {
  # Keys still queued (fast typing, paste): skip, the last one will ask.
  (( PENDING || KEYS_QUEUED_COUNT )) && { _mac_buf=$BUFFER _mac_cur=$CURSOR; return; }
  _mac_context || { _mac_cancel; _mac_close; return; }
  local -i start=$(( ${#LBUFFER} - ${#_mac_prefix} ))
  (( start == _mac_dismiss )) && { _mac_cancel; _mac_close; return; }
  _mac_dismiss=-1

  local key=$PWD$'\x1f'${(pj:\x1f:)_mac_words} fresh=0
  if [[ $key != $_mac_key ]]; then
    # New word: the old list belongs to the previous word, hide it.
    _mac_key=$key fresh=1
    _mac_close
  fi
  if [[ $_mac_prefix != $_mac_lastprefix ]]; then
    _mac_sel=1 _mac_top=1 _mac_nav=0
  fi
  _mac_lastprefix=$_mac_prefix
  # Same word: leave the current box up until the new list replaces it.
  _mac_buf=$BUFFER _mac_cur=$CURSOR
  _mac_send $fresh || _mac_close
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
  _mac_settle
  if (( _mac_open )); then
    (( _mac_sel = _mac_sel > 1 ? _mac_sel - 1 : $#_mac_view ))
    _mac_nav=1
    _mac_render
  else
    zle ${_mac_orig_up:-up-line-or-history}
  fi
}

_mac_down() {
  _mac_settle
  if (( _mac_open )); then
    (( _mac_sel = _mac_sel < $#_mac_view ? _mac_sel + 1 : 1 ))
    _mac_nav=1
    _mac_render
  else
    zle ${_mac_orig_down:-down-line-or-history}
  fi
}

_mac_tab() {
  _mac_settle
  if (( _mac_open )); then
    _mac_accept
  else
    zle ${_mac_orig_tab:-expand-or-complete}
  fi
}

_mac_enter() {
  _mac_settle
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
  (( _mac_open )) || [[ -n $_mac_fd ]] || return 0
  _mac_dismiss=$(( ${#LBUFFER} - ${#_mac_prefix} ))
  _mac_cancel
  _mac_close
}

_mac_line_init() {
  _mac_cancel
  _mac_open=0 _mac_drawn=0 _mac_dismiss=-1 _mac_nav=0
  _mac_key= _mac_lastprefix=$'\0'
  # Warm the server up in the background so the first suggestion is instant.
  [[ -S $_mac_sock ]] || _mac_start_server
}

_mac_line_finish() { _mac_cancel; _mac_close; }

# Anything else that changes the line (Ctrl-W, Ctrl-U, history, arrows) hides the
# box and drops any reply still on its way.
_mac_pre_redraw() {
  (( _mac_drawn )) || [[ -n $_mac_fd ]] || return 0
  [[ $BUFFER == $_mac_buf && $CURSOR == $_mac_cur ]] && return 0
  _mac_cancel
  _mac_close
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
zle -N _mac_on_reply

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
