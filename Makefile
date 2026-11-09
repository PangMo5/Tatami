.PHONY: install build run test release extract-localizations format lint clean bootstrap

install:
	mise exec -- swift package resolve

build:
	mise exec -- swift run --package-path Tools tatami-tools bundle-product

# Build the Debug app and launch it — the dev inner loop. The Debug build is a
# separate app ("Tatami Dev", bundle id dev.PangMo5.Tatami.debug, its own
# DEV-badged icon), Apple Development-signed by the packager, so its
# Accessibility / Screen-Recording grant never collides with an installed
# release. The packager replaces the running window manager; isolated config and
# socket overrides keep validation builds separate from the installed app.
run:
	mise exec -- swift run --package-path Tools tatami-tools bundle-product --launch

test:
	mise exec -- swift test --no-parallel

release:
	mise exec -- swift run --package-path Tools tatami-tools bundle-product --configuration release --arch arm64 --arch x86_64

# Keep each module's compiler output separate, including same-named Swift files.
extract-localizations:
	mkdir -p .build/localization/Tatami .build/localization/TatamiKit
	TATAMI_LOCALIZATION_OUTPUT="$(CURDIR)/.build/localization" mise exec -- swift build --product TatamiApp

format:
	mise exec -- swiftformat .

lint:
	mise exec -- swiftformat . --lint

clean:
	mise exec -- swift package clean
	rm -rf .build/app .build/packaging .build/localization

bootstrap: install
