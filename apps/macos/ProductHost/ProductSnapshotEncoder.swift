import Foundation

/// Preserve the complete ABI while avoiding repeated Foundation JSON walks of
/// unchanged catalog/transcript/lyric arrays. Dynamic values still ship each poll.
final class ProductSnapshotEncoder {
    private var cache: [String: (value: NSObject, json: Data)] = [:]
    private(set) var serializationCount = 0

    func encode(_ snapshot: [String: Any]) throws -> Data {
        guard let state = snapshot["state"] as? [String: Any] else {
            return try JSONSerialization.data(withJSONObject: snapshot)
        }
        var root = snapshot
        root.removeValue(forKey: "state")
        var fields = try root.keys.sorted().map { key in
            try pair(key, data: fragment(root[key]!, path: "root.\(key)"))
        }
        fields.append(try pair("state", data: object(state, path: "state")))
        return joined(fields)
    }

    private func object(_ values: [String: Any], path: String) throws -> Data {
        try joined(values.keys.sorted().map { key in
            let value = values[key]!
            let data: Data
            // Lyrics contain clock-driven scenes plus the full static source
            // lines. Cache each direct field, rather than invalidating all lines
            // whenever playbackTime or animationTime changes.
            if path == "state", key == "lyrics", let lyrics = value as? [String: Any] {
                data = try object(lyrics, path: "state.lyrics")
            } else {
                data = try fragment(value, path: "\(path).\(key)")
            }
            return try pair(key, data: data)
        })
    }

    private func fragment(_ value: Any, path: String) throws -> Data {
        let object = value as AnyObject as! NSObject
        if let cached = cache[path], cached.value.isEqual(object) { return cached.json }
        let json = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        serializationCount += 1
        cache[path] = (object, json)
        return json
    }

    private func pair(_ key: String, data: Data) throws -> Data {
        var result = try JSONSerialization.data(withJSONObject: key, options: [.fragmentsAllowed])
        result.append(58)
        result.append(data)
        return result
    }

    private func joined(_ fields: [Data]) -> Data {
        var result = Data([123])
        for (index, field) in fields.enumerated() {
            if index > 0 { result.append(44) }
            result.append(field)
        }
        result.append(125)
        return result
    }
}
