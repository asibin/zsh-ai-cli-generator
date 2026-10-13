# ai — natural language to shell command, via the claude CLI. A zsh plugin; see README.md.
#
# Key binding: type the request on the command line, press Ctrl-O, and it becomes the command.
#   find files > 100MB modified this week, largest first      press Ctrl-O
#   find . -type f -size +100M -mtime -7 -exec stat … | sort -rn   edit or hit Enter
# The shell never parses the request, so > < | & ; # $ ` " { } and apostrophes need no quoting.
# Undo (Ctrl-_ in emacs mode) brings the request back.
#
# Command:
#   ai <what you want>   generate a command and place it on your next prompt (edit or hit Enter)
# Quote the request when it contains shell characters: > < | & ; # $ ` " { }
#   ai 'find files > 100MB modified this week'
# An apostrophe can't go inside single quotes: drop it (ai 'whats my ip') or use double quotes.
#
# Load with a plugin manager, or from ~/.zshrc:   source ~/workspace/personal/scripts/ai.plugin.zsh
#
# Config (env vars, set before the plugin loads):
#   AI_CMD_MODEL   model alias passed to `claude --model` (default: sonnet)
#   AI_CMD_KEY     key bound in the emacs and viins keymaps (default: ^O, i.e. Ctrl-O; replaces
#                  accept-line-and-down-history). Set it to '' for no key binding.
#
# Requires: claude CLI, jq.

: ${AI_CMD_MODEL:=sonnet}
: ${AI_CMD_KEY='^O'}   # no colon: an empty value means no key binding

# Single-quoted string: do not use apostrophes inside it.
_AI_CMD_SYSTEM_PROMPT='You translate a natural-language request into exactly one shell command line.

__ENVIRONMENT__
The command runs in the working directory you were told about. Use relative paths like "." for "here"/"this folder".

Reply with the JSON fields "command" and "message":
- "command": ONLY the command line, exactly as it should be typed. No markdown, no backticks around it, no leading "$", no "#" comments.
  A single line. Chain steps with |, &&, ; or $(...) if the task needs several commands.
- "message": empty when you return a command, unless the command deletes, overwrites or kills something; then one short warning sentence.
- If no shell command can do what was asked, set "command" to "" and explain why in one short sentence in "message".

Command rules:
- Fully satisfy the request: include the flags/formatting needed to show exactly what was asked (e.g. for "containers and their ports" use docker ps --format "table {{.Names}}\t{{.Ports}}", not bare docker ps).
- Prefer standard, widely installed tools; prefer the safest form that does the job.
- If the request is ambiguous, pick the most common interpretation. Never ask questions.'

# Describe this machine once, at source time, so commands match the local OS and userland.
() {
  emulate -L zsh
  local os line pm
  case $OSTYPE in
    darwin*)
      os='macOS (Darwin, BSD userland — e.g. BSD sed/date/stat, not GNU)' ;;
    linux*)
      os=Linux
      if [[ -r /etc/os-release ]]; then
        for line in ${(f)"$(</etc/os-release)"}; do
          [[ $line == PRETTY_NAME=* ]] && os="Linux (${(Q)${line#PRETTY_NAME=}})"
        done
      fi
      # Alpine and other minimal images symlink sed, find, etc. to busybox.
      if [[ ${commands[sed]:A:t} == busybox ]]; then
        os+=', BusyBox userland — limited sed/date/find options, not GNU'
      else
        os+=', GNU userland — e.g. GNU sed/date/stat, not BSD'
      fi ;;
    *)
      os=$OSTYPE ;;
  esac
  local -a pms=()
  for pm in brew port apt dnf yum pacman zypper apk nix-env; do
    (( $+commands[$pm] )) && pms+=$pm
  done
  _AI_CMD_SYSTEM_PROMPT=${_AI_CMD_SYSTEM_PROMPT/__ENVIRONMENT__/"Environment: $os, zsh${pms:+, package managers: ${(j:, :)pms}}."}
}

_AI_CMD_SCHEMA='{"type":"object","properties":{"command":{"type":"string"},"message":{"type":"string"}},"required":["command","message"],"additionalProperties":false}'

# Ask Claude for one command line. Prints nothing, so the `ai` command and the ZLE widget
# can each show the result their own way.
#   success: returns 0, REPLY=the command, reply=(warning) or ()
#   failure: returns 1, reply=(error lines)
_ai_generate() {
  emulate -L zsh
  setopt extended_glob
  local query=$1
  REPLY= reply=()

  local dep
  for dep in claude jq; do
    if (( ! $+commands[$dep] )); then
      reply=("ai: $dep is required but not on PATH")
      return 1
    fi
  done

  local out err rc=1 errfile
  if ! errfile=$(mktemp "${TMPDIR:-/tmp}/ai.XXXXXX"); then
    reply=("ai: could not create a temporary file")
    return 1
  fi
  {
    # Runs in the current directory so the model knows where "here" is. --setting-sources ""
    # keeps out all settings and CLAUDE.md files; no tools, no MCP, no session files.
    # stderr goes to a file so CLI warnings never end up in the command.
    out=$(claude -p \
            --model "$AI_CMD_MODEL" \
            --system-prompt "$_AI_CMD_SYSTEM_PROMPT" \
            --output-format json \
            --json-schema "$_AI_CMD_SCHEMA" \
            --tools "" \
            --strict-mcp-config \
            --setting-sources "" \
            --no-session-persistence \
            -- "$query" 2>$errfile)
    rc=$?
    err=$(<$errfile)
  } always {
    rm -f $errfile   # also on Ctrl-C
  }

  # Parse the reply once: is_error, command, message, result as NUL-separated fields.
  local parsed is_error cmd msg detail
  if parsed=$(jq -j '[(.is_error | tostring), (.structured_output.command // ""),
                      (.structured_output.message // ""), (.result // "" | tostring)]
                     | join("\u0000")' <<<$out 2>/dev/null); then
    local -a fields=( "${(@0)parsed}" )
    is_error=$fields[1] cmd=$fields[2] msg=$fields[3] detail=$fields[4]
  else
    detail=$out   # not JSON, e.g. a plain-text CLI error
  fi

  if (( rc != 0 )) || [[ $is_error != false ]]; then
    reply=("ai: claude failed (exit $rc)${detail:+: $detail}" ${err:+"$err"})
    return 1
  fi

  # A leading space would hide the command from history (HIST_IGNORE_SPACE).
  cmd=${${cmd##[[:space:]]#}%%[[:space:]]#}

  if [[ -z $cmd ]]; then
    reply=("ai: ${msg:-empty response}")
    return 1
  fi
  if [[ $cmd == *$'\n'* ]]; then
    reply=("ai: expected one command line, got several; not inserting:" "$cmd")
    return 1
  fi

  REPLY=$cmd
  reply=(${msg:+"$msg"})
}

# Put the generated command on the next prompt, ready to edit or run.
_ai() {
  emulate -L zsh
  local query="$*"
  if [[ -z ${query//[[:space:]]/} ]]; then
    print -u2 "usage: ai '<describe the command you want>'"
    return 2
  fi

  local rc
  print -nu2 $'\e[2mthinking…\e[0m'
  {
    _ai_generate "$query"
    rc=$?
  } always {
    print -nu2 $'\r\e[K'   # clear "thinking…", also on Ctrl-C
  }

  if (( rc != 0 )); then
    print -ru2 -l -- "${reply[@]}"
    return 1
  fi
  (( $#reply )) && print -ru2 -- $'\e[2m'"$reply[1]"$'\e[0m'
  print -rz -- "$REPLY"
}

# noglob so ?, * and [] in plain English aren't treated as globs.
alias ai='noglob _ai'

# Replace the request in the line editor with the generated command.
_ai_widget() {
  emulate -L zsh
  if [[ -z ${BUFFER//[[:space:]]/} ]]; then
    zle -M "ai: type what you want, then press the key again"
    return 1
  fi

  zle -M 'thinking…'
  zle -R   # show it now; the call below blocks for a few seconds
  if ! _ai_generate "$BUFFER"; then
    zle -M "${(F)reply}"   # the request stays on the line, so you can reword it
    return 1
  fi

  BUFFER=$REPLY
  CURSOR=$#BUFFER
  zle -M "${reply[1]-}"   # the warning, if any; otherwise clears "thinking…"
}

# Only in a shell with a line editor, so sourcing this from a script still works.
if [[ -o zle ]]; then
  zle -N ai-generate _ai_widget
  if [[ -n $AI_CMD_KEY ]]; then
    bindkey -M emacs "$AI_CMD_KEY" ai-generate
    bindkey -M viins "$AI_CMD_KEY" ai-generate
  fi
fi
