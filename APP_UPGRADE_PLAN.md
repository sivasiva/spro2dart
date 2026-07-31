# APP_UPGRADE_PLAN.md — Host app: Sprockets + Webpacker/Shakapacker + react-on-rails → Propshaft + rails_vite

Goal: migrate one consumer app off the legacy asset stack to **Propshaft** (CSS/
static, served) + **`rails_vite`** (JS, incl. React) while keeping the Shaft gem
working. Runs per-app, independently of other apps. Work top-to-bottom; **do not
start a step until the previous step's PASS criteria are met.** Every step is a
separate commit so any one can be reverted.

Prereq: the gem is dual-pipeline ready (`GEM_UPGRADE_PLAN.md` done). Tooling:
`app_scanner.sh`, `theming_usage_scan.sh`. Run from the app repo root.

**Two pipelines move here, keep them separate in your head:**
- **CSS / static:** Sprockets → **Propshaft** (serves; compiles nothing).
- **JS / React:** Webpacker/Shakapacker + react-on-rails → **`rails_vite`** (Vite build to `public/vite/`, runs *alongside* Propshaft).

---

## Step 0 — Baseline inventory & risk read (no changes)

**Do:** measure what this app actually uses before touching anything.

**Verify:**
```bash
./app_scanner.sh . --gem shaft | tee /tmp/app_baseline.txt
./theming_usage_scan.sh . --gem shaft --gem-path ~/src/shaft   # is this app OVERRIDE / USE-ONLY / COMPILED-ONLY?
rg -n 'Shakapacker|Webpacker|react_on_rails|ReactOnRails' Gemfile app config | tee /tmp/legacy_stack.txt
rg -l 'react_component|ReactOnRails\.register' app                        # SSR/registration surface
```

**Pass:** you have (a) the app's gem-consumption bucket, (b) a list of Webpacker/Shakapacker/react-on-rails touch points, (c) the React component registry surface.
**Fail-gate:** scans error or the app's theming bucket is unknown — resolve before planning; an OVERRIDE app needs the gem's **source** channel and changes Step 6.

---

## Step 1 — Golden snapshot of current output

**Do:** capture the working baseline to diff against after cutover.

**Verify:**
```bash
RAILS_ENV=production bin/rails assets:precompile
ls -1 public/assets public/packs* 2>/dev/null > /tmp/golden_manifest.txt
# screenshot or curl key pages while still on the OLD stack:
bin/rails s -e production -p 4000 & sleep 4
for p in / /login /dashboard; do curl -s localhost:4000$p > /tmp/golden$(echo $p|tr / _).html; done
kill %1
```

**Pass:** precompile succeeds on the current stack and you have golden HTML for the key pages.
**Fail-gate:** current stack doesn't build — fix that first; never start a migration from a red baseline.

---

## Step 2 — Swap the CSS pipeline: Sprockets → Propshaft

**Do:** `propshaft` replaces `sprockets-rails`. Add `dartsass-rails` **only if** Step 0 flagged this app as OVERRIDE/USE-ONLY compiling the gem's SCSS on the Ruby side; a COMPILED-ONLY app just serves `dist/shaft.css` and needs no Sass compiler.
```ruby
# Gemfile — remove sprockets-rails, sassc-rails; add:
gem "propshaft"
```

**Verify:**
```bash
bundle install
bin/rails runner 'puts Rails.application.assets.class' 2>&1 | grep -qi 'NoMethodError\|undefined' && echo "SPROCKETS GONE"
./app_scanner.sh . --gem shaft | sed -n '/Sprockets manifest/,/Sass helper/p'
```

**Pass:** `SPROCKETS GONE`, `manifest.js` reported deletable/deleted, no Sprockets Sass helpers in app SCSS.
**Fail-gate:** app still boots Sprockets, or `app_scanner` finds `image-url`/`asset-path` in the app's own styles — clean those (they crash the new build).

---

## Step 3 — Remove Sprockets config remnants

**Do:** delete `app/assets/config/manifest.js`, `config/initializers/assets.rb`, and `config.assets.*` (precompile/compile/css_compressor/digest) in `config/environments/*`.

**Verify:**
```bash
rg -n 'config\.assets\.(precompile|compile|digest|css_compressor|js_compressor)|sprockets/railtie' config | tee /tmp/leftover.txt
test ! -f app/assets/config/manifest.js && test ! -f config/initializers/assets.rb && echo "CLEAN"
```

**Pass:** `/tmp/leftover.txt` empty **and** `CLEAN` printed.
**Fail-gate:** any leftover — Propshaft ignores or errors on these; remove them before adding Vite so failures are unambiguous.

---

## Step 4 — Introduce `rails_vite` alongside the pipeline

**Do:** add Vite; it builds to `public/vite/` and coexists with Propshaft (which keeps serving CSS/static).
```ruby
# Gemfile
gem "rails_vite"
```
```bash
bundle install
bin/rails generate rails_vite:install
yarn install
```

**Verify:**
```bash
test -f vite.config.ts && echo "VITE CONFIG OK"
yarn vite build && ls public/vite/.vite/manifest.json && echo "VITE BUILDS"
```

**Pass:** `VITE CONFIG OK` and `VITE BUILDS` (manifest emitted).
**Fail-gate:** generator or build fails — resolve Node/Vite setup before migrating any entrypoints.

---

## Step 5 — Migrate JS entrypoints: Webpacker/Shakapacker → Vite

**Do:** move packs to Vite entrypoints. Convert `javascript_pack_tag`/`stylesheet_pack_tag` to the `rails_vite` tags; move `app/packs/*` (or `app/javascript/packs`) → the Vite `entrypoints` dir; convert any `require`→`import`.

**Verify:**
```bash
rg -n 'javascript_pack_tag|stylesheet_pack_tag|append_javascript_pack_tag' app  # must trend to ZERO
rg -n 'vite_javascript_tag|vite_stylesheet_tag|vite_client_tag' app             # replacements present
yarn vite build && echo "ENTRYPOINTS BUILD"
```

**Pass:** no `*_pack_tag` left in views, Vite tags present, `ENTRYPOINTS BUILD`.
**Fail-gate:** a `pack_tag` remains or an entrypoint fails to build — that page will 404 its JS. Fix before touching React SSR.

---

## Step 6 — Migrate react-on-rails (highest risk: SSR + registration)

**Do:** react-on-rails was bound to Shakapacker for bundling. Preserve the pieces that matter: **component registration** must run in a Vite entrypoint, and if the app uses **server-side rendering** you need a Vite-built server bundle. Confirm your installed react-on-rails version's Vite support against its docs before assuming APIs. If SSR support is uncertain, an interim **client-only render** (drop `prerender: true`) unblocks the pipeline migration and defers SSR.

**Verify:**
```bash
rg -n 'ReactOnRails\.register' app        # every registered component…
rg -n 'react_component\(' app             # …must back a react_component call in a view
# build + boot, then check a React page:
yarn vite build && bin/rails s -e production -p 4000 & sleep 5
curl -s localhost:4000/<react_page> | grep -q 'data-reactroot\|data-react-class' && echo "SSR/MOUNT PRESENT"
# hydration: no React mismatch/registration errors in the browser console (manual or headless check)
kill %1
```

**Pass:** every `react_component` view has a matching registered component, the React page returns mounted markup (`SSR/MOUNT PRESENT`), and hydration throws no console errors.
**Fail-gate:** blank React root, "component not registered", or hydration mismatch. Do **not** proceed — either fix the entrypoint/registration or drop to client-only render and record the SSR deferral.

---

## Step 7 — Repoint the Shaft gem consumption

**Do:** based on Step 0's bucket:
- **COMPILED-ONLY:** reference `dist/shaft.css` via Propshaft (`stylesheet_link_tag`) or import `@yourorg/shaft/css` in a Vite entrypoint. No Sass compile.
- **USE-ONLY / OVERRIDE:** import the **source** in a Vite entrypoint — `@use "shaft/scss" with (…)` — so theming actually applies (a bare `@import "shaft"` would resolve to precompiled CSS and silently drop overrides).

**Verify:**
```bash
# OVERRIDE apps: the override must reach a SOURCE import, not the compiled css:
rg -n '@use +["'\'']shaft/scss["'\''].*with *\(|@use +["'\'']@yourorg/shaft/scss' app
yarn vite build && echo "GEM CSS BUILDS"
# a themed value visibly differs from the gem default (spot-check the compiled output):
grep -oE '#[0-9a-fA-F]{3,6}' public/vite/assets/*.css | grep -i "<your override hex>" && echo "THEME APPLIED"
```

**Pass:** for OVERRIDE apps `THEME APPLIED` (your color present in output); for others `GEM CSS BUILDS` and the gem's styles render.
**Fail-gate:** override hex absent → the app is pulling precompiled CSS, theming lost. Point the import at the source channel.

---

## Step 8 — Remove the legacy stack

**Do:** now that Vite covers JS/React and Propshaft covers CSS/static, delete Shakapacker/Webpacker and the Shakapacker-specific react-on-rails wiring.
```ruby
# Gemfile — remove: shakapacker (or webpacker); keep react_on_rails only if still used via Vite
```
Delete `config/shakapacker.yml` / `config/webpacker.yml`, `config/initializers/react_on_rails.rb` Shakapacker bits, `bin/shakapacker*`, `app/packs` if emptied.

**Verify:**
```bash
bundle install
rg -n 'Shakapacker|Webpacker|webpacker|shakapacker' Gemfile config bin app && echo "LEFTOVERS ↑" || echo "STACK REMOVED"
```

**Pass:** `STACK REMOVED` (no references outside historical comments).
**Fail-gate:** `LEFTOVERS` — a lingering pack_tag or config will error at boot. Remove before final verification.

---

## Step 9 — Full verification vs. the golden snapshot

**Do:** prove dev and prod both work and output matches the Step 1 baseline.

**Verify:**
```bash
# dev: both processes up
foreman start -f Procfile.dev &  sleep 6   # web + vite dev
curl -s localhost:3000/ | grep -qi 'shaft' && echo "DEV OK"; kill %1
# prod: precompile + vite build, boot, diff key pages against golden
RAILS_ENV=production bin/rails assets:precompile   # runs vite build via rails_vite hook
bin/rails s -e production -p 4000 & sleep 4
for p in / /login /dashboard; do
  curl -s localhost:4000$p > /tmp/new$(echo $p|tr / _).html
  diff <(grep -oE 'class="[^"]*"' /tmp/golden$(echo $p|tr / _).html | sort -u) \
       <(grep -oE 'class="[^"]*"' /tmp/new$(echo $p|tr / _).html | sort -u) \
       && echo "$p STRUCTURE MATCH"
done
kill %1
```

**Pass:** `DEV OK`, prod precompile succeeds, every key page prints `STRUCTURE MATCH`, React pages render + hydrate, **zero asset 404s** in the server log.
**Fail-gate:** any structural diff on a key page, asset 404, or hydration error. This is the last gate — do not cut over.

---

## Step 10 — Cutover & cleanup

**Do:** merge, deploy to staging, watch logs for 404s and JS errors, then production. Remove `Procfile.dev` webpacker lines, drop unused npm deps (`yarn remove` shakapacker/webpack loaders), delete `public/packs*` from ignore lists.

**Verify:**
```bash
# on staging, tail for the two failure modes that survive local checks:
grep -c ' 404 ' log/production.log            # asset 404s → expect 0
# browser console on smoke-tested pages → expect no React/registration errors
```

**Pass:** staging shows `0` asset 404s and clean consoles across smoke-tested pages for a full soak; production deploy repeats clean.
**Fail-gate:** 404s or console errors on staging — roll back the deploy (not the branch), fix, re-verify from Step 9.

---

## Done criteria for the whole app upgrade

- [ ] `app_scanner.sh` reports Propshaft-ready (no Sprockets config, manifest, or helpers).
- [ ] No `*_pack_tag`, no Shakapacker/Webpacker refs; Vite builds all entrypoints.
- [ ] React components register and (if used) SSR-render + hydrate with no errors.
- [ ] Shaft gem renders; OVERRIDE apps show their theme applied from the source channel.
- [ ] Prod precompile + vite build succeed; key pages match golden structure; zero asset 404s on staging soak.
