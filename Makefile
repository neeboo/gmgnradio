.PHONY: generate test test-all test-install test-worlds test-daemon test-python test-harnesses build install install-debug install-universal

# 默认 Release：只有 -O 下"承托网格派生"才是 0.5 s 量级（-Onone 是 6.6 s，
# 真机一次要六秒多，用户等不了）。想最快编译走 make install-debug。
CONFIGURATION ?= Release
DERIVED_DATA ?= apps/macos/Build
# SwiftPM 的检出/仓库/产物放在 DerivedData **之外**。过去它们在
# apps/macos/Build/SourcePackages 里，`rm -rf apps/macos/Build` 会一并删掉
# 734 MB 检出，下一次冷编译要重新 git clone 并跑 `submodule update
# --init --recursive`（实测 252 s，而且必须联网）。这四个目录名本来就在
# .gitignore 里（apps/macos/Packages/{checkouts,repositories,artifacts}）。
CLONED_SOURCE_PACKAGES ?= apps/macos/Packages
# 本机迭代只编当前架构。Release 默认 ARCHS=arm64 x86_64，每个 Swift 模块编两遍
# （实测 App target 187 个文件 arm64 320 s / x86_64 284 s，两者并行但抢同一批
# 核），post-build 的 Rust daemon 也要 cargo build 两次再 lipo（实测 162 s）。
# 需要给别人用的通用二进制走 make install-universal，那条路不受影响。
ARCH_FLAGS ?= ONLY_ACTIVE_ARCH=YES
# 保留 -O，只把编译模式从整模块优化换成增量：改一个文件时只重编它和依赖它的
# 文件，而不是**整个模块**。整模块下改一行 = 重编 App target 全部 187 个文件
# （实测增量 146 s，冷编译 320 s）。
COMPILATION_MODE ?= SWIFT_COMPILATION_MODE=incremental
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
		-clonedSourcePackagesDirPath "$(CLONED_SOURCE_PACKAGES)" \
		-disableAutomaticPackageResolution \
		-onlyUsePackageVersionsFromResolvedFile \
		-skipPackageUpdates \
		$(ARCH_FLAGS) $(COMPILATION_MODE) \
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO

# One entry point: build the app + bundled helper, then install and switch both.
# 日常迭代就用这一条：Release 的 -O 手感 + 单架构 + 增量编译。
install: build
	python3 tools/install-macos.py --source "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/gmgn radio.app"
	rm -rf "$(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/gmgn radio.app"

# 分发形状：通用二进制（arm64 + x86_64）+ 整模块优化 —— 也就是改造前
# `make install CONFIGURATION=Release` 的行为。给别人的机器用这条。
install-universal: ARCH_FLAGS := ONLY_ACTIVE_ARCH=NO
install-universal: COMPILATION_MODE := SWIFT_COMPILATION_MODE=wholemodule
install-universal: install

# 编译最快（-Onone），但承托网格派生要 6.6 s：只在改动与装修面板无关、
# 且不需要真机手感时使用。
install-debug: CONFIGURATION := Debug
install-debug: install

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
	swift tools/test-livecam-auto-presentation.swift
	swift tools/test-stage-avatar-follow-smoothing.swift
	swift tools/test-resident-walk-motion-default.swift
	swift tools/test-motion-playback-lifecycle.swift
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
	swift tools/test-resident-prop-world-collision.swift

test-all: test-install test-worlds test-daemon test-python test-harnesses dedupe

test: generate
	xcodebuild test \
		-project apps/macos/GMGNRadio.xcodeproj \
		-scheme GMGNRadio \
		-destination 'platform=macOS'
