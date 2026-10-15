# zsh-ai-cli-generator

[![tests](https://github.com/asibin/zsh-ai-cli-generator/actions/workflows/test.yml/badge.svg)](https://github.com/asibin/zsh-ai-cli-generator/actions/workflows/test.yml)

Describe what you want in plain English and get a shell command back, ready to
edit or run. Claude writes the command, or a model you run yourself through
Ollama, LM Studio or any OpenAI-compatible server; nothing runs until you press
Enter. Type a request and press Ctrl-O, or run `ai <request>`.

![Typing requests and pressing Ctrl-O turns them into shell commands](docs/demo-widget.gif)

## Dependencies

| Dependency | Needed for | Install |
| --- | --- | --- |
| macOS or Linux | the OS the commands are written for | — |
| zsh | `print -z`, the line editor (ZLE) | preinstalled on macOS; `sudo apt install zsh` (or your distro's package manager) |
| `jq` | building requests, parsing the model's JSON reply | `brew install jq` / `sudo apt install jq` |
| [Claude Code](https://claude.com/claude-code) CLI (`claude`) | the default `claude` backend | see the link, then run `claude` once to log in |
| `curl` | the `openai` backend ([local models](#local-and-other-models)) | preinstalled on macOS and most Linux distros |

Only for the [tests](#tests) and re-recording the [demo GIFs](#demo-gifs):

| Dependency | Needed for | Install |
| --- | --- | --- |
| `expect` | the interactive tests, the demo GIFs | preinstalled on macOS; `sudo apt install expect` |
| `asciinema`, `agg` | the demo GIFs | `brew install asciinema agg` |
| `python3` | the demo GIFs (a server to find on port 3000) | preinstalled on macOS; `sudo apt install python3` |

## Install

This repo is a zsh plugin named `ai`. All of it is in one file,
`ai.plugin.zsh`, which sets up the Ctrl-O key binding and the `ai` command.
After installing, open a new terminal or run `exec zsh`.

**Oh My Zsh:** clone into your custom plugins as `ai` (the folder name must
match the plugin name), then add `ai` to the `plugins` list in `~/.zshrc`:

```zsh
git clone https://github.com/asibin/zsh-ai-cli-generator ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/ai
```

```zsh
plugins=(git ai)   # keep your existing plugins, add ai
```

**Other plugin managers:**

| Manager | Add |
| --- | --- |
| antidote | `asibin/zsh-ai-cli-generator` in `~/.zsh_plugins.txt` |
| zinit | `zinit light asibin/zsh-ai-cli-generator` |
| zplug | `zplug "asibin/zsh-ai-cli-generator"` |
| sheldon | `sheldon add ai --github asibin/zsh-ai-cli-generator` |

**No plugin manager:** clone it anywhere and source the plugin file from
`~/.zshrc`:

```zsh
git clone https://github.com/asibin/zsh-ai-cli-generator ~/.zsh/zsh-ai-cli-generator
```

```zsh
source ~/.zsh/zsh-ai-cli-generator/ai.plugin.zsh
```

To update, run `git pull` in the clone (or your plugin manager's update
command).

Set [configuration](#configuration) variables in `~/.zshrc`; `AI_CMD_KEY` must
come before the plugin loads (before `source $ZSH/oh-my-zsh.sh` with Oh My
Zsh). If Ctrl-O does nothing, a plugin loaded later (such as `zsh-vi-mode`) may have rebound it:
load `ai` last, or pick another `AI_CMD_KEY`.

## Usage guide

There are two ways to ask: a key binding and a command. Both put the generated
command on your prompt for you to check. Press Enter to run it, edit it first,
or clear it with Ctrl-U.

### 1. Key binding: type, then Ctrl-O (recommended)

1. Type the request on the command line as if it were a command:
   `list files > 1MB here`
2. Press **Ctrl-O**. `thinking…` shows below the line for 3–5 seconds.
3. The request is replaced by the command:
   `find . -type f -size +1048576c -exec ls -lh {} +`
4. Read it, then press Enter, edit it, or press `Ctrl-_` (undo) to get your
   request back and reword it.

The shell never reads the request, so `>`, `|`, `#`, `$` and apostrophes need
no quoting. This is the demo at the top of this page.

### 2. The `ai` command

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

### What else you may see

- **A warning** above the prompt, or below the line with Ctrl-O, when the
  command deletes, overwrites or kills something. It comes from the model, or,
  when the model gave none, from a local check of the command (`rm`, `kill`,
  `find -delete`, `sed -i`, a `>` redirect, `git reset --hard`, …):

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

### Tips

- Be specific about the output you want ("largest first", "human-readable
  sizes", "only names"); Claude includes the flags for it.
- "Here" and "this folder" mean your current directory.
- If you keep correcting the same thing (a tool you prefer, one you don't
  have, flags you always want), put it in
  [`AI_CMD_INSTRUCTIONS`](#configuration) once.
- Always read the command before pressing Enter, especially with a warning.

## Examples

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

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `AI_CMD_BACKEND` | `claude` | `claude` for the Claude Code CLI, or `openai` for any OpenAI-compatible server (see [Local and other models](#local-and-other-models)) |
| `AI_CMD_MODEL` | `sonnet` with `claude`; none with `openai` | Model name: an alias for `claude --model` (e.g. `haiku`, `opus`), or the server's model name (e.g. `qwen2.5-coder:7b`), which `openai` requires |
| `AI_CMD_URL` | `http://localhost:11434/v1` (Ollama) | `openai` only: the API base URL, up to and including `/v1` |
| `AI_CMD_API_KEY` | — | `openai` only: sent as a bearer token, for hosted services |
| `AI_CMD_TIMEOUT` | `60` | Seconds to wait for a reply before giving up; `0` waits as long as it takes |
| `AI_CMD_KEY` | `^O` | Key that runs the widget, in the emacs and viins keymaps. The default replaces `accept-line-and-down-history`. Set it to `''` for no key binding (only the `ai` command) |
| `AI_CMD_INSTRUCTIONS` | — | Your own instructions, added to the end of the system prompt. Use one line per instruction |

Set them in `~/.zshrc`. `AI_CMD_KEY` is used once, when the plugin loads, so
set it before that. The others are read on every request: you can change them
in a running shell, or set them for one call: `AI_CMD_MODEL=opus ai …`.

`AI_CMD_INSTRUCTIONS` is for preferences that apply to every request, such as
the tools you have installed:

```zsh
AI_CMD_INSTRUCTIONS='Use bat instead of cat, and eza instead of ls.
Prefer rg over grep and fd over find.
Never use sudo.'
```

The example uses single quotes, so an apostrophe inside ("Don't use sudo")
would end the string; use double quotes for that, or avoid the apostrophe. The
instructions can't change the reply format (one command line), and the command
still needs your Enter to run.

## Local and other models

With `AI_CMD_BACKEND=openai`, `ai` talks to any server with an OpenAI-compatible
chat API instead of Claude. With a model running on your machine, nothing
leaves it, and you don't need the Claude Code CLI or an account.

**Ollama** (the default URL), with a coding model as an example:

```zsh
ollama pull qwen2.5-coder:7b
```

```zsh
AI_CMD_BACKEND=openai
AI_CMD_MODEL=qwen2.5-coder:7b
```

**Other servers:** set `AI_CMD_URL` as well.

| Server | `AI_CMD_URL` |
| --- | --- |
| LM Studio | `http://localhost:1234/v1` |
| llama.cpp (`llama-server`) | `http://localhost:8080/v1` |
| vLLM | `http://localhost:8000/v1` |
| OpenRouter (hosted) | `https://openrouter.ai/api/v1`, plus `AI_CMD_API_KEY` |

Things to know:

- **Quality depends on the model.** Small models (a few billion parameters)
  are fast but often get flags wrong, mix up BSD and GNU options, or answer
  something nobody asked. Larger models, and models trained for code, do
  better. Read the command before pressing Enter, as always.
- **The first request after a while is slow** while the server loads the
  model; later ones are quick. If a large model takes longer than a minute to
  load, raise `AI_CMD_TIMEOUT`.
- `ai` asks for the reply as JSON in a fixed shape (`response_format` with a
  JSON schema). Servers that ignore that usually still follow the system
  prompt, and `ai` ignores `<think>` blocks, code fences and other text around
  the JSON. If a model keeps answering in prose, you'll see "the model didn't
  reply with the expected JSON"; try another model.

## How it works

Each request is a single, isolated model call with `ai`'s own system prompt.
The only context the model gets about your folder is its path and whether it's
a git repository, so it knows which folder "here" means.

- **`claude` backend:** runs `claude -p` with no tools, MCP servers, settings,
  CLAUDE.md files or session history, and asks for structured output
  (`--output-format json --json-schema`).
- **`openai` backend:** sends one `POST /chat/completions` with `curl`, with
  the same JSON schema as `response_format`.

Either way, the reply is JSON with a `command` and a `message` field. If the
model gave no warning, a local check looks for commands that delete, overwrite
or stop something and adds one. A command with control characters, such as an
escape sequence or a carriage return that could make it look like something
else, is rejected, and control characters in messages are replaced before
they're shown. The `ai` command pushes the command
onto the next prompt with `print -z`; the key binding replaces the line you
typed. Any message is shown next to it.

When the plugin loads, it detects the OS and tells the model about it:
macOS with BSD `sed`/`date`/`stat`, or Linux (the distro name from
`/etc/os-release`) with GNU tools, or BusyBox tools on minimal images such as
Alpine. It also lists the package managers on your `PATH` (`brew`, `apt`, `dnf`,
`pacman`, …). Your `AI_CMD_INSTRUCTIONS`, if set, go at the end of the
system prompt. To change the built-in instructions, edit
`_AI_CMD_SYSTEM_PROMPT` in `ai.plugin.zsh`; it's a single-quoted string, so
don't use apostrophes inside it.

## Tests

```zsh
tests/run.zsh
```

It runs the plugin against fake `claude` and `curl` commands, so it calls no
model and needs nothing running. It covers both backends' requests, replies and
errors, control characters, the local warning check, and the OS detection. With
`expect` installed, it also drives a real interactive zsh to test the `ai`
command, Ctrl-O, Ctrl-C and timeouts; `AI_TEST_LOG=<file>` saves that session
for debugging.

GitHub Actions runs the tests on macOS, Ubuntu and Alpine (BusyBox tools) for
every push to `master` and every pull request.

## Demo GIFs

`docs/record-demo.sh` re-records both GIFs by driving a clean zsh through real
requests; `docs/record-demo.sh widget` or `docs/record-demo.sh command`
re-records just one. It makes real `claude` calls, so the generated commands
can differ from the current GIFs.

## Contributing

Bug reports and pull requests are welcome; see [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
