# Moving the Gem's SCSS Modules to the Internal npm Package

Guide for relocating the Rails Engine gem's SCSS out of the Rails asset pipeline
and into the **internal npm package the consumer apps already consume** via their
node bundler (Webpacker/Shakapacker today, Vite later).

Because the apps already pull that package in, this is mostly moving files and
repointing imports — no new distribution to stand up. Add the SCSS as a **subpath
of the existing package** rather than creating a new one: one version bump, no new
registry entry.

## Why do this

- The gem's CSS leaves the Rails asset pipeline entirely, so the
  **Sprockets → Propshaft** migration stops touching it.
- Consumers compile it in their node bundler, so the **Shakapacker → Vite** hop
  needs no gem or import changes — the `@use "@yourorg/pkg/scss/…"` specifier is
  identical on both.
- Compile-time theming (Sass `$variable` overrides) keeps working, because
  consumers still get the **source**, now from `node_modules`.

---

## Step 1 — Move the SCSS source into the package

- Copy the gem's `app/assets/stylesheets/<gem>/**` → the package's `src/scss/`.
- Keep the namespace; underscore-prefix partials (`_button.scss`).
- Add one entrypoint `src/scss/index.scss` that `@forward`s the public API.

```
<pkg>/src/scss/
  index.scss            # @forward "variables"; @forward "components/button"; ...
  _variables.scss
  components/_button.scss
```

---

## Step 2 — Make the SCSS node-Sass-clean

Compilation is now node-side (`sass` / sass-loader), not `sassc`. Fix the
Sprockets-isms that only worked under sassc-rails:

- `@import` → `@use` / `@forward`.
- Every themeable variable gets `!default` so `@use … with (…)` works:
  ```scss
  $primary: #0055ff !default;
  ```
- **Remove Sprockets Sass helpers** — they don't exist in node Sass:
  ```bash
  grep -rnE 'image-url|asset-path|font-url|asset-data-url' src/scss
  ```
  Replace with `url()`.
- **Asset references:** point them relative to the scss file so the bundler
  fingerprints them, and move those assets into the package:
  ```scss
  // was: background: image-url("logo.png");
  background: url("../images/logo.png");
  ```
  Anything you can't resolve cleanly, expose as a `!default` variable the app supplies.

---

## Step 3 — Expose it via `package.json`

Add the SCSS as a subpath export on the package the apps already depend on:

```jsonc
{
  "version": "1.4.0",
  "exports": {
    "./scss/*": "./src/scss/*",
    "./scss": "./src/scss/index.scss"
  },
  "files": ["src/scss", "src/images"]
}
```

---

## Step 4 — Repoint each consumer app

In the app's pack / stylesheet entry, replace the old gem asset-path import with
the npm import plus overrides:

```scss
// before (gem asset path):  @import "my_engine/application";
@use "@yourorg/pkg/scss/variables" with ($primary: #c00);
@use "@yourorg/pkg/scss";
```

- Confirm that stylesheet is actually imported by the pack entry (and rendered via
  `stylesheet_pack_tag`).
- Bump the package version the app depends on. Since they already consume it, this
  is a `yarn upgrade`, not a new install.

---

## Step 5 — Strip CSS from the rubygem

- Delete `app/assets/stylesheets/<gem>/**`.
- Remove `sassc-rails` / `sass-rails` from the gemspec — the gem no longer compiles CSS.
- Drop the gem's `manifest.js` CSS lines and any `//= require` of it.
- The rubygem now carries **Ruby only** (engine, helpers, views).

---

## Step 6 — Lockstep the versions

Keep the rubygem and the npm package in the **same repo**, tag once, publish both
at the same version. Document the compatibility contract: server code `vX` pairs
with UI `vX`, so an app never mixes gem `1.4` with frontend `1.1`.

---

## Transition strategy (many apps, over months)

Don't flag-day this. **Dual-ship for one release:**

1. Keep the SCSS on the gem's asset path **and** in the npm package for a version.
2. Each app flips its import from the gem path to `@yourorg/pkg/scss` on its own
   schedule (independent of its Sprockets→Propshaft or Shakapacker→Vite work).
3. Once every app is moved, do Step 5 and delete the asset-path copy from the gem.

This matches a per-app, multi-month cadence and never blocks an app that hasn't
migrated yet.

---

## What this does to each pipeline

| Pipeline | Effect |
| --- | --- |
| Webpacker / Shakapacker (today) | sass-loader resolves `@yourorg/pkg/scss/…` from `node_modules` — works immediately |
| Vite (later) | identical specifier, no change on the Shakapacker→Vite hop |
| Sprockets / Propshaft | no longer compiles this CSS at all — only serves the bundler's output + static assets |

---

## Verify per app

- [ ] Bundler build succeeds; gem styles render.
- [ ] A variable override (`with ($primary: …)`) visibly takes effect.
- [ ] `grep -rE 'image-url|asset-path|font-url' src/scss` returns nothing.
- [ ] Gem no longer ships stylesheets: `gem contents <gem> | grep stylesheets` is empty.

---

## TL;DR

Move the SCSS into `src/scss/` of the package the apps already consume, expose it
as a `./scss/*` subpath export, make it node-Sass-clean (`@use` + `!default`, no
Sprockets helpers), repoint each app's import from the gem asset path to
`@yourorg/pkg/scss`, then delete the SCSS from the rubygem. Dual-ship for one
release so apps migrate independently.
