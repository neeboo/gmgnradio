.PHONY: generate test test-all test-install test-worlds test-daemon test-python test-harnesses _test-harnesses build install install-debug install-universal unregister-product dedupe verify-registrations

# 默认 Release：只有 -O 下"承托网格派生"才是 0.5 s 量级（-Onone 是 6.6 s，
# 真机一次要六秒多，用户等不了）。想最快编译走 make install-debug。
CONFIGURATION ?= Release
# 目录名以 `.noindex` 结尾 —— Spotlight 不索引这整棵子树（2026-10-02 本机实测），
# 于是 mdworker 不会把 `Build/Products/<配置>/gmgn radio.app` 注册进 LaunchServices，
# 聚焦/启动台里不会再冒出第二个图标。这是"两个 gmgn radio"的**根治**：裸 `make build`
# 也不需要再靠"注销 + 删产物"兜底（那条路只赢几秒，见下面 unregister-product 一段）。
# 代价：本目录改名时每个 worktree 要一次冷编译。
DERIVED_DATA ?= apps/macos/Build.noindex
# SwiftPM 的检出/仓库/产物放在 DerivedData **之外**。过去它们在
# $(DERIVED_DATA)/SourcePackages 里（当时是 apps/macos/Build/SourcePackages），
# `rm -rf $(DERIVED_DATA)` 会一并删掉
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

# ---------------------------------------------------------------------------
# 构建互斥闸：同一个 DerivedData 上，同一时刻只跑一个重型编译。
#
# 2026-10-01 事故：7 个 agent 同时在同一个 DerivedData 上跑 `make build`，10 核机器
# 被 15 路并行 swift-frontend 打到负载 36+，并且反复出现
#
#   error: unable to attach DB: error: accessing build database
#   ".../apps/macos/Build/Build/Intermediates.noindex/XCBuildData/build.db":
#   database is locked Possibly there are two concurrent builds running in the
#   same filesystem location.
#
# —— xcodebuild 的 build database 是 DerivedData 里**独占**的 SQLite 文件，并发
# attach 必然互锁：构建于是"莫名失败"，而 agent 会把这种失败误判成自己刚改的代码
# 有问题（这正是这次事故里最贵的部分）。
#
# 闸门**只做互斥**，不改任何编译参数/产物/验证语义：拿不到锁就**排队等待**
# （打印"等待另一个构建完成…"），不做"直接失败"——直接失败同样会被误判成代码错误。
# 等待上限默认 3600 s，超时以退出码 75（EX_TEMPFAIL）结束并打印当前持有者，
# 明确区分"临时排队"和"编译失败"：
#
#   make build                          # 排队上限 1 小时
#   make build BUILD_LOCK_TIMEOUT=600   # 按需调整排队上限
#
# 锁文件放在 DerivedData 里（`Build.noindex/` 已在 .gitignore），跟着 DerivedData 走：换一个
# -derivedDataPath（或另一个 worktree）就不会互相阻塞。锁由
# tools/with-build-lock.py 的包装进程持有（构建子进程不继承锁 fd，所以 Xcode 的长驻
# 构建服务占不住闸门），持有者一退出就由内核自动释放，不会有需要手工删的死锁文件。
#
# 任何新的"重编译"目标按同样方式接线即可：$(BUILD_LOCK) <命令>
# ---------------------------------------------------------------------------
BUILD_LOCK_TIMEOUT ?= 3600
BUILD_LOCK_FILE ?= $(if $(filter /%,$(DERIVED_DATA)),$(DERIVED_DATA),$(CURDIR)/$(DERIVED_DATA))/.xcodebuild.lock
BUILD_LOCK = $(PYTHON) "$(CURDIR)/tools/with-build-lock.py" --lock "$(BUILD_LOCK_FILE)" --timeout "$(BUILD_LOCK_TIMEOUT)" --label "$@" --

# ---------------------------------------------------------------------------
# 构建产物的 LaunchServices 注销（"两个 gmgn radio 图标"的**第二层**保险）。
#
# 根治在目录名那一处：DERIVED_DATA = `apps/macos/Build.noindex`，`.noindex` 后缀
# 让 Spotlight **不索引**整棵子树，于是 `Build/Products/<配置>/gmgn radio.app` 这个
# 可启动 bundle 不会被 mdworker 注册进 LaunchServices（2026-10-02 实测：冷编译之后
# 再跑一次裸 `make build`、等 60 s，注册表里仍只有 `/Applications/gmgn radio.app`）。
# 这一段留着是因为它只花毫秒：产物一旦被挪到**会**被索引的位置（手工拷贝、别的
# DerivedData、老路径），注册仍会自动发生，多一层注销就少一次"再报一次图标"。
#
# 历史（用户 2026-09-29 起报过三次）：产物曾在 `apps/macos/Build`（不带 `.noindex`），
# xcodebuild 一把它写到磁盘上，LaunchServices 就自动注册它 —— 于是聚焦/启动台里出现
# 第二个 "gmgn radio"。`make install` 拷完会删掉产物、`make dedupe` 也会清，但**裸
# `make build`**（agent 与日常最常跑的那条）两条路都不经过，所以每构建一次图标就回来
# 一次 —— 清理挂在别处就永远追不上。因此注销挂在 build **自己**的末尾。
#
# 两条硬约束：
#   * **只注销，不删文件**：产物马上要交给 `make install` 用（删了它就废了）。
#   * **不跑 `-dump`**：dump 一次 6~9 s，而 `-u <路径>` 是毫秒级。`lsregister -u`
#     对**文件还在**的注册是有效的（只有"路径已不存在"的死注册才清不掉、只能重建
#     数据库，那条路走 dedupe/install）；这里产物刚写出来，文件必然在。
#
# 2026-10-02 补：单靠这条注销**只是赢得几秒**，不是终点。实测（新建一个 bundle 放进
# `$HOME`、完全不碰 lsregister）Spotlight 的索引在 30 s 内自己就把同一 id 注册了
# 回去 —— 只要产物文件还在、位置会被索引，注销就会被 mdworker 撤销。后来实测
# `.noindex` 后缀的目录整棵不进索引、不会注册，所以落点从"注销产物"改成"换个不被
# 索引的 DerivedData"（本次改动，代价是每个 worktree 一次冷编译）。`make dedupe`
# （删文件 + "除正规路径外全部注销"的规则 + 断言）仍然保留，它管的是老路径与别的
# DerivedData 里已经存在的那些同 id 副本。
#
# 失败不影响构建结果：命令自带 `|| true`，调用处也不改退出码。
PRODUCT_APP ?= $(DERIVED_DATA)/Build/Products/$(CONFIGURATION)/gmgn radio.app
LSREGISTER ?= /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
UNREGISTER_PRODUCT = "$(LSREGISTER)" -u "$(PRODUCT_APP)" >/dev/null 2>&1 || true

# xcodegen 也写同一份 .xcodeproj，两个并发 `make build` 会同时重写它，所以一并进闸门。
generate:
	cd apps/macos && $(BUILD_LOCK) xcodegen generate

# Build only: never stop or launch the app or its task daemon.
build: generate
	$(BUILD_LOCK) xcodebuild build \
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
		CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO; \
	status=$$?; $(UNREGISTER_PRODUCT); exit $$status

# 可单独执行（`make unregister-product`，例如 daemon/网关之外另跑了一次 xcodebuild）；
# `build` 末尾调用的就是上面同一条命令。想核对别的配置：CONFIGURATION=Debug。
unregister-product:
	-@$(UNREGISTER_PRODUCT)

# One entry point: build the app + bundled helper, then install and switch both.
# 日常迭代就用这一条：Release 的 -O 手感 + 单架构 + 增量编译。
install: build
	python3 tools/install-macos.py --source "$(PRODUCT_APP)"
	rm -rf "$(PRODUCT_APP)"

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

# LaunchServices 里这个 bundle id 只允许一条注册，路径必须是
# `/Applications/gmgn radio.app` —— 这是**规则**，不是清一次。
#
# 已知来源（2026-10-02 复核）：
#   * `$(DERIVED_DATA)/Build/Products/<配置>/gmgn radio.app`。DERIVED_DATA 现在是
#     `apps/macos/Build.noindex` —— `.noindex` 子树不进索引也不注册（本次实测），
#     所以这里 `--products` 扫的是那份**不会被注册**的产物；它仍在扫描列表里，
#     是为了"注册表必须只有一条"这条断言不被路径变化绕过；
#   * `apps/macos/Build/Build/Products/<配置>/gmgn radio.app` —— 迁移前的旧路径，
#     目录只作回退保留，里面的 app bundle 已经删掉（`find apps/macos/Build -name
#     'gmgn radio.app'` 为空）；删掉旧目录时这一条也一起作废；
#   * `~/Library/Developer/Xcode/DerivedData/*/...`（`make test` 走默认 DerivedData，
#     TEST_HOST 会**真的启动**那个产物，启动即注册 —— 那条路不经过 `unregister-product`）；
#   * `/Applications/.gmgn-install-*/previous.backup`（装机留的回滚备份：隐藏目录，当前
#     不在注册表里，但里面是一份同 id 的完整 bundle，交给 dedupe/install **从形态上**根治）。
#
# 为什么 `make build` 末尾那条注销不够（本机实测）：新建一个 bundle 放进 `$HOME`，
# 什么都不做，30 s 内 Spotlight 的索引就把它注册进了 LaunchServices。文件还在、
# 位置会被索引，注销就是暂时的。所以除了注销，落点是**让位置不被索引**
# （DERIVED_DATA 的 `.noindex` 后缀，已落地）；对老的、仍会被索引的副本，则必须
# **删掉产物文件**。
#
# 顺序：先注销再删（文件已不在的注册用 `-u` 清不掉，只能重建数据库，那一步在
# `tools/install-macos.py:ensure_single_registration` 里）。产物删除走构建闸门，
# 免得把别人正在编译/正在用的产物删掉。
#
# 退出码是有意义的：**收敛+删除之后注册表仍不是唯一正规路径就非 0** —— 这就是防复发
# 断言（注入一份同 id 的副本必须能把 `make dedupe` 顶红）。删不掉文件不算失败。
dedupe:
	$(BUILD_LOCK) $(PYTHON) tools/dedupe-app-registrations.py --products "$(if $(filter /%,$(DERIVED_DATA)),$(DERIVED_DATA),$(CURDIR)/$(DERIVED_DATA))/Build/Products"

# 只读复核（不改任何东西，不删任何文件）：注册表里是不是只剩正规安装那一条。
# 想看将要做什么而不动手用 `--dry-run`。
verify-registrations:
	$(PYTHON) tools/dedupe-app-registrations.py --check

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
# it, so this target is slow (minutes, not seconds) and each `swift` call is its
# own little swift-frontend storm -- several agents running it at once is the
# same machine-flattening event as several concurrent `make build`s. So the
# whole list shares **one** gate acquisition: taking the lock per script would
# serialise nothing (another build can slip in between any two of them).
#
# 裸 `swift tools/test-*.swift` 这条路上**没有 SwiftPM 的模块搜索路径**，所以任何一个
# `import WorldRuntime` 的生产文件都要靠 harness 自己把模块目录与目标文件传给 swiftc。
# 那份参数**只有一处定义**：tools/world-runtime-harness-flags.sh。harness 只调用它，
# 谁都不许再自己拼 `.build/...` —— 27 份各自拼写正是 SwiftPM 模块与 xcodebuild
# `Products/Debug` 旧模块两份并存的根因（后者会报 `WorldQuaternion` 没有 `identity`）。
# 改路径/换目录只改那一个脚本。
test-harnesses:
	$(BUILD_LOCK) $(MAKE) --no-print-directory _test-harnesses

_test-harnesses:
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
	# 点唱机"请求被接受 ⇒ 真的出声"的唯一判据、失败必须可见、提前结束必须带原因，
	# 以及 `makeResidentWorldTools` 抽取器必须抽到完整函数体（回合期限断言靠它）。
	# 它**从来没挂进来过**：抽取器在默认闭包参数处截断，deadline 断言永远看不到函数体，
	# 于是一直红着没人管（2026-10-01 真机"点唱机放不出声音"）。
	swift tools/test-resident-jukebox-outcome.swift
	swift tools/test-living-resident-loop.swift
	swift tools/test-resident-prop-render.swift
	swift tools/test-resident-prop-grid-editor.swift
	swift tools/test-resident-prop-grid-placement.swift
	# 摆正（朝向归一）+ 靠墙（竖直面）：两件事各自的判据，见各自文件头。
	swift tools/test-resident-prop-orientation-and-wall.swift
	swift tools/test-resident-prop-function-anchors.swift
	# 手持那一环的门禁。`tools/test-prop-attachment.swift` **从来没挂进来过**，于是
	# "手骨跟随 / 只读骨骼 / 握点单一来源 / 缺失可见失败 / 细长物件刃轴压在骨轴上"
	# 这五条今天一条都没在跑（见 tools/test-resident-prop-hold.swift 的文件头）。
	swift tools/test-resident-prop-hold.swift
	# `tools/test-prop-attachment.swift` 同样**从来没挂进来过**，所以它红着没人管：
	# 朝向那条线给 `PropAttachment.swift` 加了 `WorldPropRotation` /
	# `WorldPropOrientationPolicy` 的引用之后，这个旧 harness 的手写 stub 就跟不上了。
	# 现在它编的是**真源码**（几何 / 朝向 / 握点推断三份），只有"世界里的大类型"还是
	# stub，并多钉一条"矮胖物件的手感逐位不回归"。
	swift tools/test-prop-attachment.swift
	swift tools/test-wish-machine-coordinator.swift
	swift tools/test-wish-machine-app-runtime.swift
	swift tools/test-resident-prop-placement.swift
	# 删除一件生成资产：墓碑 + 事实（不是硬删行）、共享内容按**派生**引用计数保留、
	# 摆放/手持原子收场、判据分层（`.removal` 不跑空间判据）、失败具名、未点名物件逐位不变，
	# 以及"删干净"三层（记录 + 引用 + 文件）。见 docs/plans/2026-10-02-prop-deletion-semantics.md。
	swift tools/test-resident-prop-delete.swift
	swift tools/test-resident-prop-one-judge.swift
	swift tools/test-resident-prop-tools.swift
	swift tools/test-resident-prop-capability.swift
	swift tools/test-resident-status-lifecycle.swift
	swift tools/test-resident-chat-transcript.swift
	swift tools/test-resident-voice-authorization.swift
	swift tools/test-resident-dsh-world-loop.swift
	# Rust 侧 MCP 面在 composition 里的挂载判据（默认关闭、真实字段、路径逐字、篡改即失败）。
	# Rust 那一半（工具定义唯一来源、只读契约与权威逐字节一致、信息不足走成功通道、
	# 杀掉 MCP 不影响权威）在 services/gmgn-mcpd 里，走 `cargo test -p gmgn-mcpd`。
	swift tools/test-resident-dsh-mcp-mount.swift
	swift tools/test-resident-tool-bridge-errors.swift
	swift tools/test-resident-background-presentation.swift
	swift tools/test-resident-agent-loop.swift
	swift tools/test-resident-prop-world-collision.swift
	swift tools/test-resident-prop-size.swift
	swift tools/test-resident-prop-size-intent.swift
	swift tools/test-resident-system-inbox-window.swift
	swift tools/test-resident-prop-collision-proxy.swift
	swift tools/test-resident-state-convergence.swift
	swift tools/test-world-authority-single-writer.swift
	swift tools/test-world-authority-projection.swift
	# 生成结果的**归属与身份**判据（P-B1）。
	# B-1「状态声明的入库 ⇔ 权威里存在该条目」三层各自独立可断言；
	# B-4 资产身份必须等于**产物**字节的 sha256、且不得等于输入图哈希。
	# 三个负对照（改派生源 / 无条件报已入库 / 身份用输入哈希）在 harness 内部
	# 对源码副本做手术，证明判据真的会红 —— 一个"从不 FAIL"的门禁等于没有门禁。
	swift tools/test-generation-results-authority.swift
	# 「长期记忆」是**用户决定不做**的能力（2026-10-01），所以它必须是被钉住的，
	# 而不是靠记忆：生产代码里不得再出现会让人以为存在该能力的类型/文案/状态。
	# 判据带负对照（把策略或用户文案注入回来 ⇒ 必须 FAIL）。
	swift tools/test-no-long-term-memory-capability.swift
	# 生成结果四方对账器的**自测**（反例必须 FAIL、正例必须不 FAIL）。
	# 只挂 `--self-test`：默认那条读真机 root/真实存档（本身就是 B-1/B-2 的
	# 现场），挂进 CI 门禁会变成"依赖用户当前数据"的非确定性红。
	$(PYTHON) tools/reconcile-generation-results.py --self-test
	# 电视机的五条判据（屏幕几何只有一处定义 / 覆盖层几何一致 / 不吃场景鼠标 /
	# 失败具名可见 / 只走官方嵌入）。三条注入负对照在 harness 内部做手术：
	# 覆盖层改成吃事件、源码里塞一条抓流路径、白名单开一个后门 —— 每一条都必须红。
	# 见 docs/plans/2026-10-02-stage-tv-screen.md。
	swift tools/test-resident-screen-overlay.swift
	# 电视机**接线**的判据（App 侧唯一构造点 / 覆盖层接上舞台窗口 / 面板装上并可见 /
	# 覆盖层容器在视图树里 / 三条工具并进 additionalTools）。存在的理由：上面那五条
	# 是**类型级**的，它们可以全绿而 `WorldScreenStore` 在 App 侧一个构造点都没有 ——
	# 编译得进、跑不起来。七条注入负对照在 harness 内部删掉/重复接线，每一条都必须红。
	# 现场演示：`SCREEN_WIRING_INJECT=dropInstallCall swift tools/test-resident-screen-app-wiring.swift`。
	swift tools/test-resident-screen-app-wiring.swift

test-all: test-install test-worlds test-daemon test-python test-harnesses dedupe

test: generate
	$(BUILD_LOCK) xcodebuild test \
		-project apps/macos/GMGNRadio.xcodeproj \
		-scheme GMGNRadio \
		-destination 'platform=macOS'
