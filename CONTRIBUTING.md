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

Everything is in `ai.plugin.zsh`:

| Function | What it does |
| --- | --- |
| `_ai_generate` | builds the prompt, calls the backend, checks the reply; prints nothing |
| `_ai_ask_claude`, `_ai_ask_openai` | one per backend: send the request, set `cmd` and `msg` |
| `_ai_split_reply` | reads `command` and `message` from the reply JSON |
| `_ai_risky` | the local check for commands that delete, overwrite or stop something |
| `_ai` | the `ai` command |
| `_ai_widget` | the Ctrl-O key binding |

`_ai_generate` returns 0 with the command in `REPLY` and an optional warning in
`reply`, or 1 with error lines in `reply`. `_ai` and `_ai_widget` only decide how
to show that.

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
- Comments explain why, not what; match the style around your change.

## Tests

Run them before you open a pull request:

```zsh
tests/run.zsh
```

They use fake `claude` and `curl` commands, so they call no model and need
nothing running. Add a test for what you change:

- a reply format or error from a backend: a case in the backend's section
- a command the risky check gets wrong: add it to the `risky` or `safe` list
- a new backend: its own section, with a fake command like the existing ones

If you change the system prompt, also try a few real requests with Claude and,
if you can, a local model, and say in the pull request what you tried. Prompt
changes can't be checked by the tests.

## Adding a backend

1. Write `_ai_ask_<name>`: it gets the request and the system prompt as `$1` and
   `$2`, and sets `cmd` and `msg` (the caller's locals), or sets `reply` to error
   lines and returns 1. `_ai_split_reply` parses the usual JSON reply.
2. Add the name, and its required command, to the `case` in `_ai_generate`.
3. Document its settings in the header comment of `ai.plugin.zsh` and in the
   README's Configuration section.
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
