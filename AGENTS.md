# AGENTS.md

Engineering guidance for agents working in this repository. Read it alongside
`README.md` and the code before making changes.

## Layout

Bellterm is a native iOS client of a Herdr daemon reached over SSH. Herdr on
the host owns terminals and session state; disconnecting the app must leave
them running. The app never installs, starts, stops, or upgrades Herdr.

| Location | Responsibility |
| --- | --- |
| `app/` | SwiftUI app (XcodeGen `project.yml`), its tests, and bundled fonts |
| `ffi/` | `bellterm-ffi`: the core exposed to Swift through UniFFI |
| `native/` | Rust core: russh transport, libghostty-vt screen, input routing |
| `crates/herdr-protocol` | Herdr wire types, framing, validation, atomic surface patches |
| `crates/herdr-client` | Discovery, socket worker, session transitions, ordered commands |
| `crates/test-support/sandbox.rs` | Isolated process setup for herdr-client's opt-in live tests |
| `scripts/` | Build the core as an xcframework; gather the bundled fonts |

- Keep dependency direction from `ffi` to `native` to `herdr-client` to
  `herdr-protocol`.
- `native/` and `crates/` are shared with Bellterm for Android
  (https://github.com/nimrc/bellterm): change them there first and copy them
  here, so the two stay identical. `app/src/test/resources/frame-v1.bin` is
  the frame fixture `native/src/render/tests.rs` writes; it sits at the path
  that shared test expects, and the Swift tests parse it too.
- Bellterm is Apache-2.0, and `crates/` is third-party Apache-2.0 code (see
  `NOTICE`): keep its copyright, licence files, and `license` fields as they
  are. Vendored bincode field and enum variant order in `herdr-protocol` is a
  wire contract: never reorder it, and keep the attribution in
  `crates/herdr-protocol/NOTICE.md`.
- Never modify Herdr itself; it is owned by an unrelated team.
- Put shared Rust dependency versions in the root `[workspace.dependencies]`.

## Rust

- Every crate exposes its own `Error` and `Result<T>` built with `thiserror`.
  Never use `String` as an error type; propagate with `?` and keep sources.
- No `unwrap()`/`expect()` in production code, and no new `unsafe`.
- Keep test bodies out of production files: declare `#[cfg(test)] mod tests;`.
- Treat terminal content and daemon messages as untrusted data.

## iOS

- The main actor never blocks: `Session.nextEvent` runs on its own thread, and
  socket and SSH work lives in the Rust core.
- iOS 26 is the floor; wrap iPhone Duo APIs in `#available(iOS 27.1, *)`.
  Lay out from size classes and reserved regions, never the hinge or the
  device model.
- Keep `app/Generated/`, the generated `.xcodeproj`, signing teams, and
  provisioning profiles out of git.

## Verification

```sh
just format
just test       # Rust fmt, clippy, and tests on the host
just core       # the iOS core; needs Xcode 26.0 on macOS 26 (see README)
just test-app   # Swift tests on a simulator; needs app/Generated
```

Report what was actually run; never claim an unrun check passed.

## Git

- Conventional commit subjects (`feat`, `fix`, `refactor`, `docs`, `test`,
  `chore`); explain nontrivial changes in the body.
- Only commit, push, or open a PR when asked. Never add AI attribution lines.
