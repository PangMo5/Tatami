.PHONY: install generate build run test format clean

install:
	tuist install

generate:
	tuist generate --no-open

# `tuist build` is deprecated; the supported path is to generate, then drive
# the generated project through the `tuist xcodebuild` wrapper.
build: generate
	tuist xcodebuild build -scheme Tatami -workspace Tatami.xcworkspace -configuration Debug -destination 'platform=macOS'

# Build the Debug app and launch it — the dev inner loop. The Debug build is a
# separate app ("Tatami Dev", bundle id dev.PangMo5.Tatami.debug, its own
# DEV-badged icon), Apple Development-signed via Project.swift, so its
# Accessibility / Screen-Recording grant never collides with an installed
# release. `killall` first avoids a stale duplicate instance.
run: generate
	-killall Tatami 2>/dev/null
	tuist xcodebuild build -scheme Tatami -workspace Tatami.xcworkspace -configuration Debug -destination 'platform=macOS' -derivedDataPath DerivedData
	open DerivedData/Build/Products/Debug/Tatami.app

# Bare `tuist test` runs the auto-generated workspace test action (the
# Swift Testing suites). There is no standalone `TatamiTests` scheme.
test:
	tuist test

format:
	swiftformat .

clean:
	tuist clean
	rm -rf Derived DerivedData

bootstrap: install generate
