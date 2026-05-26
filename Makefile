.PHONY: install generate build test format clean

install:
	tuist install
	./Scripts/fix-keyboardshortcuts-strings.sh

generate:
	tuist generate --no-open

build:
	tuist build Tatami

test:
	tuist test TatamiTests

format:
	swiftformat .

clean:
	tuist clean
	rm -rf Derived

bootstrap: install generate
