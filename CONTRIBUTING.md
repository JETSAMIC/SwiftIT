# Contributing to SwiftIT

Thanks for the interest. SwiftIT is a focused library. The bar is "ships clean, doesn't regress, stays minimal." Patches that meet that bar are welcome.

## Building and testing

```sh
swift build -c release -Xswiftc -warnings-as-errors
swift test
```

The test target uses Swift Testing (`import Testing`), not XCTest. Tests live in `Tests/SwiftITTests/`, and fixtures are assembled byte by byte with `ITBuilder`, so no binary modules are checked in. Add a test for any behavioural change. Parser fixes should come with a test built from bytes derived from `Reference/IT-Format.md`.

## Commit style

Conventional commits in `type(scope): summary` form, lowercase, imperative mood:

```
feat(mixer): implement tone portamento volume slide (Lxx)
fix(parser): handle 0-pointer pattern entries without crashing
docs(readme): clarify sample-compression status
test(parser): cover delta-decoded 16-bit samples
refactor(envelope): hoist point interpolation into a helper
```

Keep the subject under about 72 characters, and use the body for the *why*.

## Pull requests

For anything non-trivial (new effect semantics, parser changes, public API changes), open an issue first so we can agree on shape and scope. Typos, small doc fixes, and obvious bug fixes don't need an issue.

Before opening a PR, check that:

- the build and tests above pass with zero warnings
- new public symbols have `///` doc comments
- there are no new dependencies (Foundation only, by design)
- format behaviour changes are reflected in `Reference/IT-Format.md` and the README coverage table

## Code of conduct

Be kind. Disagree about code, not people. Maintainers reserve the right to close threads that go off the rails.
