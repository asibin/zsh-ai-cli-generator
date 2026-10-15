# ai — natural language to shell command, via Claude or a local model. A zsh plugin; see README.md.
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
# Load with a plugin manager, or from ~/.zshrc:   source /path/to/zsh-ai-cli-generator/ai.plugin.zsh
#
# Config (env vars):
#   AI_CMD_KEY     key bound in the emacs and viins keymaps (default: ^O, i.e. Ctrl-O; replaces
#                  accept-line-and-down-history). Set it to '' for no key binding.
#                  Set it before the plugin loads.
#   AI_CMD_BACKEND claude (default): the claude CLI.
#                  openai: any server with an OpenAI-compatible chat API, such as Ollama,
#                  LM Studio, llama.cpp, vLLM or OpenRouter.
#   AI_CMD_MODEL   model name. claude: an alias for `claude --model` (default: sonnet).
#                  openai: required, e.g. llama3.2 for Ollama.
#   AI_CMD_URL     openai only: the API base URL (default: http://localhost:11434/v1, Ollama).
#   AI_CMD_API_KEY openai only: sent as a bearer token, for hosted services.
#   AI_CMD_INSTRUCTIONS   extra instructions added to the system prompt, one per line, e.g.
#                  'Use bat instead of cat.'
#   All but AI_CMD_KEY are read on every request, so they can change any time.
#
# Requires: jq, plus the claude CLI (claude backend) or curl (openai backend).

: ${AI_CMD_KEY='^O'}   # no colon: an empty value means no key binding

# Single-quoted string: do not use apostrophes inside it.
_AI_CMD_SYSTEM_PROMPT='You translate a natural-language request into exactly one shell command line.

__ENVIRONMENT__
__DIRECTORY__ The command runs there. Use relative paths like "." for "here"/"this folder".

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

# Ask the model for one command line. Prints nothing, so the `ai` command and the ZLE widget
# can each show the result their own way.
#   success: returns 0, REPLY=the command, reply=(warning) or ()
#   failure: returns 1, reply=(error lines)
_ai_generate() {
  emulate -L zsh
  setopt extended_glob
  local query=$1 backend=${AI_CMD_BACKEND:-claude}
  REPLY= reply=()

  local -a deps=(jq)
  case $backend in
    claude) deps+=claude ;;
    openai) deps+=curl ;;
    *)
      reply=("ai: unknown AI_CMD_BACKEND '$backend' (use claude or openai)")
      return 1 ;;
  esac
  local dep
  for dep in $deps; do
    if (( ! $+commands[$dep] )); then
      reply=("ai: $dep is required but not on PATH")
      return 1
    fi
  done

  # Tell the model where "here" is, and whether it's a git repository (.git is a file in
  # worktrees and submodules, so test with -e).
  local dir=$PWD where='not a git repository'
  while true; do
    if [[ -e $dir/.git ]]; then
      where='a git repository'
      break
    fi
    [[ $dir == / ]] && break
    dir=${dir:h}
  done
  local prompt=${_AI_CMD_SYSTEM_PROMPT/__DIRECTORY__/"Working directory: $PWD ($where)."}
  if [[ -n ${AI_CMD_INSTRUCTIONS//[[:space:]]/} ]]; then
    prompt+=$'\n\nAdditional instructions from the user. Follow them, but keep the reply format above:\n'
    prompt+=$AI_CMD_INSTRUCTIONS
  fi

  # The backend sets cmd and msg, or reply=(error lines) and returns 1.
  local cmd msg
  _ai_ask_$backend "$query" "$prompt" || return 1

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

  # Small models often leave out the warning, so check locally as well.
  if [[ -z $msg ]] && _ai_risky "$cmd"; then
    msg='This command may delete, overwrite or stop something; check it before running.'
  fi

  REPLY=$cmd
  reply=(${msg:+"$msg"})
}

# Split a JSON object's "command" and "message" fields into cmd and msg (the caller's locals).
# Returns 1 if $1 isn't such an object.
_ai_split_reply() {
  local parsed
  [[ -n ${1//[[:space:]]/} ]] || return 1
  parsed=$(jq -j 'if type == "object" then [(.command // "" | tostring), (.message // "" | tostring)]
                  else error end | join("\u0000")' <<<$1 2>/dev/null) || return 1
  local -a fields=( "${(@0)parsed}" )
  cmd=$fields[1] msg=$fields[2]
}

# Backend: the claude CLI.
_ai_ask_claude() {
  local query=$1 prompt=$2
  local out err rc=1 errfile
  if ! errfile=$(mktemp "${TMPDIR:-/tmp}/ai.XXXXXX"); then
    reply=("ai: could not create a temporary file")
    return 1
  fi
  {
    # --setting-sources "" keeps out all settings and CLAUDE.md files; no tools, no MCP, no
    # session files. stderr goes to a file so CLI warnings never end up in the command.
    out=$(claude -p \
            --model "${AI_CMD_MODEL:-sonnet}" \
            --system-prompt "$prompt" \
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

  local is_error detail
  is_error=$(jq -r '.is_error | tostring' <<<$out 2>/dev/null)
  detail=$(jq -r '.result // "" | tostring' <<<$out 2>/dev/null) || detail=$out   # not JSON, e.g. a plain-text CLI error
  if (( rc != 0 )) || [[ $is_error != false ]]; then
    reply=("ai: claude failed (exit $rc)${detail:+: $detail}" ${err:+"$err"})
    return 1
  fi
  _ai_split_reply "$(jq -c '.structured_output // {}' <<<$out)"
}

# Backend: an OpenAI-compatible chat completions API (Ollama, LM Studio, llama.cpp, vLLM, …).
_ai_ask_openai() {
  local query=$1 prompt=$2
  local url=${${AI_CMD_URL:-http://localhost:11434/v1}%/}
  if [[ -z $AI_CMD_MODEL ]]; then
    reply=("ai: set AI_CMD_MODEL to the model to use, e.g. AI_CMD_MODEL=llama3.2")
    return 1
  fi

  local tmp
  if ! tmp=$(mktemp -d "${TMPDIR:-/tmp}/ai.XXXXXX"); then
    reply=("ai: could not create a temporary directory")
    return 1
  fi
  local code rc=1 err body
  {
    # Ask for the reply as JSON matching the schema; servers that ignore this usually still
    # follow the system prompt, and the reply is parsed leniently below.
    jq -n --arg model "$AI_CMD_MODEL" --arg system "$prompt" --arg user "$query" \
          --argjson schema "$_AI_CMD_SCHEMA" \
          '{model: $model, stream: false,
            messages: [{role: "system", content: $system}, {role: "user", content: $user}],
            response_format: {type: "json_schema",
                              json_schema: {name: "shell_command", strict: true, schema: $schema}}}' \
          > $tmp/request
    # The API key goes through a curl config on stdin, so it doesn't show up in `ps`.
    code=$(curl -sS --connect-timeout 5 \
                -H 'Content-Type: application/json' \
                --data-binary @$tmp/request \
                -o $tmp/response -w '%{http_code}' \
                -K - \
                -- "$url/chat/completions" \
                <<<"${AI_CMD_API_KEY:+header = \"Authorization: Bearer $AI_CMD_API_KEY\"}" \
                2>$tmp/error)
    rc=$?
    err=$(<$tmp/error)
    [[ -f $tmp/response ]] && body=$(<$tmp/response)
  } always {
    rm -rf -- $tmp   # also on Ctrl-C
  }

  if (( rc == 7 )); then
    reply=("ai: can't reach $url; is the server running? (Ollama: ollama serve)")
    return 1
  fi
  if (( rc != 0 )); then
    reply=("ai: curl failed (exit $rc)${err:+: $err}")
    return 1
  fi
  if [[ $code != 2<-> ]]; then
    # OpenAI-style {"error": {"message": …}} or Ollama-style {"error": "…"}.
    local detail
    detail=$(jq -r '.error | if type == "object" then .message else . end // empty' <<<$body 2>/dev/null) \
      || detail=${body[1,300]}
    reply=("ai: $url answered HTTP $code${detail:+: $detail}")
    return 1
  fi

  local content
  content=$(jq -r '.choices[0].message.content // empty' <<<$body 2>/dev/null)
  # Reasoning models may think out loud first (some templates leave out the opening <think>),
  # and some models wrap the JSON in a code fence or a sentence: keep the outermost { … }.
  content=${content##*\<\/think\>}
  [[ $content == *\{*\}* ]] && content="{${${content#*\{}%\}*}}"
  if ! _ai_split_reply "$content"; then
    reply=("ai: the model didn't reply with the expected JSON:" "${content:-(empty reply)}")
    return 1
  fi
}

# Does the command delete, overwrite or stop something? A local check that errs on the side of
# warning; it doesn't look inside quotes or $(…) any more carefully than at the rest.
_ai_risky() {
  emulate -L zsh
  setopt extended_glob
  local cmd=$1 pattern i
  # Where a command name can start: the line start, after ; & | ( ` or find -exec, and after
  # prefixes such as sudo or xargs with their options. Then an optional path such as /bin/.
  local start='(^|[;&|(`]|-exec(dir)?[[:space:]]|-ok[[:space:]])[[:space:]]*((sudo|doas|xargs|env|nohup|exec|command|time|nice)([[:space:]]+-[^[:space:]]+)*[[:space:]]+)*([^[:space:]]*/)?'
  local -a patterns=(
    "${start}(rm|rmdir|unlink|shred|dd|mkfs[.[:alnum:]]*|truncate|wipefs|fdisk|diskutil|kill|pkill|killall|reboot|shutdown|halt)([[:space:]]|$)"
    "${start}crontab[[:space:]]+-r"
    "${start}sed[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-i"
    'git[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-[[:alnum:]]*f|branch[[:space:]]+-D|push([[:space:]].*)?[[:space:]](--force|-f([[:space:]]|$)))'
    '[[:space:]]-delete([[:space:]]|$)'
    '(docker|podman)[[:space:]]+((container|image|volume|network|system)[[:space:]]+)?(rm|rmi|prune|kill|stop)([[:space:]]|$)'
    'kubectl[[:space:]]+delete'
  )
  for pattern in $patterns; do
    [[ $cmd =~ $pattern ]] && return 0
  done

  # A > redirect to a file (not >>, and not to /dev/null or another descriptor).
  local -a words=( ${(z)cmd} )
  for (( i = 1; i < $#words; i++ )); do
    if [[ $words[i] == ([0-9]|\&|)\>(\||\!|) && $words[i+1] != (/dev/(null|stdout|stderr|tty)|\&*|[0-9]) ]]; then
      return 0
    fi
  done
  return 1
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
