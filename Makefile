.PHONY: build test app run install clean

build:
	swift build

test:
	swift test

app:
	scripts/bundle.sh

run: app
	open build/Sonata.app

# Copies the bundle into /Applications, replacing an older copy via ditto.
install: app
	ditto build/Sonata.app /Applications/Sonata.app

clean:
	swift package clean
	rm -rf build
