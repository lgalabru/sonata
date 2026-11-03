.PHONY: build test app run install clean ci

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

# What CI runs (.github/workflows/ci.yml).
ci:
	swift build -c release
	swift test --parallel
	UNIVERSAL=1 scripts/bundle.sh
	codesign --verify --deep --strict build/Sonata.app
	build/Sonata.app/Contents/MacOS/Sonata --menubar-snapshot build/menubar.png
	test -s build/menubar.png
	scripts/package.sh
