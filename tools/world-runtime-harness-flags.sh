#!/bin/sh
# ---------------------------------------------------------------------------
# 离线 harness 编 `import WorldRuntime` 的生产文件时，**唯一一处**的模块搜索路径
# 与目标文件定义。harness 只调用本脚本，不得再自己拼 `.build/...` 路径。
#
# 为什么必须有这一处：
#
# * `make test-harnesses` 的每一条都是**裸 `swift tools/test-*.swift`**（见 Makefile
#   `_test-harnesses`），harness 内部再自己调 `/usr/bin/swiftc` 编若干生产源文件。
#   这条路上**没有 SwiftPM 的模块搜索路径**，于是任何 `import WorldRuntime` 的生产
#   文件都过不去：
#
#       .../Presence/WishMachineOutputDescriptor.swift:3:8: error: no such module 'WorldRuntime'
#
# * `WorldRuntime.swiftmodule` 在本仓**同时存在两份独立编译的产物**：
#
#       apps/macos/Packages/WorldRuntime/.build/arm64-apple-macosx/debug/Modules  (SwiftPM)
#       apps/macos/Build.noindex/Build/Products/<配置>/WorldRuntime.swiftmodule  (xcodebuild)
#
#   后者是 `make build` 的产物；`CONFIGURATION ?= Release`，所以 `Products/Debug`
#   那一份会长期停在旧物上。认错它得到的不是"找不到模块"，而是更难认的：
#
#       WishMachineOutputDescriptor.swift:42:41: error: type 'WorldQuaternion' has no member 'identity'
#
#   两份并存的根因就是"27 个 harness 各拼一遍路径"：谁都不知道哪份是权威。
#
# 权威 = **同一对**（模块 + 目标文件必须同源，否则模块与实现会错位）：SwiftPM 的
# `.build/arm64-apple-macosx/debug`。这也是仓里 27 个 harness 原本就在用的那一份，
# 所以收敛不改变任何已有 harness 的语义，只是把路径从 27 处收成 1 处。
#
# 输出：stdout 每行一个参数（`-I`、模块目录、若干 `.o`），可直接拼进 Process 的
# argv；失败时往 stderr 打一行 `FAIL: ...` 并以非零码退出。
#
#   tools/world-runtime-harness-flags.sh            # 只用现成产物
#   tools/world-runtime-harness-flags.sh --ensure   # 产物缺失时先 swift build 一次
# ---------------------------------------------------------------------------
set -eu

ensure=0
[ "${1:-}" = "--ensure" ] && ensure=1

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
package="$root/apps/macos/Packages/WorldRuntime"
build="$package/.build/arm64-apple-macosx/debug"
modules="$build/Modules"
objects="$build/WorldRuntime.build"

if [ ! -e "$modules/WorldRuntime.swiftmodule" ] || [ ! -d "$objects" ]; then
    if [ "$ensure" = "1" ]; then
        swift build --package-path "$package" >&2 || true
    fi
fi

if [ ! -e "$modules/WorldRuntime.swiftmodule" ]; then
    echo "FAIL: WorldRuntime 尚未用 SwiftPM 编译（缺 $modules/WorldRuntime.swiftmodule）：先跑 swift build --package-path apps/macos/Packages/WorldRuntime 或 make test-worlds" >&2
    exit 1
fi

count=0
for object in "$objects"/*.swift.o; do
    [ -e "$object" ] || continue
    if [ "$count" = "0" ]; then
        printf '%s\n' "-I" "$modules"
    fi
    printf '%s\n' "$object"
    count=$((count + 1))
done

if [ "$count" = "0" ]; then
    echo "FAIL: WorldRuntime 目标文件为空（$objects/*.swift.o）：先跑 swift build --package-path apps/macos/Packages/WorldRuntime 或 make test-worlds" >&2
    exit 1
fi
