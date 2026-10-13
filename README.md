# scripts

Personal shell helpers.

## `ai` — natural language to shell command

Describe what you want in plain English and get a shell command back, ready to
edit or run. Claude writes the command; nothing runs until you press Enter.

![Typing requests and pressing Ctrl-O turns them into shell commands](docs/demo-widget.gif)

### Dependencies

| Dependency | Needed for | Install |
| --- | --- | --- |
| macOS or Linux | the OS the commands are written for | — |
| zsh | `print -z`, the line editor (ZLE) | preinstalled on macOS; `sudo apt install zsh` (or your distro's package manager) |
| [Claude Code](https://claude.com/claude-code) CLI (`claude`) | generating the commands | see the link, then run `claude` once to log in |
| `jq` | parsing Claude's JSON reply | `brew install jq` / `sudo apt install jq` |

Only for re-recording the demo GIFs (see [Demo GIFs](#demo-gifs)):

| Dependency | Install |
| --- | --- |
| `asciinema`, `agg` | `brew install asciinema agg` |
| `expect`, `python3` | preinstalled on macOS; `sudo apt install expect python3` |

### Install

This folder is a zsh plugin named `ai`. All of it is in one file,
`ai.plugin.zsh`, which sets up the Ctrl-O key binding and the `ai` command.
After installing, open a new terminal or run `exec zsh`.

**Oh My Zsh:** link the folder into your custom plugins as `ai` (the folder
name must match the plugin name), then add `ai` to the `plugins` list in
`~/.zshrc`:

```zsh
ln -s ~/workspace/personal/scripts ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/ai
```

```zsh
plugins=(git ai)   # keep your existing plugins, add ai
```

**Other plugin managers** (antidote, zinit, zplug, sheldon, …): point them at
this folder, or at its Git repository once it has one. They load
`ai.plugin.zsh`.

**No plugin manager:** source it from `~/.zshrc`:

```zsh
source ~/workspace/personal/scripts/ai.plugin.zsh
```

Set any [configuration](#configuration) variables in `~/.zshrc` before the
plugin loads (before `source $ZSH/oh-my-zsh.sh` with Oh My Zsh). If Ctrl-O does
nothing, a plugin loaded later (such as `zsh-vi-mode`) may have rebound it:
load `ai` last, or pick another `AI_CMD_KEY`.

### Usage guide

There are two ways to ask: a key binding and a command. Both put the generated
command on your prompt for you to check. Press Enter to run it, edit it first,
or clear it with Ctrl-U.

#### 1. Key binding: type, then Ctrl-O (recommended)

1. Type the request on the command line as if it were a command:
   `list files > 1MB here`
2. Press **Ctrl-O**. `thinking…` shows below the line for 3–5 seconds.
3. The request is replaced by the command:
   `find . -type f -size +1048576c -exec ls -lh {} +`
4. Read it, then press Enter, edit it, or press `Ctrl-_` (undo) to get your
   request back and reword it.

The shell never reads the request, so `>`, `|`, `#`, `$` and apostrophes need
no quoting. This is the demo at the top of this page.

#### 2. The `ai` command

```
ai <what you want>
```

The command appears on your next prompt. Plain words need no quotes, and `?`,
`*` and `[ ]` are safe. But zsh reads the line before `ai` does, so quote the
request when it contains any of `` > < | & ; # $ ` " { } ``:

- `ai list files > 1MB here` doesn't do what it looks like: zsh treats
  `> 1MB` as a redirect, creates an empty file named `1MB`, and `ai` only
  receives "list files here". Use `ai 'list files > 1MB here'`.
- An apostrophe opens a quote: `ai what's my ip` leaves zsh waiting at
  `quote>` (press Ctrl-C to get out). Use double quotes, `ai "what's my ip"`,
  or drop the apostrophe.

![The ai command, and what an unquoted > or apostrophe does](docs/demo-command.gif)

#### What else you may see

- **A warning** above the prompt, or below the line with Ctrl-O, when the
  command deletes, overwrites or kills something:

  ```
  ❯ ai kill whatever is on port 8080
  This sends SIGTERM to whatever process is listening on port 8080.
  ❯ lsof -ti tcp:8080 -sTCP:LISTEN | xargs kill█
  ```

- **An explanation instead of a command** when no shell command can do it:

  ```
  ❯ ai book me a flight to paris
  ai: A shell command can't book a flight; use an airline or a booking site like Google Flights instead.
  ```

#### Tips

- Be specific about the output you want ("largest first", "human-readable
  sizes", "only names"); Claude includes the flags for it.
- "Here" and "this folder" mean your current directory.
- Always read the command before pressing Enter, especially with a warning.

### Examples

Generated on macOS; on Linux you get the GNU equivalents.

| Request | Command |
| --- | --- |
| `what process is listening on port 3000` | `lsof -nP -iTCP:3000 -sTCP:LISTEN` |
| `find the 5 largest files here` | `find . -type f -exec du -k {} + 2>/dev/null \| sort -rn \| head -5` |
| `files > 100MB modified this week, largest first` | `find . -type f -size +100M -mtime -7 -exec stat -f '%z %N' {} + \| sort -rn …` |
| `count files by extension, most common first` | `find . -type f \| awk -F/ '…' \| sort \| uniq -c \| sort -rn` |
| `count lines of all .ts files excluding node_modules` | `find . -name node_modules -prune -o -type f -name "*.ts" -print0 \| xargs -0 cat \| wc -l` |
| `show git commits from last week by author` | `git shortlog --since="1 week ago" --no-merges` |
| `compress this folder into a tar.gz` | `tar -czf "../${PWD:t}.tar.gz" -C .. "${PWD:t}"` |
| `show my public ip` | `curl -s https://ifconfig.me; echo` |

With the `ai` command, quote the requests that contain `>` (see above).

### Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `AI_CMD_MODEL` | `sonnet` | Model alias passed to `claude --model` (e.g. `haiku`, `opus`) |
| `AI_CMD_KEY` | `^O` | Key that runs the widget, in the emacs and viins keymaps. The default replaces `accept-line-and-down-history`. Set it to `''` for no key binding (only the `ai` command) |

Set them in `~/.zshrc` before the plugin loads. `AI_CMD_MODEL` can also be
set per call: `AI_CMD_MODEL=opus ai …`.

### How it works

`ai` runs `claude -p` with its own system prompt and no tools, MCP servers,
settings, CLAUDE.md files or session history, so each request is a single,
isolated model call. It runs in your current directory, so the model knows
which folder "here" means; the only context it gets about that folder is its
path and whether it's a git repository.
The reply is structured JSON with a `command` and a `message` field
(`--output-format json --json-schema`). The `ai` command pushes the command
onto the next prompt with `print -z`; the key binding replaces the line you
typed. Any message is shown next to it.

When the plugin loads, it detects the OS and tells the model about it:
macOS with BSD `sed`/`date`/`stat`, or Linux (the distro name from
`/etc/os-release`) with GNU tools, or BusyBox tools on minimal images such as
Alpine. It also lists the package managers on your `PATH` (`brew`, `apt`, `dnf`,
`pacman`, …). To change the rest of the instructions, edit
`_AI_CMD_SYSTEM_PROMPT` in `ai.plugin.zsh`; it's a single-quoted string, so don't use
apostrophes inside it.

### Demo GIFs

`docs/record-demo.sh` re-records both GIFs by driving a clean zsh through real
requests; `docs/record-demo.sh widget` or `docs/record-demo.sh command`
re-records just one. It makes real `claude` calls, so the generated commands
can differ from the current GIFs.
