#!/bin/zsh
# WHAT: The way in for anyone new to AII: double-click it in Finder. It opens the aii studio for
#       this checkout — building aii the first time — to manage this Mac's Ambient Intelligence
#       Index: whose build is installed, the two servers, the lanes, the models, the doctor.
# PIN:  Finder starts it in $HOME, so it moves to the checkout first. When the build or the
#       studio fails, the window stays open with the exit code until a key is pressed.

set -u

pause_on_failure() {
    local exit_status=$?
    if (( exit_status != 0 )); then
        print
        print -u2 "aii stopped with exit code $exit_status."
        print -n "Press any key to close this window…"
        read -k 1 || true
        print
    fi
    return "$exit_status"
}
trap pause_on_failure EXIT

cd "${0:A:h}/.." || exit 1
clear
./Scripts/cli.sh
