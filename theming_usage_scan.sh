#!/usr/bin/env bash
# Classify how each host app consumes the gem, across ALL channels, and (with
# --profile) emit the migration-plan inputs for a gem + one-app upgrade.
#
# Buckets:
#   OVERRIDE      — customizes the Sass API (@use ... with, or reassigns a !default knob)
#   USE-ONLY      — reads the gem's Sass vars/mixins but takes the defaults
#   COMPILED-ONLY — consumes the gem but not its Sass API; tagged with the channel(s):
#                     [scss] SCSS @import/@use    [js]  import/require in JS/TS
#                     [tag]  Rails/Vite asset tag [css] @import in .css/.less
#                     [pin]  importmap pin in config/importmap.rb
#   NONE          — no reference to the gem in ANY scanned channel
#
# --profile adds, for the gem + one-app migration:
#   • Gem-readiness checklist (from --gem-path): package.json channels, knob
#     namespacing, SCSS cleanliness, lib/assets exposure, dist, JS format.
#   • Per-consumer card: override resolution (source vs precompiled/at-risk),
#     JS stack, asset surface, overridden knobs+values.
#   • Pilot recommendation: rank consumers, suggest the migration candidate.
#
# Read-only. BSD/macOS-grep compatible.
#   ./theming_usage_scan.sh [apps_dir] --gem NAME --gem-path DIR [--pkg NAME] [--profile] [--brief]
set -u

usage() { echo "usage: $(basename "$0") [apps_dir] --gem NAME --gem-path DIR [--pkg NAME] [--profile] [--brief]" >&2; }

root="."; PREFIX=""; PKG=""; GEMPATH=""; BRIEF=0; PROFILE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --gem)        shift; PREFIX="${1:-}" ;;
    --gem=*)      PREFIX="${1#--gem=}" ;;
    --pkg)        shift; PKG="${1:-}" ;;
    --pkg=*)      PKG="${1#--pkg=}" ;;
    --gem-path)   shift; GEMPATH="${1:-}" ;;
    --gem-path=*) GEMPATH="${1#--gem-path=}" ;;
    --profile)    PROFILE=1 ;;
    --brief)      BRIEF=1 ;;
    -*)           echo "unknown flag: $1" >&2; usage; exit 2 ;;
    *)            root="$1" ;;
  esac
  shift
done
err=""
[ -n "$PREFIX" ]  || err="${err}  --gem is required (the gem's Sass namespace)\n"
[ -n "$GEMPATH" ] || err="${err}  --gem-path is required (the gem source dir)\n"
[ -z "$GEMPATH" ] || [ -d "$GEMPATH" ] || err="${err}  --gem-path is not a directory: $GEMPATH\n"
if [ -n "$err" ]; then printf 'error:\n'"$err" >&2; usage; exit 2; fi
[ -d "$root" ] || { echo "not a directory: $root" >&2; exit 2; }
PKG="${PKG:-$PREFIX}"

c_ov=$'\033[31m'; c_use=$'\033[33m'; c_comp=$'\033[36m'; c_none=$'\033[2m'
c_ok=$'\033[32m'; c_b=$'\033[1m'; c_dim=$'\033[2m'; c_x=$'\033[0m'

# ---- grep helpers, one per file family ----
sg() { grep -rInE "$1" --include='*.scss' --include='*.sass' "$2" 2>/dev/null; }
jg() { grep -rInE "$1" --include='*.js' --include='*.jsx' --include='*.ts' --include='*.tsx' \
                       --include='*.mjs' --include='*.cjs' "$2" 2>/dev/null; }
tg() { grep -rInE "$1" --include='*.erb' --include='*.haml' --include='*.slim' --include='*.rb' "$2" 2>/dev/null; }
cg() { grep -rInE "$1" --include='*.css' --include='*.less' "$2" 2>/dev/null; }
ig() { grep -rInE "$1" --include='importmap.rb' "$2" 2>/dev/null
       [ -d "$2/config/importmap" ] && grep -rInE "$1" --include='*.rb' "$2/config/importmap" 2>/dev/null; }
cnt() { printf '%s' "$1" | grep -cE '.' ; }

Q="[\"']"
IMPORT_RE="@(use|import|forward)[[:space:]].*${PREFIX}"
MODERN_RE="@(use|forward)[[:space:]].*${PREFIX}.*with[[:space:]]*\\("
LEGACY_RE='^[[:space:]]*\$'"${PREFIX}"'[-_][A-Za-z0-9_-]*[[:space:]]*:'
USE_RE="@include[[:space:]]+${PREFIX}[-_.]|"'\$'"${PREFIX}[-_][A-Za-z0-9_-]*|(^|[^A-Za-z0-9_])${PREFIX}\\."
JS_RE="(import|require).*${Q}[^\"']*${PKG}(${Q}|/)"
TAG_RE="(stylesheet_link_tag|javascript_include_tag|stylesheet_pack_tag|javascript_pack_tag|vite_stylesheet_tag|vite_javascript_tag).*${Q}[^\"']*${PKG}"
CSS_RE="@import.*${Q}[^\"']*${PKG}"
PIN_RE="^[[:space:]]*pin(_all_from)?[[:space:]].*${PKG}"
SRC_RE="@(use|import|forward)[^;]*${PKG}/(scss|lib|src|stylesheets)"   # a SOURCE-path specifier

# ---- knob names from the gem's !default declarations ----
KNOB_RE=""; knob_n=0; knob_generic=0
knobs=$(grep -rhoE '\$[A-Za-z0-9_-]+[[:space:]]*:[^;]*!default' "$GEMPATH" \
          --include='*.scss' --include='*.sass' 2>/dev/null \
        | sed -E 's/^(\$[A-Za-z0-9_-]+).*/\1/' | sort -u)
if [ -n "$knobs" ]; then
  alt=$(printf '%s\n' "$knobs" | sed 's/^\$//' | paste -sd'|' -)
  KNOB_RE='^[[:space:]]*\$('"$alt"')[[:space:]]*:'
  knob_n=$(cnt "$knobs")
  for k in $knobs; do case "$k" in *"$PREFIX"*) : ;; *) knob_generic=$((knob_generic+1)) ;; esac; done
fi

# ---- gem-readiness probe (profile only) ----
GEM_HAS_SASS=0
if [ "$PROFILE" -eq 1 ]; then
  GEMROOT="$GEMPATH"
  for up in "$GEMPATH" "$GEMPATH/.." "$GEMPATH/../.." "$GEMPATH/../../.."; do
    if ls "$up"/*.gemspec >/dev/null 2>&1 || [ -f "$up/package.json" ]; then GEMROOT="$up"; break; fi
  done
  PJ="$GEMROOT/package.json"
  grep -q '"sass"' "$PJ" 2>/dev/null && GEM_HAS_SASS=1
  gm_exports=0; grep -qE '"\./scss"' "$PJ" 2>/dev/null && gm_exports=1
  gm_main=$(grep -oE '"main"[[:space:]]*:[[:space:]]*"[^"]*"' "$PJ" 2>/dev/null | sed -E 's/.*"([^"]*)"$/\1/')
  gm_dirty=$(cnt "$(grep -rInE 'image-url|asset-path|font-url' "$GEMPATH" --include='*.scss' 2>/dev/null)")
  gm_import=$(cnt "$(grep -rInE '^[[:space:]]*@import' "$GEMPATH" --include='*.scss' 2>/dev/null)")
  gm_expose=0; grep -rqInE 'assets\.paths.*(lib/assets|dist)|(lib/assets|dist).*assets\.paths' "$GEMROOT/lib" 2>/dev/null && gm_expose=1
  gm_dist=0; [ -d "$GEMROOT/dist" ] && gm_dist=1
  gm_fmt=$(grep -rhoE "format:[[:space:]]*['\"](cjs|iife|umd|es|esm)['\"]" "$GEMROOT" --include='rollup*.js' --include='rollup*.mjs' --include='rollup*.ts' 2>/dev/null | sed -E "s/.*['\"]([a-z]+)['\"]/\1/" | head -1)
fi

ck() { [ "$1" = "1" ] && printf '%s✓%s' "$c_ok" "$c_x" || printf '%s✗%s' "$c_ov" "$c_x"; }

# ---- per-app stack / surface (profile only) ----
detect_stack() {
  local a="$1" gf="$1/Gemfile" s=""
  grep -qiE "gem +['\"]shakapacker"    "$gf" 2>/dev/null && s="$s shakapacker"
  grep -qiE "gem +['\"]webpacker"      "$gf" 2>/dev/null && s="$s webpacker"
  grep -qiE "gem +['\"]react_on_rails" "$gf" 2>/dev/null && s="$s react-on-rails"
  grep -qiE "gem +['\"](vite_rails|vite_ruby)" "$gf" 2>/dev/null && s="$s vite_rails"
  grep -qiE "gem +['\"]rails_vite"     "$gf" 2>/dev/null && s="$s rails_vite"
  grep -qiE "gem +['\"]importmap-rails" "$gf" 2>/dev/null && s="$s importmap"
  grep -qiE "gem +['\"]sprockets"      "$gf" 2>/dev/null && s="$s sprockets"
  grep -qiE "gem +['\"]propshaft"      "$gf" 2>/dev/null && s="$s propshaft"
  # SSR?
  if grep -qiE "gem +['\"]react_on_rails" "$gf" 2>/dev/null; then
    grep -rqInE 'prerender:[[:space:]]*true|server_rendering|ReactOnRails.*server' "$a/app" "$a/config" 2>/dev/null && s="$s +SSR"
  fi
  echo "$s" | xargs
}

echo_hdr() {
  printf '%sTheming-usage scan%s  namespace: %s%s%s  pkg: %s%s%s' \
    "$c_b" "$c_x" "$c_b" "$PREFIX" "$c_x" "$c_b" "$PKG" "$c_x"
  [ "$knob_n" -gt 0 ] && printf '   (%d !default knobs)' "$knob_n"
  printf '\n'
}
echo_hdr

# ---- gem readiness section ----
if [ "$PROFILE" -eq 1 ]; then
  printf '\n%s== Gem readiness (%s) ==%s\n' "$c_b" "$GEMROOT" "$c_x"
  main_ok=0; case "$gm_main" in *.js) main_ok=1 ;; esac
  printf '  %s package.json main   : %-22s (should be JS)\n' "$(ck $main_ok)" "${gm_main:-missing}"
  printf '  %s sass field          : %-22s %s\n' "$(ck $GEM_HAS_SASS)" "$([ $GEM_HAS_SASS = 1 ] && echo present || echo missing)" \
     "$([ $GEM_HAS_SASS = 0 ] && echo "← required for source-theming consumers" || echo '')"
  printf '  %s exports ./scss      : %s\n' "$(ck $gm_exports)" "$([ $gm_exports = 1 ] && echo present || echo missing)"
  if [ "$knob_n" -gt 0 ]; then
    if [ "$knob_generic" -gt 0 ]; then
      printf '  %s knobs               : %d total · %d generic (un-prefixed) %s⚠ collision/false-positive risk%s\n' "$(ck 0)" "$knob_n" "$knob_generic" "$c_use" "$c_x"
    else printf '  %s knobs               : %d total · all prefixed\n' "$(ck 1)" "$knob_n"; fi
  fi
  clean=$([ "$gm_dirty" = 0 ] && [ "$gm_import" = 0 ] && echo 1 || echo 0)
  printf '  %s scss source clean    : %d Sprockets helpers · %d @import (want @use)\n' "$(ck $clean)" "$gm_dirty" "$gm_import"
  printf '  %s engine exposes path  : %s\n' "$(ck $gm_expose)" "$([ $gm_expose = 1 ] && echo yes || echo 'no (lib/assets & dist not on assets.paths)')"
  printf '  %s dist/ committed      : %s\n' "$(ck $gm_dist)" "$([ $gm_dist = 1 ] && echo yes || echo no)"
  printf '  %s js output format     : %-8s %s\n' "$(ck $([ -n "$gm_fmt" ] && echo 1 || echo 0))" "${gm_fmt:-unknown}" \
     "$([ "$gm_fmt" = cjs ] && echo '(bundler-import OK; add iife/umd for script-tag consumers)' || echo '')"
fi

# ---- iterate apps ----
shopt -s nullglob 2>/dev/null || true
apps=("$root"/*/); [ ${#apps[@]} -eq 0 ] && apps=("$root/")

n_ov=0; n_use=0; n_comp=0; n_none=0; ov_list=""
ch_scss=0; ch_js=0; ch_tag=0; ch_css=0; ch_pin=0
p_names=(); p_bucket=(); p_diff=(); p_real=()

evid() { [ "$BRIEF" -eq 1 ] && return
  printf '%s\n' "$1" | grep -vE '^$' | head -4 | while IFS= read -r ln; do printf '        %s%s%s\n' "$c_dim" "$ln" "$c_x"; done; }

printf '\n'
for app in "${apps[@]}"; do
  [ -d "$app" ] || continue
  name=$(basename "$app")

  ovm=$(sg "$MODERN_RE" "$app"); ovl=$(sg "$LEGACY_RE" "$app")
  ovk=""; [ -n "$KNOB_RE" ] && ovk=$(sg "$KNOB_RE" "$app")
  overrides=$(printf '%s\n%s\n%s\n' "$ovm" "$ovl" "$ovk" | grep -vE '^$' | awk '!seen[$0]++')
  uses=$(sg "$USE_RE" "$app")

  c_scss=$(sg "$IMPORT_RE" "$app"); c_js=$(jg "$JS_RE" "$app")
  c_tag=$(tg "$TAG_RE" "$app");     c_css=$(cg "$CSS_RE" "$app"); c_pin=$(ig "$PIN_RE" "$app")
  channels=""
  [ -n "$c_scss" ] && { channels="$channels scss"; ch_scss=$((ch_scss+1)); }
  [ -n "$c_js"   ] && { channels="$channels js";   ch_js=$((ch_js+1)); }
  [ -n "$c_tag"  ] && { channels="$channels tag";  ch_tag=$((ch_tag+1)); }
  [ -n "$c_css"  ] && { channels="$channels css";  ch_css=$((ch_css+1)); }
  [ -n "$c_pin"  ] && { channels="$channels pin";  ch_pin=$((ch_pin+1)); }
  channels=$(echo $channels | xargs)
  tag=""; [ -n "$channels" ] && tag="  ${c_dim}[$channels]${c_x}"

  if   [ -n "$overrides" ]; then bucket="OVERRIDE"; col="$c_ov";  n_ov=$((n_ov+1));   ov_list="$ov_list $name"
  elif [ -n "$uses" ];      then bucket="USE-ONLY"; col="$c_use"; n_use=$((n_use+1))
  elif [ -n "$channels" ];  then bucket="COMPILED-ONLY"; col="$c_comp"; n_comp=$((n_comp+1))
  else bucket="NONE"; col="$c_none"; n_none=$((n_none+1)); fi

  if [ "$PROFILE" -eq 0 ]; then
    case "$bucket" in
      OVERRIDE)      printf '  %s● OVERRIDE%s      %s%s\n' "$col" "$c_x" "$name" "$tag"; evid "$overrides" ;;
      USE-ONLY)      printf '  %s● USE-ONLY%s      %s%s\n' "$col" "$c_x" "$name" "$tag"; evid "$uses" ;;
      COMPILED-ONLY) printf '  %s● COMPILED-ONLY%s %s%s\n' "$col" "$c_x" "$name" "$tag"
                     evid "$(printf '%s\n%s\n%s\n%s\n%s\n' "$c_scss" "$c_js" "$c_tag" "$c_css" "$c_pin")" ;;
      NONE)          [ "$BRIEF" -eq 1 ] || printf '  %s○ NONE           %s%s\n' "$c_none" "$name" "$c_x" ;;
    esac
    continue
  fi

  # ---- profile card (consumers only) ----
  [ "$bucket" = "NONE" ] && continue
  # override resolution
  res="n/a"
  if [ "$bucket" = "OVERRIDE" ]; then
    if sg "$SRC_RE" "$app" >/dev/null 2>&1; then res="${c_ok}override→source${c_x} (real)"
    elif [ "$GEM_HAS_SASS" = 1 ]; then res="${c_ok}override→source${c_x} (gem sass field resolves it)"
    else res="${c_ov}override→precompiled${c_x} (at-risk: bare \"$PKG\" + gem has no sass field → verify by compiling)"; fi
  fi
  stack=$(detect_stack "$app"); [ -z "$stack" ] && stack="(none detected)"
  # surface
  ep=$(find "$app/app/packs/entrypoints" "$app/app/javascript/packs" "$app/app/javascript/entrypoints" \
          "$app/app/frontend/entrypoints" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')
  ptag=$(cnt "$(tg 'javascript_pack_tag|stylesheet_pack_tag|append_javascript_pack_tag' "$app")")
  rc=$(cnt "$(tg 'react_component\(' "$app")")
  nscss=$(find "$app" \( -name '*.scss' -o -name '*.sass' \) 2>/dev/null | wc -l | tr -d ' ')
  knobd=$(printf '%s\n' "$overrides" | sed -E 's/^[^:]*:[0-9]+:[[:space:]]*//; s/[[:space:]]*!default//' | grep -vE '^$' | head -3 | paste -sd' · ' -)

  # difficulty score (lower = easier pilot)
  d=0
  case "$stack" in *shakapacker*|*webpacker*) d=$((d+2));; esac
  case "$stack" in *react-on-rails*) d=$((d+2));; esac
  case "$stack" in *+SSR*) d=$((d+2));; esac
  [ "$ptag" -gt 10 ] && d=$((d+1)); [ "$rc" -gt 5 ] && d=$((d+1))
  real=0; case "$res" in *"override→source"*) real=1;; esac
  p_names+=("$name"); p_bucket+=("$bucket"); p_diff+=("$d"); p_real+=("$real")

  printf '  %s● %-13s%s %s%s\n' "$col" "$bucket" "$c_x" "$name" "$tag"
  [ "$bucket" = "OVERRIDE" ] && printf '      resolves : %b\n' "$res"
  printf '      stack    : %s\n' "$stack"
  printf '      surface  : entrypoints %s · pack-tags %s · react %s · scss %s   %s(difficulty %d)%s\n' "$ep" "$ptag" "$rc" "$nscss" "$c_dim" "$d" "$c_x"
  [ -n "$knobd" ] && printf '      knobs    : %s\n' "$knobd"
done

# ---- summary ----
printf '\n%s== Summary ==%s\n' "$c_b" "$c_x"
printf '  %sOVERRIDE%s %d   %sUSE-ONLY%s %d   %sCOMPILED-ONLY%s %d   %sNONE%s %d\n' \
  "$c_ov" "$c_x" "$n_ov" "$c_use" "$c_x" "$n_use" "$c_comp" "$c_x" "$n_comp" "$c_none" "$c_x" "$n_none"
printf '  %schannels among consumers:%s scss %d · js %d · tag %d · css %d · pin %d\n' \
  "$c_dim" "$c_x" "$ch_scss" "$ch_js" "$ch_tag" "$ch_css" "$ch_pin"
[ "$n_ov" -gt 0 ] && { printf '  %sTheming blast radius%s:%s\n' "$c_ov" "$c_x" ""; printf '    %s\n' "$(echo "$ov_list" | xargs)"; }
[ "$knob_n" -eq 0 ] && printf '  %swarning:%s no !default vars under %s — is --gem-path correct?\n' "$c_use" "$c_x" "$GEMPATH"

# ---- pilot recommendation ----
if [ "$PROFILE" -eq 1 ] && [ "${#p_names[@]}" -gt 0 ]; then
  printf '\n%s== Pilot recommendation ==%s\n' "$c_b" "$c_x"
  # rank: real-theming first (0 before 1 via key), then lowest difficulty
  order=$(for i in "${!p_names[@]}"; do
            rk=$([ "${p_real[$i]}" = 1 ] && echo 0 || echo 1)   # real themers first
            printf '%d %d %s %s %d\n' "$rk" "${p_diff[$i]}" "${p_names[$i]}" "${p_bucket[$i]}" "${p_real[$i]}"
          done | sort -k1,1n -k2,2n)
  printf '%s' "$order" | while read -r rk d nm bk rl; do
    lbl=$([ "$rl" = 1 ] && echo "OVERRIDE→source" || echo "$bk")
    printf '    %-22s %-16s difficulty %s\n' "$nm" "$lbl" "$d"
  done
  # pick: easiest real-themer (ri), easiest overall consumer (ei), easiest overrider (oi)
  ei=-1; ri=-1; oi=-1
  for i in "${!p_names[@]}"; do
    { [ "$ei" -lt 0 ] || [ "${p_diff[$i]}" -lt "${p_diff[$ei]}" ]; } && ei=$i
    if [ "${p_real[$i]}" = 1 ]; then { [ "$ri" -lt 0 ] || [ "${p_diff[$i]}" -lt "${p_diff[$ri]}" ]; } && ri=$i; fi
    if [ "${p_bucket[$i]}" = OVERRIDE ]; then { [ "$oi" -lt 0 ] || [ "${p_diff[$i]}" -lt "${p_diff[$oi]}" ]; } && oi=$i; fi
  done
  if [ "$ri" -ge 0 ]; then
    printf '  %s→ Theming pilot: %s%s (difficulty %d) — the only consumer whose override is real,\n' "$c_ok" "${p_names[$ri]}" "$c_x" "${p_diff[$ri]}"
    printf '     so it proves the theme survives gem+Vite. Note the difficulty; this is your hardest path.\n'
    if [ "$ei" -ge 0 ] && [ "$ei" != "$ri" ] && [ "${p_diff[$ei]}" -lt "${p_diff[$ri]}" ]; then
      printf '     %sDe-risk first (optional):%s %s (difficulty %d, no theming) proves the Propshaft+Vite\n' "$c_dim" "$c_x" "${p_names[$ei]}" "${p_diff[$ei]}"
      printf '     pipeline before you take on %s.\n' "${p_names[$ri]}"
    fi
  elif [ "$oi" -ge 0 ]; then
    printf '  %s→ No overrider resolves to source today%s — every theme override is a silent no-op.\n' "$c_use" "$c_x"
    printf '     Fix the gem sass field first (see Gem readiness), then pilot %s (difficulty %d, the\n' "${p_names[$oi]}" "${p_diff[$oi]}"
    printf '     easiest overrider); without the fix its theme would stay broken under Vite.\n'
  else
    printf '  %s→ No theming consumers.%s Pilot %s (difficulty %d) to prove the pipeline; theming is moot.\n' \
      "$c_comp" "$c_x" "${p_names[$ei]}" "${p_diff[$ei]}"
  fi
fi

exit 0
