#!/usr/bin/env python3
"""Read-only extractor for the UI-function audit (2026-10-08).

Scans the GPUI UI layer (new DeepSeek components + Unity embedded adapter panes)
for every command literal ("op"), every interactive control id and every on_click
site, then scans the host side (Swift / Objective-C / Rust services / Unity C#)
for the consumers of those ops: the product host switch, the bridge
`supportedCommands` allow-lists, the UI-layer adapter match arms and the
settings gate. Emits JSON or Markdown on stdout (or to --out). No product file
is written.

Usage:
    python3 tools/audit-ui-function-inventory.py --out /tmp/ui-inventory.json
    python3 tools/audit-ui-function-inventory.py --markdown
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from collections import defaultdict

ROOT = os.environ.get("GMGN_AUDIT_ROOT") or os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

UI_FILES = [
    "apps/gpui-ui/src/chat.rs",
    "apps/gpui-ui/src/inbox.rs",
    "apps/gpui-ui/src/settings.rs",
    "apps/gpui-ui/src/stage_panels.rs",
    "apps/gpui-ui/src/stage_panels/props.rs",
    "apps/gpui-ui/src/stage_panels/program.rs",
    "apps/gpui-ui/src/shell.rs",
    "apps/gpui-ui/src/lyrics.rs",
    "apps/gpui-ui/src/lyrics/gpu_scene.rs",
    "apps/gpui-ui/src/i18n.rs",
    "apps/gpui-ui/src/ui_tokens.rs",
    "apps/gpui-ui/src/lib.rs",
    "apps/gpui-ui/src/state.rs",
    "apps/gpui-ui/src/primitives.rs",
    "apps/gpui-ui/src/projective_card.rs",
    "tools/fixtures/gpui-unity-overlay-probe/src/lib.rs",
    "tools/fixtures/gpui-unity-overlay-probe/src/shell_ui.rs",
    "tools/fixtures/gpui-unity-overlay-probe/src/media_ui.rs",
    "tools/fixtures/gpui-unity-overlay-probe/src/inventory_ui.rs",
    "tools/fixtures/gpui-unity-overlay-probe/src/settings_ui.rs",
    "tools/fixtures/gpui-unity-overlay-probe/host/OverlayHost.m",
]

HOST_TREES = [
    ("swift-unity", "apps/macos/UnityHost", (".swift",)),
    ("swift-product", "apps/macos/ProductHost", (".swift",)),
    ("swift-app", "apps/macos/Sources/GMGNRadio/App", (".swift",)),
    ("rust-services", "services", (".rs",)),
    ("objc-host", "tools/fixtures/gpui-unity-overlay-probe/host", (".m", ".mm", ".h")),
    ("unity-csharp", "apps/unity-player/Assets/GMGN", (".cs",)),
]

BRIDGE_FILES = [
    "apps/macos/UnityHost/UnityScreenVideoBridge.swift",
    "apps/macos/UnityHost/UnityShortcutSettingsBridge.swift",
    "apps/macos/UnityHost/UnityPresenceSettingsBridge.swift",
    "apps/macos/UnityHost/UnityAgentConnectionBridge.swift",
    "apps/macos/UnityHost/UnityMarbleWorldBridge.swift",
    "apps/macos/UnityHost/UnityChatImageBridge.swift",
]

OP_PREFIX = (
    "ui|stage|chat|inbox|wish|agent|settings|app|music|video|presence|space|"
    "speech|shortcuts|screen|world|inventory|generation|voice|tts|resident|"
    "local|system|activity|asr|reply|task|props|program|queue"
)
DOTTED_RE = re.compile(r'"(?:%s)\.[a-z0-9][a-z0-9._-]*"' % OP_PREFIX)
JSON_OP_RE = re.compile(r'"op"\s*:\s*"([^"]+)"')
ID_CALL_RE = re.compile(r'\.(?:id|accessibility_id|name)\(\s*"([^"]+)"')
CTOR_ID_RE = re.compile(
    r'\b(?:Button|TabBar|IconButton|Input|Textarea|Toggle|Slider|Checkbox|Switch|Dropdown)::new\(\s*"([^"]+)"')
ARM_RE = re.compile(r'^\s*((?:"[^"]+"\s*\|\s*)*"[^"]+")\s*=>')
MATCHES_OP_RE = re.compile(r'Some\(((?:"[^"]+"\s*\|\s*)*"[^"]+")\)')

HANDLER_PATTERNS = [
    ("eq", re.compile(r'(?:==|!=)\s*"([^"]+)"')),
    ("prefix", re.compile(r'hasPrefix\(\s*"([^"]+)"')),
    ("contains", re.compile(r'(?:contains|Contains)\(\s*"([^"]+)"')),
    ("isEqualToString", re.compile(r'isEqualToString:@\s*"([^"]+)"')),
]
OUTBOUND_RE = re.compile(r'(?:command|settingsCommand|enqueue[A-Za-z]*|submit)\s*\(\s*\[?\s*"op"')
AUTHORITY_RE = re.compile(
    r'\b([A-Za-z_][A-Za-z0-9_]*)\s*\??\.\s*'
    r'(command|settingsCommand|refresh|readPlaylist|play|selectProgram|load|import|'
    r'remove|activate|save|capture|reset|record|stop|start|setVisualMode|'
    r'selectPointCloud|setParticleSizeMultiplier|reportProgramSelectionFailure|'
    r'accept|updateTextInput|showProgramHistory|ToggleFullscreen|EnterLivecamSpace|'
    r'ToggleLyrics|BeginInventoryPlacement|BeginDevicePlacement|ResetPresentationCamera)\b'
)
FN_RE = re.compile(r'^\s*(?:pub\s+)?(?:async\s+)?fn\s+([A-Za-z0-9_]+)')
SWIFT_FN_RE = re.compile(r'^\s*(?:@\w+\s+)*(?:private\s+|public\s+|internal\s+)?'
                         r'(?:static\s+|class\s+|override\s+)*func\s+([A-Za-z0-9_]+)')
OBJC_FN_RE = re.compile(r'^\s*[-+]\s*\([^)]*\)\s*([A-Za-z0-9_]+)')
CS_FN_RE = re.compile(r'^\s*(?:public|private|internal|protected|static|\s)*'
                      r'(?:void|bool|string|int|IEnumerator|[A-Z][A-Za-z0-9_<>]*)\s+([A-Za-z0-9_]+)\s*\(')


def read_lines(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as handle:
            return handle.read().split("\n")
    except OSError:
        return []


def repo_path(path):
    return os.path.relpath(path, ROOT)


def enclosing_functions(lines):
    result, current = {}, "?"
    for index, line in enumerate(lines, start=1):
        for pattern in (FN_RE, SWIFT_FN_RE, OBJC_FN_RE, CS_FN_RE):
            match = pattern.match(line)
            if match:
                current = match.group(1)
                break
        result[index] = current
    return result


def iter_host_files():
    for label, relative, extensions in HOST_TREES:
        base = os.path.join(ROOT, relative)
        if not os.path.exists(base):
            continue
        if os.path.isfile(base):
            if base.endswith(extensions):
                yield label, base
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in
                           {"target", ".build", "Build.noindex", "DerivedData",
                            "node_modules", "Library"}]
            for name in filenames:
                if name.endswith(extensions):
                    yield label, os.path.join(dirpath, name)


def test_regions(lines):
    """Line numbers inside `#[cfg(test)]` items (brace-balanced), so a mid-file
    test module never hides production code that follows it."""
    regions = set()
    index = 0
    while index < len(lines):
        if not re.match(r'\s*#\[cfg\(test\)\]', lines[index]):
            index += 1
            continue
        start = index + 1
        depth = 0
        opened = False
        cursor = index
        while cursor < len(lines):
            stripped = re.sub(r'"(?:[^"\\]|\\.)*"', '""', lines[cursor])
            depth += stripped.count("{") - stripped.count("}")
            if "{" in stripped:
                opened = True
            if not opened and cursor > index + 1:
                break
            if opened and depth <= 0 and cursor > index:
                break
            cursor += 1
        for line_number in range(start, min(cursor, len(lines) - 1) + 1):
            regions.add(line_number)
        index = cursor + 1
    return regions


def extract_ui(path):
    rel = repo_path(path)
    lines = read_lines(path)
    scopes = enclosing_functions(lines)
    tests = test_regions(lines)
    ops, controls, clicks, literals, consumers = [], [], [], [], []
    for index, line in enumerate(lines, start=1):
        stripped = line.strip()
        scope = scopes.get(index, "?")
        tags = {"test": True} if index in tests else {}
        json_ops = JSON_OP_RE.findall(line)
        for op in json_ops:
            ops.append({"op": op, "file": rel, "line": index, "scope": scope,
                        "kind": "json-op", "text": stripped[:200], **tags})
        for match in ID_CALL_RE.finditer(line):
            controls.append({"id": match.group(1), "file": rel, "line": index,
                             "scope": scope, "kind": "id-call", "text": stripped[:200], **tags})
        for match in CTOR_ID_RE.finditer(line):
            controls.append({"id": match.group(1), "file": rel, "line": index,
                             "scope": scope, "kind": "ctor", "text": stripped[:200], **tags})
        for match in DOTTED_RE.finditer(line):
            literal = match.group(0).strip('"')
            kind = "op" if literal in json_ops else "unknown"
            if kind == "unknown" and ("accessibility_id(" in line or ".id(" in line or ".name(" in line):
                kind = "control-id"
            literals.append({"literal": literal, "file": rel, "line": index,
                             "scope": scope, "kind": kind, "text": stripped[:200], **tags})
        # A UI-layer adapter that consumes the component's command itself.
        arm = ARM_RE.match(line)
        if arm:
            for op in re.findall(r'"([^"]+)"', arm.group(1)):
                consumers.append({"op": op, "file": rel, "line": index, "scope": scope,
                                  "kind": "match-arm", "text": stripped[:200], **tags})
        see = re.search(r'"op"\]\.as_str\(\),\s*Some\(', line)
        if see:
            window = "\n".join(lines[index - 1:index + 6])
            for match in MATCHES_OP_RE.finditer(window):
                for op in re.findall(r'"([^"]+)"', match.group(1)):
                    consumers.append({"op": op, "file": rel, "line": index, "scope": scope,
                                      "kind": "matches-op", "text": stripped[:200], **tags})
        if "on_click" in line or "cx.listener" in line or "AddListener" in line:
            window = "\n".join(lines[index - 1:index + 40])
            nearby = sorted(set(JSON_OP_RE.findall(window)) |
                            {m.strip('"') for m in DOTTED_RE.findall(window)})
            clicks.append({"file": rel, "line": index, "scope": scope,
                           "ops": nearby, "text": stripped[:200], **tags})
    return ops, controls, clicks, literals, consumers


def extract_host(label, path):
    rel = repo_path(path)
    lines = read_lines(path)
    scopes = enclosing_functions(lines)
    found = []
    for index, line in enumerate(lines, start=1):
        stripped = line.strip()
        scope = scopes.get(index, "?")
        outbound = bool(OUTBOUND_RE.search(line))
        case_match = re.match(r'^\s*case\s+(.+?)\s*:', line)
        if case_match:
            for op in re.findall(r'"([^"]+)"', case_match.group(1)):
                found.append({"op": op, "file": rel, "line": index, "scope": scope,
                              "kind": "case", "host": label, "text": stripped[:220],
                              "outbound": outbound})
            continue
        if "supportedCommands" in line and "=" in line and "[" in line:
            joined, cursor = line, index
            while "]" not in joined and cursor < len(lines):
                cursor += 1
                joined += "\n" + lines[cursor - 1]
            for op in re.findall(r'"([^"]+)"', joined):
                found.append({"op": op, "file": rel, "line": index, "scope": scope,
                              "kind": "supported-array", "host": label,
                              "text": stripped[:220], "outbound": False})
            continue
        array_contains = re.search(r'\[([^\]]*)\]\s*\.\s*contains\(', line)
        if array_contains:
            for op in re.findall(r'"([^"]+)"', array_contains.group(1)):
                found.append({"op": op, "file": rel, "line": index, "scope": scope,
                              "kind": "array-contains", "host": label,
                              "text": stripped[:220], "outbound": outbound})
            continue
        for kind, pattern in HANDLER_PATTERNS:
            for match in pattern.finditer(line):
                found.append({"op": match.group(1), "file": rel, "line": index,
                              "scope": scope, "kind": kind, "host": label,
                              "text": stripped[:220], "outbound": outbound})
    return found


def authority_near(lines, line_number, span=30):
    hits = []
    for offset in range(line_number - 1, min(len(lines), line_number - 1 + span)):
        text = lines[offset].strip()
        match = AUTHORITY_RE.search(text)
        if match:
            entry = {"line": offset + 1, "call": f"{match.group(1)}.{match.group(2)}",
                     "text": text[:160]}
            if entry not in hits:
                hits.append(entry)
        if len(hits) >= 3:
            break
    return hits


def settings_gate_ops():
    """The Unity settings window only forwards ops in this allow-list
    (UnityMediaHost.settingsSnapshot().supportedCommands)."""
    gate = set()
    host = os.path.join(ROOT, "apps/macos/UnityHost/UnityMediaHost.swift")
    lines = read_lines(host)
    joined, cursor = "", 0
    for index, line in enumerate(lines, start=1):
        if re.search(r'"supportedCommands"\s*:\s*\[', line):
            joined, cursor = line, index
            while cursor < len(lines):
                if re.search(r'\]\s*$', joined.rstrip()) and not lines[cursor].lstrip().startswith("+"):
                    break
                cursor += 1
                joined += "\n" + lines[cursor - 1]
            break
    for op in re.findall(r'"([^"]+)"', joined):
        if op != "supportedCommands" and "." in op:
            gate.add(op)
    for relative in BRIDGE_FILES:
        text = "\n".join(read_lines(os.path.join(ROOT, relative)))
        match = re.search(r'supportedCommands\s*=\s*\[([^\]]*)\]', text)
        if match:
            for op in re.findall(r'"([^"]+)"', match.group(1)):
                gate.add(op)
    return sorted(gate)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--markdown", action="store_true")
    parser.add_argument("--out")
    args = parser.parse_args()

    ui_ops, controls, clicks, literals, consumers, ui_file_summary = [], [], [], [], [], []
    for relative in UI_FILES:
        path = os.path.join(ROOT, relative)
        if not os.path.exists(path):
            ui_file_summary.append({"file": relative, "missing": True})
            continue
        file_ops, file_controls, file_clicks, file_literals, file_consumers = extract_ui(path)
        ui_ops.extend(file_ops)
        controls.extend(file_controls)
        clicks.extend(file_clicks)
        literals.extend(file_literals)
        consumers.extend(file_consumers)
        ui_file_summary.append({
            "file": relative, "missing": False,
            "ops": sorted({row["op"] for row in file_ops}),
            "control_ids": sorted({row["id"] for row in file_controls}),
            "click_sites": len(file_clicks),
            "adapter_arms": sorted({row["op"] for row in file_consumers}),
        })

    host_sites, host_line_cache = [], {}
    for label, path in sorted(iter_host_files(), key=lambda item: (item[0], item[1])):
        rel = repo_path(path)
        host_line_cache[rel] = read_lines(path)
        host_sites.extend(extract_host(label, path))

    host_index = defaultdict(list)
    for site in host_sites:
        host_index[site["op"]].append(site)
    consumer_index = defaultdict(list)
    for site in consumers:
        consumer_index[site["op"]].append(site)

    explicit_ops = {row["op"] for row in ui_ops}
    control_ids = {row["id"] for row in controls}
    bare_literals = {row["literal"] for row in literals}
    ui_op_set = set(explicit_ops)
    for literal in bare_literals:
        if literal in control_ids:
            continue
        if host_index.get(literal) or consumer_index.get(literal):
            ui_op_set.add(literal)

    op_rows = []
    for op in sorted(ui_op_set):
        seen, ui_sites = set(), []
        for row in ui_ops + [r for r in literals if r["literal"] == op]:
            if row.get("op", row.get("literal")) != op:
                continue
            key = (row["file"], row["line"])
            if key in seen:
                continue
            seen.add(key)
            ui_sites.append({"file": row["file"], "line": row["line"], "scope": row["scope"],
                             "kind": row["kind"], "text": row["text"],
                             **({"test": True} if row.get("test") else {})})
        ui_sites.sort(key=lambda row: (row["file"], row["line"]))
        handler_sites = host_index.get(op, [])
        inbound = [site for site in handler_sites if not site.get("outbound")]
        authorities = []
        for site in inbound[:3]:
            for near in authority_near(host_line_cache.get(site["file"], []), site["line"]):
                entry = {"file": site["file"], **near}
                if entry not in authorities:
                    authorities.append(entry)
        op_rows.append({
            "op": op,
            "ui_sites": ui_sites,
            "ui_files": sorted({row["file"] for row in ui_sites}),
            "ui_scopes": sorted({row["scope"] for row in ui_sites if row["scope"] != "?"}),
            "test_only": bool(ui_sites) and all(row.get("test") for row in ui_sites),
            "adapter_sites": consumer_index.get(op, []),
            "handler_sites": handler_sites,
            "inbound_sites": inbound,
            "authority_calls": authorities[:6],
        })

    report = {
        "snapshot_utc": __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc).isoformat(),
        "ui_op_count": len(ui_op_set),
        "ui_explicit_op_count": len(explicit_ops),
        "control_count": len(controls),
        "host_site_count": len(host_sites),
        "settings_gate_ops": settings_gate_ops(),
        "ui_files": ui_file_summary,
        "ops": op_rows,
        "controls": controls,
        "click_sites": clicks,
    }
    if args.markdown:
        print(render_markdown(report))
    elif args.out:
        with open(args.out, "w", encoding="utf-8") as handle:
            handle.write(json.dumps(report, ensure_ascii=False, indent=1))
    else:
        print(json.dumps(report, ensure_ascii=False, indent=1))
    return 0


def render_markdown(report):
    gate = set(report["settings_gate_ops"])
    out = ["# UI op extraction (raw)", "",
           f"- snapshot: {report['snapshot_utc']}",
           f"- UI ops: {report['ui_op_count']} (explicit `\"op\"`: {report['ui_explicit_op_count']})",
           f"- control ids: {report['control_count']}",
           f"- host handler sites: {report['host_site_count']}",
           f"- settings gate entries: {len(gate)}", "",
           "| op | UI file:line (scope) | adapter consumer | host handler | authority | in settings gate |",
           "| --- | --- | --- | --- | --- | --- |"]
    for row in report["ops"]:
        ui = ", ".join(f"`{site['file'].split('/')[-1]}:{site['line']}`({site['scope']})"
                       for site in row["ui_sites"][:2]) or "-"
        adapter = ", ".join(f"`{site['file'].split('/')[-1]}:{site['line']}`"
                            for site in row["adapter_sites"][:2]) or "-"
        handlers = row["inbound_sites"] or row["handler_sites"]
        host = ", ".join(f"`{site['file'].split('/')[-1]}:{site['line']}`[{site['kind']}]"
                         for site in handlers[:2]) or "**NONE**"
        auth = ", ".join(f"`{call['call']}`@{call['file'].split('/')[-1]}:{call['line']}"
                         for call in row["authority_calls"][:2]) or "-"
        out.append(f"| `{row['op']}` | {ui} | {adapter} | {host} | {auth} | "
                   f"{'yes' if row['op'] in gate else 'no'} |")
    return "\n".join(out)


if __name__ == "__main__":
    sys.exit(main())
