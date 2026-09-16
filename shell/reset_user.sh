#!/usr/bin/env bash
# reset_user.sh — put a user's home directory back to a fresh account's, keeping .ssh.
#
#   bash reset_user.sh          # dry run (default): what goes, what stays, sizes — changes nothing
#   bash reset_user.sh --yes    # do it (asks you to type the user name when run in a terminal)
#
# Deletes everything directly inside the home except the KEEP entries, then copies the
# fresh-account dotfiles back from /etc/skel (.bashrc, .profile, .bash_logout), owned by the
# user, and sets the login shell. IRREVERSIBLE.
#
# Only the home directory is touched. /data/people/<user>, their crontab and lingering
# services stay as they are — the run lists them at the end so you can decide.
#
# Refuses — before changing anything — root and system accounts (uid below MIN_UID), the
# admin running it, a home outside /home or that is a symlink, a home not owned by the user,
# anything mounted inside the home, and a user with running processes (logged in, jobs,
# tmux / zellij sessions: log them out first).
set -euo pipefail

# ---- settings -----------------------------------------------------------------------------
U=mavischan                 # the user to reset
KEEP=".ssh"                 # entries directly inside the home to keep, space-separated names
SKEL=/etc/skel              # fresh-account dotfiles to restore
LOGIN_SHELL=/bin/bash       # login shell to set; empty = leave it as it is
MIN_UID=1000                # never touch accounts below this uid
# -------------------------------------------------------------------------------------------

YES=0
case "${1:-}" in
    --yes) YES=1 ;;
    --dry-run | "") ;;
    *) echo "usage: $0 [--dry-run | --yes]" >&2; exit 2 ;;
esac

say() { printf '%s\n' "$*"; }
abort() { say "ABORT: $*"; exit 1; }
as_root() { if [[ "$(id -u)" == 0 ]]; then "$@"; else sudo -n "$@"; fi; }

# work from / — not from wherever it was started, which could even be inside the home
cd /

# ---- who and where ------------------------------------------------------------------------
entry="$(getent passwd "$U")" || abort "no user $U"
IFS=: read -r _ _ uid gid _ home shell <<<"$entry"
me="${SUDO_USER:-$(id -un)}"

[[ "$U" != root && "$uid" != 0 ]] || abort "refusing to reset root"
((uid >= MIN_UID)) || abort "$U is a system account (uid $uid < $MIN_UID)"
[[ "$U" != "$me" ]] || abort "refusing to reset the account running this ($me)"
[[ "$home" == /home/?* && "$home" != */.* && "$home" != */ ]] || abort "home $home isn't a plain /home/<name> path"
as_root test -d "$home" || abort "home $home doesn't exist"
! as_root test -L "$home" || abort "home $home is a symlink"
[[ "$(as_root realpath -e -- "$home")" == "$home" ]] || abort "home $home resolves elsewhere"
[[ "$(as_root stat -c %u -- "$home")" == "$uid" ]] || abort "home $home isn't owned by $U (uid $uid)"
mounted="$(findmnt -rno TARGET 2>/dev/null | awk -v h="$home/" 'index($0, h) == 1' || true)"
[[ -z "$mounted" ]] || abort "something is mounted inside the home: $(tr '\n' ' ' <<<"$mounted")"
if pgrep -u "$uid" >/dev/null 2>&1; then
    abort "$U has running processes — log them out first: $(ps -o pid=,comm= -u "$uid" 2>/dev/null | head -n 5 | tr '\n' ';')"
fi
for k in $KEEP; do
    [[ "$k" != */* && "$k" != . && "$k" != .. ]] || abort "KEEP entry '$k' must be a plain name"
done
as_root test -d "$SKEL" || abort "no skel directory $SKEL"
if [[ -n "$LOGIN_SHELL" ]]; then
    grep -qx -- "$LOGIN_SHELL" /etc/shells || abort "$LOGIN_SHELL isn't listed in /etc/shells"
fi

kept() { local k; for k in $KEEP; do [[ "$1" == "$k" ]] && return 0; done; return 1; }

# ---- what would happen --------------------------------------------------------------------
say "user     $U (uid $uid), home $home"
mapfile -t entries < <(as_root find "$home" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort)
deleting=()
for name in "${entries[@]}"; do
    size="$(as_root du -sh --one-file-system -- "$home/$name" 2>/dev/null | cut -f1)"
    if kept "$name"; then
        say "  keep     $name ($size)"
    else
        say "  delete   $name ($size)"
        deleting+=("$name")
    fi
done
((${#entries[@]})) || say "  (home is empty)"
say "  restore  $(as_root find "$SKEL" -mindepth 1 -maxdepth 1 -printf '%f ' ) from $SKEL"
if [[ -n "$LOGIN_SHELL" && "$shell" != "$LOGIN_SHELL" ]]; then
    say "  shell    $shell → $LOGIN_SHELL"
fi
say "outside the home — not touched, for you to decide:"
say "  data     $(as_root test -d "/data/people/$U" && as_root du -sh "/data/people/$U" 2>/dev/null | cut -f1 || echo none) (/data/people/$U)"
say "  crontab  $(as_root crontab -u "$U" -l >/dev/null 2>&1 && echo yes || echo none)"
say "  linger   $(as_root test -e "/var/lib/systemd/linger/$U" && echo 'yes (user services keep running)' || echo no)"

if ((!YES)); then
    say "dry run — nothing changed. Re-run with --yes to reset."
    exit 0
fi

# ---- do it --------------------------------------------------------------------------------
if [[ -t 0 ]]; then
    read -r -p "This deletes ${#deleting[@]} entries in $home for good. Type the user name to confirm: " answer
    [[ "$answer" == "$U" ]] || abort "confirmation didn't match — nothing changed"
fi

# 1. stage the fresh dotfiles inside the home (same filesystem), owned by the user — if any
#    of that fails, nothing has been deleted yet
stage="$(as_root mktemp -d "$home/.reset-staging.XXXXXX")"
stage_skel() {
    local name
    while IFS= read -r name; do
        kept "$name" && continue
        as_root cp -rP --preserve=mode,timestamps -- "$SKEL/$name" "$stage/" || return 1
        as_root chown -R -- "$uid:$gid" "$stage/$name" || return 1
    done < <(as_root find "$SKEL" -mindepth 1 -maxdepth 1 -printf '%f\n')
}
if ! stage_skel; then
    as_root rm -rf -- "$stage"
    abort "couldn't prepare the fresh dotfiles — nothing was deleted"
fi

# 2. the irreversible part: everything listed above, except the kept entries (the stage
#    was created after the listing, so it isn't among them)
for name in "${deleting[@]}"; do
    as_root rm -rf --one-file-system -- "${home:?}/$name"
done

# 3. the staged dotfiles into place
while IFS= read -r name; do
    as_root mv -- "$stage/$name" "$home/"
done < <(as_root find "$stage" -mindepth 1 -maxdepth 1 -printf '%f\n')
as_root rmdir -- "$stage"
if [[ -n "$LOGIN_SHELL" && "$shell" != "$LOGIN_SHELL" ]]; then
    as_root usermod -s "$LOGIN_SHELL" "$U"
fi

say "DONE: $home now holds: $(as_root find "$home" -mindepth 1 -maxdepth 1 -printf '%f ')"
say "the user should run the quant setup again at their next login (quant-setup-machine)"
