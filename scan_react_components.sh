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

OUT="app/views/application"          # generated partials: _<kebab>.html.erb
ENTRY="app/frontend/entrypoints"     # generated Vite entrypoints: <kebab>.jsx
BUNDLES_REL="../../react/bundles"    # from ENTRY to app/react/bundles (react-on-rails startup dir)

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

[ "$DRY" = 1 ] || mkdir -p "$OUT" "$ENTRY"

gen=0; skip=0; total_opens=0

while IFS= read -r -d '' f; do
  # complete single-line calls (props hash contains no ')')
  # ponytail: hand-rolled read loop instead of mapfile — works on bash 3.2 (macOS).
  # Count as we read: ${#matches[@]} on an empty array trips set -u on bash 3.2.
  matches=()
  mcount=0
  while IFS= read -r _m; do matches+=("$_m"); mcount=$(( mcount + 1 )); done \
    < <(grep -oE "react_component\([^)]*\)" "$f" 2>/dev/null || true)
  # `|| true`: grep exits 1 on no-match, and pipefail would kill the script (bash set -e)
  opens=$( { grep -oE "react_component\(" "$f" 2>/dev/null || true; } | wc -l | tr -d ' ')
  total_opens=$(( total_opens + opens ))

  # opens the -oE pass couldn't complete = multi-line or ')' inside props
  unparsed=$(( opens - mcount ))
  if [ "$unparsed" -gt 0 ]; then
    echo "SKIP  $f — $unparsed call(s) span lines or have ')' in props; convert by hand"
    skip=$(( skip + unparsed ))
  fi

  for m in ${matches[@]+"${matches[@]}"}; do   # empty-array-safe under set -u (bash 3.2)
    name=$(printf '%s' "$m" | sed -E "s/^react_component\([[:space:]]*['\"]([^'\"]+).*/\1/")
    [ -n "$name" ] || { echo "SKIP  $f — could not read component name in: $m"; skip=$((skip+1)); continue; }

    if printf '%s' "$m" | grep -q 'props:'; then
      props=$(printf '%s' "$m" | sed -E "s/.*props:[[:space:]]*\{(.*)\}[[:space:]]*\)$/\1/")
    else
      props=""
    fi

    k=$(kebab "$name")
    partial="$OUT/_$k.html.erb"   # leading _ = Rails partial
    entry="$ENTRY/$k.jsx"

    if [ "$DRY" = 1 ]; then
      echo "GEN   $partial  +  $entry   <- $name  ($f)"
      continue
    fi

    cat > "$entry" <<JS
// $entry — generated from $f by scan_react_components.sh
import React from "react";
import { createRoot } from "react-dom/client";
import $name from "$BUNDLES_REL/$name/startup/$name";

const container = document.getElementById("$k");

if (container) {
  const railsProps = JSON.parse(container.getAttribute("data-props"));

  const root = createRoot(container);
  root.render(<$name {...railsProps} />);
}
JS

    cat > "$partial" <<ERB
<%# $partial — generated from $f by scan_react_components.sh %>
<%# Rails props for $k %>
<%
props = { $props }
%>

<%# Load component from $entry %>
<%= vite_javascript_tag '$k.jsx' %>

<%# Mount $k.jsx with Rails props %>
<div id="$k" data-props="<%= props.to_json %>"></div>
ERB

    echo "GEN   $partial  +  $entry   <- $name  ($f)"
    gen=$(( gen + 1 ))
  done
done < <(find "$SRC" -type f -name '*.html.erb' -print0)

echo "----"
echo "components found: $total_opens   generated: $gen   skipped: $skip"

if [ "$gen" -gt 0 ] && [ "$DRY" != 1 ]; then
  cat <<STUB

Each component now has a partial + its own Vite entrypoint. To use one, replace
the original call
    <%= react_component('Name', props: { ... }) %>
with
    <%= render 'application/<kebab>' %>

Check the generated imports resolve — they assume react-on-rails startup files at
    app/react/bundles/<Name>/startup/<Name>
(entrypoints import via $BUNDLES_REL/<Name>/startup/<Name>). Edit BUNDLES_REL at
the top of this script if your bundles live elsewhere.
STUB
fi
