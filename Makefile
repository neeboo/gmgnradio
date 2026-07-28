.PHONY: control-panel generate test

control-panel:
	cd apps/control-panel && npm run build

generate: control-panel
	cd apps/macos && xcodegen generate

test: generate
	xcodebuild test \
		-project apps/macos/GMGNRadio.xcodeproj \
		-scheme GMGNRadio \
		-destination 'platform=macOS'
