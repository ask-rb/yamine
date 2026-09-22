# Versioning — yamine

This file is this repository's **canonical versioning policy**. When
anything else in the repo (README, RELEASE.md, CONTRIBUTING.md, commit
messages) disagrees with it, this file wins.

## Semantic Versioning

Versions are `MAJOR.MINOR.PATCH`, following
[Semantic Versioning 2.0.0](https://semver.org):

- **PATCH** — backwards-compatible bug fixes only.
- **MINOR** — backwards-compatible new functionality.
- **MAJOR** — breaking changes.

### Pre-1.0 (0.x.y)

While the major version is `0`, the public API is not frozen:

- **0.x.PATCH** — bug fixes.
- **0.x.MINOR** — new functionality, *or* any change that would be breaking
  at 1.0 (removing/renaming public API, changing defaults or behavior).
  Pre-1.0, MINOR carries the breaking changes — there is no separate major
  bump until 1.0.0.
- **1.0.0** — first stable release; from here MAJOR/MINOR/PATCH mean exactly
  what SemVer says.

### Sequential one-step patch increments

Patch numbers advance by exactly one per release: `0.15.1` → `0.15.2` →
`0.15.3`. Never skip or jump patch numbers (`0.15.1` → `0.15.4` is wrong),
even when several fixes ship together — they ship as a single release with a
single patch number. The same one-step rule applies to minor and major.

## Changelog workflow (Unreleased)

- `CHANGELOG.md` keeps an `## [Unreleased]` section at the top.
- Every user-facing change lands under `Unreleased` in the same commit/PR
  that introduces it, using Keep a Changelog headings (`Added`, `Changed`,
  `Fixed`, `Removed`).
- At release time, rename `## [Unreleased]` to `## [X.Y.Z] — YYYY-MM-DD` and
  open a fresh empty `## [Unreleased]` above it.

## All releases go through gemchain

`yamine` is part of the gemchain cascade (`cascade.yml` includes it alongside
the `ask-*` gems), so **every** release runs through **gemchain** from the
workspace root — never `rake release`, never a hand-run `gem build` /
`gem push`:

```bash
cd /Users/kaka/Code/ask-rb
gemchain guard yamine
gemchain update yamine <new-version> --dry-run
gemchain update yamine <new-version>
```

gemchain bumps the version, runs the tests, publishes, rewrites dependent
gems' constraints, and cascades their releases in topological order.

**gemchain itself** is not a cascaded gem, so the cascade cannot release it.
It follows the same release discipline manually: bump `VERSION`, update the
changelog, run tests, commit, `gem build` + `gem push`, `git tag`, push —
then `gem install gemchain` to refresh the installed binary.

## Dependency releases use the gemchain cascade

When a release changes a dependency constraint for other gems, gemchain
cascades: each dependent gets its constraint rewritten, its tests run, and a
cascade-level release published (patch by default, per `cascade.yml`), in
dependency order. Never release dependents by hand to "keep up."

## Clean tree required

A release starts from a clean tree. `git status --porcelain` must be empty
before `gemchain update` — commit or stash work-in-progress first. gemchain
commits the release's own changes (version.rb, gemspec constraint,
lockfile) as part of the release. A release is only done when it is
**published and its commit is pushed**.

## Release checklist

1. Tree clean — `git status --porcelain` is empty.
2. Tests pass — `bundle exec rake test` (optionally `rake test:e2e` for the
   heavy end-to-end suite).
3. Build passes — `bundle exec rake build` (or `gem build yamine.gemspec`).
4. Changelog — `Unreleased` entries moved under the new `X.Y.Z` heading with
   the release date.
5. Version — bumped in `lib/yamine/version.rb` by gemchain, not by hand.
6. Commit — created (gemchain does this as part of the release).
7. Tag — `vX.Y.Z` created.
8. Publish — pushed to RubyGems inside gemchain.
9. Push — commit and tag pushed (`git push origin HEAD --tags`).
10. Verify — see "Version agreement" below.

## Version agreement

After every release these must all say the same thing:

| Source | Must equal |
|---|---|
| Published version on RubyGems | `X.Y.Z` |
| `lib/yamine/version.rb` at HEAD | `X.Y.Z` |
| Git tag | `vX.Y.Z` |
| Source committed **and** pushed | yes |

If the published version and the committed source disagree, the release is
orphaned (published but never committed). Fix it by running the tests, then
committing and pushing the version/changelog changes.

## Examples

- Bug fix only: `0.15.1` → `0.15.2`.
- Several bug fixes ship together: one release, `0.15.1` → `0.15.2` (never
  `0.15.4`).
- New backwards-compatible API: `0.15.2` → `0.16.0`.
- Breaking change while pre-1.0: `0.16.0` → `0.17.0`, with a `Changed` /
  `Removed` changelog entry calling out the break.
- First stable release: `0.9.x` → `1.0.0`.
- This gem bumped because a dependency released: patch only, e.g. `0.15.2` →
  `0.15.3`, via the gemchain cascade — never hand-published.
