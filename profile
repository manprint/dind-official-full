# ~/.profile: executed by the command interpreter for login shells.
# dind-env-profile

if [ -n "$BASH_VERSION" ]; then
    if [ -f "$HOME/.bashrc" ]; then
        . "$HOME/.bashrc"
    fi
fi

# user tool dirs (go install, cargo install, pip install --user, ~/bin),
# each added once however deep login shells nest
for dir in "$HOME/go/bin" "$HOME/.cargo/bin" "$HOME/bin" "$HOME/.local/bin"; do
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) PATH="$dir:$PATH" ;;
    esac
done
unset dir
export PATH
