.PHONY: generate test

generate:
	cd apps/macos && xcodegen generate

test: generate
	xcodebuild test \
		-project apps/macos/GMGNRadio.xcodeproj \
		-scheme GMGNRadio \
		-destination 'platform=macOS'

