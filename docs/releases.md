# Runtime Releases And Tags

`twilic/twilic` is the canonical source for the Twilic specification, conformance material, and every language runtime. Package releases stay independent per runtime under `runtimes/<language>/`.

## Canonical Source

- Source of truth: [`twilic/twilic`](https://github.com/twilic/twilic)
- Runtime code: `runtimes/<language>/`
- Issues and pull requests: this monorepo only

Language-specific repositories such as `twilic/twilic-js` or `twilic/twilic-go` are not required for day-to-day development. New work lands here first.

## Tag Naming

Runtime release tags use the monorepo path prefix so Go nested-module resolution and GitHub Releases share one scheme:

```text
runtimes/<language>/v<semver>
```

Examples:

```text
runtimes/rust/v3.1.0
runtimes/javascript/v3.1.0
runtimes/go/v3.1.0
runtimes/python/v3.0.0
```

`<language>` matches the directory name under `runtimes/` (`javascript`, `csharp`, `cpp`, …).

Do not publish unprefixed tags such as `v3.1.0` for runtime packages. Unprefixed tags are reserved for future repository-wide protocol milestones if needed.

## GitHub Releases

Each runtime tag SHOULD create a GitHub Release on `twilic/twilic` whose title names the runtime and version, for example `javascript 3.1.0`. Release notes come from that runtime's `docs/CHANGELOG.md` (or equivalent) for the tagged version.

Do not link changelog footers to `releases/tag/runtimes/...` or `compare/runtimes/...` until those tags exist on this repository. Historical package versions from before the monorepo may lack matching tags; version headings in each changelog remain authoritative.

## Package Registries

Publishing remains per ecosystem. A typical flow:

```text
runtimes/<language>/** changed and version bumped
        ↓
tag runtimes/<language>/vX.Y.Z
        ↓
ecosystem publish (crates.io, npm, PyPI, …)
        ↓
GitHub Release for the same tag
```

Version numbers live in each runtime's package manifest. The git tag must match that manifest version.

## Ecosystem Notes

| Ecosystem | Install from monorepo | Notes |
| --- | --- | --- |
| Rust | crates.io when published; otherwise `git = "https://github.com/twilic/twilic.git"` (nested crate discovery) | Optional `tag = "runtimes/rust/vX.Y.Z"` |
| JavaScript | npm `@twilic/core`; git metadata uses `repository.directory` | Tags: `runtimes/javascript/vX.Y.Z`; `publish-npm.yml` not yet restored |
| Go | module `github.com/twilic/twilic/runtimes/go/v3` | Major versions require a `/vN` path suffix; tags remain `runtimes/go/vX.Y.Z` |
| Python | PyPI when published; URLs point at `runtimes/python` | Tags: `runtimes/python/vX.Y.Z` |
| Java / Kotlin / Scala | Maven coordinates when published; SCM URLs point at this monorepo | Tags: `runtimes/<language>/vX.Y.Z` |
| Ruby | RubyGems when published; `source_code_uri` points at `runtimes/ruby` | Tags: `runtimes/ruby/vX.Y.Z` |
| Dart | `git` + `path: runtimes/dart` supported | Tags: `runtimes/dart/vX.Y.Z` |
| Lua | `luarocks make` from `runtimes/lua` until `runtimes/lua/vX.Y.Z` exists | Rockspec must not point at missing tag archives |
| Elixir | `git` + `sparse: "runtimes/elixir"` when using Mix git deps | Tags: `runtimes/elixir/vX.Y.Z` |
| Swift | SwiftPM requires `Package.swift` at the repository root | Until an automated mirror exists, depend on a local path checkout of `runtimes/swift` |

### Optional publish mirrors

Some package managers (notably SwiftPM) cannot consume a nested package path from a remote git URL. For those ecosystems, maintainers MAY add thin automated mirrors that sync only `runtimes/<language>/` to a dedicated repository at release time. Mirrors are distribution adapters, not alternate sources of truth.

## Changing A Runtime Version

1. Update the version in the runtime manifest and changelog.
2. Land the change on `main` through the normal review process.
3. Create and push `runtimes/<language>/vX.Y.Z`.
4. Run the ecosystem publish workflow (when present) and confirm the GitHub Release.
