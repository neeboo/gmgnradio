.PHONY: generate test build install test-install

CONFIGURATION ?= Debug
DERIVED_DATA ?= apps/macos/Build

generate:
	cd apps/macos && xcodegen generate

# Build only: never stop or launch the app or its task daemon.
build: generate
	xcodebuild build \
		-project apps/macos/GMGNRadio.xcodeproj \
		-scheme GMGNRadio \
		-configuration "$(CONFIGURATION)" \
		-destination 'platform=macOS' \
		-derivedDataPath "$(DERIVED_DATA)" \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
		-skipPackageUpdates \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

# One entry point: build the app + bundled helper, then install and switch both.
install: build
	python3 tools/install-macos.py --source "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/gmgn radio.app"

test-install:
	python3 tools/test-install-macos.py

test: generate
	xcodebuild test \
		-project apps/macos/GMGNRadio.xcodeproj \
		-scheme GMGNRadio \
		-destination 'platform=macOS'
