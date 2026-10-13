#!/usr/bin/env zsh
# Re-record the README GIFs by driving a clean zsh through real requests:
#   docs/demo-widget.gif    type a request, press Ctrl-O
#   docs/demo-command.gif   the ai command, and what goes wrong without quotes
#
#   docs/record-demo.sh [widget] [command]    (default: both)
#
# Requires: asciinema, agg, expect, python3, and a logged-in claude CLI. Each run makes real
# claude calls, so the generated commands can differ from the last recording.

emulate -L zsh
setopt err_exit

repo=${0:A:h:h}
work=$(mktemp -d "${TMPDIR:-/tmp}/ai-demo.XXXXXX")
server_pid=

cleanup() {
  [[ -n $server_pid ]] && kill $server_pid 2>/dev/null
  pkill -f "$work" 2>/dev/null   # the recorder, if expect died before it finished
  rm -rf $work
}
trap cleanup EXIT

# A minimal shell: no personal config, a plain prompt, and the plugin.
mkdir -p $work/zdotdir
cat > $work/zdotdir/.zshrc <<EOF
source ${(q)repo}/ai.plugin.zsh
cd ${(q)work}/demo
EOF
cat >> $work/zdotdir/.zshrc <<'EOF'
PROMPT='%F{cyan}demo%f %F{magenta}❯%f '
setopt transient_rprompt   # drop the key badge from lines that have been run
RPROMPT=

# Tell expect when claude has answered: an invisible terminal-title change, which agg ignores.
functions[_ai_generate_real]=$functions[_ai_generate]
_ai_generate() { _ai_generate_real "$@"; local rc=$?; print -n $'\e]2;ai-done\a' >/dev/tty; return $rc }

# Show which key was pressed as a badge at the right end of the line. Clearing RPROMPT
# without a redraw leaves the badge on screen until the next redraw, and keeps the
# widget's messages below the line (a redraw would erase them).
_demo_badge() { RPROMPT="%K{magenta}%F{black} $1 %f%k"; zle reset-prompt; zle -R; RPROMPT=; }

zle -N ai-generate-real _ai_widget
_demo_ai() { _demo_badge Ctrl-O; zle ai-generate-real; }
_demo_enter() { _demo_badge Enter; sleep 0.6; zle accept-line; }
_demo_clear() { _demo_badge Ctrl-U; sleep 0.6; zle kill-whole-line; }
# Print the caption expect left in $ZDOTDIR/caption above the prompt as a gray "# …"
# comment, without typing it. zle -I leaves the empty prompt line behind; erase it first.
_demo_caption() {
  local line
  zle -I
  print -rn -- $'\e[1A\r\e[K'
  for line in "${(@f)$(<$ZDOTDIR/caption)}"; do
    print -r -- $'\e[90m# '"$line"$'\e[0m'
  done
}

zle -N demo-ai _demo_ai
zle -N demo-enter _demo_enter
zle -N demo-clear _demo_clear
zle -N demo-caption _demo_caption
bindkey '^O' demo-ai
bindkey '^M' demo-enter
bindkey '^U' demo-clear
bindkey '^G' demo-caption

# expect ends the recording by killing this shell, so no "exit" line lands in the GIF.
print $$ > $ZDOTDIR/pid
EOF

# Steps shared by both recordings.
cat > $work/prelude.exp <<'EOF'
set cast [lindex $argv 0]
set timeout 60
set send_human {.05 .1 1 .03 .2}

spawn asciinema rec -q --overwrite --window-size 86x20 --command "zsh -i" $cast
expect "❯"   ;# no trailing space: a color code sits between it and the space
sleep 0.4

# Wait until the shell has been quiet for a moment.
proc settle {} {
  expect -timeout 1 -re {.+} { exp_continue } timeout {}
}

# Widget: type a request, press Ctrl-O, wait for claude's answer, leave time to read it.
proc ask {request} {
  send -h -- $request
  sleep 0.8
  send "\x0f"
  expect "ai-done"
  settle
  sleep 2.5
}

# Command: type `ai <request>`, press Enter, wait for the command on the next prompt.
proc ai {request} {
  send -h -- "ai $request"
  sleep 0.8
  send "\r"
  expect "ai-done"
  settle
  sleep 2.5
}

# Type a plain command line.
proc type {line} {
  send -h -- $line
  sleep 0.5
}

proc run {} {
  send "\r"
  sleep 0.5
  settle
  sleep 2.5
}

proc clear_line {} {
  send "\x15"
  sleep 0.6
  settle
}

proc caption {text} {
  set f [open $::env(ZDOTDIR)/caption w]
  puts -nonewline $f $text
  close $f
  send "\x07"
  settle
  sleep 1.5
}

proc new_screen {} {
  send "\x0c"
  settle
}

proc finish {} {
  sleep 2
  exec kill -KILL [exec cat $::env(ZDOTDIR)/pid]
  expect eof
}
EOF

# Fresh demo folder and port-3000 server for each recording (named by $1).
setup_demo() {
  rm -rf $work/demo
  mkdir -p $work/demo
  # Files of different sizes to search.
  dd if=/dev/urandom of=$work/demo/backup.tar bs=1m count=6 2>/dev/null
  dd if=/dev/urandom of=$work/demo/video.mov bs=1m count=4 2>/dev/null
  dd if=/dev/urandom of=$work/demo/photo.jpg bs=1m count=2 2>/dev/null
  print 'buy milk' > $work/demo/notes.txt
  # Small files with repeated extensions, for the widget demo to count by extension.
  # The command demo lists the folder, so it stays short there to fit on one screen.
  local f
  if [[ $1 == widget ]]; then
    for f in app.log error.log access.log debug.log todo.txt readme.txt config.json package.json; do
      print x > $work/demo/$f
    done
  fi
  # Something listening on port 3000 to find and stop.
  python3 -m http.server 3000 >/dev/null 2>&1 &
  server_pid=$!
  sleep 0.5
}

stop_server() {
  [[ -n $server_pid ]] && kill $server_pid 2>/dev/null
  server_pid=
}

# record <name>: run the prelude plus the steps on stdin, write docs/demo-<name>.gif.
record() {
  local name=$1 cast=$work/$1.cast
  cat $work/prelude.exp - > $work/$name.exp
  setup_demo $name
  ZDOTDIR=$work/zdotdir TERM=xterm-256color expect -f $work/$name.exp $cast
  stop_server
  agg --theme github-dark --font-size 18 --idle-time-limit 2.5 $cast $repo/docs/demo-$name.gif
  print "wrote $repo/docs/demo-$name.gif"
}

(( $# )) || set -- widget command

for target; do
  case $target in
    widget) record widget <<'EOF'
ask {list files > 1MB here}
run
ask {count files by extension, most common first}
run
ask {what's listening on port 3000?}
run
ask {stop whatever is on port 3000}
run
ask {book me a flight to paris}
clear_line
finish
EOF
    ;;
    command) record command <<'EOF'
caption {ai <request> puts a command on your next prompt. Nothing runs until Enter.}
ai {find the 3 largest files here}
run

new_screen
caption {Pitfall: an unquoted > is a redirect, not part of the request.}
ai {list files > 1MB here}
run
caption {ai only got "list files here", so it listed everything,
and zsh created the empty file 1MB.}
caption {Fix: quote the request.}
ai {'list files > 1MB here'}
run

new_screen
caption {Pitfall: an apostrophe opens a quote, so zsh waits for the closing one.}
type {ai what's listening on port 3000?}
send "\r"
sleep 2.5
caption {Press Ctrl-C to get out.}
send "\x03"
settle
sleep 1
caption {Fix: use double quotes.}
ai {"what's listening on port 3000?"}
run
finish
EOF
    ;;
    *) print -u2 "usage: $0 [widget] [command]"; exit 2 ;;
  esac
done
