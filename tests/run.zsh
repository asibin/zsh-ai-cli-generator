#!/usr/bin/env zsh
# Tests for ai.plugin.zsh. Fake claude and curl commands stand in for the real ones, so no
# model is called and nothing needs to be running.
#
#   tests/run.zsh

emulate -L zsh

repo=${0:A:h:h}
fake=$(mktemp -d "${TMPDIR:-/tmp}/ai-test.XXXXXX")
fake=${fake:A}   # $PWD has no // even when $TMPDIR ends in /
trap 'rm -rf -- $fake' EXIT
export FAKE=$fake

mkdir $fake/bin
# Records the model and system prompt, prints $FAKE_OUT, exits with $FAKE_RC.
cat > $fake/bin/claude <<'EOF'
#!/usr/bin/env zsh
while (( $# )); do
  case $1 in
    --model) print -r -- $2 > $FAKE/model; shift ;;
    --system-prompt) print -r -- $2 > $FAKE/prompt; shift ;;
  esac
  shift
done
print -r -- $FAKE_OUT
exit ${FAKE_RC:-0}
EOF
# Records the request, URL and config (stdin), writes $FAKE_BODY to the -o file, prints
# $FAKE_CODE as the HTTP status, exits with $FAKE_RC.
cat > $fake/bin/curl <<'EOF'
#!/usr/bin/env zsh
out=
while (( $# )); do
  case $1 in
    -o) out=$2; shift ;;
    --data-binary) cat ${2#@} > $FAKE/request; shift ;;
    -K) cat > $FAKE/config; shift ;;
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

# expect <name> <rc> <REPLY> <first reply line>: check the result of the last _ai_generate.
expect() {
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

export FAKE_OUT FAKE_RC FAKE_BODY FAKE_CODE
integer rc

print '# claude backend'
cd $repo
unset AI_CMD_BACKEND AI_CMD_MODEL AI_CMD_URL AI_CMD_API_KEY AI_CMD_INSTRUCTIONS

claude_out 'ls -la' ''; FAKE_RC=0
_ai_generate 'list files'; rc=$?
expect 'command' 0 'ls -la' ''
contains 'default model is sonnet' $fake/model 'sonnet'
contains 'prompt names the working directory' $fake/prompt "Working directory: $repo (a git repository)."
contains 'prompt names the OS' $fake/prompt 'Environment: '
[[ $(<$fake/prompt) != *__DIRECTORY__* && $(<$fake/prompt) != *__ENVIRONMENT__* ]] \
  && pass 'no placeholders left' || fail 'no placeholders left'
[[ $(<$fake/prompt) != *'Additional instructions'* ]] \
  && pass 'no instructions section when unset' || fail 'no instructions section when unset'

AI_CMD_MODEL=opus AI_CMD_INSTRUCTIONS='Use bat instead of cat.' _ai_generate 'show file'; rc=$?
contains 'AI_CMD_MODEL' $fake/model 'opus'
contains 'AI_CMD_INSTRUCTIONS' $fake/prompt $'keep the reply format above:\nUse bat instead of cat.'

claude_out 'lsof -ti :3000 | xargs kill' 'This stops the server.'
_ai_generate 'stop port 3000'; rc=$?
expect "model's warning is kept" 0 'lsof -ti :3000 | xargs kill' 'This stops the server.'

claude_out 'rm -r build' ''
_ai_generate 'delete build'; rc=$?
expect 'local warning when the model gave none' 0 'rm -r build' 'This command may delete, overwrite or stop something; check it before running.'

claude_out '  git status  ' ''
_ai_generate 'status'; rc=$?
expect 'spaces trimmed' 0 'git status' ''

claude_out '' 'A shell command cannot book a flight.'
_ai_generate 'book a flight'; rc=$?
expect 'explanation instead of a command' 1 '' 'ai: A shell command cannot book a flight.'

claude_out $'cd /tmp\nls' ''
_ai_generate 'two lines'; rc=$?
expect 'several lines rejected' 1 '' 'ai: expected one command line, got several; not inserting:'

FAKE_OUT='{"is_error":true,"result":"Invalid API key"}'
_ai_generate 'x'; rc=$?
expect 'is_error' 1 '' 'ai: claude failed (exit 0): Invalid API key'

FAKE_OUT='Not logged in'; FAKE_RC=1
_ai_generate 'x'; rc=$?
expect 'plain-text CLI error' 1 '' 'ai: claude failed (exit 1): Not logged in'
FAKE_RC=0

cd $fake
claude_out 'ls' ''
_ai_generate 'x'; rc=$?
contains 'outside a git repository' $fake/prompt "Working directory: $fake (not a git repository)."
cd $repo

AI_CMD_BACKEND=gemini _ai_generate 'x'; rc=$?
expect 'unknown backend' 1 '' "ai: unknown AI_CMD_BACKEND 'gemini' (use claude or openai)"

print '\n# openai backend'
export AI_CMD_BACKEND=openai

_ai_generate 'x'; rc=$?
expect 'model required' 1 '' 'ai: set AI_CMD_MODEL to the model to use, e.g. AI_CMD_MODEL=llama3.2'

export AI_CMD_MODEL=llama3.2
openai_body '{"command":"ls -la","message":""}'; FAKE_CODE=200 FAKE_RC=0
_ai_generate 'list files'; rc=$?
expect 'command' 0 'ls -la' ''
contains 'default URL is Ollama' $fake/url 'http://localhost:11434/v1/chat/completions'
[[ $(jq -r .model $fake/request) == llama3.2 ]] && pass 'request model' || fail 'request model'
[[ $(jq -r '.messages[1].content' $fake/request) == 'list files' ]] && pass 'request: user message' || fail 'request: user message'
[[ $(jq -r '.messages[0].content' $fake/request) == *"Working directory: $repo"* ]] \
  && pass 'request: system prompt' || fail 'request: system prompt'
[[ $(jq -r '.response_format.json_schema.schema.required | join(",")' $fake/request) == command,message ]] \
  && pass 'request: JSON schema' || fail 'request: JSON schema'
[[ $(jq -r .stream $fake/request) == false ]] && pass 'request: no streaming' || fail 'request: no streaming'
[[ -z $(<$fake/config) ]] && pass 'no auth header without a key' || fail 'no auth header without a key' "$(<$fake/config)"

AI_CMD_URL=https://example.com/api/v1/ AI_CMD_API_KEY=sk-test _ai_generate 'x'; rc=$?
contains 'AI_CMD_URL, trailing slash dropped' $fake/url 'https://example.com/api/v1/chat/completions'
contains 'AI_CMD_API_KEY as a bearer token' $fake/config 'header = "Authorization: Bearer sk-test"'

openai_body $'<think>\nThe user wants files.\n</think>\n```json\n{"command": "ls", "message": ""}\n```'
_ai_generate 'x'; rc=$?
expect 'think block and code fence stripped' 0 'ls' ''

openai_body $'Thinking it over without an opening tag.\n</think>\n{"command": "ls", "message": ""}'
_ai_generate 'x'; rc=$?
expect 'think block without an opening tag' 0 'ls' ''

openai_body 'Here is the command: {"command": "echo {}", "message": ""} Hope it helps!'
_ai_generate 'x'; rc=$?
expect 'JSON inside a sentence, braces in the command' 0 'echo {}' ''

openai_body 'ls -la'
_ai_generate 'x'; rc=$?
expect 'reply that is not JSON' 1 '' "ai: the model didn't reply with the expected JSON:"

openai_body '"ls"'
_ai_generate 'x'; rc=$?
expect 'JSON that is not an object' 1 '' "ai: the model didn't reply with the expected JSON:"

FAKE_BODY='{"choices":[]}'
_ai_generate 'x'; rc=$?
expect 'no choices' 1 '' "ai: the model didn't reply with the expected JSON:"

FAKE_BODY='{"error":"model \"llama9\" not found, try pulling it first"}' FAKE_CODE=404
_ai_generate 'x'; rc=$?
expect 'Ollama-style HTTP error' 1 '' 'ai: http://localhost:11434/v1 answered HTTP 404: model "llama9" not found, try pulling it first'

FAKE_BODY='{"error":{"message":"Incorrect API key provided","type":"invalid_request_error"}}' FAKE_CODE=401
_ai_generate 'x'; rc=$?
expect 'OpenAI-style HTTP error' 1 '' 'ai: http://localhost:11434/v1 answered HTTP 401: Incorrect API key provided'

FAKE_BODY='Bad Gateway' FAKE_CODE=502
_ai_generate 'x'; rc=$?
expect 'HTTP error that is not JSON' 1 '' 'ai: http://localhost:11434/v1 answered HTTP 502: Bad Gateway'

FAKE_BODY= FAKE_CODE=000 FAKE_RC=7
_ai_generate 'x'; rc=$?
expect 'server not running' 1 '' "ai: can't reach http://localhost:11434/v1; is the server running? (Ollama: ollama serve)"
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
  _ai_risky $c && pass "risky: $c" || fail "risky: $c" 'not flagged'
done
for c in $safe; do
  _ai_risky $c && fail "safe: $c" 'flagged' || pass "safe: $c"
done

print
if (( failures )); then
  print "$failures failed"
  exit 1
fi
print 'all passed'
