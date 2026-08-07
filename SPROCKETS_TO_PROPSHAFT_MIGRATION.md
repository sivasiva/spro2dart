# Migrating a Rails Engine Gem: Sprockets → Propshaft + dartsass-rails

Guide for a **Rails Engine gem** whose SCSS modules are `@use`/`@import`ed by
consumer applications. The host app compiles the gem's Sass (so it can override
variables); the gem ships raw `.scss` partials, not precompiled CSS.

## Key facts that shape this migration

- **Propshaft does not compile anything.** It digests and serves static files.
  All `.scss` → `.css` compilation happens in the **host app** via `dartsass-rails`.
- **No load-path wiring needed.** `dartsass-rails` adds every path in
  `Rails.application.config.assets.paths` as a Sass load path, and a Rails Engine
  already appends its `app/assets/stylesheets` to that list. Consumers can
  `@use "my_engine/..."` out of the box.
- **The gem depends on `propshaft`** (to serve its own images/fonts), **not** on
  `dartsass-rails` — that's the host's toolchain. Document it as a host requirement.

---

## Step 1 — Dependencies

```ruby
# my_engine.gemspec
spec.add_dependency "propshaft"

# dartsass-rails is a DEV dependency (for the dummy app / CI), not runtime:
spec.add_development_dependency "dartsass-rails"

# REMOVE:
#   spec.add_dependency "sprockets-rails"
#   spec.add_dependency "sassc-rails"
#   spec.add_dependency "sass-rails"
```

Remove any `require "sprockets/railtie"` from `lib/my_engine/engine.rb`.

---

## Step 2 — Delete Sprockets artifacts

- [ ] Delete `app/assets/config/manifest.js` — Propshaft ignores it entirely.
- [ ] Remove all directive comments: `//= require`, `//= require_tree`,
      `//= require_self`, `//= link`, `//= link_tree`, `//= link_directory`.
- [ ] Remove `config.assets.precompile += [...]` lines — Propshaft auto-serves
      everything on the load path; there is no precompile allowlist.
- [ ] Rename `*.scss.erb` → `*.scss` and strip the ERB (Dart Sass can't run ERB).

---

## Step 3 — Restructure stylesheets into partials

Namespace everything under `my_engine/` to avoid host collisions.

```
app/assets/stylesheets/my_engine/
  _variables.scss          # configurable vars — all marked !default
  _mixins.scss
  components/
    _button.scss
    _card.scss
```

- Partials **must** be underscore-prefixed (`_button.scss`).
- Do **not** register a `config.dartsass.builds` entry in the engine — partials
  are not standalone build targets. The host owns builds.

---

## Step 4 — Make variables overridable (`!default`)

The reason consumers import your SCSS is to override values. Use the Dart Sass
module system:

```scss
// my_engine/_variables.scss
$primary:   #0055ff !default;   // !default makes it host-overridable
$radius:    0.5rem  !default;
$font-stack: system-ui, sans-serif !default;
```

Consumer overrides at import time:

```scss
// host: app/assets/stylesheets/application.scss
@use "my_engine/variables" with ($primary: #c00);
@use "my_engine/components/button";
```

> If you stay on the legacy `@import` + global `!default` pattern instead, the
> consumer must set the variable **before** importing. Pick one convention and
> document it — don't mix.

---

## Step 5 — Replace Sprockets Sass helper functions

These are **Sprockets extensions and do not exist in Dart Sass** — they crash the
host's build:

| Sprockets (remove)              | Dart Sass / Propshaft (use)          |
| ------------------------------- | ------------------------------------ |
| `image-url("my_engine/x.png")`  | `url("my_engine/x.png")`             |
| `asset-path("my_engine/x")`     | `url("my_engine/x")`                 |
| `font-url("my_engine/x.woff2")` | `url("my_engine/x.woff2")`           |
| `asset-data-url(...)`           | inline the data URI, or use `url()`  |

Grep to find them all:

```bash
grep -rnE 'image-url|asset-path|font-url|asset-data-url|image-path|font-path' app/assets
```

**Use full logical paths in `url()`** — `url("my_engine/logo.png")`, not
`url("logo.png")`. The host compiles into *its* `app/assets/builds`, and Propshaft
rewrites `url()` against the **host's** load paths (which include your engine's
`app/assets/images`). A bare relative path won't resolve; the namespaced logical
path will.

---

## Step 6 — JavaScript (if the engine shipped JS via `//= require`)

Propshaft does not bundle JS. Options, laziest first:

- **Ship one pre-bundled file** at `app/assets/builds/my_engine/application.js`,
  reference with `javascript_include_tag "my_engine/application"`. Simplest.
- **Provide importmap pins** from the engine (only if hosts use importmap-rails):

  ```ruby
  # lib/my_engine/engine.rb
  initializer "my_engine.importmap", before: "importmap" do |app|
    app.config.importmap.paths << Engine.root.join("config/importmap.rb")
  end
  ```
- **Let the host bundle it with jsbundling-rails** — if your JS needs a real build
  (npm deps, JSX/TS), ship raw ES modules and have each consumer app run
  `bin/rails javascript:install:esbuild`, then `import "my_engine/..."` from its
  `app/javascript/application.js`. Full host steps are in
  `CONSUMER_APP_MIGRATION.md` (Step 9). Publish the JS as an npm package (or vendor
  it) so esbuild can resolve the import.

---

## Step 7 — Consumer app integration (document this)

In the host app's Gemfile the app needs `propshaft` + `dartsass-rails`. Then:

```ruby
# host: config/initializers/dartsass.rb
Rails.application.config.dartsass.builds = {
  "application.scss" => "application.css"
}
```

```scss
// host: app/assets/stylesheets/application.scss
@use "my_engine/variables" with ($primary: #c00);
@use "my_engine/components/button";
@use "my_engine/components/card";
```

```erb
<%= stylesheet_link_tag "application" %>
```

No engine-side load-path config required — see the "Key facts" note above.

---

## Step 8 — Ship a dummy app + CI check

Add a minimal app under `test/dummy` that actually `@use`s your modules, and run
the real compile in CI so a broken import surfaces in *your* pipeline, not a
consumer's:

```bash
cd test/dummy
bin/rails dartsass:build            # must exit 0
RAILS_ENV=production bin/rails assets:precompile   # verify prod digesting
```

---

## Verification checklist

- [ ] `grep -rn '//= ' app/assets` returns nothing (no directives left).
- [ ] `app/assets/config/manifest.js` is gone.
- [ ] `grep -rnE 'image-url|asset-path|font-url'` returns nothing.
- [ ] Configurable variables are all `!default`.
- [ ] All `url()` references use `my_engine/`-prefixed logical paths.
- [ ] Raw `.scss` partials are included in the gem (`spec.files` / gemspec glob).
- [ ] Dummy app's `dartsass:build` and prod `assets:precompile` both pass in CI.

---

## What this migration mostly is

Deletion (manifest, directives, precompile lists, `sassc-rails`) + a `!default`
variables refactor + a `url()` path sweep. There's no load-path plumbing to
write — Rails Engine + dartsass-rails handle discovery automatically.
