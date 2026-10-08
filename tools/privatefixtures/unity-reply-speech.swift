import Foundation

// Production Settings methods are compiled unchanged against these private fields.
/*
// SETTINGS FIELDS BEGIN
let client: RustVoiceClient
let speechHostSessionID = "private-host"
let chatSpeechAuthority: RustSpeechDeliveryClient
var chatSpeechEventTask: Task<Void, Never>?
var speechClosed = false
var replySpeech: RustSpeechSynthesizer?
var preview: RustSpeechSynthesizer?
let replyStatus = AgentSpeechStatusStore()
var replyPlayback = AgentSpeechPlaybackState.idle
var previewPlayback = AgentSpeechPlaybackState.idle
var onSpeechPlaybackChanged: ((Bool) -> Void)?
init(_ endpoint: String) {
    client = RustVoiceClient(root: URL(fileURLWithPath: endpoint).deletingLastPathComponent(), allowsLaunching: false)
    chatSpeechAuthority = RustSpeechDeliveryClient(scopeID: "unity.reply", hostSessionID: speechHostSessionID, voiceClient: client)
}
func voiceConfiguration(for purpose: String) -> RustVoiceConfiguration { .init(apiKey: "synthetic-memory-only") }
func flush() async { await chatSpeechEventTask?.value }
// SETTINGS FIELDS END
*/
@MainActor final class Mixer {
    var envelope = DuckingEnvelope(sampleRate: 100)
    func setDJSpeaking(_ value: Bool) { envelope.setDJSpeaking(value) }
    func gain() -> Float { envelope.advance(frameCount: 100) }
}
@MainActor final class AgentSpeechStatusStore { var lastErrorMessage: String? }
@MainActor final class Device: StreamingPCMDevice {
    var level: (@Sendable (Float) -> Void)?
    var played: [@Sendable () -> Void] = []
    var scheduled = 0
    func start(onLevel: @escaping @Sendable (Float) -> Void) throws { level=onLevel }
    func schedule(_ samples:[Float],onPlayed:@escaping @Sendable ()->Void) throws {
        precondition(samples.count==1);scheduled+=1;played.append(onPlayed);level?(0.42)
    }
    func stop() {}
    func drain() { let old=played; played=[]; for callback in old {callback()} }
}
@MainActor final class Stream: RustVoiceStreaming {
    let sessionID = UUID().uuidString
    let identity: RustSpeechDeliveryClient.Identity
    var index = 0
    init(_ identity: RustSpeechDeliveryClient.Identity) { self.identity=identity }
    func nextEvent() async throws -> RustVoiceEvent {
        index += 1
        if index == 1 { return .init(sessionID:sessionID,type:"audio",audioBase64:Data([0,0]).base64EncodedString(),sampleRate:24000,channels:1,encoding:"pcm16le",delivery:identity,sequence:0,frameCount:1) }
        if index == 2 { return .init(sessionID:sessionID,type:"input_finished",delivery:identity) }
        try await Task.sleep(for:.seconds(20));throw CancellationError()
    }
    func cancel() {}
    func close() {}
}
// Device/provider-only adapter. Every issued ticket and terminal receipt uses
// the unchanged production RustSpeechDeliveryPlayback implementation.
@MainActor final class RustSpeechSynthesizer {
    static var database = ""
    static var started: [String] = []
    static var devices: [Device] = []
    let playback: RustSpeechDeliveryPlayback
    init(configuration: @escaping @MainActor () -> RustVoiceConfiguration, statusStore: AgentSpeechStatusStore,
         client: RustVoiceClient, scopeID: String, hostSessionID: String, deliveryMode: String,
         onPlaybackChanged: @escaping @MainActor (AgentSpeechPlaybackState) -> Void) {
        let device = Device(); Self.devices.append(device)
        playback=RustSpeechDeliveryPlayback(authority:RustSpeechDeliveryClient(scopeID:scopeID,hostSessionID:hostSessionID,voiceClient:client),player:StreamingPCMPlayer(makeDevice:{device}),
            start:{ text, _, ticket in
                Self.started.append(text)
                try Self.providerFact(ticket.identity)
                return Stream(ticket.identity)
            },onPlaybackChanged:onPlaybackChanged,onPendingChanged:{_ in},onFailure:{_ in statusStore.lastErrorMessage="unconfirmed"})
    }
    func speakIssued(_ dispatch: RustSpeechDeliveryClient.ChatDispatch) async {
        await playback.submitIssued(utteranceID:dispatch.utteranceID,text:dispatch.text,configuration:.init(apiKey:"synthetic-memory-only"),view:dispatch.delivery)
    }
    func applyIssuedSpeechView(_ view: RustSpeechDeliveryClient.View) async { await playback.applyIssued(view) }
    func stopSpeaking() { playback.cancel() }
    static func sql(_ statement: String) throws -> String {
        let process=Process();process.executableURL=URL(fileURLWithPath:"/usr/bin/sqlite3");process.arguments=[database,statement]
        let pipe=Pipe();process.standardOutput=pipe;try process.run();let data=pipe.fileHandleForReading.readDataToEndOfFile();process.waitUntilExit()
        precondition(process.terminationStatus==0);return String(decoding:data,as:UTF8.self)
    }
    static func providerFact(_ identity: RustSpeechDeliveryClient.Identity) throws {
        // Synthetic provider packet reservation only: no native receipt or success
        // state is injected. HTTP device_started/scheduled/played decide delivery.
        let text=try sql("SELECT payload FROM speech_delivery_lanes WHERE scope='unity.reply';")
        var lane=try JSONSerialization.jsonObject(with:Data(text.utf8)) as! [String:Any]
        var states=lane["states"] as! [[String:Any]]
        let index=states.firstIndex { ($0["identity"] as? [String:Any])?["utteranceID"] as? String == identity.utteranceID }!
        states[index]["status"]="starting";states[index]["nextSequence"]=1;states[index]["totalFrames"]=1;states[index]["playedFrames"]=0;states[index]["eof"]=true
        states[index]["packets"]=[["sequence":0,"frameCount":1,"scheduled":false,"played":false]]
        lane["states"]=states
        let value=String(decoding:try JSONSerialization.data(withJSONObject:lane),as:UTF8.self).replacingOccurrences(of:"'",with:"''")
        _=try sql("UPDATE speech_delivery_lanes SET payload='\(value)' WHERE scope='unity.reply';")
    }
}
@main struct Checks {
    @MainActor static func main() async throws {
        let endpoint=CommandLine.arguments[1]
        RustSpeechSynthesizer.database=URL(fileURLWithPath:endpoint).deletingLastPathComponent().appendingPathComponent("tasks.sqlite3").path
        let settings=Settings(endpoint),graph=Graph()
        let host=Host(settings)
        settings.onSpeechPlaybackChanged={graph.setResidentSpeechPlaying($0)}
        let transport=TaskdHTTPAuthorityClient(endpointFile:endpoint,helperPath:"/private/never",allowsLaunching:false,timeout:5)
        func rpc(_ method:String,_ params:[String:Any]) async throws -> [String:Any] {
            let input=try JSONSerialization.data(withJSONObject:params)
            let output=try await Task.detached {
                let params=try JSONSerialization.jsonObject(with:input) as! [String:Any]
                return try JSONSerialization.data(withJSONObject:transport.call(method:method,params:params))
            }.value
            return try JSONSerialization.jsonObject(with:output) as! [String:Any]
        }
        func source(_ id:Int)->[String:Any] { ["kind":"chat","backend":"codex","scopeID":"private-chat","hostSessionID":"model-host","requestID":String(id)] }
        func event(_ id:Int,_ kind:String) async {
            if kind=="accepted" {host.send(NSNumber(value:id))}
            else if kind=="cancelled" {host.cancel(NSNumber(value:id))}
            else {host.poll([["requestID":NSNumber(value:id),"kind":kind,"text":"untrusted UI text","speechSource":source(id)]])}
            await settings.flush()
        }
        func until(_ label:String,_ predicate:()->Bool) async throws { let end=Date().addingTimeInterval(4);while !predicate(){precondition(Date()<end,"timeout \(label)");try await Task.sleep(for:.milliseconds(10))} }
        func autoSpeak(_ value:Bool) async throws {
            let snapshot=try await rpc("product_settings_read",[:])
            _=try await rpc("product_settings_apply",["requestID":UUID().uuidString,"expectedRevision":snapshot["revision"]!,"changes":["autoSpeak":value]])
        }
        try await autoSpeak(true)
        await event(1,"accepted");await event(1,"delta")
        precondition(RustSpeechSynthesizer.started.isEmpty)
        await event(1,"reply");await event(1,"reply")
        try await until("first packet"){RustSpeechSynthesizer.devices.first?.scheduled==1}
        precondition(RustSpeechSynthesizer.started==["confirmed reply 1"])
        precondition(settings.replyPlaybackSnapshot["isPlaying"] as? Bool == true)
        precondition(graph.duckingController.gain()<=0.301 && graph.musicVolume==0.72)
        precondition(settings.replyPlaybackSnapshot["level"] as? Float == 0.42)
        let active=try await rpc("speech_delivery_read",["scopeID":"unity.reply","hostSessionID":"private-host"])
        precondition((active["states"] as! [[String:Any]]).last?["status"] as? String != "delivered")
        RustSpeechSynthesizer.devices[0].drain()
        try await until("drained release"){!graph.residentSpeechPlaying}
        let delivered=try await rpc("speech_delivery_read",["scopeID":"unity.reply","hostSessionID":"private-host"])
        precondition((delivered["states"] as! [[String:Any]]).last?["status"] as? String == "delivered")
        precondition(graph.duckingController.gain()>=0.999)
        await event(2,"accepted");await event(1,"reply");await event(2,"cancelled");await event(2,"reply")
        precondition(RustSpeechSynthesizer.started.count==1)
        try await autoSpeak(false);await event(3,"accepted");await event(3,"reply")
        precondition(RustSpeechSynthesizer.started.count==1)
        await event(4,"accepted");await event(4,"failure");await event(4,"reply")
        precondition(RustSpeechSynthesizer.started.count==1)
        try await autoSpeak(true);await event(5,"accepted");await event(5,"reply")
        try await until("second packet"){RustSpeechSynthesizer.devices[0].scheduled==2}
        precondition(graph.duckingController.gain()<=0.301)
        let oldLevel=RustSpeechSynthesizer.devices[0].level
        await event(6,"accepted")
        try await until("new send stops old"){!graph.residentSpeechPlaying}
        RustSpeechSynthesizer.devices[0].drain();oldLevel?(1);await event(5,"reply")
        try await Task.sleep(for:.milliseconds(20))
        precondition(graph.duckingController.gain()>=0.999 && graph.musicVolume==0.72)
        precondition(settings.replyPlaybackSnapshot["level"] as? Float == 0)
        precondition(RustSpeechSynthesizer.started==["confirmed reply 1","confirmed reply 5"])
        let muted=RustSpeechDeliveryClient(scopeID:"private-muted",hostSessionID:"private-host",voiceClient:settings.client)
        _=try await muted.chatEvent(requestID:"7",kind:"accepted")
        let receipt=try await muted.chatEvent(requestID:"7",kind:"reply",source:source(7),testMuted:true)
        precondition(receipt.dispatch==nil)
        let invalid=RustSpeechDeliveryClient(scopeID:"private-invalid",hostSessionID:"private-host",voiceClient:settings.client)
        _=try await invalid.chatEvent(requestID:"8",kind:"accepted")
        var wrong=source(8);wrong["hostSessionID"]="other-host"
        do {_=try await invalid.chatEvent(requestID:"8",kind:"reply",source:wrong);preconditionFailure("wrong completed-source host accepted")}
        catch {precondition(RustSpeechSynthesizer.started.count==2)}
        // Autonomous FIFO input is forwarded immediately; Rust picks the next
        // ticket, and the production consumer waits for genuine played receipts.
        let playback=settings.replySpeech!.playback
        playback.submit(text:"full first reply",configuration:.init(apiKey:"synthetic-memory-only"),mode:"fifo",completion:nil)
        playback.submit(text:"autonomous second reply",configuration:.init(apiKey:"synthetic-memory-only"),mode:"fifo",completion:nil)
        try await until("FIFO first"){RustSpeechSynthesizer.devices[0].scheduled==3}
        precondition(RustSpeechSynthesizer.started.last=="full first reply")
        RustSpeechSynthesizer.devices[0].drain()
        try await until("FIFO next after played"){RustSpeechSynthesizer.devices[0].scheduled==4}
        precondition(RustSpeechSynthesizer.started.suffix(2)==["full first reply","autonomous second reply"])
        playback.submit(text:"queued then cancelled",configuration:.init(apiKey:"synthetic-memory-only"),mode:"fifo",completion:nil)
        settings.stopReplySpeech()
        try await until("queue stopped"){!graph.residentSpeechPlaying}
        RustSpeechSynthesizer.devices[0].drain()
        try await Task.sleep(for:.milliseconds(30))
        precondition(!RustSpeechSynthesizer.started.contains("queued then cancelled"))
        print("PASS real Rust send/cancel/failure/mute/duplicate/out-of-order selection; issued ticket scheduled/played completion and stale-drain rejection; 0.3 ducking + unchanged user volume. Synthetic provider reservation/PCM device only; no actual provider or audio.")
    }
}
