# ai-widget — type a request on the command line, press a key, and it becomes a shell command.
#
#   find files > 100MB modified this week, largest first      press Ctrl-X Ctrl-A
#   find . -type f -size +100M -mtime -7 -exec stat … | sort -rn   edit or hit Enter
#
# The shell never parses the request, so > < | & ; # $ ` " { } and apostrophes need no quoting.
# Undo (Ctrl-_ in emacs mode) brings the request back.
#
# Source from ~/.zshrc instead of ai.zsh; it loads ai.zsh, so the `ai` command keeps working:
#   source ~/workspace/personal/scripts/ai-widget.zsh
#
# Config (env vars, set before the source line):
#   AI_CMD_KEY     key bound in the emacs and viins keymaps (default: ^X^A, i.e. Ctrl-X Ctrl-A)
#   AI_CMD_MODEL   see ai.zsh

source ${${(%):-%x}:A:h}/ai.zsh

: ${AI_CMD_KEY:='^X^A'}

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

zle -N ai-generate _ai_widget
bindkey -M emacs "$AI_CMD_KEY" ai-generate
bindkey -M viins "$AI_CMD_KEY" ai-generate
