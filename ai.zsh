# ai — natural language to shell command, via the claude CLI.
#
#   ai <what you want>   generate a command and place it on your next prompt (edit or hit Enter)
#
# Quote the request when it contains shell characters: > < | & ; # $ ` " { }
#   ai 'find files > 100MB modified this week'
# An apostrophe can't go inside single quotes: drop it (ai 'whats my ip') or use double quotes.
#
# Source from ~/.zshrc:   source ~/workspace/personal/scripts/ai.zsh
#
# Config (env vars):
#   AI_CMD_MODEL   model alias passed to `claude --model` (default: sonnet)
#
# Requires: claude CLI, jq.

: ${AI_CMD_MODEL:=sonnet}

# Single-quoted string: do not use apostrophes inside it.
_AI_CMD_SYSTEM_PROMPT='You translate a natural-language request into exactly one shell command line.

Environment: macOS (Darwin, BSD userland — e.g. BSD sed/date/stat, not GNU), zsh, Homebrew available.
The command runs in the current directory of the shell, which you do not know (ignore any working directory you were told about). Use relative paths like "." for "here"/"current dir".

Reply with the JSON fields "command" and "message":
- "command": ONLY the command line, exactly as it should be typed. No markdown, no backticks around it, no leading "$", no "#" comments.
  A single line. Chain steps with |, &&, ; or $(...) if the task needs several commands.
- "message": empty when you return a command, unless the command deletes, overwrites or kills something; then one short warning sentence.
- If no shell command can do what was asked, set "command" to "" and explain why in one short sentence in "message".

Command rules:
- Fully satisfy the request: include the flags/formatting needed to show exactly what was asked (e.g. for "containers and their ports" use docker ps --format "table {{.Names}}\t{{.Ports}}", not bare docker ps).
- Prefer standard, widely installed tools; prefer the safest form that does the job.
- If the request is ambiguous, pick the most common interpretation. Never ask questions.'

_AI_CMD_SCHEMA='{"type":"object","properties":{"command":{"type":"string"},"message":{"type":"string"}},"required":["command","message"],"additionalProperties":false}'

# Put the generated command on the next prompt, ready to edit or run.
_ai() {
  emulate -L zsh
  setopt extended_glob
  local query="$*"
  if [[ -z ${query//[[:space:]]/} ]]; then
    print -u2 "usage: ai '<describe the command you want>'"
    return 2
  fi

  local out err rc=1 errfile
  errfile=$(mktemp -t ai) || return 1
  print -nu2 $'\e[2mthinking…\e[0m'
  {
    # Run from $HOME so no project CLAUDE.md/settings leak into the prompt; no tools, no MCP, no session files.
    # stderr goes to a file so CLI warnings never end up in the command.
    out=$(cd ~ && claude -p \
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
    print -nu2 $'\r\e[K'   # clear "thinking…", also on Ctrl-C
    rm -f $errfile
  }

  local is_error detail
  is_error=$(jq -r '.is_error' <<<$out 2>/dev/null)
  if (( rc != 0 )) || [[ $is_error != false ]]; then
    detail=$(jq -r '.result // empty' <<<$out 2>/dev/null) || detail=$out
    print -ru2 -- "ai: claude failed (exit $rc)${detail:+: $detail}"
    [[ -n $err ]] && print -ru2 -- "$err"
    return 1
  fi

  local cmd msg
  cmd=$(jq -r '.structured_output.command // empty' <<<$out)
  msg=$(jq -r '.structured_output.message // empty' <<<$out)

  # Defensive cleanup in case the model wraps the command anyway.
  cmd=${${cmd//$'\r'/}##[[:space:]]#}
  cmd=${cmd#\`\`\`[[:alnum:]]#$'\n'}         # opening fence line, optional language
  cmd=${cmd#\`\`\`}                          # inline ```cmd```
  cmd=${${cmd%%[[:space:]]#}%\`\`\`}
  cmd=${${cmd##[[:space:]]#}%%[[:space:]]#}
  cmd=${cmd#\$[[:space:]]##}                 # leading "$ " prompt sigil
  [[ $cmd == \`[^\`]##\` ]] && cmd=${cmd:1:-1}   # wrapped in backticks
  # Trailing "# comment" (zsh treats # as a plain word unless INTERACTIVE_COMMENTS is set).
  # Only when the # follows whitespace and no quote/backtick comes after it, so '#' inside quotes survives.
  [[ $cmd == (#b)(*[^[:space:]])[[:space:]]##\#[^\'\"\`]# ]] && cmd=$match[1]
  cmd=${${cmd##[[:space:]]#}%%[[:space:]]#}   # trim last: a leading space would hide it from history

  if [[ -z $cmd ]]; then
    print -ru2 -- "ai: ${msg:-empty response}"
    return 1
  fi
  if [[ $cmd == *$'\n'* ]]; then
    print -ru2 -- "ai: expected one command line, got several; not inserting:"
    print -ru2 -- "$cmd"
    return 1
  fi

  [[ -n $msg ]] && print -ru2 -- $'\e[2m'"$msg"$'\e[0m'
  print -rz -- "$cmd"
}

# noglob so ?, * and [] in plain English aren't treated as globs.
alias ai='noglob _ai'
