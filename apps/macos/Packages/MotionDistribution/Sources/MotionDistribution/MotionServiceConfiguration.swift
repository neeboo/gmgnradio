import Foundation

public enum MotionServiceConfiguration {
    public static let defaultCatalogURL = URL(
        string: "https://192.168.1.85:8765/catalog.json"
    )!

    public static let pinnedCertificateSHA256 =
        "dbb4485c64e349c4a3838c0c06d58c5e2d9bfec4cf5f4a3f122f3ce4603463aa"

    public static let legacyLocalCatalogURL = URL(
        string: "http://127.0.0.1:8765/catalog.json"
    )!

    public static let legacyPrivateCatalogURL = URL(
        string: "http://pancat-linux-ci.tail4c7fb9.ts.net:8765/catalog.json"
    )!

    public static let legacyPrivateIPCatalogURL = URL(
        string: "http://100.110.226.64:8765/catalog.json"
    )!

    public static let legacyPrivateHTTPSCatalogURL = URL(
        string: "https://100.110.226.64:8765/catalog.json"
    )!

    public static func resolvedCatalogURLString(persisted: String?) -> String {
        guard let persisted, !persisted.isEmpty else {
            return defaultCatalogURL.absoluteString
        }
        if persisted == legacyLocalCatalogURL.absoluteString
            || persisted == legacyPrivateCatalogURL.absoluteString
            || persisted == legacyPrivateIPCatalogURL.absoluteString
            || persisted == legacyPrivateHTTPSCatalogURL.absoluteString
        {
            return defaultCatalogURL.absoluteString
        }
        return persisted
    }
}
