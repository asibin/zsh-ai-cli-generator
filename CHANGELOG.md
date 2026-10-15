# Changelog

Notable changes to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) from the first release on.

## [Unreleased]

### Added

- The `ai` command: `ai <request>` puts a generated shell command on your next
  prompt, to edit or run with Enter.
- A key binding: type the request on the command line and press Ctrl-O to turn
  it into the command, with no quoting needed. `AI_CMD_KEY` picks the key, and
  `AI_CMD_KEY=''` turns the binding off.
- Packaging as a zsh plugin named `ai` (`ai.plugin.zsh`), for Oh My Zsh,
  antidote, zinit, zplug, sheldon, or a plain `source`.
- macOS and Linux support: the model is told the OS, whether the tools are BSD,
  GNU or BusyBox, and which package managers are installed.
- The current directory and whether it's a git repository are sent with each
  request, so "here" means the folder you're in.
- `AI_CMD_INSTRUCTIONS` for your own additions to the system prompt, such as
  "Use bat instead of cat".
- Backends: `claude` (the default, through the Claude Code CLI) and `openai`
  for any OpenAI-compatible server, such as Ollama, LM Studio, llama.cpp, vLLM
  or OpenRouter. Configured with `AI_CMD_BACKEND`, `AI_CMD_MODEL`,
  `AI_CMD_URL` and `AI_CMD_API_KEY`.
- Warnings when the command deletes, overwrites or stops something, from the
  model or, when it gave none, from a local check of the command.
- Tests (`tests/run.zsh`) with fake `claude` and `curl` commands.
- Demo GIFs and the script that records them (`docs/record-demo.sh`).
- README with install steps, a usage guide and configuration, plus an MIT
  license and contributing guidelines.

[Unreleased]: https://github.com/asibin/zsh-ai-cli-generator/commits/master
