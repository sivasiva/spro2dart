# Consumer App Migration: Sprockets → Propshaft + dartsass-rails (Rails 7)

Steps for a **Rails 7 application** that depends on the engine gem, when the gem
moves from Sprockets to Propshaft + Dart Sass. The gem now ships raw `.scss`
partials; your app compiles them. This is what changes on your side.

## What actually changes

- You swap the asset pipeline: `sprockets-rails` → `propshaft`.
- You add `dartsass-rails` to compile SCSS (yours + the gem's `@use`d modules).
- Compiled CSS now lands in `app/assets/builds/` and is served digested by Propshaft.
- Propshaft **does not** run directives, ERB, or transpilation — anything relying
  on those must move.

---

## Step 1 — Gemfile

```ruby
# Gemfile

# REMOVE:
#   gem "sprockets-rails"
#   gem "sassc-rails"
#   gem "sass-rails"

# ADD:
gem "propshaft"
gem "dartsass-rails"
```

```bash
bundle install
```

Removing `sprockets-rails` is what deactivates Sprockets — having `propshaft` in
the Gemfile makes it the pipeline. If your `config/application.rb` uses
`require "rails/all"`, no change needed; if it cherry-picks railties, ensure
`require "sprockets/railtie"` is gone.

---

## Step 2 — Delete Sprockets config & artifacts

- [ ] Delete `app/assets/config/manifest.js`.
- [ ] Remove these from `config/environments/*.rb` and `application.rb` — Propshaft
      always digests and has no compile step, so they no longer exist:
  ```ruby
  config.assets.compile      = ...
  config.assets.precompile  += ...
  config.assets.debug        = ...
  config.assets.digest       = ...
  config.assets.version      = ...
  config.assets.css_compressor = ...   # use --style=compressed in dartsass instead
  config.assets.js_compressor  = ...
  ```
- [ ] Remove `//= require`, `//= require_tree`, `//= link` directives from any
      remaining `.css`/`.js` files.
- [ ] Rename `*.css.erb` / `*.scss.erb` → drop `.erb`; Propshaft won't process it.

---

## Step 3 — Configure the Sass build

```ruby
# config/initializers/dartsass.rb
Rails.application.config.dartsass.builds = {
  "application.scss" => "application.css"
}
```

```scss
// app/assets/stylesheets/application.scss
// Import the gem's modules — the engine's stylesheets dir is auto-added to the
// Sass load path, so no path config is needed. Override variables here:
@use "my_engine/variables" with ($primary: #c00);
@use "my_engine/components/button";

// ...your own styles
```

> If you're on the gem's legacy `@import` convention, set overridable variables
> **before** the import instead of `@use ... with`.

---

## Step 4 — Compiled output directory

```bash
mkdir -p app/assets/builds
```

```gitignore
# .gitignore
/app/assets/builds/*
!/app/assets/builds/.keep
```
```bash
touch app/assets/builds/.keep
```

Propshaft auto-adds `app/assets/builds` to the asset paths; `dartsass:build`
writes `application.css` there, Propshaft serves it digested.

---

## Step 5 — View reference

`stylesheet_link_tag` is unchanged; it now resolves the compiled build:

```erb
<%= stylesheet_link_tag "application" %>
```

`image_tag`, `asset_path`, `favicon_link_tag` all still work under Propshaft.
Note Propshaft **raises on a missing asset** — that's a correctness win, but it
will surface any stale reference immediately.

---

## Step 6 — Dev workflow

Compile on change during development. If you use `bin/dev` + `Procfile.dev`:

```procfile
# Procfile.dev
web: bin/rails server
css: bin/rails dartsass:watch
```

Otherwise run `bin/rails dartsass:watch` in a second terminal. One-off build:
`bin/rails dartsass:build`.

---

## Step 7 — Deployment / precompile

No command change: `dartsass-rails` hooks `dartsass:build` in as a prerequisite of
`assets:precompile`, so your existing deploy step still works:

```bash
RAILS_ENV=production bin/rails assets:precompile
```

Order: Dart Sass compiles `application.scss` → `app/assets/builds/application.css`,
then Propshaft digests everything on the load path into `public/assets`.

---

## Step 8 — Sweep for Sprockets assumptions

Things that silently worked under Sprockets and now break:

- [ ] **Sass asset helpers** anywhere in *your* SCSS: `image-url`, `asset-path`,
      `font-url` don't exist in Dart Sass → use `url("logo.png")` (Propshaft
      rewrites the digest).
      ```bash
      grep -rnE 'image-url|asset-path|font-url|asset-data-url' app/assets
      ```
- [ ] **`Rails.application.assets`** / `Sprockets::…` API calls in initializers or
      code → gone under Propshaft.
- [ ] **Other gems that assumed Sprockets** (e.g. a Bootstrap gem via `sassc`) →
      import via `@use "bootstrap/scss/bootstrap"` instead of a `//= require`.
- [ ] **JS that relied on Sprockets bundling/ES transpilation** → Propshaft does
      neither; move JS to `importmap-rails` or `jsbundling-rails`. (CSS migration
      doesn't force this, but flag it if you were leaning on Sprockets for JS.)

---

## Verification checklist

- [ ] App boots: `bin/rails runner 'puts Rails.application.assets.class' ` errors
      (Sprockets gone) — expected.
- [ ] `bin/rails dartsass:build` exits 0 and writes `app/assets/builds/application.css`.
- [ ] Page loads with styles in dev (`bin/dev`).
- [ ] `RAILS_ENV=production bin/rails assets:precompile` succeeds; digested CSS
      appears in `public/assets`.
- [ ] No `image-url`/`asset-path`/`font-url` left in `app/assets`.
- [ ] No `config.assets.precompile` / `manifest.js` references remain.

---

## TL;DR

Swap `sprockets-rails` → `propshaft`, add `dartsass-rails`, delete the Sprockets
config + `manifest.js`, point `config.dartsass.builds` at `application.scss`,
`@use` the gem's modules (no load-path config needed), and add a
`dartsass:watch` line to `Procfile.dev`. Deploy command is unchanged.
