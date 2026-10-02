#!/bin/bash
# =============================================================================
# install.sh — link the versioned hooks into a clone (idempotent).
#
#   scripts/hooks/install.sh [<repo>]           install; a foreign hook already there → rc 2
#   scripts/hooks/install.sh --force [<repo>]   back the foreign hook up (<name>.bak-<ts>), replace it
#   scripts/hooks/install.sh --check [<repo>]   verify only: rc 0 = every hook is live
#   <repo> defaults to the clone of the current directory.
#
# Why symlinks: git never clones .git/hooks, so a hook that only lives there exists in
# exactly one clone — the rule it enforces is an assumption everywhere else. The hook
# source is versioned in the repo; the symlink makes that one reviewed file live in
# every clone. (A copy would silently age; a symlink always runs the current version.)
#
# What --check catches, because git does NOT complain about any of it — it just skips
# the hook: a dangling link (clone moved, absolute target gone), a target that is not
# executable, a foreign file in place of the link, and core.hooksPath pointing elsewhere.
# Run --check from a scheduled job; a barrier whose presence you cannot check is an assumption.
# =============================================================================
set -u
MODE=install
while [ $# -gt 0 ]; do
  case "$1" in
    --force) MODE=force; shift ;;
    --check) MODE=check; shift ;;
    -h|--help) sed -n '2,19p' "$0"; exit 0 ;;
    *) break ;;
  esac
done
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(git -C "${1:-.}" rev-parse --show-toplevel 2>/dev/null)" || { echo "not a git checkout: ${1:-.}" >&2; exit 2; }
HOOKDIR="$(git -C "$ROOT" rev-parse --git-path hooks)"
case "$HOOKDIR" in /*) ;; *) HOOKDIR="$ROOT/$HOOKDIR" ;; esac
rc=0
if [ -n "$(git -C "$ROOT" config --get core.hooksPath)" ]; then
  echo "WARN    core.hooksPath=$(git -C "$ROOT" config --get core.hooksPath) — git reads hooks THERE, not in .git/hooks"
  [ "$MODE" = check ] && rc=1
fi
mkdir -p "$HOOKDIR"
for h in pre-commit pre-merge-commit pre-rebase post-commit; do
  case "$h" in post-commit) src="$HERE/post-commit" ;; *) src="$HERE/pre-commit" ;; esac
  # Relative link when the hook source lives inside this clone and hooks sit in .git/hooks:
  # it survives moving the clone. Otherwise absolute (and --check will notice if it breaks).
  tgt="$src"
  case "$src" in "$ROOT"/*) [ "$HOOKDIR" = "$ROOT/.git/hooks" ] && tgt="../../${src#"$ROOT"/}" ;; esac
  dst="$HOOKDIR/$h"
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$tgt" ]; then
    if [ ! -e "$dst" ]; then echo "BROKEN  $h → $tgt (target missing)"; rc=1; continue; fi
    if [ ! -x "$dst" ]; then
      [ "$MODE" = check ] && { echo "BROKEN  $h → $tgt (not executable — git ignores it)"; rc=1; continue; }
      chmod +x "$src" && echo "REPAIR  $h (+x)"
    fi
    echo "OK      $h → $tgt"; continue
  fi
  if [ "$MODE" = check ]; then
    if [ -e "$dst" ] || [ -L "$dst" ]; then echo "FOREIGN $h — not the versioned hook"; else echo "MISSING $h"; fi
    rc=1; continue
  fi
  if [ -e "$dst" ] || [ -L "$dst" ]; then
    [ "$MODE" = force ] || { echo "ABORT   $h: foreign hook at $dst — inspect it, then --force (it will be backed up)" >&2; rc=2; continue; }
    mv "$dst" "$dst.bak-$(date +%Y%m%d-%H%M%S)" && echo "BACKUP  $h"
  fi
  chmod +x "$src" && ln -s "$tgt" "$dst" && echo "INSTALL $h → $tgt" || { echo "ERROR   $h" >&2; rc=2; }
done
exit $rc
