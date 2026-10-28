# The Rust workspace's checks and tests on the host.
test:
    cargo fmt --all --check
    cargo clippy --workspace --locked --all-targets -- -D warnings
    cargo test --workspace --locked

format:
    cargo fmt --all

# The Rust core as app/Generated: an xcframework and its Swift bindings.
core:
    scripts/build-core.sh

# The fonts the app bundles, checksummed, into app/Generated/fonts.
fonts:
    scripts/fetch-fonts.sh

# The Xcode project from app/project.yml.
project: fonts
    cd app && xcodegen

# Swift tests on the newest iPhone simulator; needs app/Generated from `just core`.
test-app: project
    cd app && xcodebuild test -project Bellterm.xcodeproj -scheme Bellterm \
        -destination "platform=iOS Simulator,name=$(xcrun simctl list devices available | grep -o 'iPhone[^(]*' | tail -1 | sed 's/ *$//')" \
        CODE_SIGNING_ALLOWED=NO
