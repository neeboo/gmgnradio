.PHONY: generate test test-all test-install test-worlds test-daemon test-python test-harnesses build install

CONFIGURATION ?= Debug
DERIVED_DATA ?= apps/macos/Build
PYTHON ?= python3
CARGO ?= $(shell command -v cargo 2>/dev/null || echo $(HOME)/.cargo/bin/cargo)

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
	rm -rf "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/gmgn radio.app"

# ---------------------------------------------------------------------------
# Verification
#
# Use `test-all` for routine work. It is fully offline and never launches the
# app, the task daemon, real models or system permission prompts.
#
# `test` is retained for the Xcode unit test bundle, but be aware that
# apps/macos/project.yml sets TEST_HOST to the app executable, so `make test`
# launches the real app. That conflicts with this project's host-operation
# rules; prefer `test-all`.
# ---------------------------------------------------------------------------

test-install:
	$(PYTHON) tools/test-install-macos.py

# Build products are launchable bundles, so LaunchServices registers every one
# of them the moment Xcode writes it -- and Spotlight then offers a second
# "gmgn radio" next to the installed app. `make install` deletes its product
# after copying it into place; routine verification builds one too, so this is
# the same cleanup as a standalone target. Unregister first (the file is about
# to be deleted, and a registration whose bundle is gone cannot be removed with
# `lsregister -u` afterwards), then delete.
dedupe:
	-python3 tools/dedupe-app-registrations.py

test-worlds:
	swift test --package-path apps/macos/Packages/WorldRuntime

test-daemon:
	"$(CARGO)" test --locked --manifest-path services/gmgn-taskd/Cargo.toml

test-python:
	$(PYTHON) -m unittest discover -s tools/navigation -p 'test_*.py'
	$(PYTHON) -m unittest discover -s tools/assets -p 'test_*.py'
	$(PYTHON) -m unittest discover -s tools/marble/tests -p 'test_*.py'
	$(PYTHON) -m unittest discover -s tools/blender/tests -p 'test_*.py'
	$(PYTHON) -m unittest discover -s tools/motion/tests -p 'test_*.py'

# The resident-agent regression harnesses named in
# docs/plans/2026-09-22-user-experience-fixes-and-acceptance.md. Each script
# reads production source, compiles a temporary harness with swiftc and runs
# it, so this target is slow (minutes, not seconds).
test-harnesses:
	swift tools/test-first-use-guidance.swift
	swift tools/test-space-first-defaults.swift
	swift tools/test-stage-decoration-menu.swift
	swift tools/test-stage-control-actions.swift
	swift tools/test-stage-control-panels.swift
	swift tools/test-space-presentation.swift
	swift tools/test-livecam-avatar-framing.swift
	swift tools/test-livecam-panel-sizing.swift
	swift tools/test-stage-avatar-follow-smoothing.swift
	swift tools/test-living-resident-loop.swift
	swift tools/test-resident-prop-render.swift
	swift tools/test-resident-prop-grid-editor.swift
	swift tools/test-resident-prop-grid-placement.swift
	swift tools/test-resident-prop-function-anchors.swift
	swift tools/test-wish-machine-coordinator.swift
	swift tools/test-wish-machine-app-runtime.swift
	swift tools/test-resident-prop-placement.swift
	swift tools/test-resident-prop-one-judge.swift
	swift tools/test-resident-prop-tools.swift
	swift tools/test-resident-prop-capability.swift
	swift tools/test-resident-status-lifecycle.swift
	swift tools/test-resident-chat-transcript.swift
	swift tools/test-resident-voice-authorization.swift
	swift tools/test-resident-dsh-world-loop.swift
	swift tools/test-resident-tool-bridge-errors.swift
	swift tools/test-resident-background-presentation.swift
	swift tools/test-resident-agent-loop.swift

test-all: test-install test-worlds test-daemon test-python test-harnesses dedupe

test: generate
	xcodebuild test \
		-project apps/macos/GMGNRadio.xcodeproj \
		-scheme GMGNRadio \
		-destination 'platform=macOS'
