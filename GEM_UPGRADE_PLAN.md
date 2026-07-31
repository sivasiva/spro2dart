# GEM_UPGRADE_PLAN.md — Shaft engine gem: dual-pipeline (Sprockets + Propshaft) ready

Goal: make the rollup-built Shaft gem consumable by **both** legacy Sprockets hosts
and Rails 8 Propshaft hosts **from one version**, without breaking the apps that
theme it. Work top-to-bottom. **Do not start a step until the previous step's
PASS criteria are met.** Each step is reversible on its own.

Tooling used below (from the migration-tools repo): `gem_scanner.sh`,
`theming_usage_scan.sh`. Run all commands from the gem repo root unless noted.

**Compatibility contract this plan delivers**
- **Precompiled channel:** `dist/shaft.css` / `dist/shaft.min.css` served by the host pipeline (Sprockets *or* Propshaft). No host compile.
- **Source channel (theming):** raw `lib/assets/stylesheets/shaft.scss` consumed by a host's node bundler via `@use "shaft/scss" with (…)`.
- **JS channel:** the rollup bundle, resolved by node, not the Rails page (unless Step 6 says otherwise).

---

## Step 0 — Baseline inventory (no changes)

**Do:** capture the starting state so every later scan has a reference.

**Verify:**
```bash
./gem_scanner.sh . --gem shaft | tee /tmp/gem_baseline.txt
git rev-parse HEAD > /tmp/gem_baseline_sha.txt
```

**Pass:** scan runs clean-of-errors and you have a written inventory of Sprockets-isms, url() usages, and current deps.
**Fail-gate:** scanner errors (wrong dir / missing assets) — fix invocation before proceeding; a wrong baseline invalidates every later comparison.

---

## Step 1 — Fix `package.json` resolution (JS vs SCSS vs CSS)

**Do:** today `main` and `style` both point at `dist/shaft.min.css`, so the JS bundle is orphaned and bare `@import "shaft"` silently resolves to minified CSS (no theming). Separate the three channels:
```jsonc
{
  "main":  "dist/shaft.js",
  "style": "dist/shaft.min.css",
  "sass":  "lib/assets/stylesheets/shaft.scss",
  "exports": {
    ".":      "./dist/shaft.js",
    "./scss": "./lib/assets/stylesheets/shaft.scss",
    "./css":  "./dist/shaft.min.css"
  }
}
```

**Verify:**
```bash
node -e 'let p=require("./package.json");
  console.log("main:",p.main); console.log("sass:",p.sass); console.log("style:",p.style);
  process.exit(/\.js$/.test(p.main) && /\.scss$/.test(p.sass) ? 0 : 1)'
```

**Pass:** exit 0 — `main` is JS, `sass` is the `.scss` source, `style`/`./css` are the compiled CSS.
**Fail-gate:** `main` still a stylesheet → JS consumers break and theming stays ambiguous. Do not proceed.

---

## Step 2 — Make the SCSS source Dart-Sass-clean

**Do:** the source must compile under Dart Sass (node `sass` and host `dartsass-rails`). Convert `@import`→`@use`/`@forward`, mark every themeable var `!default`, remove Sprockets helpers (`image-url`/`asset-path`/`font-url`), directives, and `.erb`.

**Verify:**
```bash
# must return NOTHING:
grep -rnE 'image-url|asset-path|font-url|asset-data-url|//= ' lib/assets app/assets
find lib app -name '*.scss.erb' -o -name '*.css.erb'
# must COMPILE clean under Dart Sass:
npx sass lib/assets/stylesheets/shaft.scss /tmp/probe.css --load-path=lib/assets/stylesheets >/dev/null && echo "SASS OK"
```

**Pass:** both greps/find empty **and** `SASS OK` printed.
**Fail-gate:** any Sprockets helper remains, or Dart Sass errors — fix the source; these crash the host build later, in a worse place.

---

## Step 3 — Decide & implement `url()` ownership

**Do:** the rollup scss plugin bakes final `url()`s for `dist/`; Propshaft *also* rewrites `url()` to digested paths. Pick one owner (recommended: **Propshaft owns it**). Configure the scss plugin to emit **logical, namespaced, un-fingerprinted** refs — `url("shaft/logo.png")` — and copy images/fonts to matching logical names under `dist/` (`dist/shaft/…`).

**Verify:**
```bash
yarn build
# every url() in the shipped CSS must be a logical shaft/ path — no absolute, no host paths, no pre-digested hashes:
grep -oE 'url\([^)]*\)' dist/shaft.css | sort -u
grep -oE 'url\([^)]*\)' dist/shaft.css | grep -vE 'url\(["'\'']?(data:|shaft/)' && echo "BAD URLS ↑" || echo "URLS OK"
```

**Pass:** `URLS OK` — every non-data `url()` is a `shaft/…` logical path.
**Fail-gate:** any `BAD URLS` line — those won't resolve or will double-rewrite under Propshaft. Fix the plugin config and rebuild.

---

## Step 4 — Expose `lib/assets` + `dist` on the load path (both pipelines)

**Do:** neither `lib/assets` nor `dist` is auto-added to the asset path (only `app/assets/*` is). Add them from the engine, conditionally for each pipeline:
```ruby
# lib/shaft/engine.rb
initializer "shaft.assets" do |app|
  next unless app.config.respond_to?(:assets)
  %w[lib/assets/stylesheets dist].each { |d| app.config.assets.paths << root.join(d).to_s }
  app.config.assets.precompile << "shaft.css" if defined?(::Sprockets)   # legacy only
end
```

**Verify (Propshaft dummy under test/dummy-propshaft):**
```bash
cd test/dummy-propshaft
RAILS_ENV=production bin/rails assets:precompile
ls public/assets | grep -E 'shaft(\.min)?-[0-9a-f]+\.css'   # digested CSS present
bin/rails runner 'puts Rails.application.config.assets.paths.grep(/shaft/)'  # both paths listed
```

**Pass:** a digested `shaft*.css` appears in `public/assets` **and** both engine paths are listed.
**Fail-gate:** CSS missing from `public/assets` (the #1 "404 in prod" symptom) or paths absent — the initializer didn't take. Do not proceed.

---

## Step 5 — Decide JS output format vs. consumption

**Do:** `output: cjs` is correct **only** if hosts `import "shaft"` through their bundler. It will not run from a `javascript_include_tag`. Confirm how hosts load JS; if any load it via a Rails script tag, add an `iife`/`umd` output artifact (e.g. `dist/shaft.iife.js`).

**Verify:**
```bash
# how the fleet actually loads the gem's JS:
rg -n "javascript_include_tag.*shaft" ~/apps        # Rails-tag consumers (need iife/umd)
rg -n "import .*['\"]shaft['\"]|require\(['\"]shaft" ~/apps  # bundler consumers (cjs OK)
```

**Pass:** either (a) zero `javascript_include_tag` hits → keep CJS, or (b) an `iife`/`umd` artifact exists and builds for the tag consumers.
**Fail-gate:** tag consumers exist but only CJS is shipped → those pages get a non-executable module. Add the browser build first.

---

## Step 6 — Gemspec: deps and shipped files

**Do:** `propshaft` runtime dep (serves the gem's assets); remove `sprockets-rails`/`sassc-rails`; ensure `dist/**` (committed build output) is in `spec.files`.

**Verify:**
```bash
ruby -e 'require "rubygems"; s=Gem::Specification.load(Dir["*.gemspec"].first);
  dep=s.dependencies.map(&:name);
  abort "sprockets/sassc still present" if (dep & %w[sprockets-rails sassc-rails]).any?;
  abort "propshaft missing" unless dep.include?("propshaft");
  abort "dist not packaged" unless s.files.grep(%r{\Adist/}).any?;
  puts "GEMSPEC OK"'
```

**Pass:** `GEMSPEC OK`.
**Fail-gate:** any `abort` message — fix the gemspec; a gem that omits `dist/` ships broken to every host.

---

## Step 7 — Dual dummy-app verification (the real gate)

**Do:** prove one gem version works on **both** pipelines. Keep two dummy apps: `test/dummy-sprockets` (Rails 7 + Sprockets) and `test/dummy-propshaft` (Rails 8 + Propshaft + dartsass-rails). Each renders a page using the gem's CSS and (if applicable) JS.

**Verify (run for BOTH dummies):**
```bash
RAILS_ENV=production bin/rails assets:precompile
bin/rails server -e production -p 4000 & sleep 4
# CSS asset resolves (200) and referenced images/fonts resolve (200, not 404):
curl -sI localhost:4000/assets/$(ls public/assets | grep -m1 -E 'shaft.*\.css') | head -1
curl -s localhost:4000/ | grep -qi 'shaft' && echo "PAGE RENDERS SHAFT"
kill %1
```

**Pass:** on **both** dummies — CSS returns `200`, no `404` for its `url()` assets, page renders the gem's styles.
**Fail-gate:** any 404 (missing digest, unresolved `url()`, or JS format mismatch) on **either** pipeline. The gem is not dual-safe; return to the failing step.

---

## Step 8 — Lockstep version & release

**Do:** tag the rubygem and npm package at the **same** version from the same commit. Document the contract "server vX ⇄ frontend vX".

**Verify:**
```bash
test "$(ruby -e 'puts Gem::Specification.load(Dir["*.gemspec"].first).version')" \
   = "$(node -p 'require("./package.json").version')" && echo "VERSIONS LOCKSTEP"
```

**Pass:** `VERSIONS LOCKSTEP` — gemspec and package.json versions identical; both published from the tagged commit.
**Fail-gate:** version drift — an app could mix gem `1.4` server code with frontend `1.1`. Align before releasing.

---

## Done criteria for the whole gem upgrade

- [ ] `gem_scanner.sh` reports no Sprockets-isms in the SCSS source.
- [ ] `package.json` resolves JS/SCSS/CSS to three distinct, correct targets.
- [ ] Both dummy apps precompile and render with zero asset 404s.
- [ ] `dist/**` shipped; `propshaft` runtime; `sprockets-rails`/`sassc-rails` gone.
- [ ] Gem + npm published lockstep from one tag.

Once green, hosts migrate on their own schedule using `APP_UPGRADE_PLAN.md`.
