import Foundation
import CryptoKit

/// Read-only discovery. Xcode continues to own account login, issuance and downloads.
public enum AppleSigningInventory {
    public struct Profile: Identifiable, Sendable {
        public let id: String
        public let applicationIdentifier: String
        public let expires: Date
        public let problems: [String]
        public let extendedAddressing: Bool
        public let lowLatency: Bool
    }

    public struct Snapshot: Sendable {
        public let teams: [AppleTeam]
        public let identities: [String]
        public let profiles: [Profile]
        public let errors: [String]
    }

    public static func scan(team: String, device: String? = nil) -> Snapshot {
        let identities = SigningWarmUp.existingIdentities(team: team)
        var profiles: [Profile] = [], errors: [String] = []
        for root in SigningProfiles.cacheDirectories {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            do {
                for path in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
                    .sorted(by: { $0.path < $1.path })
                    where ["mobileprovision", "provisionprofile"].contains(path.pathExtension) {
                    do {
                        let values = try ProvisioningProfileDecoder.decode(Data(contentsOf: path))
                        guard (values["TeamIdentifier"] as? [String])?.contains(team) == true else { continue }
                        profiles.append(try describe(values, identities: identities, device: device))
                    } catch { errors.append("\(path.lastPathComponent): \(error)") }
                }
            } catch { errors.append("\(root.path): \(error)") }
        }
        return Snapshot(teams: AppleTeams.known(), identities: identities, profiles: profiles, errors: errors)
    }

    /// Called only after CMS authentication. Inventory eligibility is not admission for a game:
    /// ExistingAppSigner still checks its exact Bundle ID, device and complete requested entitlements.
    static func describe(_ values: [String: Any], identities: [String], device: String?, now: Date = Date()) throws -> Profile {
        guard let id = values["UUID"] as? String,
              let expires = values["ExpirationDate"] as? Date,
              let created = values["CreationDate"] as? Date,
              let entitlements = values["Entitlements"] as? [String: Any],
              let application = entitlements["application-identifier"] as? String,
              let certificates = values["DeveloperCertificates"] as? [Data] else {
            throw ProvisioningProfileDecoder.DecodeError.invalidPropertyList
        }
        var problems: [String] = []
        if expires <= now { problems.append("Perfil expirado") }
        if created > now { problems.append("Perfil ainda não vigente") }
        if !(values["Platform"] as? [String] ?? []).contains(where: { ["xrOS", "visionOS", "XROS"].contains($0) }) {
            problems.append("Sem suporte a visionOS")
        }
        let fingerprints = certificates.map { Insecure.SHA1.hash(data: $0).map { String(format: "%02X", $0) }.joined() }
        if !identities.contains(where: { fingerprints.contains($0.uppercased()) }) {
            problems.append("Sem identidade Apple Development válida correspondente no Keychain")
        }
        if let device, !(values["ProvisionedDevices"] as? [String] ?? []).contains(device) {
            problems.append("Não inclui o Vision Pro selecionado")
        }
        return Profile(id: id, applicationIdentifier: application, expires: expires, problems: problems,
                       extendedAddressing: entitlements["com.apple.developer.kernel.extended-virtual-addressing"] as? Bool == true,
                       lowLatency: entitlements["com.apple.developer.low-latency-streaming"] as? Bool == true)
    }
}
