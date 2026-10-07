import Foundation

@main struct ReceiptTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            checks += 1
            if !value { print("FAIL: \(label)"); exit(1) }
        }
        let sessionID = UUID().uuidString, wishID = UUID().uuidString, projectionID = UUID().uuidString
        let descriptor: [String: Any] = ["worldID": "world", "stage": "ready", "sourceWishID": wishID,
            "objectID": "output", "localModelPath": "/fixture/model.glb",
            "projectionSessionID": sessionID, "projectionID": projectionID]
        var receipts = UnityWishOutputReceipts(sessionID: sessionID)
        func receipt(_ sequence: Int, rendered: Bool) -> [String: Any] {
            ["op": "wish.output.projected", "worldID": "world", "wishID": wishID, "objectID": "output",
             "modelPath": "/fixture/model.glb", "projectionSessionID": sessionID, "projectionID": projectionID,
             "receiptSequence": sequence, "rendered": rendered, "renderedFrame": 12]
        }
        func isRendered() -> Bool { receipts.isRendered(objectID: "output", wishID: wishID, modelPath: "/fixture/model.glb") }
        check(!receipts.accept(receipt(1, rendered: true)), "generation without a published projection is not rendered")
        receipts.update(worldID: "world", entries: [descriptor])
        check(!isRendered(), "catalog publication alone is not a render receipt")
        for key in ["projectionSessionID", "projectionID", "worldID", "wishID", "objectID", "modelPath"] {
            var wrong = receipt(1, rendered: true); wrong[key] = "different"
            check(!receipts.accept(wrong), "reject mismatched \(key)")
        }
        for invalid: Any in [true, 0, -1, 1.5, Double.infinity, 9_007_199_254_740_992.0, "1"] {
            var wrong = receipt(1, rendered: true); wrong["receiptSequence"] = invalid
            check(!receipts.accept(wrong), "reject malformed sequence")
        }
        for invalid: Any in [true, 0, -1, 1.5, "12"] {
            var wrong = receipt(1, rendered: true); wrong["renderedFrame"] = invalid
            check(!receipts.accept(wrong), "true receipt requires a real positive frame")
        }
        var numericBool = receipt(1, rendered: true); numericBool["rendered"] = 1
        check(!receipts.accept(numericBool), "numeric one cannot masquerade as boolean render fact")
        check(receipts.accept(receipt(1, rendered: true)) && isRendered(), "matching positive frame establishes visibility")
        check(receipts.accept(receipt(1, rendered: true)), "identical receipt retransmission is idempotent")
        check(!receipts.accept(receipt(1, rendered: false)) && isRendered(), "same sequence cannot contradict original receipt")
        check(receipts.accept(receipt(3, rendered: false)) && !isRendered(), "unload revokes rendered evidence")
        check(!receipts.accept(receipt(2, rendered: true)) && !isRendered(), "delayed true cannot override later unload")
        check(receipts.accept(receipt(4, rendered: true)) && isRendered(), "fresh frame after reenable restores evidence")
        receipts.update(worldID: "world", entries: [descriptor])
        check(isRendered(), "unchanged snapshot retains matching frame evidence")
        var replacement = descriptor; replacement["projectionID"] = UUID().uuidString
        receipts.update(worldID: "world", entries: [replacement])
        check(!isRendered() && !receipts.accept(receipt(5, rendered: true)), "replacement requires new projection receipt")
        var current = receipt(1, rendered: true); current["projectionID"] = replacement["projectionID"]
        check(receipts.accept(current) && isRendered(), "new projection may start its own sequence")
        check(!receipts.accept(receipt(99, rendered: false)) && isRendered(), "old projection unload cannot clear replacement")
        receipts.update(worldID: "world", entries: [])
        check(!isRendered() && !receipts.accept(current), "catalog revocation rejects in-flight receipts")
        receipts.update(worldID: "world", entries: [descriptor, descriptor])
        check(!receipts.accept(receipt(1, rendered: true)), "duplicate object capabilities are rejected")
        var reopened = UnityWishOutputReceipts()
        reopened.update(worldID: "world", entries: [descriptor])
        check(!reopened.accept(receipt(1, rendered: true)), "reopened world cannot reuse prior session render evidence")
        check(receipts.renderedObjectIDs.isEmpty, "diagnostics expose only accepted currently rendered IDs")

        var retry = UnityNotificationRetry()
        check((0..<8).map { _ in retry.failed() } == [1, 2, 4, 8, 16, 30, 30, 30].map { UInt64($0) * 1_000_000_000 },
              "idle transport failures retry with bounded backoff")
        retry.succeeded()
        check(retry.failures == 0 && retry.failed() == 1_000_000_000, "successful synchronization resets retry delay")
        print("PASS: \(checks) production render receipt and notification retry checks")
    }
}
