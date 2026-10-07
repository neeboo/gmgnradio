#!/usr/bin/env python3
"""Compile the actual feature store; no device, audio or GUI interaction."""
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
source = (repo / "apps/macos/Sources/GMGNRadio/VisualEngine/OrbMotionModel.swift").read_text()
store = source.split("struct OrbMotionFrame:", 1)[0]
program = store + r'''
extension VisualAudioFeatureStore {
    func holdForTest(_ entered: DispatchSemaphore, _ release: DispatchSemaphore) {
        storage.withLock { _ in entered.signal(); release.wait() }
    }
}
let store = VisualAudioFeatureStore()
let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
let completed = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    store.holdForTest(entered, release)
    completed.signal()
}
precondition(entered.wait(timeout: .now() + 2) == .success)
let started = DispatchTime.now().uptimeNanoseconds
store.updateFromAudioTap(VisualAudioFeatures(low: 1, mid: 1, high: 1))
let elapsed = DispatchTime.now().uptimeNanoseconds - started
release.signal()
precondition(completed.wait(timeout: .now() + 2) == .success)
precondition(elapsed < 50_000_000, "Audio visual tap blocked behind renderer")
precondition(store.current == .silent, "Busy render reader must only drop visual frame")
let next = VisualAudioFeatures(low: 0.3, mid: 0.5, high: 0.7)
store.updateFromAudioTap(next)
precondition(store.current == next, "Next tap must publish fresh features")
print("PASS: actual audio feature store contention returns without waiting, next frame recovers")
'''
with tempfile.TemporaryDirectory(prefix="gmgn-tap-lock-") as temporary:
    directory = Path(temporary)
    swift = directory / "main.swift"
    swift.write_text(program)
    executable = directory / "tap-check"
    subprocess.run(["swiftc", str(swift), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
