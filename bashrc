# ~/.bashrc: executed by bash(1) for non-login shells.
# dind-env-bashrc

# If not running interactively, don't do anything
case $- in
    *i*) ;;
      *) return;;
esac

# don't put duplicate lines or lines starting with space in the history
HISTCONTROL=ignoreboth

# append to the history file, don't overwrite it
shopt -s histappend

# for setting history length see HISTSIZE and HISTFILESIZE in bash(1)
HISTSIZE=1000
HISTFILESIZE=2000

# check the window size after each command
shopt -s checkwinsize

# If set, the pattern "**" used in a pathname expansion context will
# match all files and zero or more directories and subdirectories.
#shopt -s globstar

# make less more friendly for non-text input files
[ -x /usr/bin/lesspipe ] && eval "$(SHELL=/bin/sh lesspipe)"

# set variable identifying the chroot you work in (used in the prompt below)
if [ -z "${debian_chroot:-}" ] && [ -r /etc/debian_chroot ]; then
    debian_chroot=$(cat /etc/debian_chroot)
fi

# set a fancy prompt (non-color, unless we know we "want" color)
case "$TERM" in
    xterm-color|*-256color) color_prompt=yes;;
esac

force_color_prompt=yes

if [ -n "$force_color_prompt" ]; then
    if [ -x /usr/bin/tput ] && tput setaf 1 >&/dev/null; then
	color_prompt=yes
    else
	color_prompt=
    fi
fi

# "(name)" from DIND_ENVIRONMENT_NAME, nothing when it is unset or empty.
# `sudo -i` and `su -` give root a clean environment: the entrypoint keeps a
# copy of the name in /etc/dind-environment-name for those shells.
__dind_env_name() {
    local name="${DIND_ENVIRONMENT_NAME:-}"
    if [ -z "$name" ] && [ -r /etc/dind-environment-name ]; then
        read -r name </etc/dind-environment-name 2>/dev/null || true
    fi
    [ -n "$name" ] && printf '(%s)' "$name"
    return 0
}

# "(branch)" of the git repository around $PWD, or "(abc1234)" on a detached
# HEAD. It reads .git/HEAD instead of running git: the prompt shows up in
# repositories owned by someone else (root inside alpine's checkout, where git
# refuses with "dubious ownership"), and it must never run a repository's own
# configuration (core.fsmonitor) as root.
__dind_git_branch() {
    local dir="$PWD" git head ref
    while :; do
        if [ -e "$dir/.git" ]; then
            git="$dir/.git"
            break
        fi
        [ -n "$dir" ] || return 0
        dir="${dir%/*}"
    done
    # A worktree or submodule has a .git file pointing at the real directory.
    if [ -f "$git" ]; then
        read -r head <"$git" 2>/dev/null || return 0
        git="${head#gitdir: }"
        case "$git" in /*) ;; *) git="$dir/$git" ;; esac
    fi
    read -r head <"$git/HEAD" 2>/dev/null || return 0
    case "$head" in
        "ref: refs/heads/"*) ref="${head#ref: refs/heads/}" ;;
        "ref: "*) ref="${head#ref: }" ;;
        *) ref="${head:0:7}" ;;
    esac
    [ -n "$ref" ] && printf '(%s)' "$ref"
    return 0
}

# user@host in green (red for root), (DIND_ENVIRONMENT_NAME) in yellow,
# (git branch) in cyan, then the directory in blue.
if [ "$color_prompt" = yes ]; then
    if [ "$(id -u)" -eq 0 ]; then
        __dind_user_color='\[\033[01;31m\]'
    else
        __dind_user_color='\[\033[01;32m\]'
    fi
    PS1='${debian_chroot:+($debian_chroot)}'"$__dind_user_color"'\u@\h\[\033[00m\]\[\033[01;33m\]$(__dind_env_name)\[\033[00m\]\[\033[01;36m\]$(__dind_git_branch)\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '
    unset __dind_user_color
else
    PS1='${debian_chroot:+($debian_chroot)}\u@\h$(__dind_env_name)$(__dind_git_branch):\w\$ '
fi
unset color_prompt force_color_prompt

# If this is an xterm set the title to user@host:dir
case "$TERM" in
xterm*|rxvt*)
    PS1="\[\e]0;${debian_chroot:+($debian_chroot)}\u@\h: \w\a\]$PS1"
    ;;
*)
    ;;
esac

# enable color support of ls and also add handy aliases
if [ -x /usr/bin/dircolors ]; then
    test -r ~/.dircolors && eval "$(dircolors -b ~/.dircolors)" || eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
else
    alias ls='ls --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

# Alias definitions.
# You may want to put all your additions into a separate file like
# ~/.bash_aliases, instead of adding them here directly.
if [ -f ~/.bash_aliases ]; then
    . ~/.bash_aliases
fi

# enable programmable completion features
if ! shopt -oq posix; then
  if [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  elif [ -f /etc/bash_completion ]; then
    . /etc/bash_completion
  fi
fi

# user tool dirs (go install, cargo install, pip install --user, ~/bin),
# each added once however deep shells nest
for dir in "$HOME/go/bin" "$HOME/.cargo/bin" "$HOME/bin" "$HOME/.local/bin"; do
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) PATH="$dir:$PATH" ;;
    esac
done
unset dir
export PATH

export TZ="${TZ:-Europe/Rome}"
export LANG="${LANG:-it_IT.UTF-8}"
export LC_ALL="${LC_ALL:-it_IT.UTF-8}"
export LANGUAGE="${LANGUAGE:-it_IT:it}"

if command -v direnv >/dev/null 2>&1; then
    eval "$(direnv hook bash)"
fi
