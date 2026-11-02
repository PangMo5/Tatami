.PHONY: install generate build run test format lint clean bootstrap

install:
	mise exec -- tuist install

generate:
	mise exec -- tuist generate --no-open

# `tuist build` is deprecated; the supported path is to generate, then drive
# the generated project through the `tuist xcodebuild` wrapper.
build: generate
	mise exec -- tuist xcodebuild build -scheme Tatami -workspace Tatami.xcworkspace -configuration Debug -destination 'platform=macOS'

# Build the Debug app and launch it — the dev inner loop. The Debug build is a
# separate app ("Tatami Dev", bundle id dev.PangMo5.Tatami.debug, its own
# DEV-badged icon), Apple Development-signed via Project.swift, so its
# Accessibility / Screen-Recording grant never collides with an installed
# release. `killall` first avoids a stale duplicate instance.
run: generate
	-killall Tatami 2>/dev/null
	mise exec -- tuist xcodebuild build -scheme Tatami -workspace Tatami.xcworkspace -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData
	open DerivedData/Build/Products/Debug/Tatami.app

# The Tatami scheme includes the Swift Testing suites. Generate once, then
# test through the same Xcode wrapper used for builds.
test: generate
	mise exec -- tuist xcodebuild test -scheme Tatami -workspace Tatami.xcworkspace -destination 'platform=macOS'

format:
	mise exec -- swiftformat .

lint:
	mise exec -- swiftformat . --lint

clean:
	mise exec -- tuist clean
	rm -rf Derived DerivedData

bootstrap: install generate
