# PILOT_UPGRADE.md — one host app: sassc/Shakapacker/react-on-rails → Propshaft + Vite, on the upgraded Shaft gem

Tailored to the chosen pilot: an **`override→source`** consumer (its theme
overrides are real and load-bearing today under sassc) with **difficulty 4**
(Shakapacker + react-on-rails, **no SSR**). This plan strips every branch that
doesn't apply to this app (SSR, precompiled-only shortcuts, at-risk no-op paths)
and centers on the one load-bearing risk: **keeping the theme override working
when SCSS resolution moves from the Ruby load path to Vite/Dart Sass.**

Prereq tooling: `theming_usage_scan.sh`, `app_scanner.sh`. Two repos change: the
**gem** (minimal, additive — other consumers keep working on sassc) and the
**pilot app**. Work top-to-bottom; **do not start a step until the previous
step's PASS criteria are met.**

---

## Why theming is the crux here (read once)

Today, under **sassc-rails**, the pilot does:
```scss
$primary: #0055ff;   // app sets it first
@import "shaft";     // gem's `$primary: … !default;` picks up the app's value
```
`@import "shaft"` resolves via the **Sprockets load path** to the gem's SCSS
**source**, so the override compiles in. The gem's `package.json` is irrelevant to
this path.

Moving to **Vite** breaks this in two ways at once:
1. **Resolution flips to node** → bare `"shaft"` resolves via `package.json`
   (`style`/`main` → `dist/shaft.min.css`, **precompiled**) → the override becomes
   a silent **no-op**.
2. **Syntax flips** → the `$var`-before-`@import` + global-`!default` pattern only
   works with `@import` (deprecated in Dart Sass); `@use` requires explicit `with()`.

The fix is a gem source-specifier + an app rewrite, verified by the override
value surviving into the built CSS.

---

## Part A — Gem (minimal, additive)

### Step A1 — Expose a node-resolvable source specifier

**Do:** add source exports alongside the existing precompiled fields; do **not**
remove `style`/`dist` (the other 10 consumers still serve precompiled on sassc).
The `sass`/`exports["./scss"]` fields point at the **Dart-Sass module entrypoint**
you create in A2 — NOT the legacy `shaft.scss` (which stays LibSass-safe for the
sassc apps and is resolved by them via the Sprockets load path, not package.json).
```jsonc
// package.json
{
  "main":  "dist/shaft.js",                              // was dist/shaft.min.css — fix the JS entry too
  "style": "dist/shaft.min.css",                         // keep: precompiled consumers
  "sass":  "lib/assets/stylesheets/shaft.module.scss",   // NEW: Vite/Dart-Sass module entrypoint (A2)
  "exports": {
    ".":      "./dist/shaft.js",
    "./scss": "./lib/assets/stylesheets/shaft.module.scss",
    "./css":  "./dist/shaft.min.css"
  }
}
```

**Verify:**
```bash
node -e 'let p=require("./package.json");
  process.exit(p.sass && p.exports && p.exports["./scss"] ? 0 : 1)' && echo "SOURCE EXPORT OK"
```
**Pass:** `SOURCE EXPORT OK`.
**Fail-gate:** missing `sass`/`exports["./scss"]` → Vite can't reach the source and the pilot's theme cannot survive. Stop.

### Step A2 — Dual entrypoints: keep the legacy source LibSass-safe, add a Dart-Sass module entrypoint

> **Why dual, not an in-place `sass-migrator` run.** The other 10 consumers use
> **sassc-rails = LibSass**, which has **no module system** — it cannot parse
> `@use`/`@forward`/`sass:math`. Running `sass-migrator module` (or any migration
> that emits module syntax) on the shared source would make it *uncompilable* by
> every sassc app, and `.import.scss` shims don't help (LibSass ignores them).
> So the legacy entrypoint stays `@import`-based, and the module entrypoint is a
> **parallel** file that only Vite/Dart-Sass consumers load. Full in-place
> `sass-migrator module` is a fleet-wide *retirement* step for after the last
> LibSass consumer is gone — not now.

**Do:**
1. **Legacy entrypoint** `lib/assets/stylesheets/shaft.scss` — keep LibSass-safe:
   `@import`-based internals, every themed var `!default`, and remove the only
   thing LibSass and Dart Sass both reject — Sprockets helpers (`image-url`/
   `asset-path`/`font-url` → `url()`). The 10 sassc apps keep `@import "shaft"`.
2. **Module entrypoint** `lib/assets/stylesheets/shaft.module.scss` — a parallel,
   Dart-Sass-only file that `@forward`s the same partials with `!default` so the
   pilot can `@use "@yourorg/shaft/scss" with (…)`. `sass-migrator` can *scaffold*
   this (run it against a copy to generate the `@forward` graph); do not let it
   overwrite the legacy entrypoint.

**Verify (both compilers must pass):**
```bash
grep -rnE 'image-url|asset-path|font-url' lib/assets && echo "DIRTY ↑" || echo "CLEAN"
# legacy entrypoint MUST still compile under LibSass/sassc (the 10 untouched apps):
sassc lib/assets/stylesheets/shaft.scss /tmp/legacy.css \
  -I lib/assets/stylesheets >/dev/null && echo "LIBSASS OK"     # or a sassc-rails dummy app
# module entrypoint MUST compile under Dart Sass (the pilot):
npx sass lib/assets/stylesheets/shaft.module.scss /tmp/mod.css \
  --load-path=lib/assets/stylesheets >/dev/null && echo "DARTSASS OK"
```
**Pass:** `CLEAN`, `LIBSASS OK`, **and** `DARTSASS OK`.
**Fail-gate:** legacy entrypoint fails under LibSass → you've leaked module syntax
into the shared source and just broke the 10 sassc apps; back it out. Module
entrypoint fails under Dart Sass → the pilot can't theme; fix before B4.

### Step A3 — Publish, keep versions lockstep

**Do:** release the gem + npm package at the same version from one tag. The pilot
depends on this new version.

**Verify:**
```bash
test "$(ruby -e 'puts Gem::Specification.load(Dir["*.gemspec"].first).version')" \
   = "$(node -p 'require("./package.json").version')" && echo "LOCKSTEP"
```
**Pass:** `LOCKSTEP` and both published.
**Fail-gate:** version drift → the pilot could mix server/frontend versions. Align first.

> Nothing here breaks the sassc consumers: `style`/`dist`/the Sprockets load path
> are untouched. This gem release is safe to ship fleet-wide before the pilot moves.

---

## Part B — Pilot app

### Step B0 — Baseline & golden snapshot

**Do:** capture the working baseline, including the current theme.

**Verify:**
```bash
./theming_usage_scan.sh . --gem shaft --gem-path ~/src/shaft --profile   # confirm override→source (sassc), difficulty 4, no +SSR
RAILS_ENV=production bin/rails assets:precompile
bin/rails s -e production -p 4000 & sleep 4
curl -s localhost:4000/ > /tmp/golden.html
# record the CURRENT compiled override value for later comparison:
grep -roE '#0055ff|<your override hex>' public/assets/*.css | head; kill %1
```
**Pass:** profile card confirms `override→source (sassc load-path)`, `no +SSR`; golden HTML saved; the override hex is present in the current build.
**Fail-gate:** card shows `+SSR` or `override→precompiled` → this plan's assumptions don't hold; re-scope before proceeding.

### Step B1 — Point the app at the upgraded gem

**Do:** bump the gem (Ruby) and add the npm package at the new version.
```bash
bundle update shaft
yarn add @yourorg/shaft@<new-version>   # or git-tag dep if internal
```
**Verify:** `bundle list | grep shaft` and `cat node_modules/@yourorg/shaft/package.json | grep '"sass"'` → source export present.
**Pass:** both resolve to the new version with the `sass`/`exports` fields.
**Fail-gate:** old version resolves → fix the dep pin before rewiring imports.

### Step B2 — Swap CSS pipeline: Sprockets → Propshaft

**Do:** `propshaft` replaces `sprockets-rails`/`sassc-rails` (the app's SCSS now
compiles in Vite, not sassc).
```ruby
# Gemfile — remove sprockets-rails, sassc-rails; add:
gem "propshaft"
```
**Verify:**
```bash
bundle install
./app_scanner.sh . --gem shaft | sed -n '/Sprockets config/,/Sass helper/p'
```
**Pass:** Sprockets config/manifest reported removable; no Sprockets Sass helpers in the app's own SCSS.
**Fail-gate:** app-owned `image-url`/`asset-path` remain → clean them (Vite/Propshaft won't provide them).

### Step B3 — Introduce Vite (rails_vite or vite_rails)

**Do:** add the Vite integration; it builds JS + CSS, Propshaft serves static.
```bash
# Gemfile: gem "rails_vite"   (or "vite_rails")
bundle install && bin/rails generate rails_vite:install && yarn install
```
**Verify:** `yarn vite build && ls public/vite/.vite/manifest.json && echo "VITE BUILDS"`.
**Pass:** `VITE BUILDS`.
**Fail-gate:** generator/build fails → resolve Vite/Node setup before migrating entrypoints.

### Step B4 — THE THEMING STEP: rewrite the override to a source specifier

**Do:** this is the load-bearing change. Convert the sassc `@import` + pre-set var
into the Vite-safe `@use … with()` on the gem's source export, in a Vite entrypoint.
```scss
// before (sassc, Ruby load-path):
//   $primary: #0055ff;
//   @import "shaft";
// after (Vite, node-resolved source):
@use "@yourorg/shaft/scss" with ($primary: #0055ff);
```
Remove any `~`-prefixed specifier — **Vite's Sass does not understand `~`**.

**Verify (the gate for the whole migration):**
```bash
yarn vite build
grep -roE '#0055ff|<your override hex>' public/vite/assets/*.css | head && echo "THEME APPLIED"
```
**Pass:** `THEME APPLIED` — your override value is present in the Vite-built CSS (proves resolution hit the **source**, not precompiled `dist`).
**Fail-gate:** the hex is **absent** → Vite resolved `shaft` to precompiled CSS or dropped the override. Do **not** proceed; fix the specifier (Step A1 export + this import) until the value appears.

### Step B5 — Migrate JS entrypoints: Shakapacker → Vite

**Do:** move packs to Vite entrypoints; convert `javascript_pack_tag`/
`stylesheet_pack_tag` to the Vite tags; `require`→`import`.

**Verify:**
```bash
rg -n 'javascript_pack_tag|stylesheet_pack_tag' app   # → zero
rg -n 'vite_javascript_tag|vite_stylesheet_tag' app   # → present
yarn vite build && echo "ENTRYPOINTS BUILD"
```
**Pass:** no `*_pack_tag` left; Vite tags present; `ENTRYPOINTS BUILD`.
**Fail-gate:** a `pack_tag` remains or an entrypoint fails → that page 404s its JS. Fix before React.

### Step B6 — react-on-rails: client render (no SSR)

**Do:** difficulty 4 means no SSR, so this is the simpler path — ensure every
`ReactOnRails.register` runs in a Vite entrypoint and every `react_component` view
mounts client-side. Confirm no `prerender: true` is lurking.

**Verify:**
```bash
rg -n 'prerender:\s*true' app && echo "UNEXPECTED SSR ↑" || echo "CLIENT-ONLY OK"
rg -n 'ReactOnRails\.register' app    # each backs a react_component( in a view
yarn vite build && bin/rails s -e production -p 4000 & sleep 5
curl -s localhost:4000/<react_page> | grep -q 'data-react-class' && echo "MOUNT PRESENT"; kill %1
```
**Pass:** `CLIENT-ONLY OK`, every registered component maps to a view, React page mounts and hydrates with no console errors.
**Fail-gate:** unexpected `prerender: true`, unregistered component, or hydration error → fix registration/entrypoint (SSR support would be a separate, later effort).

### Step B7 — Remove the legacy stack

**Do:** delete Shakapacker + Sprockets remnants now that Vite + Propshaft cover it.
```ruby
# Gemfile — remove: shakapacker
```
Delete `config/shakapacker.yml`, `bin/shakapacker*`, `app/assets/config/manifest.js`,
`config/initializers/assets.rb`, `config.assets.*` in environments, emptied `app/packs`.

**Verify:**
```bash
rg -n 'Shakapacker|shakapacker|webpacker|sprockets/railtie|config\.assets\.' Gemfile config bin app \
  && echo "LEFTOVERS ↑" || echo "STACK REMOVED"
```
**Pass:** `STACK REMOVED`.
**Fail-gate:** leftovers → a stray pack tag or config errors at boot. Remove before final verify.

### Step B8 — Full verification vs. golden

**Do:** dev + prod, and confirm the theme + structure match the baseline.

**Verify:**
```bash
foreman start -f Procfile.dev & sleep 6; curl -s localhost:3000/ | grep -qi 'shaft' && echo "DEV OK"; kill %1
RAILS_ENV=production bin/rails assets:precompile   # runs vite build via the hook
bin/rails s -e production -p 4000 & sleep 4
curl -s localhost:4000/ > /tmp/new.html
diff <(grep -oE 'class="[^"]*"' /tmp/golden.html | sort -u) <(grep -oE 'class="[^"]*"' /tmp/new.html | sort -u) && echo "STRUCTURE MATCH"
grep -roE '#0055ff|<your override hex>' public/vite/assets/*.css | head && echo "THEME STILL APPLIED"
kill %1
```
**Pass:** `DEV OK`, prod precompile succeeds, `STRUCTURE MATCH`, `THEME STILL APPLIED`, React mounts/hydrates, **zero asset 404s** in the log.
**Fail-gate:** structural diff, missing theme hex, asset 404, or hydration error → last gate; do not cut over.

### Step B9 — Cutover

**Do:** merge, deploy to staging, soak (watch for asset 404s + console/hydration
errors + a visual theme check), then production.

**Verify:** `grep -c ' 404 ' log/production.log` → `0`; the themed color renders correctly on smoke-tested pages.
**Pass:** clean staging soak, theme visibly correct; production repeats clean.
**Fail-gate:** 404s, console errors, or wrong/absent theme → roll back the deploy, fix, re-verify from B8.

---

## Done criteria

- [ ] Gem publishes `sass` + `exports["./scss"]`; sassc consumers untouched; versions lockstep.
- [ ] Pilot's override rewritten to `@use "@yourorg/shaft/scss" with (…)`; **theme hex present in Vite-built CSS**.
- [ ] No `*_pack_tag`, no Shakapacker/Sprockets refs; Vite builds all entrypoints.
- [ ] react-on-rails components register + mount client-side, no SSR, no hydration errors.
- [ ] Prod precompile + vite build succeed; structure matches golden; theme visibly correct; zero 404s on staging soak.

## What was deliberately left out (and when it returns)

- **SSR for react-on-rails** — not present at difficulty 4; add only if a later app needs it.
- **Migrating the other 10 consumers** — they stay on sassc + precompiled `dist`; the gem release supports both. Each moves later via this same plan.
- **Removing the precompiled channel from the gem** — keep it until *every* consumer is on the source specifier.
