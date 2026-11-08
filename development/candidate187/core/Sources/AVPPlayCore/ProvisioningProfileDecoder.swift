import Foundation
import Security

/// Reads Apple's CMS-wrapped provisioning profiles without relying on the `security cms` CLI parser.
/// The native decoder verifies the CMS signer signature and its X.509 trust chain before exposing content.
public enum ProvisioningProfileDecoder {
    public enum DecodeError: Error, CustomStringConvertible {
        case cms(OSStatus)
        case signerCount(Int)
        case untrustedSigner(CMSSignerStatus, OSStatus)
        case nonAppleSigner
        case missingContent
        case invalidPropertyList

        public var description: String {
            switch self {
            case .cms(let status): return "CMS profile could not be decoded (Security status \(status))."
            case .signerCount(let count): return "CMS profile must contain exactly one signer (found \(count))."
            case .untrustedSigner(let status, let trust):
                return "CMS profile signature or signer trust failed (status \(status.rawValue), trust \(trust))."
            case .nonAppleSigner: return "Provisioning profile signer is not an Apple certificate."
            case .missingContent: return "CMS profile has no embedded content."
            case .invalidPropertyList: return "Verified profile content is not a property list."
            }
        }
    }

    /// Returns profile fields only after signature and signer-chain validation succeeds.
    public static func decode(_ data: Data) throws -> [String: Any] {
        guard !data.isEmpty else { throw DecodeError.cms(errSecDecode) }
        var decoder: CMSDecoder?
        guard CMSDecoderCreate(&decoder) == errSecSuccess, let decoder else { throw DecodeError.cms(errSecDecode) }

        let update = data.withUnsafeBytes { bytes -> OSStatus in
            guard let base = bytes.baseAddress else { return errSecDecode }
            return CMSDecoderUpdateMessage(decoder, base, bytes.count)
        }
        guard update == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess else {
            throw DecodeError.cms(errSecDecode)
        }

        var signerCount = 0
        guard CMSDecoderGetNumSigners(decoder, &signerCount) == errSecSuccess else { throw DecodeError.cms(errSecDecode) }
        guard signerCount == 1 else { throw DecodeError.signerCount(signerCount) }

        var signer = CMSSignerStatus.unsigned
        var trustStatus = errSecSuccess
        let signatureStatus = CMSDecoderCopySignerStatus(
            decoder, 0, SecPolicyCreateBasicX509(), true, &signer, nil, &trustStatus)
        guard signatureStatus == errSecSuccess, signer == .valid else {
            throw DecodeError.untrustedSigner(signer, trustStatus == errSecSuccess ? signatureStatus : trustStatus)
        }

        var signerCertificate: SecCertificate?
        guard CMSDecoderCopySignerCert(decoder, 0, &signerCertificate) == errSecSuccess,
              let signerCertificate,
              let summary = SecCertificateCopySubjectSummary(signerCertificate) as String?,
              summary.localizedCaseInsensitiveContains("Apple") else {
            throw DecodeError.nonAppleSigner
        }

        var content: CFData?
        guard CMSDecoderCopyContent(decoder, &content) == errSecSuccess, let content else {
            throw DecodeError.missingContent
        }
        guard let values = try? PropertyListSerialization.propertyList(from: content as Data, format: nil) as? [String: Any] else {
            throw DecodeError.invalidPropertyList
        }
        return values
    }
}
