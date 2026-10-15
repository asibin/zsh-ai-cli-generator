# Contributing

Thanks for helping out. Bug reports, fixes and new ideas are all welcome.

## Reporting a problem

Open an issue with:

- what you typed, and what you expected to get
- what you got: the command, or the full error line starting with `ai:`
- your OS (`uname -a`), zsh version (`zsh --version`), and backend:
  `AI_CMD_BACKEND`, `AI_CMD_MODEL`, and the server for the `openai` backend
  (Ollama, LM Studio, …)

A model giving a wrong command once is usually not a bug: models vary, and
small local models get things wrong often. It is worth reporting when a
request fails the same way every time with a capable model, or when the
prompt seems to steer the model in the wrong direction.

## Setting up

Clone the repo and load the plugin from your clone, so your shell runs the code
you're editing:

```zsh
git clone https://github.com/asibin/zsh-ai-cli-generator
source zsh-ai-cli-generator/ai.plugin.zsh
```

After an edit, `source` the file again or open a new shell. You need the
[dependencies](README.md#dependencies) for the backend you test with.

## Code layout

Everything is in `ai.plugin.zsh`. Functions start with `_ai_cmd_`, like the
`AI_CMD_*` settings, so they don't clash with other plugins.

| Function | What it does |
| --- | --- |
| `_ai_cmd_generate` | the entry point: runs `_ai_cmd_request`, then replaces control characters in its messages; prints nothing |
| `_ai_cmd_request` | builds the prompt, calls the backend, checks the reply |
| `_ai_cmd_ask_claude`, `_ai_cmd_ask_openai` | one per backend: send the request, return the reply's JSON |
| `_ai_cmd_parse_reply` | reads `command` and `message` from the reply's JSON |
| `_ai_cmd_risky` | the local check for commands that delete, overwrite or stop something |
| `_ai_cmd_command` | the `ai` command |
| `_ai_cmd_widget` | the Ctrl-O key binding |

`_ai_cmd_generate` returns 0 with the command in `REPLY` and an optional warning
in `reply`, or 1 with error lines in `reply`. `_ai_cmd_command` and
`_ai_cmd_widget` only decide how to show that.

## Conventions

- Start functions with `emulate -L zsh`, so users' shell options can't change
  how they behave.
- Error messages start with `ai: ` and say what to do next, where possible.
- Keep it working on macOS (BSD tools) and Linux (GNU and BusyBox tools). If you
  use `sed`, `date`, `stat`, `mktemp` or similar in the plugin, check that the
  flags exist on both.
- No new dependencies beyond zsh, `jq` and the backend's own tool (`claude` or
  `curl`).
- `_AI_CMD_SYSTEM_PROMPT` is a single-quoted string: no apostrophes inside it.
- Don't name variables after zsh's special parameters, even as locals: a local
  `prompt` (zsh's `PS1`) showed the system prompt as the shell prompt while a
  request ran. `zsh -fc 'print ${(k)parameters[(R)*special*]}'` lists them.
- Comments explain why, not what; match the style around your change.

## Tests

Run them before you open a pull request:

```zsh
tests/run.zsh
```

They use fake `claude` and `curl` commands, so they call no model and need
nothing running. With `expect` installed, `tests/interactive.exp` also drives a
real interactive zsh, for what only a terminal shows: the `ai` command, Ctrl-O,
Ctrl-C and timeouts. If it fails, `AI_TEST_LOG=session.log tests/run.zsh` saves
the whole session to read. GitHub Actions runs everything on macOS, Ubuntu and
Alpine for each pull request.

Add a test for what you change:

- a reply format or error from a backend: a case in the backend's section
- a command the risky check gets wrong: add it to the `risky` or `safe` list
- a new backend: its own section, with a fake command like the existing ones
- something you can only see in a terminal: a step in `tests/interactive.exp`

If you change the system prompt, also try a few real requests with Claude and,
if you can, a local model, and say in the pull request what you tried. Prompt
changes can't be checked by the tests.

## Adding a backend

1. Write `_ai_cmd_ask_<name> <request> <system prompt> <timeout> <temp dir>`.
   On success it returns 0 with the reply's JSON text (`command` and `message`)
   in `REPLY`; on failure it returns 1 with error lines in `reply`. The timeout
   is in seconds, 0 for none. The temp dir is the backend's to use; the caller
   removes it.
2. Add the name, and the command it needs, to the `case` in `_ai_cmd_request`.
3. Add its settings to the list in the header comment of `ai.plugin.zsh`, and
   describe them in the README's Configuration section.
4. Add tests.

Many services already offer an OpenAI-compatible API; check whether the `openai`
backend with the right `AI_CMD_URL` is enough before adding a new one.

## Demo GIFs

If you change what users see, re-record the GIFs with `docs/record-demo.sh` (see
[Demo GIFs](README.md#demo-gifs)). It makes real `claude` calls, so check the
result before committing it.

## Pull requests

- One change per pull request, with a short description of what and why, and
  how you tested it.
- Commit messages: a short subject in the imperative ("Add …", "Fix …"), and a
  body when the reason isn't obvious.
- Update the README when you change behaviour or settings.

By contributing, you agree that your contributions are licensed under the
[MIT License](LICENSE).
