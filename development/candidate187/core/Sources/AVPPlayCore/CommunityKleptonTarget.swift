import Foundation

/// Community catalog metadata that can be attached to an APK only after its parsed identity matches.
/// It is intentionally separate from official Recipe data and never changes official playability.
public struct CommunityKleptonTarget: Codable, Sendable, Equatable {
    public let appID: String
    public let packageID: String
    public let target: String
    public let versionName: String
    public let versionCode: String
    public let title: String
    public let status: String
    public let provenance: String

    public static let known: [CommunityKleptonTarget] = [
        .init(appID: "6072194326150034", packageID: "com.XrealGames.Zc15",
              target: "x6072194326150034", versionName: "2.0.1173-S-80237",
              versionCode: "1173", title: "Zero Caliber 2",
              status: "community", provenance: "AVP Play community catalog; identity matched to inspected APK")
    ]

    public init(appID: String, packageID: String, target: String, versionName: String,
                versionCode: String, title: String, status: String, provenance: String) {
        self.appID = appID; self.packageID = packageID; self.target = target
        self.versionName = versionName; self.versionCode = versionCode
        self.title = title; self.status = status; self.provenance = provenance
    }

    /// Package and version code are authoritative. A present version name must agree too.
    public static func candidate(package: String?, versionCode: String?, versionName: String?) -> CommunityKleptonTarget? {
        guard let package, let versionCode,
              let entry = known.first(where: { $0.packageID == package && $0.versionCode == versionCode }) else { return nil }
        if let versionName, !versionName.isEmpty, versionName != entry.versionName { return nil }
        return entry
    }
}
