#!/usr/bin/env bash
# migrate_venv.sh — rebuild one user's venv on another Python, keeping what it has.
#
#   bash migrate_venv.sh --dry-run    # preview: method, package count, import baseline
#   bash migrate_venv.sh              # do it
#
# Run as the admin; every change inside the project is made as the venv's owner.
#
# How it rebuilds:
#   - uv project (pyproject.toml + uv.lock next to the venv): `uv sync --frozen` from the
#     project's own lock, all extras and groups. Must end up with every package the old
#     venv had (a missing one means something was installed outside the lock).
#   - anything else (pip / requirements.txt venvs): the exact installed set, name==version,
#     reinstalled with --no-deps from wheels. That reproduces the venv as it is — including
#     any existing conflicts — rather than resolving it into something different. Packages
#     installed from git or a local path can't be reproduced: the script stops.
#
# How it checks, before deleting anything: the package set (above), and every third-party
# module the project's own code imports must import exactly as it did on the old venv
# (a module that already failed may still fail; one that worked must still work).
#
# Safety: nothing changes if a precondition fails (venv in use, missing Python, leftover
# backup, non-reproducible packages). Once it starts, the old venv is moved aside, and any
# failure deletes the new one and moves the old one back to the same path, intact.
set -euo pipefail

# ---- settings -----------------------------------------------------------------------------
U=mavischan                                  # the venv's owner
DIR=orchestrate                              # the project folder
PROJECT="/data/people/$U/repo/$DIR"          # project path (edit if it lives elsewhere)
VENV="$PROJECT/.venv"                        # the venv to rebuild
PY=/usr/local/bin/python3.13                 # the Python to rebuild on
MODULES=""                                   # modules to check; empty = found in the project's code
IMPORT_TIMEOUT=120                           # seconds per import check
# -------------------------------------------------------------------------------------------

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "") ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

BACKUP="$VENV.migration-backup"
WORK="$(mktemp -d)"
chmod 755 "$WORK"
trap 'rm -rf "$WORK"' EXIT

say() { printf '%s\n' "$*"; }
abort() { say "ABORT: $*"; exit 1; }

# Work from / rather than wherever the admin started it: sudo -u keeps the working
# directory, and the owner usually can't read the admin's folder — uv reads uv.toml from
# the working directory and stops on "Permission denied", and GNU find fails when it can't
# return to its starting directory.
cd /

# run as the owner, from inside the project (where uv finds the project's own config) —
# directly when that's who we already are
as_owner() {
    if [[ "$(id -un)" == "$U" ]]; then
        (cd "$PROJECT" && "$@")
    else
        sudo -n -u "$U" -H bash -c 'cd "$1" && shift && exec "$@"' _ "$PROJECT" "$@"
    fi
}
# read anywhere — root-owned homes and 0700 dirs need sudo unless we are root
as_admin() {
    if [[ "$(id -u)" == 0 || "$(id -un)" == "$U" ]]; then "$@"; else sudo -n "$@"; fi
}

freeze_of() { # <venv> → name==version per distribution, sorted; DIRECT_URL <name> for non-index installs
    as_admin find "$1/lib" -maxdepth 3 -name '*.dist-info' -type d 2>/dev/null | while read -r d; do
        name="$(as_admin sed -n 's/^Name: //p' "$d/METADATA" | head -n 1 | tr -d '\r')"
        version="$(as_admin sed -n 's/^Version: //p' "$d/METADATA" | head -n 1 | tr -d '\r')"
        if as_admin test -f "$d/direct_url.json"; then
            printf 'DIRECT_URL %s\n' "$name"
        else
            printf '%s==%s\n' "$name" "$version"
        fi
    done | sort -f
}

project_modules() { # third-party top-level modules the project's own code imports
    local py="$1"
    as_admin find "$PROJECT" -name '*.py' -not -path "$VENV/*" -not -path "$BACKUP/*" \
        -not -path '*/.git/*' -size -2M 2>/dev/null |
        as_admin xargs -r grep -hoE '^\s*(import|from)\s+[A-Za-z_][A-Za-z0-9_.]*' 2>/dev/null |
        sed -E 's/^\s*(import|from)\s+//; s/\..*//' | sort -u |
        as_owner "$py" -c '
import sys, pathlib
project, skip = pathlib.Path(sys.argv[1]), {pathlib.Path(a) for a in sys.argv[2:]}
def own(path):  # code of the project itself, not the venv, backup or git internals
    return not any(s == path or s in path.parents for s in skip) and ".git" not in path.parts
local = {p.name for p in project.rglob("*") if p.is_dir() and own(p) and (p / "__init__.py").exists()}
local |= {p.stem for p in project.rglob("*.py") if own(p)}
for name in sys.stdin.read().split():
    if name not in sys.stdlib_module_names and name not in local and name != "__future__":
        print(name)
' "$PROJECT" "$VENV" "$BACKUP"
}

imports_of() { # <venv python> → "module:ok|FAIL" per module, one per line
    local py="$1" m
    for m in $MODULES; do
        if as_owner timeout "$IMPORT_TIMEOUT" "$py" -W ignore -c "import $m" >/dev/null 2>&1; then
            say "$m:ok"
        else
            say "$m:FAIL"
        fi
    done
}

# ---- preconditions: nothing is touched if one fails ---------------------------------------
id "$U" >/dev/null 2>&1 || abort "no user $U"
as_admin test -f "$VENV/pyvenv.cfg" || abort "no venv at $VENV"
[[ -x "$PY" ]] || abort "no Python at $PY"
as_admin test ! -e "$BACKUP" || abort "$BACKUP exists — a previous run didn't finish; inspect it first"
if pgrep -f -- "$VENV/" >/dev/null; then abort "$VENV is in use: $(pgrep -af -- "$VENV/" | head -n 1)"; fi

old_version="$(as_admin sed -n 's/^version_info *= *//p' "$VENV/pyvenv.cfg" | head -n 1)"
new_version="$("$PY" -c 'import sys; print("%d.%d.%d" % sys.version_info[:3])')"
prompt="$(as_admin sed -n 's/^prompt *= *//p' "$VENV/pyvenv.cfg" | head -n 1)"
[[ "${old_version%.*}" != "${new_version%.*}" ]] || abort "$VENV is already on ${new_version%.*}"

freeze_of "$VENV" >"$WORK/old-freeze"
if as_admin test -f "$PROJECT/pyproject.toml" && as_admin test -f "$PROJECT/uv.lock"; then
    METHOD=uv-sync
else
    METHOD=exact-set
    if grep -q '^DIRECT_URL ' "$WORK/old-freeze"; then
        abort "installed from git / a local path, can't be reproduced: $(sed -n 's/^DIRECT_URL //p' "$WORK/old-freeze" | tr '\n' ' ')"
    fi
fi
# a uv project's own editable install is expected to differ; compare everything else
grep -v '^DIRECT_URL ' "$WORK/old-freeze" >"$WORK/old-set"

[[ -n "$MODULES" ]] || MODULES="$(project_modules "$VENV/bin/python" | tr '\n' ' ')"
imports_of "$VENV/bin/python" >"$WORK/old-imports"

say "venv      $VENV (owner $U)"
say "python    $old_version → $new_version ($PY)"
say "method    $METHOD"
say "packages  $(wc -l <"$WORK/old-set") ($(grep -c '^DIRECT_URL ' "$WORK/old-freeze" || true) editable / local)"
say "imports   $(tr '\n' ' ' <"$WORK/old-imports")"
if ((DRY_RUN)); then
    say "dry run — nothing changed"
    exit 0
fi

# ---- the rebuild: any failure from here puts the old venv back -----------------------------
restore() {
    say "FAILED: $1 — restoring the old venv"
    as_owner rm -rf "$VENV"
    as_owner mv "$BACKUP" "$VENV"
    if diff -q <(imports_of "$VENV/bin/python") "$WORK/old-imports" >/dev/null; then
        say "restored: $VENV on $old_version, imports as before"
    else
        say "restored $VENV, but its imports now differ from before — check by hand"
    fi
    exit 1
}

as_owner mv "$VENV" "$BACKUP"
say "old venv moved to $BACKUP"

if [[ "$METHOD" == uv-sync ]]; then
    as_owner env UV_PYTHON_DOWNLOADS=never UV_PROJECT_ENVIRONMENT="$VENV" /usr/local/bin/uv sync \
        --project "$PROJECT" --frozen --all-extras --all-groups --python "$PY" >"$WORK/log" 2>&1 ||
        restore "uv sync ($(tail -n 3 "$WORK/log" | tr '\n' ' '))"
    freeze_of "$VENV" | grep -v '^DIRECT_URL ' >"$WORK/new-set"
    missing="$(comm -23 <(sed 's/==.*//' "$WORK/old-set" | tr 'A-Z_.' 'a-z--' | sort -u) \
        <(sed 's/==.*//' "$WORK/new-set" | tr 'A-Z_.' 'a-z--' | sort -u) | tr '\n' ' ')"
    [[ -z "$missing" ]] || restore "the rebuild lacks: $missing"
else
    cp "$WORK/old-set" "$WORK/requirements.txt"
    chmod 644 "$WORK/requirements.txt"
    as_owner env UV_PYTHON_DOWNLOADS=never /usr/local/bin/uv venv --quiet --python "$PY" \
        ${prompt:+--prompt "$prompt"} "$VENV" >"$WORK/log" 2>&1 || restore "uv venv ($(tail -n 3 "$WORK/log" | tr '\n' ' '))"
    as_owner env UV_PYTHON_DOWNLOADS=never /usr/local/bin/uv pip install --quiet \
        --python "$VENV/bin/python" --no-deps --only-binary :all: -r "$WORK/requirements.txt" >"$WORK/log" 2>&1 ||
        restore "uv pip install ($(tail -n 3 "$WORK/log" | tr '\n' ' '))"
    freeze_of "$VENV" | grep -v '^DIRECT_URL ' >"$WORK/new-set"
    diff -q "$WORK/old-set" "$WORK/new-set" >/dev/null ||
        restore "package set differs: $(diff "$WORK/old-set" "$WORK/new-set" | head -n 5 | tr '\n' ' ')"
fi
say "packages  $(wc -l <"$WORK/new-set") installed"

# every import that worked before must still work
imports_of "$VENV/bin/python" >"$WORK/new-imports"
broken="$(comm -12 <(sed -n 's/:ok$//p' "$WORK/old-imports" | sort) <(sed -n 's/:FAIL$//p' "$WORK/new-imports" | sort) | tr '\n' ' ')"
[[ -z "$broken" ]] || restore "imports that worked before now fail: $broken"
say "imports   $(tr '\n' ' ' <"$WORK/new-imports")"

as_owner rm -rf "$BACKUP"
say "DONE: $VENV rebuilt on $(as_admin sed -n 's/^version_info *= *//p' "$VENV/pyvenv.cfg"), owner $(as_admin stat -c %U "$VENV"); old venv removed"
