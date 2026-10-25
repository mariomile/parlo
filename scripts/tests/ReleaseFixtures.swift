import CryptoKit
import Foundation

// Synthetic keys only, written inside the test's temporary directory. Never touches the keychain.
let args = CommandLine.arguments
let directory = URL(fileURLWithPath: args[2])
if args[1] == "key" {
    let key = Curve25519.Signing.PrivateKey()
    try key.rawRepresentation.write(to: directory.appending(path: "test-key"))
    try key.publicKey.rawRepresentation.base64EncodedString().write(
        to: directory.appending(path: "public-key"), atomically: true, encoding: .utf8)
} else {
    let archive = URL(fileURLWithPath: args[3])
    let feed = URL(fileURLWithPath: args[4])
    let version = args[5], build = args[6], mode = args[7]
    let bytes = try Data(contentsOf: archive)
    let key = mode == "wrong-signature" ? Curve25519.Signing.PrivateKey() :
        try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: directory.appending(path: "test-key")))
    let signature = try key.signature(for: bytes).base64EncodedString()
    let signatureAttribute = mode == "unsigned" ? "" : "sparkle:edSignature=\"\(signature)\""
    let xml = """
    <?xml version="1.0" encoding="utf-8"?>
    <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
      <channel><item>
        <sparkle:version>\(build)</sparkle:version>
        <sparkle:shortVersionString>\(version)</sparkle:shortVersionString>
        <enclosure url="https://github.com/mariomile/parlo/releases/download/v\(version)/Parlo-\(version).zip"
          type="application/octet-stream" length="\(bytes.count)" \(signatureAttribute)/>
      </item></channel>
    </rss>
    """
    try xml.write(to: feed, atomically: true, encoding: .utf8)
}
