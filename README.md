# mini-autocomplete

A Kiro/Fig-style autocomplete dropdown for zsh, powered by [Fig's autocomplete specs](https://github.com/withfig/autocomplete). It covers 700+ CLIs, including git, npm, docker, aws, gh, brew and kubectl.

```
➜  ~ git ch
         ┌──────────────────────────────────────────────────────────────────────┐
         │ › checkout     Switch branches or restore working tree files         │
         │ › cherry-pick  Apply the changes introduced by some existing commits │
         │ › archive      Create an archive of files from a named tree          │
         │ › fetch        Download objects and refs from another repository     │
         └ 1/6 ─────────────────────────────────────────────────────────────────┘
```

## Install

You need zsh, git and Node.js 20+.

```sh
curl -fsSL https://raw.githubusercontent.com/hanselsj/mini-autocomplete/main/install.sh | bash
```

Then open a new terminal or run `exec zsh`.

The script clones into `~/.mini-autocomplete` (override with `MINI_AC_HOME`), installs the specs with npm, and adds one `source` line to the end of your `~/.zshrc`. To update, run the same command again.

To install from a clone instead, run `./install.sh` inside it, and it will use that folder.

**Uninstall:** `~/.mini-autocomplete/uninstall.sh`

## Using it

Type a command and a space (`cd `, `git `, `npm run `) and a box opens under the cursor.

| Key | Action |
|---|---|
| keep typing | fuzzy-filters the list: starts-with first, then word starts, then contains, then letters in order (`chk` → `checkout`) |
| Up / Down | move the selection (history works as usual when the box is closed) |
| Tab | insert the selection |
| Enter | insert the selection if you picked it or it matches what you typed; otherwise run the line |
| Esc | hide the box until the next word |

Folders drill down: pick `Repos/` and the box immediately lists what's inside it. Commands without a spec offer files.

Set `MINI_AC_ROWS` (default 8) before the `source` line to change the box height.

## How it works

- `dropdown.zsh` hooks the line editor (typing, space, backspace, arrows, Tab, Enter, Esc) and draws the box with terminal escape codes.
- `server.mjs` is a background Node process on a per-user Unix socket. It starts on first use and exits after an hour idle, so typing never pays Node's startup cost. Suggestions are fetched once per word and filtered in zsh as you type.
- `complete.mjs` walks a Fig spec: subcommands, `loadSpec`, options and their values, `--`, and `sudo`-style commands. It runs `script`/`postProcess`/`splitOn`/`custom` generators for things like git branches and npm scripts.
- `mini-autocomplete.zsh` is the entry point. When the box is closed, it also adds a regular Tab completer driven by the same specs.

After changing `complete.mjs`, run `mini-ac-restart` so the server reloads it.

## Limitations

- It's drawn inside the terminal, not as an OS-level floating window.
- Not supported yet: inline ghost-text suggestions, caching generator results across lines, `insertValue`/`{cursor}` templates, `requiresSeparator` (`--opt=`), and picking a versioned spec by installed version.
- zsh only.

## Credits

Completion specs: [withfig/autocomplete](https://github.com/withfig/autocomplete) (MIT), installed from npm.
