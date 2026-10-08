# scripts

Personal shell helpers.

## `ai` — natural language to shell command

Describe what you want in plain English. `ai` asks Claude for a matching shell
command and puts it on your next prompt, ready to run with Enter, edit, or
clear with Ctrl-C. Nothing runs until you press Enter.

```
❯ ai show all running containers and their open ports
❯ docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Ports}}"█
```

### Requirements

- zsh (uses `print -z` to fill the next prompt)
- [Claude Code](https://claude.com/claude-code) CLI (`claude`), logged in
- `jq`

### Install

Add to `~/.zshrc`:

```zsh
source ~/workspace/personal/scripts/ai.zsh
```

Then open a new terminal or run `exec zsh`.

### Usage

```
ai <what you want>
ai '<what you want>'      # quoted, when the request contains shell characters
```

Plain requests need no quotes; `?`, `*` and `[ ]` are safe. Quote the request
when it contains any of `` > < | & ; # $ ` " { } ``, because zsh interprets these
before `ai` sees them. For example, an unquoted `ai files > 100MB` would create
a file named `100MB`.

An apostrophe can't go inside single quotes. Leave it out (`ai 'whats my ip'`)
or use double quotes (`ai "what's my ip"`).

Each request takes about 3–5 seconds; a dim `thinking…` shows while it waits.

### Examples

| Request | Command |
| --- | --- |
| `ai what process is listening on port 3000` | `lsof -nP -iTCP:3000 -sTCP:LISTEN` |
| `ai find the 5 largest files here` | `find . -type f -exec du -k {} + 2>/dev/null \| sort -rn \| head -5` |
| `ai 'files > 100MB modified this week, largest first'` | `find . -type f -size +100M -mtime -7 -exec stat -f '%z %N' {} + \| sort -rn …` |
| `ai count lines of all .ts files excluding node_modules` | `find . -name node_modules -prune -o -type f -name "*.ts" -print0 \| xargs -0 cat \| wc -l` |
| `ai show git commits from last week by author` | `git shortlog --since="1 week ago" --no-merges` |
| `ai compress this folder into a tar.gz` | `tar -czf "../${PWD:t}.tar.gz" -C .. "${PWD:t}"` |
| `ai show my public ip` | `curl -s https://ifconfig.me; echo` |

Commands that delete, overwrite or kill something come with a short dimmed
warning above the prompt:

```
❯ ai kill whatever is on port 8080
This sends SIGTERM to whatever process is listening on port 8080.
❯ lsof -ti tcp:8080 -sTCP:LISTEN | xargs kill█
```

If no shell command can do what you asked, you get an explanation instead of
a command:

```
❯ ai book me a flight to paris
ai: A shell command can't book a flight; use an airline or a booking site like Google Flights instead.
```

### Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `AI_CMD_MODEL` | `sonnet` | Model alias passed to `claude --model` (e.g. `haiku`, `opus`) |

Set it in `~/.zshrc` before the `source` line, or per call:
`AI_CMD_MODEL=opus ai …`.

### How it works

`ai` runs `claude -p` with its own system prompt and no tools, MCP servers,
settings, CLAUDE.md files or session history, so each request is a single,
isolated model call. It runs in your current directory, so the model knows
which folder "here" means; the only context it gets about that folder is its
path and whether it's a git repository.
The reply is structured JSON with a `command` and a `message` field
(`--output-format json --json-schema`); the command is pushed onto the next
prompt with `print -z`, and any message is printed above it.

The model is told you're on macOS (BSD `sed`/`date`/`stat`, not GNU) with zsh
and Homebrew. To change that, edit `_AI_CMD_SYSTEM_PROMPT` in `ai.zsh`; it's a
single-quoted string, so don't use apostrophes inside it.
