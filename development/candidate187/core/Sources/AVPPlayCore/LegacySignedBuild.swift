import Foundation

/// Read-only comparison of an unsigned ARM64 product and its signed copy. Never strips or edits either file.
/// Accept only the exact LC_CODE_SIGNATURE command, signature blob/alignment and __LINKEDIT size changes.
/// Unsupported Mach-O layouts fail closed; signature validity is checked separately with codesign.
enum LegacySignedBuild {
    static func sameCode(_ unsigned: Data, _ signed: Data) throws -> Bool {
        func uint(_ bytes: [UInt8], _ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= bytes.count else { throw invalid() }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[offset + $1]) << (8 * $1) }
        }
        func normalized(_ data: Data, signedCopy: Bool) throws -> [UInt8] {
            var bytes = [UInt8](data)
            guard try uint(bytes, 0) == 0xfeedfacf, try uint(bytes, 4) == 0x0100000c else { throw invalid() }
            let count = Int(try uint(bytes, 16)), size = Int(try uint(bytes, 20))
            guard count > 0, count < 10000, size >= 8, 32 + size <= unsigned.count else { throw invalid() }
            var offset = 32, signature = false
            for i in 0..<count {
                let command = try uint(bytes, offset), length = Int(try uint(bytes, offset + 4))
                guard length >= 8, offset + length <= 32 + size else { throw invalid() }
                if command == 0x19 {
                    guard length >= 72 else { throw invalid() }
                    let name = String(bytes: bytes[(offset + 8)..<(offset + 24)].prefix { $0 != 0 }, encoding: .utf8)
                    if name == "__LINKEDIT" {
                        bytes.replaceSubrange((offset + 32)..<(offset + 40), with: repeatElement(0, count: 8))
                        bytes.replaceSubrange((offset + 48)..<(offset + 56), with: repeatElement(0, count: 8))
                    }
                }
                if command == 0x1d {
                    guard signedCopy, !signature, i == count - 1, length == 16 else { throw invalid() }
                    let start = Int(try uint(bytes, offset + 8)), length = Int(try uint(bytes, offset + 12))
                    guard start >= unsigned.count, start - unsigned.count <= 15,
                          start <= bytes.count, length > 0, start + length == bytes.count,
                          bytes[unsigned.count..<start].allSatisfy({ $0 == 0 }) else { throw invalid() }
                    bytes.replaceSubrange(offset..<(offset + 16), with: repeatElement(0, count: 16))
                    for (at, value) in [(16, count - 1), (20, size - 16)] {
                        for j in 0..<4 { bytes[at + j] = UInt8((value >> (j * 8)) & 255) }
                    }
                    signature = true
                }
                offset += length
            }
            guard offset == 32 + size, signature == signedCopy,
                  signedCopy || bytes.count == unsigned.count else { throw invalid() }
            return Array(bytes.prefix(unsigned.count))
        }
        if unsigned == signed { return true }
        return try normalized(unsigned, signedCopy: false) == normalized(signed, signedCopy: true)
    }

    static func verify(unsigned: URL, signed: URL, unsignedFiles: [String: String], signedFiles: [String: String]) throws {
        for (relative, hash) in unsignedFiles {
            guard let other = signedFiles[relative] else { throw invalid() }
            if hash == other { continue }
            let a = try Data(contentsOf: unsigned.appendingPathComponent(relative))
            let b = try Data(contentsOf: signed.appendingPathComponent(relative))
            guard try sameCode(a, b) else {
                throw LocalAPKVariantError.invalidRecord("O código assinado diverge do build preservado: \(relative)")
            }
        }
        for relative in signedFiles.keys where unsignedFiles[relative] == nil {
            guard relative == "embedded.mobileprovision" || relative.hasSuffix("_CodeSignature/CodeResources") else {
                throw LocalAPKVariantError.invalidRecord("Arquivo inesperado na cópia assinada: \(relative)")
            }
        }
    }
    private static func invalid() -> LocalAPKVariantError {
        .invalidRecord("Não foi possível vincular o código assinado ao build original; formato ou diferenças sem suporte.")
    }
}
