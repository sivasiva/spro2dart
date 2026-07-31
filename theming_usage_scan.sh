#!/usr/bin/env bash
# Classify how each host app consumes the gem's Sass API:
#   OVERRIDE      — customizes it (@use ... with, or reassigns a !default knob)
#   USE-ONLY      — reads vars/mixins but takes the defaults
#   COMPILED-ONLY — imports the gem but touches no var/mixin (precompiled CSS is enough)
#   NONE          — doesn't reference the gem in SCSS
#
# Any var/mixin reference proves the app compiles the gem's SOURCE (you can't read
# a Sass $var or @mixin from dist/shaft.min.css). The OVERRIDE list is your
# theming blast radius. Read-only. BSD/macOS-grep compatible.
#
#   ./theming_usage_scan.sh [apps_dir] [--gem NAME] [--gem-path DIR] [--brief]
#
# apps_dir  : directory of host-app checkouts (one subdir each). Default: .
# --gem     : the gem's Sass namespace/prefix. Default: shaft
# --gem-path: gem source dir — derives the exact !default knob names for precise
#             override detection (recommended, esp. if vars aren't prefixed).
# --brief   : one line per app, no file:line evidence.
set -u

root="."
PREFIX="shaft"
GEMPATH=""
BRIEF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gem)       shift; PREFIX="${1:-shaft}" ;;
    --gem=*)     PREFIX="${1#--gem=}" ;;
    --gem-path)  shift; GEMPATH="${1:-}" ;;
    --gem-path=*)GEMPATH="${1#--gem-path=}" ;;
    --brief)     BRIEF=1 ;;
    -*)          echo "unknown flag: $1 (use --gem, --gem-path, --brief)" >&2; exit 2 ;;
    *)           root="$1" ;;
  esac
  shift
done
[ -d "$root" ] || { echo "not a directory: $root" >&2; exit 2; }

# ---- colors ----
c_ov=$'\033[31m'; c_use=$'\033[33m'; c_comp=$'\033[36m'; c_none=$'\033[2m'
c_b=$'\033[1m'; c_dim=$'\033[2m'; c_x=$'\033[0m'

sg() { grep -rInE "$1" --include='*.scss' --include='*.sass' "$2" 2>/dev/null; }

# ---- build the regexes (BSD-ERE safe; literal $ via single-quoted fragments) ----
IMPORT_RE="@(use|import|forward)[[:space:]].*${PREFIX}"
MODERN_RE="@(use|forward)[[:space:]].*${PREFIX}.*with[[:space:]]*\\("
LEGACY_RE='^[[:space:]]*\$'"${PREFIX}"'[-_][A-Za-z0-9_-]*[[:space:]]*:'
USE_RE="@include[[:space:]]+${PREFIX}[-_.]|"'\$'"${PREFIX}[-_][A-Za-z0-9_-]*|(^|[^A-Za-z0-9_])${PREFIX}\\."

# ---- optional: exact knob names from the gem's !default declarations ----
KNOB_RE=""; knob_n=0
if [ -n "$GEMPATH" ]; then
  knobs=$(grep -rhoE '\$[A-Za-z0-9_-]+[[:space:]]*:[^;]*!default' "$GEMPATH" \
            --include='*.scss' --include='*.sass' 2>/dev/null \
          | sed -E 's/^(\$[A-Za-z0-9_-]+).*/\1/' | sort -u)
  if [ -n "$knobs" ]; then
    alt=$(printf '%s\n' "$knobs" | sed 's/^\$//' | paste -sd'|' -)
    KNOB_RE='^[[:space:]]*\$('"$alt"')[[:space:]]*:'
    knob_n=$(printf '%s\n' "$knobs" | grep -c .)
  fi
fi

# ---- iterate apps ----
shopt -s nullglob 2>/dev/null || true
apps=("$root"/*/)
[ ${#apps[@]} -eq 0 ] && apps=("$root/")   # treat root itself as a single app

printf '%sTheming-usage scan%s  gem namespace: %s%s%s' "$c_b" "$c_x" "$c_b" "$PREFIX" "$c_x"
[ "$knob_n" -gt 0 ] && printf '   (%d !default knobs from %s)' "$knob_n" "$GEMPATH"
printf '\n'

n_ov=0; n_use=0; n_comp=0; n_none=0; ov_list=""

evid() { # $1=color $2=lines  — print up to 4 file:line evidence rows
  [ "$BRIEF" -eq 1 ] && return
  printf '%s\n' "$2" | grep -vE '^$' | head -4 | while IFS= read -r ln; do
    printf '        %s%s%s\n' "$c_dim" "$ln" "$c_x"
  done
}

for app in "${apps[@]}"; do
  [ -d "$app" ] || continue
  name=$(basename "$app")

  imp=$(sg "$IMPORT_RE" "$app")
  ovm=$(sg "$MODERN_RE" "$app")
  ovl=$(sg "$LEGACY_RE" "$app")
  ovk=""; [ -n "$KNOB_RE" ] && ovk=$(sg "$KNOB_RE" "$app")
  overrides=$(printf '%s\n%s\n%s\n' "$ovm" "$ovl" "$ovk" | grep -vE '^$')
  uses=$(sg "$USE_RE" "$app")

  if   [ -n "$overrides" ]; then
    n_ov=$((n_ov+1)); ov_list="$ov_list $name"
    printf '  %s● OVERRIDE%s      %s\n' "$c_ov" "$c_x" "$name"; evid "$c_ov" "$overrides"
  elif [ -n "$uses" ]; then
    n_use=$((n_use+1))
    printf '  %s● USE-ONLY%s      %s\n' "$c_use" "$c_x" "$name"; evid "$c_use" "$uses"
  elif [ -n "$imp" ]; then
    n_comp=$((n_comp+1))
    printf '  %s● COMPILED-ONLY%s %s\n' "$c_comp" "$c_x" "$name"; evid "$c_comp" "$imp"
  else
    n_none=$((n_none+1))
    [ "$BRIEF" -eq 1 ] || printf '  %s○ NONE           %s%s\n' "$c_none" "$name" "$c_x"
  fi
done

printf '\n%s== Summary ==%s\n' "$c_b" "$c_x"
printf '  %sOVERRIDE%s %d   %sUSE-ONLY%s %d   %sCOMPILED-ONLY%s %d   %sNONE%s %d\n' \
  "$c_ov" "$c_x" "$n_ov" "$c_use" "$c_x" "$n_use" "$c_comp" "$c_x" "$n_comp" "$c_none" "$c_x" "$n_none"
if [ "$n_ov" -gt 0 ]; then
  printf '  %sTheming blast radius%s (must move to @use "…/scss" with (…)):%s\n' "$c_ov" "$c_x" ""
  printf '    %s\n' "$(echo "$ov_list" | xargs)"
fi
if [ "$n_use" -gt 0 ]; then
  printf '  %sUSE-ONLY%s apps still need the SCSS source — precompiled-only would break them.\n' "$c_use" "$c_x"
fi
if [ "$knob_n" -eq 0 ] && [ -z "$GEMPATH" ]; then
  printf '  %stip:%s pass --gem-path <gem-dir> to detect overrides of un-prefixed vars precisely.\n' "$c_dim" "$c_x"
fi

exit 0   # informational; never fail the caller
