# Decision Record: SCSS/JS Stack for the Engine Gem Across the Rails 8 + Vite Migration

How we arrived at "move the SCSS into the internal npm package." Captures the
forks considered and why each was kept or dropped, so the reasoning survives the
conversation.

## Context

- A custom legacy **Sprockets-based Rails Engine gem**, consumed by **many Rails
  7.x apps** currently on **Sprockets + Webpacker/Shakapacker**.
- The fleet is prepping for **Rails 8 + Vite**, rolling out **per-app over
  months**. The gem must work with **both legacy and upgraded apps at the same
  time**.
- Hard requirement surfaced early: **consumers import the gem's SCSS modules and
  override Sass `$variables` at their own build** (compile-time theming).

---

## Fork 1 — How does the gem hand SCSS to a Propshaft app?

**Considered:** ship precompiled CSS vs. ship raw SCSS + let the host compile.

**Decision:** ship **raw SCSS**; host compiles. Precompiled CSS can't be
re-themed, and consumers override variables.

**Confirmed via docs:** `dartsass-rails` adds every `config.assets.paths` entry as
a Sass load path, and a Rails Engine auto-appends its `app/assets/stylesheets`.
So a Propshaft+dartsass host resolves `@use "gem/…"` with **no load-path config**.

This was correct — but only for the **Ruby-side** pipeline. It didn't yet account
for the node bundlers the apps actually run.

---

## Fork 2 — The real constraint: two migrations crossing two compiler families

Two independent migrations, per-app, in any order:

- CSS pipeline: **Sprockets → Propshaft**
- JS/asset bundler: **Webpacker/Shakapacker → Vite**

The trap: imports resolve **completely differently** on each side.

| Resolves imports via | Pipelines |
| --- | --- |
| **Ruby asset load paths** (engine auto-adds) | Sprockets, Propshaft + dartsass-rails |
| **Node module resolution** (`node_modules`) | Webpacker, Shakapacker, **Vite** |

A Rails engine's `app/assets` is automatic on the Ruby side but **invisible to
node bundlers**. So no single "put files in `app/assets`" answer covers all four
pipelines. The gem has to speak both worlds.

**Leverage identified:** the JS is *already* node-bundled, and Vite is *also* a
node bundler — so an **npm package is the through-line**. The specifier
`@yourorg/pkg` is identical under Shakapacker today and Vite tomorrow; the
Webpacker→Vite hop becomes an app-side config change with **zero gem changes**.

---

## Fork 3 — Evaluating the Avo "support both from an engine" pattern

Reviewed: <https://avohq.io/blog/support-sprockets-and-proshaft-from-rails-engines>

**What it does:** the gem **self-bundles** its CSS/JS (cssbundling/jsbundling) and
ships **compiled** files in `app/assets/builds/`; a conditional `engine.rb`
(`if defined?(::Sprockets)` / `if app.config.respond_to?(:assets)`) registers with
whichever pipeline is present. Elegant for the **Sprockets ↔ Propshaft axis** —
the host needs no Sass toolchain at all.

**Why it doesn't fit us:**
1. It ships **compiled CSS**, which **kills Sass-variable theming** — our hard
   requirement. Avo's admin UI is self-contained and not re-themed by consumers,
   so it can precompile; we can't.
2. It's **silent on Webpacker/Shakapacker/Vite** — it sidesteps node bundlers by
   self-bundling, which does nothing for consumers importing *source* into their
   own build.

**Reconciliation noted:** if theming could move to **CSS custom properties**
(runtime `--primary`), the Avo model would become the *simplest* option (one
artifact, every pipeline). We explicitly rejected that path because the gem needs
**compile-time Sass** at the consumer level.

---

## Fork 4 — Given SCSS-as-source is required, how to deliver it?

| Option | Ruby-side (Sprockets/dartsass) | Node-side (Shakapacker/Vite) | Verdict |
| --- | --- | --- | --- |
| **A. Rubygem asset path** | ✅ automatic | ❌ can't see it | Ruby-pipeline apps only |
| **B. npm package** | ⚠️ needs `node_modules` on Sass load path (awkward for dartsass) | ✅ native, stable specifier | Every node-bundler app + Vite goal |
| **C. Dual channel (A+B)** | ✅ | ✅ | Covers everything; most to maintain |
| **D. Point node bundler `loadPaths` at gem's Ruby path** | — | ✅ but brittle (dynamic `bundle show` path) | Not worth it at fleet scale |

**Decision:** standardize on **"the gem's CSS is compiled by the node bundler in
every app"** and ship **Option B (npm)**. It reaches the goal with the least
maintenance: all apps already have a node bundler, Vite is one too, and it
sidesteps the Ruby-vs-node split by never compiling gem CSS in the Rails pipeline.
Keep Option A only as a temporary bridge for stragglers.

---

## Fork 5 — Distributing an *internal* npm package

**Considered:** git dependency (tag-pinned) vs. private registry (GitHub
Packages / CodeArtifact / Verdaccio) vs. monorepo workspace.

**Key fact:** SCSS is **source** — it ships as-is, no build/transpile — so no
publish pipeline is strictly required; installing tagged files privately is enough.

Then the situation simplified further: **the apps already consume an internal npm
package** through their node bundler. So distribution is already solved — the move
becomes **adding the SCSS as a subpath of the existing package**, not standing up
anything new.

---

## Final decision

- **Move the SCSS into the internal npm package the apps already consume**, as a
  `./scss/*` subpath export. Steps in `SCSS_TO_NPM_MIGRATION.md`.
- **Compile it in the node bundler in every app** — one consumption model,
  identical specifier across Shakapacker → Vite.
- **Rubygem carries Ruby only** (engine, helpers, views); versioned in **lockstep**
  with the npm package from the same repo.
- **Dual-ship the SCSS for one release** (gem asset path + npm) so apps migrate
  independently over months, then delete it from the gem.

**Net effect:** the gem's CSS leaves the Rails asset pipeline entirely, so
Sprockets → Propshaft stops touching it, and Shakapacker → Vite needs no gem or
import change.

---

## Fork 6 — Vite via `rails_vite`: JS and CSS travel on different tracks

Evaluated <https://github.com/skryukov/rails_vite> (leaner than `vite_rails` —
no Rack proxy, no `config/vite.json`, config in `vite.config.ts`; runs
**alongside** the asset pipeline, builds to its own `public/vite/` manifest).

**Key finding:** it's a *JS* decision, not a CSS one. It resolves imports through
**node module resolution** and its docs don't address engines/gems, so a Vite
build **cannot see the engine's `lib/assets`** (the Ruby-channel load path that
`dartsass-rails` reads). It neither solves nor simplifies engine-SCSS delivery —
it only *forces* the npm channel for any host that compiles the engine CSS in Vite.

**Because it runs alongside the pipeline, the clean split is to let the two
concerns ride different tracks on the same host:**

| Concern | Track |
| --- | --- |
| App's own JS (+ optionally app CSS) | `rails_vite` → `public/vite/` |
| **Shaft engine's SCSS** | `dartsass-rails` + Propshaft (Ruby channel — the `lib/assets` setup) |

**Decision:** adopting `rails_vite` (or any Vite integration) is a **JS-only**
choice and is compatible with keeping the engine's CSS on the dartsass/Propshaft
track — the engine migration doesn't change. Only move the engine's SCSS into
Vite if the host commits to compiling **all** CSS in the node bundler, which means
the npm channel (Fork 4, Option B). The deciding question is unchanged: *does the
host compile the engine's CSS in Rails or in a node bundler?* `rails_vite` affects
only the JS answer.

---

## Ruled out (and why)

- **Precompiled CSS in the gem (Avo pattern):** breaks compile-time Sass theming.
- **Asset-path-only (Option A) as the permanent model:** invisible to node bundlers.
- **CSS custom properties instead of Sass vars:** would enable the simplest model,
  but the consumers require compile-time Sass.
- **`loadPaths` bridge (Option D):** brittle dynamic gem path across dev/CI/deploy.
- **Flag-day cutover:** incompatible with a per-app, multi-month rollout.

---

## Related docs

- `SCSS_TO_NPM_MIGRATION.md` — the concrete move (chosen path).
- `SPROCKETS_TO_PROPSHAFT_MIGRATION.md` — gem-side pipeline migration (Ruby channel).
- `CONSUMER_APP_MIGRATION.md` — host app Sprockets → Propshaft + dartsass, incl. JS.
