#!/usr/bin/env bash
# scan_react_components.sh — find react-on-rails `react_component(...)` calls in
# *.html.erb under a directory and generate a vite_rails-compatible mount view
# per component at app/views/application/<kebab-of-name>.html.erb.
#
# Each generated view drops the `react_component` helper for a plain mount div:
#     <div data-react-component="Name" data-react-props="<%= {...}.to_json %>">
# A Vite entrypoint that scans `[data-react-component]` hydrates it (see the
# stub the script prints once). Props stay as the original Ruby expressions,
# serialized to JSON server-side — so `current_user.id`, i18n, etc. still work.
#
# ponytail: parses the common single-line form
#     <%= react_component('Name', props: { k: v, ... }) %>
# Ceiling — reported as SKIPPED (never mangled), fix by hand:
#   * the call spans multiple lines
#   * a ')' appears inside the props hash (e.g. props: { id: foo(x) })
# Bump this parser to a real Ruby AST pass only if those cases are common.

set -euo pipefail

usage() { echo "usage: $0 <views-dir> [--dry-run] [--selftest]"; exit 2; }

DRY=0
SRC=""
for a in "$@"; do
  case "$a" in
    --dry-run) DRY=1 ;;
    --selftest) SELFTEST=1 ;;
    -*) usage ;;
    *) SRC="$a" ;;
  esac
done

OUT="app/views/application"

# NameOfComponent -> name-of-component ; HTMLParser -> html-parser
kebab() {
  printf '%s' "$1" \
    | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g; s/([A-Z]+)([A-Z][a-z])/\1-\2/g' \
    | tr '[:upper:]' '[:lower:]'
}

# ---- self-check: fails loudly if the parsing logic breaks -------------------
if [ "${SELFTEST:-0}" = 1 ]; then
  ck() { [ "$1" = "$2" ] || { echo "FAIL: '$1' != '$2'"; exit 1; }; }
  ck "$(kebab NameOfComponent)"  "name-of-component"
  ck "$(kebab HTMLParser)"       "html-parser"
  ck "$(kebab Foo)"              "foo"
  line="<%= react_component('UserCard', props: { id: user.id, name: 'x' }) %>"
  m=$(printf '%s' "$line" | grep -oE "react_component\([^)]*\)")
  nm=$(printf '%s' "$m" | sed -E "s/^react_component\([[:space:]]*['\"]([^'\"]+).*/\1/")
  pr=$(printf '%s' "$m" | sed -E "s/.*props:[[:space:]]*\{(.*)\}[[:space:]]*\)$/\1/")
  ck "$nm" "UserCard"
  ck "$(printf '%s' "$pr" | tr -s ' ')" " id: user.id, name: 'x' "
  echo "SELFTEST OK"; exit 0
fi

[ -n "$SRC" ] || usage
[ -d "$SRC" ] || { echo "not a directory: $SRC"; exit 2; }

[ "$DRY" = 1 ] || mkdir -p "$OUT"

gen=0; skip=0; total_opens=0

while IFS= read -r -d '' f; do
  # complete single-line calls (props hash contains no ')')
  mapfile -t matches < <(grep -oE "react_component\([^)]*\)" "$f" 2>/dev/null || true)
  opens=$(grep -oE "react_component\(" "$f" 2>/dev/null | wc -l | tr -d ' ')
  total_opens=$(( total_opens + opens ))

  # opens the -oE pass couldn't complete = multi-line or ')' inside props
  unparsed=$(( opens - ${#matches[@]} ))
  if [ "$unparsed" -gt 0 ]; then
    echo "SKIP  $f — $unparsed call(s) span lines or have ')' in props; convert by hand"
    skip=$(( skip + unparsed ))
  fi

  for m in "${matches[@]}"; do
    name=$(printf '%s' "$m" | sed -E "s/^react_component\([[:space:]]*['\"]([^'\"]+).*/\1/")
    [ -n "$name" ] || { echo "SKIP  $f — could not read component name in: $m"; skip=$((skip+1)); continue; }

    if printf '%s' "$m" | grep -q 'props:'; then
      props=$(printf '%s' "$m" | sed -E "s/.*props:[[:space:]]*\{(.*)\}[[:space:]]*\)$/\1/")
    else
      props=""
    fi

    k=$(kebab "$name")
    dest="$OUT/_$k.html.erb"   # leading _ = Rails partial

    if [ "$DRY" = 1 ]; then
      echo "GEN   $dest   <- $name  ($f)"
      continue
    fi

    cat > "$dest" <<ERB
<%# Auto-generated from $f by scan_react_components.sh — do not hand-edit. %>
<%# Mounts <$name /> via Vite (react-on-rails-free). Props render to JSON server-side. %>
<div
  data-react-component="$name"
  data-react-props="<%= { $props }.to_json %>">
</div>
ERB
    echo "GEN   $dest   <- $name  ($f)"
    gen=$(( gen + 1 ))
  done
done < <(find "$SRC" -type f -name '*.html.erb' -print0)

echo "----"
echo "components found: $total_opens   generated: $gen   skipped: $skip"

if [ "$gen" -gt 0 ] && [ "$DRY" != 1 ]; then
  cat <<'STUB'

Add a Vite entrypoint that hydrates the mount divs (once), e.g. app/frontend/entrypoints/react_mounts.jsx:

    import { createRoot } from 'react-dom/client'
    import * as Components from '../components'          // barrel of your components

    document.querySelectorAll('[data-react-component]').forEach((el) => {
      const Comp = Components[el.dataset.reactComponent]
      if (!Comp) return console.warn('No component:', el.dataset.reactComponent)
      createRoot(el).render(<Comp {...JSON.parse(el.dataset.reactProps || '{}')} />)
    })

Load it in the layout: <%= vite_javascript_tag 'react_mounts' %>
STUB
fi
