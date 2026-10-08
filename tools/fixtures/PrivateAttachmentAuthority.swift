import Foundation

// Compile-only launch glue; every rule/request uses the real private HTTP daemon.
final class TaskdHTTPAuthorityClient: @unchecked Sendable {
    init(endpointFile: String, helperPath: String, allowsLaunching: Bool, timeout: TimeInterval) { fatalError("fixture must inject transport") }
    func call(method: String, params: [String:Any]) throws -> [String:Any] { fatalError("fixture must inject transport") }
}
enum WorldAuthorityEndpoint {
    static func taskServiceRoot() -> URL { URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true) }
}
enum FixtureFailure: Error { case rejected(String), timedOut, invalidResponse }
actor PreparationGate {
    private var continuation: CheckedContinuation<Void,Never>?
    var waiting: Bool {continuation != nil}
    func wait() async {await withCheckedContinuation {continuation=$0}}
    func release() {continuation?.resume();continuation=nil}
}
final class ResponseBox: @unchecked Sendable {
    let lock = NSLock(); var data = Data(); var error: Error?
    func receive(_ data: Data) { lock.lock();self.data = data;lock.unlock() }
    func finish(_ error: Error?) {lock.lock();self.error = error;lock.unlock()}
}
final class PrivateRPC: @unchecked Sendable {
    struct Endpoint: Decodable {let address: String;let token: String}
    let endpoint: Endpoint
    init(_ path: String) throws {endpoint = try JSONDecoder().decode(Endpoint.self,from:Data(contentsOf:URL(fileURLWithPath:path)))}
    func call(_ method: String, _ params: Data) throws -> Data {
        guard endpoint.address.hasPrefix("127.0.0.1:") else {throw FixtureFailure.invalidResponse}
        var request = URLRequest(url:URL(string:"http://\(endpoint.address)/rpc")!,timeoutInterval:10)
        request.httpMethod = "POST";request.setValue("Bearer \(endpoint.token)",forHTTPHeaderField:"Authorization")
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["id":UUID().uuidString,"method":method,"params":JSONSerialization.jsonObject(with:params)])
        let box = ResponseBox(), done = DispatchSemaphore(value:0)
        let transport = TaskdHTTPTransport(streaming:false,receive:{box.receive($0)},completion:{box.finish($0);done.signal()})
        transport.start(request)
        guard done.wait(timeout:.now()+12) == .success else {transport.cancel();throw FixtureFailure.timedOut}
        if let error = box.error {throw error}
        guard let envelope = try JSONSerialization.jsonObject(with:box.data) as? [String:Any] else {throw FixtureFailure.invalidResponse}
        if let error = envelope["error"] as? [String:Any] {throw FixtureFailure.rejected(error["code"] as? String ?? "unknown")}
        guard let result = envelope["result"] else {throw FixtureFailure.invalidResponse}
        return try JSONSerialization.data(withJSONObject:result)
    }
}
final class LostReplyRPC: @unchecked Sendable {
    let rpc: PrivateRPC;let lostMethod: String;private let lock=NSLock()
    private var dropped=false;private var calls:[String:Int]=[:]
    init(_ rpc: PrivateRPC, method: String) {self.rpc=rpc;lostMethod=method}
    func count(_ method: String) -> Int {lock.lock();defer{lock.unlock()};return calls[method,default:0]}
    func call(_ method: String,_ params: Data) throws -> Data {
        lock.lock();calls[method,default:0]+=1;lock.unlock()
        let actual=try rpc.call(method,params)
        lock.lock();let lose=method==lostMethod && !dropped;if lose{dropped=true};lock.unlock()
        if lose {throw FixtureFailure.timedOut}
        return actual
    }
}
