.PHONY: format lint lint-fix check zig-build

format:
	swiftformat .

lint:
	swiftlint lint

lint-fix:
	swiftlint lint --fix

check: lint

# Build the Zig static library.  Must run before `swift build`.
# Override the target architecture with ZIG_TARGET=x86_64-macos if needed.
zig-build:
	./build-zig.sh
