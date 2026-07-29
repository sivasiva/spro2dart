#!/usr/bin/env bash
# Scan a Rails Engine gem for Sprockets-isms and print the migration steps that
# actually apply. Run from the gem root. Read-only: changes nothing.
# Exit 0 = clean, 1 = migration work found.
set -u

root="."
FIX=0
GEM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --fix)   FIX=1 ;;
    --gem)   shift; GEM="${1:-}" ;;
    --gem=*) GEM="${1#--gem=}" ;;
    -*)      echo "unknown flag: $1 (use --fix, --gem NAME)" >&2; exit 2 ;;
    *)       root="$1" ;;
  esac
  shift
done

# NS = namespace used in path suggestions; gem_lc = case-insensitive match key
NS="${GEM:-my_engine}"
gem_lc=$(printf '%s' "$NS" | tr '[:upper:]' '[:lower:]')

found=0
say()  { printf '\n\033[1m== %s ==\033[0m\n' "$1"; }
hit()  { found=1; printf '  \033[31m✗\033[0m %s\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
step() { printf '      → %s\n' "$1"; }
fixed(){ printf '  \033[33m⟳ fixed:\033[0m %s\n' "$1"; }

# assets live here in an engine; scan gemspec + config too
scan_dirs=(app/assets lib config)
present=(); for d in "${scan_dirs[@]}"; do [ -d "$root/$d" ] && present+=("$root/$d"); done
if [ "${#present[@]}" -eq 0 ]; then
  echo "No app/assets, lib, or config dir under '$root' — run this from the gem root." >&2
  exit 2
fi

# empty-array guard: never let grep -r fall back to scanning cwd
g() { grep -rInE "$1" "${present[@]}" 2>/dev/null; }         # matches, with file:line
c() { g "$1" | wc -l | tr -d ' '; }                           # match count

printf '\033[1mSprockets → Propshaft/dartsass scan: %s\033[0m\n' "$(cd "$root" && pwd)"
[ -n "$GEM" ] && printf '\033[1mTarget gem: %s (case-insensitive)\033[0m\n' "$GEM"

say "0. Asset namespace"
if [ -n "$GEM" ]; then
  # -iname = case-insensitive: "MyEngine" matches app/assets/**/my_engine
  ns_dir=$(find "$root/app/assets" -type d -iname "$gem_lc" 2>/dev/null | head -1)
  if [ -n "$ns_dir" ]; then
    ok "assets namespaced under $ns_dir"
  else
    hit "no asset dir matching '$NS' under app/assets (case-insensitive)"
    step "namespace assets as app/assets/stylesheets/$gem_lc/ to avoid host collisions"
  fi
  # gemspec sanity: does a gemspec for this gem exist? (case-insensitive)
  if ! ls "$root"/*.gemspec 2>/dev/null | grep -qi "$gem_lc"; then
    printf '  \033[33m!\033[0m no *%s*.gemspec here — is this the right gem dir?\n' "$gem_lc"
  fi
else
  ok "no --gem given; using placeholder namespace '$NS' in suggestions"
fi

say "1. Dependencies (gemspec)"
gemspec=$(ls "$root"/*.gemspec 2>/dev/null | head -1)
if [ -n "$gemspec" ]; then
  for dep in sprockets-rails sassc-rails sass-rails; do
    if grep -qE "[\"']$dep[\"']" "$gemspec"; then
      hit "gemspec depends on $dep"
      step "remove it; add: spec.add_dependency \"propshaft\""
      step "dartsass-rails → add_development_dependency (host compiles)"
    fi
  done
  grep -qE "[\"']propshaft[\"']" "$gemspec" && ok "propshaft already declared"
else
  ok "no gemspec found (skipping dep check)"
fi

say "2. Sprockets manifest"
mf=$(find "$root/app/assets/config" -name manifest.js 2>/dev/null)
if [ -n "$mf" ]; then
  hit "found $mf"
  if [ "$FIX" -eq 1 ]; then
    rm -f "$mf" && fixed "deleted $mf"
  else
    step "delete it — Propshaft ignores manifest.js entirely (--fix does this)"
  fi
else
  ok "no manifest.js"
fi

say "3. Sprockets directives"
n=$(c '^\s*//=')
if [ "$n" -gt 0 ]; then
  hit "$n directive line(s) (//= require / link / require_tree)"
  g '^\s*//=' | sed 's/^/        /'
  if [ "$FIX" -eq 1 ]; then
    # strip every //= directive line in place (inert under Propshaft); perl -i is portable
    grep -rIlE '^\s*//=' "${present[@]}" 2>/dev/null | while IFS= read -r f; do
      perl -i -ne 'print unless /^\s*\/\/=/' "$f" && fixed "stripped directives from $f"
    done
    step "review: replace require concatenation with @use in one entrypoint scss"
  else
    step "delete all directives — Propshaft has no directive language (--fix does this)"
    step "then replace require concatenation with @use in one entrypoint scss"
  fi
else
  ok "no //= directives"
fi

say "4. Sprockets Sass helper functions"
n=$(c 'image-url|asset-path|font-url|asset-data-url|image-path|font-path')
if [ "$n" -gt 0 ]; then
  hit "$n use(s) of Sprockets Sass helpers (crash under Dart Sass)"
  g 'image-url|asset-path|font-url|asset-data-url|image-path|font-path' | sed 's/^/        /'
  step "replace with url(\"$gem_lc/<path>\") — Propshaft rewrites the digest"
  step "use full logical paths (namespaced), not bare relative ones"
else
  ok "no Sprockets Sass helper functions"
fi

say "5. ERB-processed assets"
n=$(find "$root/app/assets" \( -name '*.scss.erb' -o -name '*.css.erb' -o -name '*.js.erb' \) 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -gt 0 ]; then
  hit "$n .erb asset file(s) — Dart Sass/Propshaft won't run ERB"
  find "$root/app/assets" \( -name '*.scss.erb' -o -name '*.css.erb' -o -name '*.js.erb' \) 2>/dev/null | sed 's/^/        /'
  step "rename to drop .erb and remove the ERB templating"
else
  ok "no .erb asset files"
fi

say "6. Precompile allowlists / sprockets config"
n=$(c 'config\.assets\.(precompile|compile|digest|version|css_compressor|js_compressor)|sprockets/railtie|Sprockets::')
if [ "$n" -gt 0 ]; then
  hit "$n Sprockets config/API reference(s)"
  g 'config\.assets\.(precompile|compile|digest|version|css_compressor|js_compressor)|sprockets/railtie|Sprockets::' | sed 's/^/        /'
  step "remove — Propshaft auto-serves the load path; no allowlist, no compile flags"
else
  ok "no Sprockets config references"
fi

say "7. Configurable variables (!default)"
scss_vars=$(grep -rIlE '^\s*\$[A-Za-z]' "$root/app/assets/stylesheets" 2>/dev/null | wc -l | tr -d ' ')
if [ "$scss_vars" -gt 0 ]; then
  n=$(grep -rInE '^\s*\$[A-Za-z][^;]*;\s*$' "$root/app/assets/stylesheets" 2>/dev/null | grep -vc '!default')
  if [ "$n" -gt 0 ]; then
    hit "$n scss variable assignment(s) without !default"
    step "add !default to any variable consumers should override (@use ... with)"
  else
    ok "scss variables look override-ready"
  fi
else
  ok "no scss variables found"
fi

say "8. JavaScript bundling (Propshaft won't bundle/transpile)"
js_hit=0
# JS files with sprockets require directives = relied on concatenation
n=$(grep -rInE '^\s*//=\s*require' "${present[@]}" --include='*.js' 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -gt 0 ]; then
  js_hit=1; hit "$n //= require directive(s) in .js — Sprockets concatenation"
  grep -rInE '^\s*//=\s*require' "${present[@]}" --include='*.js' 2>/dev/null | sed 's/^/        /'
fi
# ES module syntax = assumes a bundler resolves imports
n=$(grep -rInE '^\s*(import\s|export\s|export\{|import\{)' "${present[@]}" --include='*.js' 2>/dev/null | wc -l | tr -d ' ')
[ "$n" -gt 0 ] && { js_hit=1; hit "$n ESM import/export line(s) in .js — need importmap or a bundler"; }
# CoffeeScript = Sprockets transpiled it; Propshaft won't
n=$(find "$root/app/assets" -name '*.coffee' 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" -gt 0 ]; then
  js_hit=1; hit "$n .coffee file(s) — Sprockets transpiled these; Propshaft won't"
  find "$root/app/assets" -name '*.coffee' 2>/dev/null | sed 's/^/        /'
fi
if [ "$js_hit" -eq 1 ]; then
  step "Propshaft serves JS as-is — no concat, no transpile. Pick one:"
  step "  a) ship one pre-bundled app/assets/builds/$gem_lc/application.js (simplest)"
  step "  b) provide importmap pins from the engine (host uses importmap-rails)"
  step "  c) move to jsbundling-rails (esbuild/rollup) if you need a real build"
  step "  compile .coffee to .js first — CoffeeScript support is gone"
else
  ok "no Sprockets-bundled JS detected"
fi

printf '\n\033[1m== Summary ==\033[0m\n'
if [ "$found" -eq 0 ]; then
  printf '  \033[32mClean\033[0m — no Sprockets-isms detected.\n'
else
  cat <<'EOF'
  Migration work found (see ✗ above). Full guides:
    - Gem side:      SPROCKETS_TO_PROPSHAFT_MIGRATION.md
    - Consumer apps: CONSUMER_APP_MIGRATION.md
EOF
  if [ "$FIX" -eq 1 ]; then
    echo "  --fix applied the safe changes above; review with 'git diff' and re-run to confirm."
  else
    echo "  Re-run with --fix to auto-apply the safe ones (manifest.js + //= directives)."
  fi
fi
exit $found
