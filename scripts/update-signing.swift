// Small independent CryptoKit check of Sparkle's signing output. Private keys
// are read from files, never command-line arguments or diagnostic output.
import Foundation
import CryptoKit

enum SigningError: Error { case arguments, key, signature, existingFile }
func privateKey(_ path: String) throws -> Curve25519.Signing.PrivateKey {
    let text = try String(contentsOfFile: path).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let bytes = Data(base64Encoded: text), bytes.count == 32 else { throw SigningError.key }
    return try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
}
do {
    let args = CommandLine.arguments
    switch args.dropFirst().first {
    case "generate":
        guard args.count == 3 else { throw SigningError.arguments }
        guard !FileManager.default.fileExists(atPath: args[2]) else { throw SigningError.existingFile }
        let key = Curve25519.Signing.PrivateKey()
        guard FileManager.default.createFile(atPath: args[2],
            contents: Data(key.rawRepresentation.base64EncodedString().utf8),
            attributes: [.posixPermissions: 0o600]) else { throw SigningError.key }
        print(key.publicKey.rawRepresentation.base64EncodedString())
    case "public-key":
        guard args.count == 3 else { throw SigningError.arguments }
        print(try privateKey(args[2]).publicKey.rawRepresentation.base64EncodedString())
    case "verify":
        guard args.count == 5, let publicBytes = Data(base64Encoded: args[2]),
              let signature = Data(base64Encoded: args[4]) else { throw SigningError.arguments }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicBytes)
        guard key.isValidSignature(signature, for: try Data(contentsOf: URL(fileURLWithPath: args[3]))) else {
            throw SigningError.signature
        }
        print("Ed25519 archive signature verified.")
    default: throw SigningError.arguments
    }
} catch {
    fputs("Update signing validation failed.\n", stderr)
    exit(1)
}
