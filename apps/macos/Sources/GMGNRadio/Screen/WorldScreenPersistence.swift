import Foundation

// MARK: - 电视来源 / 标定 / 内容的**本机持久化**

/// 屏幕定义（来源 + 标定）与内容（用户在放什么）的持久化**唯一**入口。
///
/// ## 为什么是 App 本地文件，而不是世界权威
///
/// 世界状态的唯一写入者是 `gmgn-taskd`；屏幕定义/内容本该走 `world_commit`。但当前
/// 权威的布局命令集（`WorldPropLayoutCommand`）里**没有**写物件 metadata 的命令，
/// `WorldScreenMetadata` 的写入口至今零调用点。在不动 Rust 权威的前提下，这一层把
/// 「标定 / 来源 / 当前内容」持久化在 **App 数据根**的一个 JSON 文件里：
///
/// - 落盘内容**只有**原始屏幕定义与原始页面 URL，**绝不**写解析器产出的签名媒资地址；
/// - 读的时候只补 `WorldScreenStore` 的会话缓存，不冒充世界状态；
/// - 物件从世界里消失（`rebuild` 清掉屏幕）时，这条记录也随之删除 —— 过期内容不会
///   复活一台已经不在的电视。
///
/// `E2E` 下根由 `E2ERuntime` 显式注入，因此重启同一测试根能恢复、不同根互不影响。
struct WorldScreenPersistence: Sendable {
    struct Record: Codable, Equatable, Sendable {
        var definitions: [String: WorldScreenDefinition] = [:]
        var contents: [String: WorldScreenContent] = [:]
    }

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct Document: Codable, Equatable, Sendable {
        var worlds: [String: Record] = [:]
    }

    private func loadDocument() -> Document {
        guard let data = try? Data(contentsOf: fileURL),
              let document = try? JSONDecoder().decode(Document.self, from: data) else {
            return Document()
        }
        return document
    }

    private func write(_ document: Document) {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(document)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // 持久化失败只能进日志；绝不让界面为一次写盘失败崩溃。控制器据此在重启后
            // 读不到记录（fail-closed：宁可不恢复，也不猜）。
            FileHandle.standardError.write(
                Data("WorldScreenPersistence write failed: \(error.localizedDescription)\n".utf8)
            )
        }
    }

    func record(worldID: String) -> Record {
        loadDocument().worlds[worldID] ?? Record()
    }

    /// 写入屏幕定义（来源 / 标定）。`definition` 为 nil 时删除该物件的定义。
    func setDefinition(_ definition: WorldScreenDefinition?, objectID: String, worldID: String) {
        guard !worldID.isEmpty else { return }
        var document = loadDocument()
        var record = document.worlds[worldID] ?? Record()
        record.definitions[objectID] = definition
        document.worlds[worldID] = record
        write(document)
    }

    func setContent(_ content: WorldScreenContent, objectID: String, worldID: String) {
        guard !worldID.isEmpty else { return }
        var document = loadDocument()
        var record = document.worlds[worldID] ?? Record()
        record.contents[objectID] = content
        document.worlds[worldID] = record
        write(document)
    }

    /// 物件不在（或被收回）时删除它的记录，避免过期内容复活一台不存在的电视。
    func remove(objectID: String, worldID: String) {
        guard !worldID.isEmpty else { return }
        var document = loadDocument()
        guard var record = document.worlds[worldID],
              record.definitions[objectID] != nil || record.contents[objectID] != nil else {
            return
        }
        record.definitions[objectID] = nil
        record.contents[objectID] = nil
        document.worlds[worldID] = record
        write(document)
    }
}
