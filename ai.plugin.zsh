# ai — natural language to shell command, via Claude or a local model. A zsh plugin.
#
#   ai <what you want>     put the command on your next prompt; quote the request if it
#                          contains > < | & ; # $ ` " { } or an apostrophe
#   <request>, then Ctrl-O replace the request typed on the command line with the command
#
# Settings, described in README.md: AI_CMD_KEY (set it before the plugin loads), AI_CMD_BACKEND,
# AI_CMD_MODEL, AI_CMD_URL, AI_CMD_API_KEY, AI_CMD_TIMEOUT, AI_CMD_INSTRUCTIONS.
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
# reply is model and server text that ends up in the terminal, so control characters are
# replaced: escape sequences in it could rewrite the screen or set the clipboard.
_ai_cmd_generate() {
  emulate -L zsh
  local rc
  _ai_cmd_request "$1"
  rc=$?
  (( $#reply )) && reply=( "${(@)${(@f)${(F)reply}}//[[:cntrl:]]/ }" )
  return $rc
}

# Build the prompt, ask the backend, and check the reply; see _ai_cmd_generate.
_ai_cmd_request() {
  emulate -L zsh
  setopt extended_glob
  local query=$1 backend=${AI_CMD_BACKEND:-claude} timeout=${AI_CMD_TIMEOUT:-60}
  REPLY= reply=()

  if [[ $timeout != <-> ]]; then
    reply=("ai: AI_CMD_TIMEOUT must be a whole number of seconds (0 for no limit), not '$timeout'")
    return 1
  fi

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
  # Not "prompt": that's zsh's PS1, and the line editor would show it while we wait.
  local system=${_AI_CMD_SYSTEM_PROMPT/__DIRECTORY__/"Working directory: $PWD ($where)."}
  if [[ -n ${AI_CMD_INSTRUCTIONS//[[:space:]]/} ]]; then
    system+=$'\n\nAdditional instructions from the user. Follow them, but keep the reply format above:\n'
    system+=$AI_CMD_INSTRUCTIONS
  fi

  local tmp json
  if ! tmp=$(mktemp -d "${TMPDIR:-/tmp}/ai.XXXXXX"); then
    reply=("ai: could not create a temporary directory")
    return 1
  fi
  {
    _ai_cmd_ask_$backend "$query" "$system" "$timeout" "$tmp" || return 1
    json=$REPLY
    REPLY=
  } always {
    rm -rf -- $tmp   # also on Ctrl-C
  }

  if ! _ai_cmd_parse_reply "$json"; then
    reply=("ai: the model didn't reply with the expected JSON:" "${json:-(empty reply)}")
    return 1
  fi
  local control=$reply[1] cmd=$reply[2] msg=$reply[3]
  reply=()

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
  # A carriage return or escape sequence could make the command look like something else.
  if [[ -n $control ]]; then
    reply=("ai: the command contains control characters; not inserting:" "$cmd")
    return 1
  fi

  # Small models often leave out the warning, so check locally as well.
  if [[ -z $msg ]] && _ai_cmd_risky "$cmd"; then
    msg='This command may delete, overwrite or stop something; check it before running.'
  fi

  REPLY=$cmd
  reply=(${msg:+"$msg"})
}

# Read "command" and "message" from a JSON reply.
#   success: returns 0, reply=(control command message). control is non-empty when the command
#            has control characters other than tab and newline; they are replaced with U+FFFD.
#            The message has every control character replaced with a space.
#   failure: returns 1 when $1 isn't a JSON object
# Fields are passed back joined by NUL, so no field may contain one.
_ai_cmd_parse_reply() {
  emulate -L zsh
  local parsed
  [[ -n ${1//[[:space:]]/} ]] || return 1
  parsed=$(jq -j '
    def control: . < 32 or (. >= 127 and . < 160);
    def unsafe: control and . != 9 and . != 10;
    if type != "object" then error else . end
    | (.command // "" | tostring | explode) as $c
    | [ (if any($c[]; unsafe) then "control" else "" end),
        ($c | map(if unsafe then 65533 else . end) | implode),
        (.message // "" | tostring | explode | map(if control then 32 else . end) | implode) ]
    | join("\u0000")' <<<$1 2>/dev/null) || return 1
  reply=( "${(@0)parsed}" )
}

# Backends: _ai_cmd_ask_<name> <request> <system prompt> <timeout in seconds, 0: none> <temp dir>
#   success: returns 0, REPLY=the reply: JSON text with "command" and "message"
#   failure: returns 1, reply=(error lines)
# The temp dir is theirs to use; the caller removes it.

# Backend: the claude CLI.
#
# --setting-sources "" keeps out all settings and CLAUDE.md files; no tools, no MCP, no session
# files. Output goes to files, so CLI warnings never end up in the command, and a process claude
# leaves behind can't keep us waiting.
#
# The CLI has no timeout option and macOS has no timeout command, so claude runs in the
# background of a subshell, which stops it after $timeout seconds. The subshell isn't
# interactive, so zsh prints no job messages for it. Background jobs ignore Ctrl-C, so the
# subshell's trap passes it on.
_ai_cmd_ask_claude() {
  emulate -L zsh
  local query=$1 system=$2 timeout=$3 tmp=$4
  local out err rc
  # Wait a tenth of a second between checks; zselect does it without starting a process.
  local -a nap=(zselect -t 10)
  zmodload -F zsh/zselect b:zselect 2>/dev/null || nap=(sleep 0.1)

  (
    trap 'kill $pid 2>/dev/null; exit 130' INT TERM
    claude -p \
      --model "${AI_CMD_MODEL:-sonnet}" \
      --system-prompt "$system" \
      --output-format json \
      --json-schema "$_AI_CMD_SCHEMA" \
      --tools "" \
      --strict-mcp-config \
      --setting-sources "" \
      --no-session-persistence \
      -- "$query" >$tmp/out 2>$tmp/err &
    pid=$!
    integer ticks=0
    while kill -0 $pid 2>/dev/null; do
      if (( timeout && ticks >= timeout * 10 )); then
        kill $pid 2>/dev/null
        : > $tmp/timed-out
        break
      fi
      $nap
      (( ticks++ ))
    done
    wait $pid
  )
  rc=$?
  if [[ -e $tmp/timed-out ]]; then
    reply=("ai: no reply from claude within ${timeout}s (AI_CMD_TIMEOUT)")
    return 1
  fi
  # Ctrl-C: 128 + SIGINT. Some systems interrupt the caller as well, others let it carry on.
  if (( rc == 130 )); then
    reply=("ai: cancelled")
    return 1
  fi
  out=$(<$tmp/out) err=$(<$tmp/err)

  local is_error detail
  is_error=$(jq -r '.is_error | tostring' <<<$out 2>/dev/null)
  detail=$(jq -r '.result // "" | tostring' <<<$out 2>/dev/null) || detail=$out   # not JSON, e.g. a plain-text CLI error
  if (( rc != 0 )) || [[ $is_error != false ]]; then
    reply=("ai: claude failed (exit $rc)${detail:+: $detail}" ${err:+"$err"})
    return 1
  fi
  REPLY=$(jq -c '.structured_output // {}' <<<$out)
}

# Backend: an OpenAI-compatible chat completions API (Ollama, LM Studio, llama.cpp, vLLM, …).
_ai_cmd_ask_openai() {
  emulate -L zsh
  local query=$1 system=$2 timeout=$3 tmp=$4
  local url=${${AI_CMD_URL:-http://localhost:11434/v1}%/}
  if [[ -z $AI_CMD_MODEL ]]; then
    reply=("ai: set AI_CMD_MODEL to the model to use, e.g. AI_CMD_MODEL=llama3.2")
    return 1
  fi

  # Ask for the reply as JSON matching the schema; servers that ignore this usually still
  # follow the system prompt, and the reply is read leniently below.
  jq -n --arg model "$AI_CMD_MODEL" --arg system "$system" --arg user "$query" \
        --argjson schema "$_AI_CMD_SCHEMA" \
        '{model: $model, stream: false,
          messages: [{role: "system", content: $system}, {role: "user", content: $user}],
          response_format: {type: "json_schema",
                            json_schema: {name: "shell_command", strict: true, schema: $schema}}}' \
        > $tmp/request

  local code rc err body
  local -a limit=()
  (( timeout )) && limit=(--max-time $timeout)
  # The API key goes through a curl config on stdin, so it doesn't show up in `ps`.
  code=$(curl -sS --connect-timeout 5 $limit \
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

  if (( rc == 130 )); then   # Ctrl-C
    reply=("ai: cancelled")
    return 1
  fi
  if (( rc == 7 )); then
    reply=("ai: can't reach $url; is the server running? (Ollama: ollama serve)")
    return 1
  fi
  if (( rc == 28 )); then
    reply=("ai: no reply from $url within ${timeout}s (AI_CMD_TIMEOUT); loading a model the first time can take longer")
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
  REPLY=$content
}

# Does the command delete, overwrite or stop something? A local check that errs on the side of
# warning; it doesn't look inside quotes or $(…) any more carefully than at the rest.
_ai_cmd_risky() {
  emulate -L zsh
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

# The `ai` command: put the generated command on the next prompt, ready to edit or run.
_ai_cmd_command() {
  emulate -L zsh
  local query="$*"
  if [[ -z ${query//[[:space:]]/} ]]; then
    print -u2 "usage: ai '<describe the command you want>'"
    return 2
  fi

  local rc
  print -nu2 $'\e[2mthinking…\e[0m'
  {
    _ai_cmd_generate "$query"
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
alias ai='noglob _ai_cmd_command'

# The key binding: replace the request in the line editor with the generated command.
_ai_cmd_widget() {
  emulate -L zsh
  if [[ -z ${BUFFER//[[:space:]]/} ]]; then
    zle -M "ai: type what you want, then press the key again"
    return 1
  fi

  zle -M 'thinking…'
  zle -R   # show it now; the call below blocks for a few seconds
  if ! _ai_cmd_generate "$BUFFER"; then
    zle -M "${(F)reply}"   # the request stays on the line, so you can reword it
    return 1
  fi

  BUFFER=$REPLY
  CURSOR=$#BUFFER
  zle -M "${reply[1]-}"   # the warning, if any; otherwise clears "thinking…"
}

# Only in a shell with a line editor, so sourcing this from a script still works.
if [[ -o zle ]]; then
  zle -N ai-generate _ai_cmd_widget
  if [[ -n $AI_CMD_KEY ]]; then
    bindkey -M emacs "$AI_CMD_KEY" ai-generate
    bindkey -M viins "$AI_CMD_KEY" ai-generate
  fi
fi
