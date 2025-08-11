if [ -f /etc/bashrc ]; then
    . /etc/bashrc
fi

export PS1='\[\033[38;5;1m\]\u\[\033[38;5;11m\]\[$(tput sgr0)\]\[\033[38;5;33m\][\[$(tput sgr0)\]\[\033[38;5;39m\]\w\[$(tput sgr0)\]\[\033[38;5;33m\]]\[$(tput sgr0)\]\[\033[38;5;15m\]($?)\\$ \[$(tput sgr0)\]'

export LS_COLORS=$LS_COLORS:'ow=1;34:'

source "$HOME/.cargo/env"
export CARGO_INCREMENTAL=1
export BAT_THEME=monokai-extended

alias nv=nvim
alias vim=nvim
