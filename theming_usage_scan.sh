#!/usr/bin/env bash
# Classify how each host app consumes the gem, across ALL channels:
#   OVERRIDE      — customizes the Sass API (@use ... with, or reassigns a !default knob)
#   USE-ONLY      — reads the gem's Sass vars/mixins but takes the defaults
#   COMPILED-ONLY — consumes the gem but not its Sass API; tagged with the channel(s):
#                     [scss] SCSS @import/@use    [js]  import/require in JS/TS
#                     [tag]  Rails/Vite asset tag [css] @import in .css/.less
#                     [pin]  importmap pin in config/importmap.rb
#   NONE          — no reference to the gem in ANY scanned channel
#
# Any var/mixin reference proves the app compiles the gem's SOURCE (you can't read
# a Sass $var or @mixin from dist/shaft.min.css). The extra channels stop JS-import
# and Rails-tag consumers from hiding in NONE. Read-only. BSD/macOS-grep compatible.
#
#   ./theming_usage_scan.sh [apps_dir] --gem NAME --gem-path DIR [--pkg NAME] [--brief]
#
# apps_dir  : directory of host-app checkouts (one subdir each). Default: .
# --gem     : REQUIRED. The gem's Sass namespace/prefix (e.g. shaft).
# --gem-path: REQUIRED. Gem source dir — derives exact !default knob names so
#             override detection is precise even for un-prefixed vars. Theming
#             classification is unreliable without it, so it is mandatory.
# --pkg     : the npm/import specifier to match (JS + tag channels). Default: --gem value.
# --brief   : one line per app, no file:line evidence.
set -u

usage() { echo "usage: $(basename "$0") [apps_dir] --gem NAME --gem-path DIR [--pkg NAME] [--brief]" >&2; }

root="."
PREFIX=""
PKG=""
GEMPATH=""
BRIEF=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gem)        shift; PREFIX="${1:-}" ;;
    --gem=*)      PREFIX="${1#--gem=}" ;;
    --pkg)        shift; PKG="${1:-}" ;;
    --pkg=*)      PKG="${1#--pkg=}" ;;
    --gem-path)   shift; GEMPATH="${1:-}" ;;
    --gem-path=*) GEMPATH="${1#--gem-path=}" ;;
    --brief)      BRIEF=1 ;;
    -*)           echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *)            root="$1" ;;
  esac
  shift
done

# --gem and --gem-path are required — theming detection is unreliable without both
err=""
[ -n "$PREFIX" ]      || err="${err}  --gem is required (the gem's Sass namespace)\n"
[ -n "$GEMPATH" ]     || err="${err}  --gem-path is required (the gem source dir)\n"
[ -z "$GEMPATH" ] || [ -d "$GEMPATH" ] || err="${err}  --gem-path is not a directory: $GEMPATH\n"
if [ -n "$err" ]; then printf 'error:\n'"$err" >&2; usage; exit 2; fi
[ -d "$root" ] || { echo "not a directory: $root" >&2; exit 2; }
PKG="${PKG:-$PREFIX}"

# ---- colors ----
c_ov=$'\033[31m'; c_use=$'\033[33m'; c_comp=$'\033[36m'; c_none=$'\033[2m'
c_b=$'\033[1m'; c_dim=$'\033[2m'; c_x=$'\033[0m'

# ---- grep helpers, one per file family ----
sg() { grep -rInE "$1" --include='*.scss' --include='*.sass' "$2" 2>/dev/null; }                                   # Sass
jg() { grep -rInE "$1" --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' \
                       --include='*.mjs' --include='*.cjs' "$2" 2>/dev/null; }                                     # JS/TS
tg() { grep -rInE "$1" --include='*.erb' --include='*.haml' --include='*.slim' --include='*.rb' "$2" 2>/dev/null; } # views/ruby
cg() { grep -rInE "$1" --include='*.css' --include='*.less' "$2" 2>/dev/null; }                                    # plain CSS/LESS
ig() { grep -rInE "$1" --include='importmap.rb' "$2" 2>/dev/null                                                   # importmap pins
       [ -d "$2/config/importmap" ] && grep -rInE "$1" --include='*.rb' "$2/config/importmap" 2>/dev/null; }

# ---- regexes (BSD-ERE safe; literal $ via single-quoted fragments) ----
Q="[\"']"
IMPORT_RE="@(use|import|forward)[[:space:]].*${PREFIX}"
MODERN_RE="@(use|forward)[[:space:]].*${PREFIX}.*with[[:space:]]*\\("
LEGACY_RE='^[[:space:]]*\$'"${PREFIX}"'[-_][A-Za-z0-9_-]*[[:space:]]*:'
USE_RE="@include[[:space:]]+${PREFIX}[-_.]|"'\$'"${PREFIX}[-_][A-Za-z0-9_-]*|(^|[^A-Za-z0-9_])${PREFIX}\\."
JS_RE="(import|require).*${Q}[^\"']*${PKG}(${Q}|/)"
TAG_RE="(stylesheet_link_tag|javascript_include_tag|stylesheet_pack_tag|javascript_pack_tag|vite_stylesheet_tag|vite_javascript_tag).*${Q}[^\"']*${PKG}"
CSS_RE="@import.*${Q}[^\"']*${PKG}"
PIN_RE="^[[:space:]]*pin(_all_from)?[[:space:]].*${PKG}"

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
[ ${#apps[@]} -eq 0 ] && apps=("$root/")

printf '%sTheming-usage scan%s  namespace: %s%s%s  pkg: %s%s%s' \
  "$c_b" "$c_x" "$c_b" "$PREFIX" "$c_x" "$c_b" "$PKG" "$c_x"
[ "$knob_n" -gt 0 ] && printf '   (%d !default knobs from %s)' "$knob_n" "$GEMPATH"
printf '\n\n'

n_ov=0; n_use=0; n_comp=0; n_none=0; ov_list=""
ch_scss=0; ch_js=0; ch_tag=0; ch_css=0; ch_pin=0

evid() { # $1=lines — up to 4 file:line rows
  [ "$BRIEF" -eq 1 ] && return
  printf '%s\n' "$1" | grep -vE '^$' | head -4 | while IFS= read -r ln; do
    printf '        %s%s%s\n' "$c_dim" "$ln" "$c_x"
  done
}

for app in "${apps[@]}"; do
  [ -d "$app" ] || continue
  name=$(basename "$app")

  # theming signals (Sass source)
  ovm=$(sg "$MODERN_RE" "$app"); ovl=$(sg "$LEGACY_RE" "$app")
  ovk=""; [ -n "$KNOB_RE" ] && ovk=$(sg "$KNOB_RE" "$app")
  overrides=$(printf '%s\n%s\n%s\n' "$ovm" "$ovl" "$ovk" | grep -vE '^$')
  uses=$(sg "$USE_RE" "$app")

  # consumption channels
  c_scss=$(sg "$IMPORT_RE" "$app"); c_js=$(jg "$JS_RE" "$app")
  c_tag=$(tg "$TAG_RE" "$app");     c_css=$(cg "$CSS_RE" "$app")
  c_pin=$(ig "$PIN_RE" "$app")
  channels=""
  [ -n "$c_scss" ] && { channels="$channels scss"; ch_scss=$((ch_scss+1)); }
  [ -n "$c_js"   ] && { channels="$channels js";   ch_js=$((ch_js+1)); }
  [ -n "$c_tag"  ] && { channels="$channels tag";  ch_tag=$((ch_tag+1)); }
  [ -n "$c_css"  ] && { channels="$channels css";  ch_css=$((ch_css+1)); }
  [ -n "$c_pin"  ] && { channels="$channels pin";  ch_pin=$((ch_pin+1)); }
  channels=$(echo $channels | xargs)
  tag=""; [ -n "$channels" ] && tag="  ${c_dim}[$channels]${c_x}"

  if   [ -n "$overrides" ]; then
    n_ov=$((n_ov+1)); ov_list="$ov_list $name"
    printf '  %s● OVERRIDE%s      %s%s\n' "$c_ov" "$c_x" "$name" "$tag"; evid "$overrides"
  elif [ -n "$uses" ]; then
    n_use=$((n_use+1))
    printf '  %s● USE-ONLY%s      %s%s\n' "$c_use" "$c_x" "$name" "$tag"; evid "$uses"
  elif [ -n "$channels" ]; then
    n_comp=$((n_comp+1))
    printf '  %s● COMPILED-ONLY%s %s%s\n' "$c_comp" "$c_x" "$name" "$tag"
    evid "$(printf '%s\n%s\n%s\n%s\n%s\n' "$c_scss" "$c_js" "$c_tag" "$c_css" "$c_pin")"
  else
    n_none=$((n_none+1))
    [ "$BRIEF" -eq 1 ] || printf '  %s○ NONE           %s%s\n' "$c_none" "$name" "$c_x"
  fi
done

printf '\n%s== Summary ==%s\n' "$c_b" "$c_x"
printf '  %sOVERRIDE%s %d   %sUSE-ONLY%s %d   %sCOMPILED-ONLY%s %d   %sNONE%s %d\n' \
  "$c_ov" "$c_x" "$n_ov" "$c_use" "$c_x" "$n_use" "$c_comp" "$c_x" "$n_comp" "$c_none" "$c_x" "$n_none"
printf '  %schannels among consumers:%s scss %d · js %d · tag %d · css %d · pin %d\n' \
  "$c_dim" "$c_x" "$ch_scss" "$ch_js" "$ch_tag" "$ch_css" "$ch_pin"
if [ "$n_ov" -gt 0 ]; then
  printf '  %sTheming blast radius%s (must move to @use "…/scss" with (…)):\n' "$c_ov" "$c_x"
  printf '    %s\n' "$(echo "$ov_list" | xargs)"
fi
if [ "$n_use" -gt 0 ]; then
  printf '  %sUSE-ONLY%s apps still need the SCSS source — precompiled-only would break them.\n' "$c_use" "$c_x"
fi
if [ "$knob_n" -eq 0 ]; then
  printf '  %swarning:%s no !default variables found under %s — is --gem-path correct? Override\n' "$c_use" "$c_x" "$GEMPATH"
  printf '           detection fell back to the %s-prefix only; un-prefixed overrides may be missed.\n' "$PREFIX"
fi

exit 0   # informational; never fail the caller
