#!/usr/bin/env swift
import CryptoKit
import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// Verify the exact archive, not just generate_appcast's exit status. No keychain access is needed.
struct VerificationError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

func require(_ condition: Bool, _ message: String) throws {
    if !condition { throw VerificationError(message: message) }
}

func verify() throws {
    let args = CommandLine.arguments
    try require(args.count == 7, "Usage: verify-appcast.swift <feed> <archive> <public-key> <version> <build> <download-url>")
    let (_, feedPath, archivePath, publicKey, version, build, downloadURL) =
        (args[0], args[1], args[2], args[3], args[4], args[5], args[6])
    let archive = try Data(contentsOf: URL(fileURLWithPath: archivePath), options: .mappedIfSafe)
    let feed = try XMLDocument(contentsOf: URL(fileURLWithPath: feedPath), options: .nodeLoadExternalEntitiesNever)
    guard let root = feed.rootElement(), root.name == "rss",
          root.namespace(forPrefix: "sparkle")?.stringValue == "http://www.andymatuschak.org/xml-namespaces/sparkle" else {
        throw VerificationError(message: "Invalid Sparkle RSS namespace")
    }
    let items = root.elements(forName: "channel").flatMap { $0.elements(forName: "item") }
    try require(items.count == 1, "Expected exactly one release in the generated appcast")
    let item = items[0]
    let enclosures = item.elements(forName: "enclosure")
    try require(enclosures.count == 1, "Expected exactly one full update enclosure")
    let enclosure = enclosures[0]
    func attribute(_ name: String) -> String? { enclosure.attribute(forName: name)?.stringValue }
    func field(_ name: String) -> String? { item.elements(forName: name).first?.stringValue ?? attribute(name) }
    try require(field("sparkle:version") == build, "Appcast build does not match the release")
    try require(field("sparkle:shortVersionString") == version, "Appcast version does not match the release")
    try require(attribute("url") == downloadURL, "Appcast download URL does not match the release")
    try require(attribute("type") == "application/octet-stream", "Unexpected archive type")
    try require(attribute("length").flatMap(Int.init) == archive.count, "Appcast archive length is incorrect")
    guard let keyBytes = Data(base64Encoded: publicKey), let encodedSignature = attribute("sparkle:edSignature"),
          let signature = Data(base64Encoded: encodedSignature) else {
        throw VerificationError(message: "Missing or malformed Ed25519 signature/public key")
    }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
    try require(key.isValidSignature(signature, for: archive), "Archive signature does not match the trusted public key")

    // Read Info.plist from the signed bytes, not a separate (possibly stale) build directory.
    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-p", archivePath, "Parlo.app/Contents/Info.plist"]
    let output = Pipe()
    unzip.standardOutput = output
    try unzip.run()
    let infoData = output.fileHandleForReading.readDataToEndOfFile()
    unzip.waitUntilExit()
    try require(unzip.terminationStatus == 0, "Cannot read the archived app's Info.plist")
    guard let info = try PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] else {
        throw VerificationError(message: "Invalid app Info.plist")
    }
    try require(info["CFBundleIdentifier"] as? String == "com.mariomiletta.parlo", "Unexpected app bundle identifier")
    try require(info["CFBundleShortVersionString"] as? String == version, "Archived app version is incorrect")
    try require(info["CFBundleVersion"] as? String == build, "Archived app build is incorrect")
    try require(info["SUPublicEDKey"] as? String == publicKey, "Archived app changes the trusted update key")
    print("Verified Parlo \(version) (build \(build)): archive signature, metadata and download URL")
}

do { try verify() }
catch {
    FileHandle.standardError.write(Data("Release verification failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
