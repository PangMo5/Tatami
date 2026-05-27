.PHONY: install generate build test format clean app

install:
	tuist install
	./Scripts/fix-keyboardshortcuts-strings.sh

generate:
	tuist generate --no-open

build:
	tuist build Tatami

# Build, re-sign with the local Apple Development cert, and install
# Tatami.app into /Applications. Run this any time you want the
# running copy to pick up source changes — sign stays stable so
# macOS Accessibility/Input Monitoring permissions are preserved
# across rebuilds.
#
# Provide TUIST_DEVELOPMENT_TEAM (and optionally TATAMI_CERT_HASH /
# TATAMI_CERT_NAME) via `.mise.local.toml` or your shell environment —
# none of those are checked into the repo. Run `make generate` after
# setting the team so it gets baked into the project.
app:
	xcodebuild \
		-workspace Tatami.xcworkspace \
		-scheme Tatami \
		-configuration Debug \
		-destination 'generic/platform=macOS' \
		build | tail -3
	./Scripts/install-dev-signed.sh

test:
	tuist test TatamiTests

format:
	swiftformat .

clean:
	tuist clean
	rm -rf Derived

bootstrap: install generate
