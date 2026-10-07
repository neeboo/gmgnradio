#!/usr/bin/env python3
"""Compile the production Unity-window title predicate without opening windows."""
from pathlib import Path
import re
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = (repo / "apps/macos/UnityHost/UnityWindowModeBridge.swift").read_text()
matches = re.findall(r'\$0\.title\.([A-Za-z]+\("[^"\n]+"\))', source)
assert len(matches) == 1, "Expected exactly one production window-title predicate"
predicate = matches[0]
program = '''import Foundation
func accepts(_ title: String) -> Bool { title.''' + predicate + ''' }
let cases: [(String, Bool)] = [
    ("gmgn radio", true),
    ("GMGN Unity Sample", true),
    ("GmGn Radio", true),
    ("Unity Sample", false),
    ("Music Player", false),
    ("", false),
]
for (title, expected) in cases {
    precondition(accepts(title) == expected, "Window-title mismatch: \\(title)")
}
print("PASS: production window-title predicate, \\(cases.count) cases")
'''
with tempfile.TemporaryDirectory(prefix="gmgn-window-title-") as temporary:
    directory = Path(temporary)
    swift = directory / "main.swift"
    executable = directory / "window-title-check"
    swift.write_text(program)
    subprocess.run(["swiftc", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
