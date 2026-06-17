# Migrate the package index to the Homebrew 6.0 cache layout

## Why

Homebrew 6.0 removed the public combined JWS index files
(`~/Library/Caches/Homebrew/api/formula.jws.json` and
`cask.jws.json`) that the Brew Package Manager read to build its
package universe. The package-manager window now shows the loading
spinner and then an empty universe in every list, because the path
resolver finds neither file and the loader composes from an empty
entry set.

6.0 ships a single consolidated, platform-specific file instead:

```
~/Library/Caches/Homebrew/api/internal/packages.<bottle_tag>.jws.json
```

e.g. `packages.arm64_tahoe.jws.json`. The format also changed:

| | old `formula.jws.json` | new `internal/packages.*.jws.json` |
|---|---|---|
| payload | top-level **array** of DTOs | **object**: `{metadata, formulae, casks, …}` |
| `formulae` / `casks` | — | **dicts keyed by name/token**, not arrays |
| per-entry fields | `name`, `full_name`, `tap`, `desc` | key *is* the name; entries carry no `name`/`tap`; casks carry `tap_string` |

The internal index covers `homebrew/core` + `homebrew/cask` only.
Third-party taps continue to flow through the Steading-owned
tap-cache (`brew info --json=v2` → `parseInfoEnvelope`), which is
unaffected — so there is no universe-coverage loss.

## Scope: brew 6 only

We drop old-format support entirely rather than carrying both. No
fallback to `formula.jws.json` / `cask.jws.json`.

## Decisions

- **Glob, don't compute the bottle tag.** The default resolver
  enumerates `…/api/internal/` for `packages.*.jws.json` and returns
  the single match. Avoids hardcoding a macOS-codename → version map
  that would need touching every macOS release.
- **Single combined parse.** `parsePackagesIndex` returns formulae +
  casks together; the loader calls it once rather than once per kind.
- **Deterministic order.** Dict decode order is unstable, so entries
  are sorted (by `fullToken`, formulae then casks) for stable rows
  and reproducible tests.

## Changes

### Production
- [ ] `BrewIndexParser`: remove `parseJWSFormulae` / `parseJWSCasks`;
  add `parsePackagesIndex(_:)` for the new payload object. Keep
  `parseInfoEnvelope` and `unwrapJWSPayload`.
- [ ] `BrewPackageManager`: replace `JWSCachePathResolver`
  (`(Kind) -> URL?`) with `PackagesIndexPathResolver` (`() -> URL?`);
  default globs the `internal/packages.*.jws.json` file. Collapse the
  two `readJWSEntriesAsync(kind:)` calls into one
  `readPackagesIndexAsync()`.

### Tests (exercise production code; live tests hit the real file)
- [ ] `BrewIndexParserTests`: replace JWS array tests with
  object-shape tests.
- [ ] `BrewJWSCacheLiveTests`: read the real `internal/packages.*`
  file via glob, parse through `parsePackagesIndex`.
- [ ] `BrewPackageManagerRefreshTests`: new payload shape + single
  resolver/URL across all three tests.

## Progress log

- Branch cut from `main`. Diagnosed root cause (brew auto-updated to
  6.0.2 today; old cache files gone).
- Parser + resolver + tests migrated; full suite green, live test
  parses the real 15 MB internal index in ~0.2s. Committed + pushed.
- Startup preload: the first parse is multi-second, so the universe is
  now warmed in the app's launch `.task`
  (`brewPackages.refresh(outdated:)`). `brewPackages` outlives every
  window, and the table renders `rows` under a `.loading` overlay
  rather than blanking, so the Brew Package Manager window opens warm
  and the existing on-open `.task(id:)` reload is a non-blocking
  refresh. Only the one preload line was staged from `SteadingApp.swift`
  — the in-flight service-definition edits in that file stay uncommitted.
</content>
</invoke>
