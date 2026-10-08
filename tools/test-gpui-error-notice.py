#!/usr/bin/env python3
"""Compile actual App error methods in both presentation branches, no audio/UI."""
from pathlib import Path
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
source=(ROOT/"apps/macos/Sources/GMGNRadio/App/GMGNRadioApp.swift").read_text()
methods=source[source.index("    private func presentPlaybackError("):source.index("    private func restoreSavedProgramPlayback()")]
snapshot=source[source.index("    func gpuiErrorNoticeSnapshot()"):source.index("    func gpuiSubmit(")]
fields="\n".join(line for line in source.splitlines() if "private var gpuiErrorNotice" in line)
harness='''import Foundation
@MainActor final class NSAlert {
    enum Style { case warning }
    var alertStyle:Style = .warning
    var messageText="", informativeText=""
    static var calls:[(String,String)]=[]
    func runModal(){Self.calls.append((messageText,informativeText))}
}
@MainActor final class AppDelegate {
FIELDS
#if GMGN_GPUI_PRODUCT_BOOTSTRAP
SNAPSHOT
#endif
METHODS
    func exercise() {
        let ordinary=NSError(domain:"private-fixture",code:1,userInfo:[NSLocalizedDescriptionKey:"真实错误详情"])
        let ats=NSError(domain:NSURLErrorDomain,code:NSURLErrorAppTransportSecurityRequiresSecureConnection)
#if GMGN_GPUI_PRODUCT_BOOTSTRAP
        precondition(gpuiErrorNoticeSnapshot() == nil)
        presentPlaybackError(ordinary)
        let first=gpuiErrorNoticeSnapshot()!
        precondition(first["revision"] as? UInt64 == 1 && first["title"] as? String == "这首音乐暂时播放不了")
        precondition(first["message"] as? String == "真实错误详情")
        precondition(gpuiErrorNoticeSnapshot()!["revision"] as? UInt64 == 1)
        presentProgramError(ats)
        let second=gpuiErrorNoticeSnapshot()!
        precondition(second["revision"] as? UInt64 == 2 && second["title"] as? String == "音乐资源连接失败")
        precondition(second["message"] as? String == "音乐服务返回了不安全的播放地址，应用已阻止连接。")
        presentProgramError(ordinary)
        precondition(gpuiErrorNoticeSnapshot()!["title"] as? String == "DJ 暂时无法完成这个操作")
        precondition(gpuiErrorNoticeSnapshot()!["revision"] as? UInt64 == 3)
        precondition(NSAlert.calls.isEmpty)
        print("PASS: actual GPUI error methods publish stable revisions and ATS/detail text; modal calls=0")
#else
        presentPlaybackError(ordinary);presentProgramError(ats);presentProgramError(ordinary)
        precondition(NSAlert.calls.count == 3)
        precondition(NSAlert.calls[0].0 == "这首音乐暂时播放不了" && NSAlert.calls[0].1 == "真实错误详情")
        precondition(NSAlert.calls[1].0 == "音乐资源连接失败" && NSAlert.calls[1].1 == "音乐服务返回了不安全的播放地址，应用已阻止连接。")
        precondition(NSAlert.calls[2].0 == "DJ 暂时无法完成这个操作")
        print("PASS: actual legacy error methods retain modal branch and exact text")
#endif
    }
}
@main @MainActor struct Acceptance {static func main(){AppDelegate().exercise()}}
'''.replace("FIELDS",fields).replace("SNAPSHOT",snapshot).replace("METHODS",methods)
with tempfile.TemporaryDirectory(prefix="gmgn-error-notice-") as temporary:
    folder=Path(temporary);fixture=folder/"Fixture.swift";fixture.write_text(harness)
    for define in [True,False]:
        binary=folder/("gpui" if define else "legacy")
        command=["swiftc","-swift-version","6","-parse-as-library"]
        if define:command += ["-D","GMGN_GPUI_PRODUCT_BOOTSTRAP"]
        subprocess.run(command+[str(fixture),"-o",str(binary)],check=True,timeout=60)
        subprocess.run([str(binary)],check=True,timeout=10)
print("CLEANUP: private compiled fixture directory removed; no native UI or audio invoked")
