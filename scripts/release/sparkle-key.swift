// Geraldine's update-signing key, in the file format Sparkle's sign_update
// reads with --ed-key-file: one base64 line holding a 32-byte Ed25519 seed.
//
//   swift scripts/release/sparkle-key.swift create <private-key-file>
//   swift scripts/release/sparkle-key.swift public-key <private-key-file>
//   swift scripts/release/sparkle-key.swift verify <public-key> <file> <signature>
//   swift scripts/release/sparkle-key.swift verify-feed <public-key> <appcast.xml>
//
// `create` refuses to replace an existing file and writes it 0600 inside a
// 0700 folder. Only the public key is ever printed.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("sparkle-key: " + message + "\n").utf8))
    exit(1)
}

func readPrivateKey(_ path: String) -> Curve25519.Signing.PrivateKey {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { fail("cannot read \(path)") }
    let encoded = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let seed = Data(base64Encoded: encoded), seed.count == 32,
          let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
        fail("\(path) is not a base64 32-byte Ed25519 seed")
    }
    return key
}

func readPublicKey(_ encoded: String) -> Curve25519.Signing.PublicKey {
    guard let data = Data(base64Encoded: encoded),
          let key = try? Curve25519.Signing.PublicKey(rawRepresentation: data) else {
        fail("the public key is not a base64 32-byte Ed25519 key")
    }
    return key
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch (arguments.first, arguments.count) {
case ("create", 2):
    let url = URL(fileURLWithPath: arguments[1])
    let folder = url.deletingLastPathComponent()
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    } catch {
        fail("cannot create \(folder.path): \(error.localizedDescription)")
    }
    let key = Curve25519.Signing.PrivateKey()
    let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
    guard descriptor >= 0 else { fail("refusing to write \(url.path): \(String(cString: strerror(errno)))") }
    let line = Data((key.rawRepresentation.base64EncodedString() + "\n").utf8)
    let written = line.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
    guard written == line.count, fsync(descriptor) == 0, close(descriptor) == 0 else {
        fail("could not finish writing \(url.path)")
    }
    print(key.publicKey.rawRepresentation.base64EncodedString())
case ("public-key", 2):
    print(readPrivateKey(arguments[1]).publicKey.rawRepresentation.base64EncodedString())
case ("verify", 4):
    let publicKey = readPublicKey(arguments[1])
    guard let data = FileManager.default.contents(atPath: arguments[2]) else { fail("cannot read \(arguments[2])") }
    guard let signature = Data(base64Encoded: arguments[3]) else { fail("the signature is not base64") }
    guard publicKey.isValidSignature(signature, for: data) else { fail("signature does not verify") }
    print("verified")
case ("verify-feed", 3):
    // Sparkle's signed-feed format: the signature covers every byte before the
    // last "<!-- sparkle-signatures:" comment, whose length line must match.
    let publicKey = readPublicKey(arguments[1])
    guard let data = FileManager.default.contents(atPath: arguments[2]) else { fail("cannot read \(arguments[2])") }
    guard let prefix = data.range(of: Data("<!-- sparkle-signatures:\n".utf8), options: .backwards),
          let suffix = data.range(of: Data("-->".utf8), in: prefix.upperBound..<data.endIndex),
          let block = String(data: data.subdata(in: prefix.upperBound..<suffix.lowerBound), encoding: .utf8) else {
        fail("\(arguments[2]) carries no Sparkle feed signature")
    }
    let content = data.subdata(in: data.startIndex..<prefix.lowerBound)
    var signature: Data?
    var length: Int?
    for line in block.split(separator: "\n") {
        if line.hasPrefix("edSignature:") {
            signature = Data(base64Encoded: line.dropFirst("edSignature:".count).trimmingCharacters(in: .whitespaces))
        } else if line.hasPrefix("length:") {
            length = Int(line.dropFirst("length:".count).trimmingCharacters(in: .whitespaces))
        }
    }
    guard let signature, let length else { fail("the feed signature block is incomplete") }
    guard length == content.count else { fail("the feed signs \(length) bytes but holds \(content.count)") }
    guard publicKey.isValidSignature(signature, for: content) else { fail("the feed signature does not verify") }
    print("verified")
default:
    fail("usage: sparkle-key.swift create|public-key <private-key-file> | verify <public-key> <file> <signature> | verify-feed <public-key> <appcast>")
}
