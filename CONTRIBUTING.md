# Contributing to SwiftIT

Thanks for the interest. SwiftIT is a focused library. The bar is "ships clean, doesn't regress, stays minimal." Patches that match that bar are welcome.

## Running the tests

```sh
swift test
```

The test target uses Swift Testing (the `import Testing` framework), not XCTest. Tests live in `Tests/SwiftITTests/`. Add a test for any behavioral change. The suite is small enough that adding a case or two is cheap and forces you to articulate intent.

```sh
swift build
swift build -c release
```

## Commit style

Conventional commits in `action(noun): verb` form, lowercase, imperative mood:

```
feat(mixer): implement tone portamento volume slide (Lxx)
fix(parser): handle 0-pointer pattern entries without crashing
docs(readme): clarify sample-compression status
test(parser): cover delta-decoded 16-bit samples
refactor(envelope): hoist point interpolation into a helper
```

Keep the subject under ~72 characters. Use the body for the *why*. Group related changes in one commit; split unrelated changes across commits.

## Pull requests

For anything non-trivial (new effect implementation, parser change, public API change), open an issue first so we can agree on shape and scope before you spend time on code. Typos, small doc fixes, and obvious bug fixes don't need an issue.

When opening a PR, ensure:

- `swift test` passes locally
- New public symbols have `///` doc comments
- No new dependencies (Foundation only, by design)
- The public API of `ITFile`, `ITMixer`, and `ITError` is unchanged unless explicitly discussed

## Code of conduct

Be kind. Disagree about code, not people. Maintainers reserve the right to close threads that go off the rails.
