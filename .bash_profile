#
# ~/.bash_profile
#


[[ -f ~/.bashrc ]] && . ~/.bashrc
+
export HISTCONTROL=ignoredups:erasedups  # no duplicate entries
shopt -s histappend                      # append to history, don't overwrite it

# Save and reload the history after each command finishes
export PROMPT_COMMAND="history -a; history -c; history -r; $PROMPT_COMMAND"
