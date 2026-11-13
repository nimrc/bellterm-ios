import Foundation
import Testing
@testable import Bellterm

struct SSHKeyFormatTests {
    private let material = RSAKeyMaterial(
        modulus: Data([0x80, 0x11, 0x22, 0x33, 0x44]),
        publicExponent: Data([0x01, 0x00, 0x01]),
        privateExponent: Data([0x7f, 0x01]),
        prime1: Data([0x80, 0x02]),
        prime2: Data([0x03]),
        exponent1: Data([0x04]),
        exponent2: Data([0x05]),
        coefficient: Data([0x06])
    )

    @Test func publicKeyLineIsOpenSSHAndUsesTheNameAsComment() throws {
        let blob = material.publicKeyBlob()
        let line = material.publicKeyLine(comment: "alice@example")
        #expect(line == "ssh-rsa \(blob.base64EncodedString()) alice@example")
        #expect(line.hasPrefix("ssh-rsa AAAA"))

        var reader = BlobReader(blob)
        #expect(try reader.readString() == Data("ssh-rsa".utf8))
        #expect(try reader.readMPInt() == material.publicExponent)
        #expect(try reader.readMPInt() == material.modulus)
        #expect(reader.isAtEnd)
    }

    @Test func emptyCommentHasNoTrailingSpace() {
        #expect(!material.publicKeyLine(comment: "  ").hasSuffix(" "))
    }

    @Test func pkcs1DERParsesBackIntoTheSameComponents() throws {
        let der = derSequence([
            derInteger(Data([0x00])),
            derInteger(material.modulus),
            derInteger(material.publicExponent),
            derInteger(material.privateExponent),
            derInteger(material.prime1),
            derInteger(material.prime2),
            derInteger(material.exponent1),
            derInteger(material.exponent2),
            derInteger(material.coefficient),
        ])
        #expect(try RSAKeyMaterial(pkcs1DER: der) == material)
    }

    @Test func securityGeneratedRSAKeyLooksLikeOpenSSH() throws {
        let privateKey = try RSAKeyMaterial.generate(bits: 2048, comment: "unit-test")
        #expect(privateKey.hasPrefix("-----BEGIN OPENSSH PRIVATE KEY-----"))
        let body = privateKey
            .split(separator: "\n", omittingEmptySubsequences: true)
            .filter { !$0.hasPrefix("-----") }
            .joined()
        let payload = try #require(Data(base64Encoded: body))
        #expect(payload.starts(with: Data("openssh-key-v1\u{0}".utf8)))
    }

    @Test func securityGeneratedRSAKeyIsReadableByTheCore() throws {
        let privateKey = try RSAKeyMaterial.generate(bits: 2048, comment: "unit-test")
        let line = try publicKey(privateKey: privateKey)
        #expect(line.hasPrefix("ssh-rsa AAAA"))
        #expect(line.hasSuffix(" unit-test"))

        let imported = try importKey(text: privateKey, passphrase: nil)
        #expect(imported.contains(#""algorithm":"ssh-rsa""#))
    }

    @Test func unsupportedSizesAreRejected() {
        #expect(throws: Error.self) { try RSAKeyMaterial.generate(bits: 1024, comment: "small") }
    }
}

private struct BlobReader {
    let data: Data
    var index = 0

    init(_ data: Data) { self.data = data }

    var isAtEnd: Bool { index == data.count }

    mutating func readString() throws -> Data {
        let length = Int(try readUInt32())
        guard index + length <= data.count else { throw SSHKeyFormatError("short key blob") }
        let value = data.subdata(in: index..<(index + length))
        index += length
        return value
    }

    mutating func readMPInt() throws -> Data {
        var value = try readString()
        while value.count > 1, value.first == 0 { value.removeFirst() }
        if value == Data([0]) { return Data() }
        return value
    }

    private mutating func readUInt32() throws -> UInt32 {
        guard index + 4 <= data.count else { throw SSHKeyFormatError("short key blob") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            value = (value << 8) | UInt32(data[index])
            index += 1
        }
        return value
    }
}

private func derSequence(_ values: [Data]) -> Data {
    let body = values.reduce(Data()) { $0 + $1 }
    return Data([0x30]) + derLength(body.count) + body
}

private func derInteger(_ value: Data) -> Data {
    var bytes = value
    while bytes.count > 1, bytes.first == 0 { bytes.removeFirst() }
    if bytes.isEmpty { bytes = Data([0x00]) }
    if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
    return Data([0x02]) + derLength(bytes.count) + bytes
}

private func derLength(_ length: Int) -> Data {
    if length < 0x80 { return Data([UInt8(length)]) }
    var bytes: [UInt8] = []
    var value = length
    while value > 0 {
        bytes.insert(UInt8(value & 0xff), at: 0)
        value >>= 8
    }
    return Data([0x80 | UInt8(bytes.count)] + bytes)
}
