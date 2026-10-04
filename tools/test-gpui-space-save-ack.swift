// Production save callback regression with in-memory store only; never writes user keys.
import Foundation
let source=try String(contentsOfFile:"apps/macos/ProductHost/ProductSettingsParity.swift",encoding:.utf8)
let start=source.range(of:"    private func saveProps(")!.lowerBound
let end=source.range(of:"    private func installLabel(",range:start..<source.endIndex)!.lowerBound
let method=String(source[start..<end])
let harness = #"""
import Foundation
enum PropGenerationError: Error, LocalizedError {
    case invalidEndpoint
    var errorDescription:String? { "地址错误" }
}
struct PropGenerationConfiguration {
    let endpoint:URL;let token:String
    init(endpoint:URL,token:String)throws {
        guard endpoint.scheme=="https",!token.isEmpty else{throw PropGenerationError.invalidEndpoint}
        self.endpoint=URL(string:endpoint.absoluteString.hasSuffix("/") ? String(endpoint.absoluteString.dropLast()) : endpoint.absoluteString)!
        self.token=token
    }
}
final class Store {
    var value:PropGenerationConfiguration?
    var fail=false
    var writes=0
    func load()throws->PropGenerationConfiguration?{value}
    func save(_ config:PropGenerationConfiguration)throws{
        if fail{throw CocoaError(.fileWriteNoPermission)}
        value=config;writes+=1
    }
}
extension Notification.Name { static let propGenerationConfigurationDidChange=Notification.Name("test-only") }
final class Settings {
    let props=Store()
    var operations:[String:Task<Void,Never>]=[:]
    var spaceNotice:String?
    var spaceHasError=false
    var propSaveRevision:UInt64=0
    var propEndpoint=""
    func loadPropConfiguration(){propEndpoint=props.value?.endpoint.absoluteString ?? ""}
    \#(method)
    func save(_ endpoint:String,_ key:String="")->Bool{saveProps(["endpoint":endpoint,"apiKey":key])}
}
let ui=Settings()
precondition(!ui.save("https://example.test"))
precondition(ui.propSaveRevision==0&&ui.spaceHasError&&ui.props.writes==0)
precondition(ui.save(" https://example.test/ ","fixture-only"))
precondition(ui.propSaveRevision==1 && ui.propEndpoint=="https://example.test" && !ui.spaceHasError)
precondition(!ui.save("https://changed.test"))
precondition(ui.propSaveRevision==1&&ui.spaceNotice=="更换服务地址时请同时填写密钥。")
precondition(ui.save("https://example.test/"))
precondition(ui.propSaveRevision==2&&ui.props.writes==2)
ui.props.fail=true
precondition(!ui.save("https://example.test"))
precondition(ui.propSaveRevision==2&&ui.spaceHasError&&ui.props.writes==2)
precondition(!ui.save("http://invalid.test","fixture-only"))
precondition(ui.propSaveRevision==2&&ui.spaceNotice=="地址错误")
print("PASS: production space save ack, normalized endpoint and failure regressions; in-memory store only")
"""#
let dir=FileManager.default.temporaryDirectory.appendingPathComponent("gmgn-save-ack-\(UUID())")
try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
defer{try? FileManager.default.removeItem(at:dir)}
let file=dir.appendingPathComponent("main.swift");try harness.write(to:file,atomically:true,encoding:.utf8)
let runner=Process();runner.executableURL=URL(fileURLWithPath:"/usr/bin/swift");runner.arguments=[file.path]
try runner.run();runner.waitUntilExit();precondition(runner.terminationStatus==0)
