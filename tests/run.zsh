#!/usr/bin/env zsh
# Tests for ai.plugin.zsh. Fake claude and curl commands stand in for the real ones, so no
# model is called and nothing needs to be running.
#
#   tests/run.zsh

emulate -L zsh
# The control-character tests use non-ASCII text, which needs a UTF-8 locale.
[[ ${LC_ALL:-${LC_CTYPE:-$LANG}} == *(UTF-8|utf8)* ]] || export LC_ALL=C.UTF-8

repo=${0:A:h:h}
fake=$(mktemp -d "${TMPDIR:-/tmp}/ai-test.XXXXXX")
fake=${fake:A}   # $PWD has no // even when $TMPDIR ends in /
trap 'rm -rf -- $fake' EXIT
export FAKE=$fake

mkdir $fake/bin
# Records the model and system prompt, waits $FAKE_SLEEP seconds, prints $FAKE_ERR to stderr
# and $FAKE_OUT, or a reply with the command `echo got: <request>`, and exits with $FAKE_RC.
cat > $fake/bin/claude <<'EOF'
#!/usr/bin/env zsh
[[ -n $FAKE_SLEEP ]] && sleep $FAKE_SLEEP
query=
while (( $# )); do
  case $1 in
    --model) print -r -- $2 > $FAKE/model; shift ;;
    --system-prompt) print -r -- $2 > $FAKE/prompt; shift ;;
    --) query=$2; shift ;;
  esac
  shift
done
[[ -n $FAKE_ERR ]] && print -ru2 -- $FAKE_ERR
if [[ -n $FAKE_OUT ]]; then
  print -r -- $FAKE_OUT
else
  jq -nc --arg q "$query" '{is_error: false, result: "", structured_output: {command: ("echo got: " + $q), message: ""}}'
fi
exit ${FAKE_RC:-0}
EOF
# Records the request, URL, config (stdin) and --max-time, writes $FAKE_BODY to the -o file, prints
# $FAKE_CODE as the HTTP status, exits with $FAKE_RC.
cat > $fake/bin/curl <<'EOF'
#!/usr/bin/env zsh
out=
while (( $# )); do
  case $1 in
    -o) out=$2; shift ;;
    --data-binary) cat ${2#@} > $FAKE/request; shift ;;
    -K) cat > $FAKE/config; shift ;;
    --max-time) print -r -- $2 > $FAKE/max-time; shift ;;
    -H|-w|--connect-timeout) shift ;;
    --) print -r -- $2 > $FAKE/url; shift ;;
  esac
  shift
done
[[ -n $FAKE_BODY && -n $out ]] && print -r -- $FAKE_BODY > $out
print -n -- ${FAKE_CODE:-200}
exit ${FAKE_RC:-0}
EOF
chmod +x $fake/bin/claude $fake/bin/curl
path=($fake/bin $path)

source $repo/ai.plugin.zsh

integer failures=0
pass() { print -r -- "ok    $1" }
fail() { print -r -- "FAIL  $1"; shift; print -rl -- "      "$^@; (( failures++ )) }

# check <name> <rc> <REPLY> <first reply line>: check the result of the last _ai_cmd_generate.
check() {
  local name=$1 want_rc=$2 want_cmd=$3 want_msg=$4
  if [[ $rc == $want_rc && $REPLY == $want_cmd && ${reply[1]-} == $want_msg ]]; then
    pass $name
  else
    fail $name "want: rc=$want_rc REPLY=[$want_cmd] reply[1]=[$want_msg]" \
               "got:  rc=$rc REPLY=[$REPLY] reply[1]=[${reply[1]-}]"
  fi
}

# contains <name> <file> <text>: the file contains the text.
contains() {
  if [[ $(<$2) == *"$3"* ]]; then pass $1; else fail $1 "$2 lacks: $3" "it has: $(<$2)"; fi
}

claude_out() {   # <command> <message>
  FAKE_OUT=$(jq -nc --arg c "$1" --arg m "$2" '{is_error: false, result: "", structured_output: {command: $c, message: $m}}')
}

openai_body() {   # <message content>
  FAKE_BODY=$(jq -nc --arg c "$1" '{choices: [{message: {role: "assistant", content: $c}}]}')
}

export FAKE_OUT FAKE_RC FAKE_BODY FAKE_CODE FAKE_SLEEP FAKE_ERR
integer rc

print '# claude backend'
cd $repo
unset AI_CMD_BACKEND AI_CMD_MODEL AI_CMD_URL AI_CMD_API_KEY AI_CMD_INSTRUCTIONS

claude_out 'ls -la' ''; FAKE_RC=0
_ai_cmd_generate 'list files'; rc=$?
check 'command' 0 'ls -la' ''
contains 'default model is sonnet' $fake/model 'sonnet'
contains 'prompt names the working directory' $fake/prompt "Working directory: $repo (a git repository)."
case $OSTYPE in
  darwin*)
    contains 'prompt: macOS with BSD tools' $fake/prompt 'Environment: macOS (Darwin, BSD userland' ;;
  linux*)
    contains 'prompt: Linux distro' $fake/prompt 'Environment: Linux ('
    if [[ ${commands[sed]:A:t} == busybox ]]; then
      contains 'prompt: BusyBox tools' $fake/prompt 'BusyBox userland'
    else
      contains 'prompt: GNU tools' $fake/prompt 'GNU userland'
    fi ;;
esac
[[ $(<$fake/prompt) != *__DIRECTORY__* && $(<$fake/prompt) != *__ENVIRONMENT__* ]] \
  && pass 'no placeholders left' || fail 'no placeholders left'
[[ $(<$fake/prompt) != *'Additional instructions'* ]] \
  && pass 'no instructions section when unset' || fail 'no instructions section when unset'

AI_CMD_MODEL=opus AI_CMD_INSTRUCTIONS='Use bat instead of cat.' _ai_cmd_generate 'show file'; rc=$?
contains 'AI_CMD_MODEL' $fake/model 'opus'
contains 'AI_CMD_INSTRUCTIONS' $fake/prompt $'keep the reply format above:\nUse bat instead of cat.'

claude_out 'lsof -ti :3000 | xargs kill' 'This stops the server.'
_ai_cmd_generate 'stop port 3000'; rc=$?
check "model's warning is kept" 0 'lsof -ti :3000 | xargs kill' 'This stops the server.'

claude_out 'rm -r build' ''
_ai_cmd_generate 'delete build'; rc=$?
check 'local warning when the model gave none' 0 'rm -r build' 'This command may delete, overwrite or stop something; check it before running.'

claude_out '  git status  ' ''
_ai_cmd_generate 'status'; rc=$?
check 'spaces trimmed' 0 'git status' ''

claude_out '' 'A shell command cannot book a flight.'
_ai_cmd_generate 'book a flight'; rc=$?
check 'explanation instead of a command' 1 '' 'ai: A shell command cannot book a flight.'

claude_out $'cd /tmp\nls' ''
_ai_cmd_generate 'two lines'; rc=$?
check 'several lines rejected' 1 '' 'ai: expected one command line, got several; not inserting:'

FAKE_OUT='{"is_error":true,"result":"Invalid API key"}'
_ai_cmd_generate 'x'; rc=$?
check 'is_error' 1 '' 'ai: claude failed (exit 0): Invalid API key'

FAKE_OUT='x'; FAKE_RC=130
_ai_cmd_generate 'x'; rc=$?
check 'Ctrl-C (exit 130)' 1 '' 'ai: cancelled'

FAKE_OUT='Not logged in'; FAKE_RC=1
_ai_cmd_generate 'x'; rc=$?
check 'plain-text CLI error' 1 '' 'ai: claude failed (exit 1): Not logged in'

FAKE_ERR=$'warning: one\nwarning: two'
_ai_cmd_generate 'x'; rc=$?
[[ $#reply == 3 && $reply[2] == 'warning: one' && $reply[3] == 'warning: two' ]] \
  && pass 'stderr lines become error lines' || fail 'stderr lines become error lines' "got: ${(qq)reply}"
FAKE_ERR=

FAKE_OUT=$'Not logged in\e[31m'
_ai_cmd_generate 'x'; rc=$?
check 'escape sequence in an error is replaced' 1 '' 'ai: claude failed (exit 1): Not logged in [31m'
FAKE_RC=0

print '\n# control characters'
claude_out $'ls \e[2K' ''
_ai_cmd_generate 'x'; rc=$?
check 'escape in the command: rejected' 1 '' 'ai: the command contains control characters; not inserting:'
[[ $reply[2] == $'ls \ufffd[2K' ]] && pass 'rejected command shown without the escape' \
  || fail 'rejected command shown without the escape' "got: ${(q+)reply[2]}"

claude_out $'rm -rf ~/x\rls' ''
_ai_cmd_generate 'x'; rc=$?
check 'carriage return in the command: rejected' 1 '' 'ai: the command contains control characters; not inserting:'

FAKE_OUT='{"is_error":false,"result":"","structured_output":{"command":"ls\u0000rm x","message":""}}'
_ai_cmd_generate 'x'; rc=$?
check 'NUL in the command: rejected' 1 '' 'ai: the command contains control characters; not inserting:'

claude_out $'printf "a\tb"' ''
_ai_cmd_generate 'x'; rc=$?
check 'tab in the command: allowed' 0 $'printf "a\tb"' ''

claude_out 'ls' $'Careful\e]52;c;ZXZpbA==\a now\u009b2J'
_ai_cmd_generate 'x'; rc=$?
check 'escapes in the warning are replaced' 0 'ls' 'Careful ]52;c;ZXZpbA==  now 2J'

claude_out 'ls' ''; FAKE_SLEEP=3
integer start=$SECONDS
AI_CMD_TIMEOUT=1 _ai_cmd_generate 'slow'; rc=$?
check 'timeout' 1 '' 'ai: no reply from claude within 1s (AI_CMD_TIMEOUT)'
(( SECONDS - start < 3 )) && pass 'timeout stops waiting' || fail 'timeout stops waiting' "took $(( SECONDS - start ))s"
FAKE_SLEEP=1
AI_CMD_TIMEOUT=0 _ai_cmd_generate 'slow'; rc=$?
check 'AI_CMD_TIMEOUT=0 waits' 0 'ls' ''
AI_CMD_TIMEOUT=3 _ai_cmd_generate 'slow'; rc=$?
check 'reply within the timeout' 0 'ls' ''
FAKE_SLEEP=

AI_CMD_TIMEOUT=5s _ai_cmd_generate 'x'; rc=$?
check 'invalid AI_CMD_TIMEOUT' 1 '' "ai: AI_CMD_TIMEOUT must be a whole number of seconds (0 for no limit), not '5s'"

cd $fake
claude_out 'ls' ''
_ai_cmd_generate 'x'; rc=$?
contains 'outside a git repository' $fake/prompt "Working directory: $fake (not a git repository)."
cd $repo

AI_CMD_BACKEND=gemini _ai_cmd_generate 'x'; rc=$?
check 'unknown backend' 1 '' "ai: unknown AI_CMD_BACKEND 'gemini' (use claude or openai)"

print '\n# openai backend'
export AI_CMD_BACKEND=openai

_ai_cmd_generate 'x'; rc=$?
check 'model required' 1 '' 'ai: set AI_CMD_MODEL to the model to use, e.g. AI_CMD_MODEL=llama3.2'

export AI_CMD_MODEL=llama3.2
openai_body '{"command":"ls -la","message":""}'; FAKE_CODE=200 FAKE_RC=0
_ai_cmd_generate 'list files'; rc=$?
check 'command' 0 'ls -la' ''
contains 'default URL is Ollama' $fake/url 'http://localhost:11434/v1/chat/completions'
[[ $(jq -r .model $fake/request) == llama3.2 ]] && pass 'request model' || fail 'request model'
[[ $(jq -r '.messages[1].content' $fake/request) == 'list files' ]] && pass 'request: user message' || fail 'request: user message'
[[ $(jq -r '.messages[0].content' $fake/request) == *"Working directory: $repo"* ]] \
  && pass 'request: system prompt' || fail 'request: system prompt'
[[ $(jq -r '.response_format.json_schema.schema.required | join(",")' $fake/request) == command,message ]] \
  && pass 'request: JSON schema' || fail 'request: JSON schema'
[[ $(jq -r .stream $fake/request) == false ]] && pass 'request: no streaming' || fail 'request: no streaming'
contains 'default timeout' $fake/max-time '60'
[[ -z $(<$fake/config) ]] && pass 'no auth header without a key' || fail 'no auth header without a key' "$(<$fake/config)"

AI_CMD_URL=https://example.com/api/v1/ AI_CMD_API_KEY=sk-test _ai_cmd_generate 'x'; rc=$?
contains 'AI_CMD_URL, trailing slash dropped' $fake/url 'https://example.com/api/v1/chat/completions'
contains 'AI_CMD_API_KEY as a bearer token' $fake/config 'header = "Authorization: Bearer sk-test"'

openai_body $'<think>\nThe user wants files.\n</think>\n```json\n{"command": "ls", "message": ""}\n```'
_ai_cmd_generate 'x'; rc=$?
check 'think block and code fence stripped' 0 'ls' ''

openai_body $'Thinking it over without an opening tag.\n</think>\n{"command": "ls", "message": ""}'
_ai_cmd_generate 'x'; rc=$?
check 'think block without an opening tag' 0 'ls' ''

openai_body 'Here is the command: {"command": "echo {}", "message": ""} Hope it helps!'
_ai_cmd_generate 'x'; rc=$?
check 'JSON inside a sentence, braces in the command' 0 'echo {}' ''

openai_body 'ls -la'
_ai_cmd_generate 'x'; rc=$?
check 'reply that is not JSON' 1 '' "ai: the model didn't reply with the expected JSON:"

openai_body '"ls"'
_ai_cmd_generate 'x'; rc=$?
check 'JSON that is not an object' 1 '' "ai: the model didn't reply with the expected JSON:"

FAKE_BODY='{"choices":[]}'
_ai_cmd_generate 'x'; rc=$?
check 'no choices' 1 '' "ai: the model didn't reply with the expected JSON:"

FAKE_BODY='{"error":"model \"llama9\" not found, try pulling it first"}' FAKE_CODE=404
_ai_cmd_generate 'x'; rc=$?
check 'Ollama-style HTTP error' 1 '' 'ai: http://localhost:11434/v1 answered HTTP 404: model "llama9" not found, try pulling it first'

FAKE_BODY='{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}' FAKE_CODE=401
_ai_cmd_generate 'x'; rc=$?
check 'OpenAI-style HTTP error' 1 '' 'ai: http://localhost:11434/v1 answered HTTP 401: Incorrect API key provided'

FAKE_BODY='{"error":"bad\u001b[2Jthing"}' FAKE_CODE=500
_ai_cmd_generate 'x'; rc=$?
check 'escape in a server error is replaced' 1 '' 'ai: http://localhost:11434/v1 answered HTTP 500: bad [2Jthing'

FAKE_BODY='Bad Gateway' FAKE_CODE=502
_ai_cmd_generate 'x'; rc=$?
check 'HTTP error that is not JSON' 1 '' 'ai: http://localhost:11434/v1 answered HTTP 502: Bad Gateway'

rm -f $fake/max-time
AI_CMD_TIMEOUT=0 _ai_cmd_generate 'x'; rc=$?
[[ ! -e $fake/max-time ]] && pass 'AI_CMD_TIMEOUT=0: no --max-time' || fail 'AI_CMD_TIMEOUT=0: no --max-time'

FAKE_BODY= FAKE_CODE=000 FAKE_RC=28
AI_CMD_TIMEOUT=7 _ai_cmd_generate 'x'; rc=$?
check 'timeout' 1 '' 'ai: no reply from http://localhost:11434/v1 within 7s (AI_CMD_TIMEOUT); loading a model the first time can take longer'

FAKE_BODY= FAKE_CODE=000 FAKE_RC=130
_ai_cmd_generate 'x'; rc=$?
check 'Ctrl-C (exit 130)' 1 '' 'ai: cancelled'

FAKE_BODY= FAKE_CODE=000 FAKE_RC=7
_ai_cmd_generate 'x'; rc=$?
check 'server not running' 1 '' "ai: can't reach http://localhost:11434/v1; is the server running? (Ollama: ollama serve)"
FAKE_RC=0 FAKE_CODE=200

unset AI_CMD_BACKEND AI_CMD_MODEL

print '\n# risky-command check'
local -a risky=(
  'rm -rf build'
  'sudo rm /etc/hosts.bak'
  '/bin/rm notes.txt'
  'find . -name "*.tmp" -delete'
  'find . -name "*.tmp" -exec rm {} +'
  'lsof -ti :3000 | xargs kill'
  'kill -9 1234'
  'pkill -f node'
  'git reset --hard HEAD~1'
  'git clean -fd'
  'git push --force origin main'
  'git push -f origin main'
  'git branch -D old'
  'docker system prune -a'
  'docker rm -f web'
  'kubectl delete pod web'
  "sed -i '' 's/a/b/' file.txt"
  'echo hello > out.txt'
  'sort names.txt >| names.txt'
  'make 2> errors.log'
  'dd if=/dev/zero of=disk.img bs=1m count=10'
  'crontab -r'
  'cd build && rm -r cache'
  'echo $(rm x)'
)
local -a safe=(
  'ls -la'
  'find . -name "*.log"'
  'grep -r kill .'
  'ps aux | grep killall'
  'echo "rm -rf is dangerous"'
  'echo hello >> log.txt'
  'ls missing 2>/dev/null'
  'make >/dev/null 2>&1'
  'make 2>&1 | less'
  'echo oops >&2'
  'git push origin main'
  'git status'
  'docker ps'
  "sed 's/a/b/' file.txt"
  'du -sh * | sort -rh'
  'lsof -nP -iTCP:3000 -sTCP:LISTEN'
  'firmware-info --all'
)
local c
for c in $risky; do
  _ai_cmd_risky $c && pass "risky: $c" || fail "risky: $c" 'not flagged'
done
for c in $safe; do
  _ai_cmd_risky $c && fail "safe: $c" 'flagged' || pass "safe: $c"
done

print '\n# interactive shell'
if (( ! $+commands[expect] )); then
  print 'skipped: expect is not installed'
else
  mkdir $fake/zdotdir
  cat > $fake/zdotdir/.zshrc <<EOF
unset AI_CMD_BACKEND AI_CMD_MODEL AI_CMD_URL AI_CMD_API_KEY AI_CMD_INSTRUCTIONS AI_CMD_TIMEOUT AI_CMD_KEY
path=(${(q)fake}/bin \$path)
source ${(q)repo}/ai.plugin.zsh
PROMPT='P> '
EOF
  # interactive.exp prints "ok <name>" or "FAIL <name>" per check.
  local line
  FAKE_OUT= FAKE_RC=0 FAKE_SLEEP= ZDOTDIR=$fake/zdotdir expect -f $repo/tests/interactive.exp 2>&1 |
    while IFS= read -r line; do
      case $line in
        ok\ *) pass ${line#ok } ;;
        FAIL\ *) fail ${line#FAIL } ;;
        *) fail "unexpected output from interactive.exp" $line ;;
      esac
    done
fi

print
if (( failures )); then
  print "$failures failed"
  exit 1
fi
print 'all passed'
