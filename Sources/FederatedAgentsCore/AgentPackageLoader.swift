import CryptoKit
import Foundation

public enum AgentPackageLoaderError: LocalizedError {
    case missingManifest
    case invalidManifest
    case missingFile(String)
    case invalidSignaturePayload

    public var errorDescription: String? {
        switch self {
        case .missingManifest:
            "The package is missing manifest.json."
        case .invalidManifest:
            "The package manifest could not be decoded."
        case .missingFile(let path):
            "The package is missing \(path)."
        case .invalidSignaturePayload:
            "The signing payload could not be decoded."
        }
    }
}

public struct AgentPackageLoader {
    private let decoder: JSONDecoder

    public init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func load(from packageDirectory: URL) throws -> AgentPackage {
        let manifestURL = packageDirectory.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw AgentPackageLoaderError.missingManifest
        }

        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: PackageManifest

        do {
            manifest = try decoder.decode(PackageManifest.self, from: manifestData)
        } catch {
            throw AgentPackageLoaderError.invalidManifest
        }

        let purposeURL = packageDirectory.appendingPathComponent(manifest.purposeFile)
        let instructionsURL = packageDirectory.appendingPathComponent(manifest.instructionsFile)

        guard FileManager.default.fileExists(atPath: purposeURL.path) else {
            throw AgentPackageLoaderError.missingFile(manifest.purposeFile)
        }

        guard FileManager.default.fileExists(atPath: instructionsURL.path) else {
            throw AgentPackageLoaderError.missingFile(manifest.instructionsFile)
        }

        let purposeMarkdown = try String(contentsOf: purposeURL, encoding: .utf8)
        let instructionsMarkdown = try String(contentsOf: instructionsURL, encoding: .utf8)
        let verification = try verifyPackage(manifest: manifest, packageDirectory: packageDirectory)

        return AgentPackage(
            id: manifest.packageID,
            title: manifest.title,
            summary: manifest.summary,
            sender: manifest.sender,
            expiresAt: manifest.expiresAt,
            callbackURL: manifest.callbackURL,
            purposeMarkdown: purposeMarkdown,
            instructionsMarkdown: instructionsMarkdown,
            requestedCapabilities: manifest.requestedCapabilities,
            questions: manifest.questions,
            outputContract: manifest.outputContract,
            verification: verification,
            packageDirectory: packageDirectory
        )
    }

    private func verifyPackage(
        manifest: PackageManifest,
        packageDirectory: URL
    ) throws -> PackageVerification {
        guard
            let signature = manifest.signature,
            let signingPayloadFile = manifest.signingPayloadFile
        else {
            return PackageVerification(
                status: .unsigned,
                message: "No sender signature was provided. The prototype can still open the package, but it cannot prove sender authenticity.",
                fileDigests: []
            )
        }

        let signingPayloadURL = packageDirectory.appendingPathComponent(signingPayloadFile)
        guard FileManager.default.fileExists(atPath: signingPayloadURL.path) else {
            throw AgentPackageLoaderError.missingFile(signingPayloadFile)
        }

        let signingPayloadData = try Data(contentsOf: signingPayloadURL)
        let signingPayload: SigningPayload

        do {
            signingPayload = try decoder.decode(SigningPayload.self, from: signingPayloadData)
        } catch {
            throw AgentPackageLoaderError.invalidSignaturePayload
        }

        let fileDigestMismatch = signingPayload.trackedFiles.first { trackedFile in
            let fileURL = packageDirectory.appendingPathComponent(trackedFile.path)
            guard let currentDigest = try? sha256(of: fileURL) else {
                return true
            }

            return currentDigest != trackedFile.sha256
        }

        guard fileDigestMismatch == nil else {
            return PackageVerification(
                status: .invalid,
                message: "The package contents do not match the sender's signed digest list.",
                fileDigests: signingPayload.trackedFiles
            )
        }

        let publicKeyData = Data(base64Encoded: signature.publicKeyBase64)
        let signatureData = Data(base64Encoded: signature.signatureBase64)

        guard
            let publicKeyData,
            let signatureData,
            signature.algorithm == "ed25519"
        else {
            return PackageVerification(
                status: .invalid,
                message: "The package signature is malformed or uses an unsupported algorithm.",
                fileDigests: signingPayload.trackedFiles
            )
        }

        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            let isValid = publicKey.isValidSignature(signatureData, for: signingPayloadData)

            return PackageVerification(
                status: isValid ? .verified : .invalid,
                message: isValid
                    ? "Sender signature and tracked file digests verified."
                    : "The sender signature did not verify.",
                fileDigests: signingPayload.trackedFiles
            )
        } catch {
            return PackageVerification(
                status: .invalid,
                message: "The sender public key could not be decoded.",
                fileDigests: signingPayload.trackedFiles
            )
        }
    }

    private func sha256(of fileURL: URL) throws -> String {
        let data = try Data(contentsOf: fileURL)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
