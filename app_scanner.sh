#!/usr/bin/env bash
# Scan a Rails 7 CONSUMER APP for Sprockets-isms and print the migration steps
# that apply when a dependency gem moves to Propshaft + dartsass-rails.
# Run from the app root. Read-only unless --fix. Pair with gem_scanner.sh.
#   ./app_scanner.sh [app_dir] --gem NAME [--fix]
# Exit 0 = clean, 1 = work found, 2 = wrong dir / bad flag.
set -u

root="."
FIX=0
BRIEF=0
GEM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fix)    FIX=1 ;;
    --brief)  BRIEF=1 ;;   # collapse BEFORE/AFTER blocks to one line per match
    --gem)    shift; GEM="${1:-}" ;;
    --gem=*)  GEM="${1#--gem=}" ;;
    -*)       echo "unknown flag: $1 (use --fix, --brief, --gem NAME)" >&2; exit 2 ;;
    *)        root="$1" ;;
  esac
  shift
done

NS="${GEM:-your_gem}"
gem_lc=$(printf '%s' "$NS" | tr '[:upper:]' '[:lower:]')

found=0
say()   { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
hit()   { found=1; printf '  \033[31m✗\033[0m %s\n' "$1"; }
ok()    { printf '  \033[32m✓\033[0m %s\n' "$1"; }
note()  { printf '  \033[33m!\033[0m %s\n' "$1"; }
step()  { printf '      → %s\n' "$1"; }
fixed() { printf '  \033[33m⟳ fixed:\033[0m %s\n' "$1"; }
emit()  {
  if [ "$BRIEF" -eq 1 ]; then
    if [ "$3" = "(missing)" ]; then printf '        \033[2m%s\033[0m  add: %s\n' "$1" "$4"
    else printf '        \033[2m%s:%s\033[0m  %s\n' "$1" "$2" "$3"; fi
  else
    printf '        \033[2m%s:%s\033[0m\n' "$1" "$2"
    printf '          \033[31mBEFORE:\033[0m %s\n' "$3"
    printf '          \033[32mAFTER: \033[0m %s\n' "$4"
  fi
}
trim()  { printf '%s' "$1" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'; }
splitrow() { F=${1%%:*}; local r=${1#*:}; L=${r%%:*}; C=$(trim "${r#*:}"); }

[ -f "$root/config/application.rb" ] || { echo "No config/application.rb under '$root' — run from the Rails app root." >&2; exit 2; }

scan_dirs=(app/assets config)
present=(); for d in "${scan_dirs[@]}"; do [ -d "$root/$d" ] && present+=("$root/$d"); done
[ "${#present[@]}" -gt 0 ] || { echo "No app/assets or config dir under '$root'." >&2; exit 2; }

g() { grep -rInE "$1" "${present[@]}" 2>/dev/null; }
c() { g "$1" | wc -l | tr -d ' '; }

printf '\033[1mConsumer-app Sprockets → Propshaft scan: %s\033[0m\n' "$(cd "$root" && pwd)"
[ -n "$GEM" ] && printf '\033[1mDependency gem: %s (case-insensitive)\033[0m\n' "$GEM"

say "0. Does this app import the gem's SCSS?"
if [ -n "$GEM" ]; then
  n=$(grep -rInE "@(use|import)[[:space:]]+[\"']${gem_lc}" "$root/app/assets/stylesheets" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" -gt 0 ]; then
    ok "app @use/@imports '$gem_lc' ($n reference(s))"
  else
    hit "app does not @use '$gem_lc' — nothing pulls the gem's styles in"
    step "add to application.scss:  @use \"$gem_lc/variables\" with (\$primary: #c00);"
    step "                          @use \"$gem_lc/components/button\";"
    step "no load-path config needed — the engine's stylesheets dir is auto-added"
  fi
else
  note "no --gem given; skipping the gem-import check (pass --gem NAME)"
fi

say "1. Gemfile"
gf="$root/Gemfile"
if [ -f "$gf" ]; then
  for dep in sprockets-rails sassc-rails sass-rails; do
    if grep -qE "gem[[:space:]]+[\"']$dep[\"']" "$gf"; then
      hit "Gemfile has $dep"
      grep -nE "gem[[:space:]]+[\"']$dep[\"']" "$gf" | while IFS= read -r row; do
        splitrow "$gf:$row"; emit "$F" "$L" "$C" "(delete this line)"
      done
    fi
  done
  grep -qE "gem[[:space:]]+[\"']propshaft[\"']" "$gf"      && ok "propshaft present" \
    || { hit "propshaft missing";      emit "$gf" "-" "(missing)" "gem \"propshaft\""; }
  grep -qE "gem[[:space:]]+[\"']dartsass-rails[\"']" "$gf" && ok "dartsass-rails present" \
    || { hit "dartsass-rails missing"; emit "$gf" "-" "(missing)" "gem \"dartsass-rails\""; }
else
  note "no Gemfile found"
fi

say "2. Sprockets manifest"
mf=$(find "$root/app/assets/config" -name manifest.js 2>/dev/null)
if [ -n "$mf" ]; then
  hit "found $mf"
  if [ "$FIX" -eq 1 ]; then rm -f "$mf" && fixed "deleted $mf"
  else step "delete it — Propshaft ignores manifest.js (--fix does this)"; fi
else
  ok "no manifest.js"
fi

say "3. Sprockets config (environments / application.rb)"
n=$(c 'config\.assets\.(precompile|compile|digest|version|css_compressor|js_compressor|debug)|require [\"'\'']sprockets/railtie[\"'\'']|Sprockets::')
if [ "$n" -gt 0 ]; then
  hit "$n Sprockets config/API reference(s)"
  g 'config\.assets\.(precompile|compile|digest|version|css_compressor|js_compressor|debug)|require [\"'\'']sprockets/railtie[\"'\'']|Sprockets::' | while IFS= read -r row; do
    splitrow "$row"; emit "$F" "$L" "$C" "(delete this line)"
  done
  step "Propshaft always digests, has no compile step, no allowlist"
else
  ok "no Sprockets config references"
fi

say "4. Sprockets Sass helper functions"
n=$(c 'image-url|asset-path|font-url|asset-data-url|image-path|font-path')
if [ "$n" -gt 0 ]; then
  hit "$n use(s) of Sprockets Sass helpers (crash under Dart Sass)"
  g 'image-url|asset-path|font-url|asset-data-url|image-path|font-path' | while IFS= read -r row; do
    splitrow "$row"
    after=$(printf '%s' "$C" | sed -E 's/(image|asset|font)-url\(/url(/g')
    if printf '%s' "$after" | grep -qE '(image|asset|font)-path\(|asset-data-url\('; then
      after="$after   # *-path / data-url: resolve manually to a logical url()"
    fi
    emit "$F" "$L" "$C" "$after"
  done
else
  ok "no Sprockets Sass helper functions"
fi

say "5. ERB-processed assets"
n=$(find "$root/app/assets" \( -name '*.scss.erb' -o -name '*.css.erb' -o -name '*.js.erb' \) 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -gt 0 ]; then
  hit "$n .erb asset file(s) — Propshaft won't run ERB"
  find "$root/app/assets" \( -name '*.scss.erb' -o -name '*.css.erb' -o -name '*.js.erb' \) 2>/dev/null | sed 's/^/        /'
  step "rename to drop .erb and remove the templating"
else
  ok "no .erb asset files"
fi

say "6. Sprockets directives"
n=$(c '^[[:space:]]*//=')
if [ "$n" -gt 0 ]; then
  hit "$n //= directive line(s)"
  g '^[[:space:]]*//=' | while IFS= read -r row; do splitrow "$row"; emit "$F" "$L" "$C" "(delete this line)"; done
  if [ "$FIX" -eq 1 ]; then
    grep -rIlE '^[[:space:]]*//=' "${present[@]}" 2>/dev/null | while IFS= read -r f; do
      perl -i -ne 'print unless /^\s*\/\/=/' "$f" && fixed "stripped directives from $f"
    done
  else
    step "delete all directives — Propshaft has no directive language (--fix does this)"
  fi
else
  ok "no //= directives"
fi

say "7. Dart Sass build wiring"
if grep -rqInE 'config\.dartsass\.builds' "$root/config" 2>/dev/null; then
  ok "config.dartsass.builds is set"
else
  hit "no config.dartsass.builds found"
  step "config/initializers/dartsass.rb: config.dartsass.builds = { \"application.scss\" => \"application.css\" }"
fi
if [ -d "$root/app/assets/builds" ]; then
  ok "app/assets/builds exists"
  grep -qE 'app/assets/builds' "$root/.gitignore" 2>/dev/null || note "add /app/assets/builds/* to .gitignore (compiled output)"
else
  hit "app/assets/builds/ missing (dartsass output dir)"
  step "mkdir -p app/assets/builds && touch app/assets/builds/.keep"
fi

say "8. Dev workflow (Procfile.dev)"
pf="$root/Procfile.dev"
if [ -f "$pf" ]; then
  grep -qE 'dartsass:watch' "$pf" && ok "Procfile.dev runs dartsass:watch" \
    || { hit "Procfile.dev has no dartsass:watch"; step "add line:  css: bin/rails dartsass:watch"; }
else
  note "no Procfile.dev — run 'bin/rails dartsass:watch' manually, or add bin/dev + Procfile.dev"
fi

say "9. JavaScript bundling (Propshaft won't bundle/transpile)"
js_hit=0
n=$(grep -rInE '^[[:space:]]*//=[[:space:]]*require' "${present[@]}" --include='*.js' 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -gt 0 ]; then
  js_hit=1; hit "$n //= require directive(s) in .js"
  grep -rInE '^[[:space:]]*//=[[:space:]]*require' "${present[@]}" --include='*.js' 2>/dev/null | while IFS= read -r row; do
    splitrow "$row"; emit "$F" "$L" "$C" "(delete this line)"
  done
fi
n=$(grep -rInE '^[[:space:]]*(import[[:space:]]|export[[:space:]])' "${present[@]}" --include='*.js' 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -gt 0 ] && { js_hit=1; hit "$n ESM import/export line(s) in .js — need importmap or a bundler"; }
n=$(find "$root/app/assets" -name '*.coffee' 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -gt 0 ] && { js_hit=1; hit "$n .coffee file(s) — Propshaft won't transpile"; }
if [ "$js_hit" -eq 1 ]; then
  step "move JS to importmap-rails or jsbundling-rails; compile .coffee to .js first"
else
  ok "no Sprockets-bundled JS detected"
fi

printf '\n\033[1m== Summary ==\033[0m\n'
if [ "$found" -eq 0 ]; then
  printf '  \033[32mClean\033[0m — app is Propshaft-ready.\n'
else
  echo "  Migration work found (see ✗ above). Full guide: CONSUMER_APP_MIGRATION.md"
  if [ "$FIX" -eq 1 ]; then
    echo "  --fix applied the safe changes; review with 'git diff' and re-run to confirm."
  else
    echo "  Re-run with --fix to auto-apply the safe ones (manifest.js + //= directives)."
  fi
fi
exit $found
