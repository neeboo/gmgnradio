#!/usr/bin/env python3
"""第二宿主一致性门禁的聚合入口（`make test-python` 自动发现本文件）。

为什么是 Python 而不是再加一个 Makefile 目标：`make test-python` 走的是
`unittest discover -s tools/tests -p 'test_*.py'`，**新增文件即被聚合目标跑到**，
不需要改 Makefile（Makefile 上有多条线在飞，本工作无权改）。

为什么值得用第二种语言再读一遍同一份事实：Rust 侧的门禁
（`apps/windows-host/tests/second_host_contract.rs`）和这里的解析器是**各自独立
实现**的。两份实现同时读 `interface_parity.rs` 的 `OPS` 表并得出同一个 op 集合，
才叫交叉校验；如果这里只是 `subprocess.run(["cargo","test"])` 转发一下，那它
除了一次多余编译什么也没证明。

所以本文件做两件事：

1. **独立复算**：自己把 `OPS` 表解析一遍，再自己把 `registry.rs` 里登记的 op 读
   出来，两边对账。口径与 Rust 侧一致：注释与字符串都要正确跳过 —— 这不是洁癖，
   `interface_parity.rs` 里 `stage.props.undo` 那条的说明注释本身就引用了
   `{op:"undo"}`，不跳注释就会多数出一个根本不存在的 op。
2. **跑真门禁**：`cargo run -- check`，断言退出码 0。这一步覆盖字段级与
   「自称已实现但 handler 树里没有」这两类 Python 侧不复算的判据。
"""

from __future__ import annotations

import re
import shutil
import subprocess
import sys
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_SOURCE = REPO_ROOT / "apps" / "gpui-ui" / "tests" / "interface_parity.rs"
REGISTRY_SOURCE = REPO_ROOT / "apps" / "windows-host" / "src" / "registry.rs"
MANIFEST = REPO_ROOT / "apps" / "windows-host" / "Cargo.toml"

TABLE_HEAD = "const OPS: &[OpContract] = &["
TABLE_TAIL = "const UI_RETIRED_OPS"


def strip_rust_comments(source: str) -> str:
    """去掉 `//` 与 `/* */` 注释，保留字符串字面量本体。

    与 `apps/windows-host/src/contract.rs::strip_rust_comments` 同口径，
    但**独立实现**（这里是逐字符状态机，那边是 chars 迭代器）。
    """
    out: list[str] = []
    i, n = 0, len(source)
    while i < n:
        c = source[i]
        if c == '"':
            out.append(c)
            i += 1
            while i < n:
                if source[i] == "\\" and i + 1 < n:
                    out.append(source[i : i + 2])
                    i += 2
                    continue
                out.append(source[i])
                if source[i] == '"':
                    i += 1
                    break
                i += 1
        elif source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            i = n if end < 0 else end + 2
            out.append("\n")
        else:
            out.append(c)
            i += 1
    return "".join(out)


def balanced_brace_end(source: str, open_index: int) -> int:
    """`source[open_index]` 是 `{`，返回配对 `}` 的下标。跳过字符串与注释。"""
    depth = 0
    i, n = open_index, len(source)
    while i < n:
        c = source[i]
        if c == '"':
            i += 1
            while i < n:
                if source[i] == "\\":
                    i += 2
                    continue
                if source[i] == '"':
                    break
                i += 1
        elif source.startswith("//", i):
            while i < n and source[i] != "\n":
                i += 1
            continue
        elif source.startswith("/*", i):
            end = source.find("*/", i + 2)
            i = n if end < 0 else end + 2
            continue
        elif c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                return i
        i += 1
    raise AssertionError("unbalanced braces in the OPS table")


def parse_contract_ops(source: str) -> dict[str, list[str]]:
    """`{op: [fields...]}`，来自 `interface_parity.rs` 的 `OPS` 表。"""
    head = source.index(TABLE_HEAD) + len(TABLE_HEAD)
    tail = source.index(TABLE_TAIL)
    body, cursor, ops = source[head:tail], 0, {}
    while True:
        rel = body.find("OpContract {", cursor)
        if rel < 0:
            break
        brace = rel + len("OpContract ")
        end = balanced_brace_end(body, brace)
        entry = strip_rust_comments(body[brace + 1 : end])
        op = re.search(r'op:\s*"([^"]+)"', entry)
        if not op:
            raise AssertionError(f"an OpContract entry at offset {rel} has no op literal")
        fields_at = entry.index("ui_fields:")
        open_bracket = entry.index("[", fields_at)
        close_bracket = entry.index("]", open_bracket)
        fields = sorted(set(re.findall(r'"([^"]+)"', entry[open_bracket + 1 : close_bracket])))
        if op.group(1) in ops:
            raise AssertionError(f"`{op.group(1)}` is declared twice")
        ops[op.group(1)] = fields
        cursor = end + 1
    if not ops:
        raise AssertionError("the OPS table parsed to zero ops")
    return ops


def parse_registry_ops(source: str) -> dict[str, list[str]]:
    """`{op: [reads...]}`，来自本宿主的 `registry.rs`。

    只认 `Registration { ... }` 行，不认 `pub struct Registration {` 定义 ——
    这正是 `registry.rs` 顶部注释里那句「由契约生成后手工冻结」的机器含义。
    """
    ops: dict[str, list[str]] = {}
    pattern = re.compile(
        r'Registration\s*\{\s*op:\s*"([^"]+)"\s*,\s*reads:\s*&\[([^\]]*)\]\s*,\s*status:\s*([^}]+?)\}',
        re.S,
    )
    for op, reads, status in pattern.findall(source):
        if op in ops:
            raise AssertionError(f"`{op}` is registered twice in registry.rs")
        ops[op] = sorted(re.findall(r'"([^"]+)"', reads))
        del status  # 只在 check 门禁里判，这里不重复
    if not ops:
        raise AssertionError("registry.rs parsed to zero registrations")
    return ops


class SecondHostContractTest(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.contract_source = CONTRACT_SOURCE.read_text(encoding="utf-8")
        self.registry_source = REGISTRY_SOURCE.read_text(encoding="utf-8")

    def test_contract_entry_count_matches_parsed_ops(self) -> None:
        """解析器不许漏读也不许多读 —— 这一条正是抓到 `undo` 是注释的那条。"""
        head = self.contract_source.index(TABLE_HEAD)
        tail = self.contract_source.index(TABLE_TAIL)
        entries = self.contract_source[head:tail].count("OpContract {")
        parsed = parse_contract_ops(self.contract_source)
        self.assertEqual(
            len(parsed),
            entries,
            f"parser recovered {len(parsed)} ops but the table has {entries} entries",
        )

    def test_registry_covers_the_contract_exactly(self) -> None:
        contract = parse_contract_ops(self.contract_source)
        registry = parse_registry_ops(self.registry_source)

        missing = sorted(set(contract) - set(registry))
        invented = sorted(set(registry) - set(contract))
        self.assertEqual(
            missing,
            [],
            f"the Windows host registers nothing for {missing}; that click would do nothing",
        )
        self.assertEqual(
            invented,
            [],
            f"the Windows host registers {invented}, which the UI cannot emit",
        )

    def test_registry_reads_every_field_the_ui_sends(self) -> None:
        contract = parse_contract_ops(self.contract_source)
        registry = parse_registry_ops(self.registry_source)
        problems: list[str] = []
        for op, fields in contract.items():
            for field in fields:
                if field not in registry[op]:
                    problems.append(f"{op} sends `{field}`, which the host does not declare reading")
            for field in registry[op]:
                if field not in fields:
                    problems.append(f"{op} declares reading `{field}`, which the UI never sends")
        self.assertEqual(problems, [], "\n  - " + "\n  - ".join(problems))

    def test_the_rust_gate_passes(self) -> None:
        """真门禁：字段级判据 + 「自称已实现但 handler 树里没有」。"""
        cargo = shutil.which("cargo")
        if cargo is None:
            self.fail(
                "cargo is not on PATH, so the second-host gate cannot run. This is a hard "
                "failure rather than a skip: a gate that quietly skips is a gate that rots."
            )
        result = subprocess.run(
            [cargo, "run", "--quiet", "--manifest-path", str(MANIFEST), "--", "check"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            result.returncode,
            0,
            f"`gmgn-windows-host check` failed with {result.returncode}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}",
        )
        self.assertIn("OK", result.stdout, f"expected an OK line, got:\n{result.stdout}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
