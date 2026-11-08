#!/bin/bash
# Installed as both GUI and CLI entry points. No process restrictions or data migration.
set -euo pipefail
canonical() {
  local path="$1" part result="" target depth="${2:-0}"
  [ "$depth" -lt 40 ] || { echo "Symlink loop in candidate path" >&2; return 1; }
  local -a parts
  IFS=/ read -r -a parts <<< "$path"
  for part in "${parts[@]}"; do
    case "$part" in
      ''|.) continue ;;
      ..) result="${result%/*}" ;;
      *) result="$result/$part"
         if [ -L "$result" ]; then
           target="$(readlink "$result")"
           case "$target" in /*) ;; *) target="${result%/*}/$target" ;; esac
           result="$(canonical "$target" "$((depth + 1))")"
         elif [ -d "$result" ]; then result="$(cd "$result" && pwd -P)"; fi ;;
    esac
  done
  printf '%s\n' "${result:-/}"
}
ROOT="${AVPPLAY_HOME:-$HOME/Library/Application Support/AVPPlayCandidate187}"
case "$ROOT" in /*) ;; *) echo 'AVPPLAY_HOME must be absolute' >&2; exit 1 ;; esac
ROOT="$(canonical "$ROOT")"
for name in AVPPlay AVPPlayModificado AVPPlayCandidate AVPPlayCandidate185 AVPPlayCandidate186 QuestInstaller; do
  protected="$(canonical "$HOME/Library/Application Support/$name")"
  case "$ROOT/" in "$protected/"*) echo 'Candidate root overlaps installed data' >&2; exit 1 ;; esac
  case "$protected/" in "$ROOT/"*) echo 'Candidate root contains installed data' >&2; exit 1 ;; esac
done
for protected in "$HOME/Applications/AVP Play Candidate 185.app" "$HOME/Applications/AVP Play Candidate 186.app" "$HOME/Applications/AVP Play Modificado" "/Applications/AVP Play.app"; do
  protected="$(canonical "$protected")"
  case "$ROOT/" in "$protected/"*) echo 'Candidate root overlaps protected app' >&2; exit 1 ;; esac
  case "$protected/" in "$ROOT/"*) echo 'Candidate root contains protected app' >&2; exit 1 ;; esac
done
# Reject preexisting state links before the GUI or helper can write through them.
for child in jobs toolchains local-variants build-only store cache tmp saves provisional-recipes tools steam signed-existing prepared-local; do
  resolved="$(canonical "$ROOT/$child")"
  case "$resolved/" in "$ROOT/"*) ;; *) echo 'Candidate child escapes its root' >&2; exit 1 ;; esac
done
export AVPPLAY_HOME="$ROOT"
export TMPDIR="$ROOT/tmp/"
# A previous symlink must not redirect candidate temporaries outside its root.
if [ "$(canonical "$TMPDIR")" != "$ROOT/tmp" ]; then
  echo 'Candidate temporary directory is redirected' >&2; exit 1
fi
mkdir -p "$TMPDIR"
exec "$0-bin" "$@"
