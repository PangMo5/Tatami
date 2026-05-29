.PHONY: install generate build test format clean

install:
	tuist install
	./Scripts/fix-keyboardshortcuts-strings.sh

generate:
	tuist generate --no-open

# `tuist build` is deprecated; the supported path is to generate, then drive
# the generated project through the `tuist xcodebuild` wrapper.
build: generate
	tuist xcodebuild build -scheme Tatami -workspace Tatami.xcworkspace -configuration Debug -destination 'platform=macOS'

# Bare `tuist test` runs the auto-generated workspace test action (the
# Swift Testing suites). There is no standalone `TatamiTests` scheme.
test:
	tuist test

format:
	swiftformat .

clean:
	tuist clean
	rm -rf Derived

bootstrap: install generate
