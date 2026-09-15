import Foundation
import CryptoKit
import os

/// The result of a successful package validation.
struct ValidatedRegionPackage {
    let manifest: OfflineRegionManifest
    let stagingDirectory: URL
    let routingDatabaseURL: URL
    let mapDataURL: URL?
}

/// Validates an offline region package bundle (`.relyvoregion`).
final class OfflineRegionPackageValidator: Sendable {
    private let logger = Logger(subsystem: "com.RaiEnterprise.Relyvo", category: "OfflineRegionValidator")
    
    init() {}
    
    /// Validates the package located at `stagingURL`.
    /// `stagingURL` should be a directory containing `manifest.json`.
    func validate(stagingURL: URL) async throws -> ValidatedRegionPackage {
        logger.info("[OfflineRegionValidator] Validating package at \(stagingURL.path)")
        
        // 1. Verify manifest exists
        let manifestURL = stagingURL.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            logger.error("[OfflineRegionValidator] manifest.json missing")
            throw OfflineRegionError.manifestMissing
        }
        
        // 2. Decode manifest
        let manifestData = try Data(contentsOf: manifestURL)
        let manifest: OfflineRegionManifest
        do {
            manifest = try JSONDecoder().decode(OfflineRegionManifest.self, from: manifestData)
        } catch {
            logger.error("[OfflineRegionValidator] manifest.json malformed: \(error.localizedDescription)")
            throw OfflineRegionError.manifestMalformed(error.localizedDescription)
        }
        
        // 3. Validate format version
        guard manifest.packageFormatVersion == 1 else {
            logger.error("[OfflineRegionValidator] unsupported package format version \(manifest.packageFormatVersion)")
            throw OfflineRegionError.unsupportedPackageVersion
        }
        
        // 4. Validate core fields
        guard !manifest.regionId.isEmpty else {
            throw OfflineRegionError.invalidRegionID
        }
        
        guard manifest.maxLatitude > manifest.minLatitude, manifest.maxLongitude > manifest.minLongitude else {
            throw OfflineRegionError.invalidBounds
        }
        
        // 5. Resolve and validate routing DB path
        let routingURL = try resolveAndValidatePath(manifest.routingDatabase, relativeTo: stagingURL)
        guard FileManager.default.fileExists(atPath: routingURL.path) else {
            throw OfflineRegionError.routingDatabaseMissing
        }
        
        // 6. Checksum routing DB
        if let expectedRoutingChecksum = manifest.routingChecksum, !expectedRoutingChecksum.isEmpty {
            try validateChecksum(fileURL: routingURL, expectedChecksum: expectedRoutingChecksum)
        }
        
        // 7. Validate routing database contents
        try validateRoutingDatabase(url: routingURL, manifest: manifest)
        
        // 8. Resolve and validate map data path (if present)
        var mapURL: URL? = nil
        if let mapPath = manifest.mapData, !mapPath.isEmpty {
            mapURL = try resolveAndValidatePath(mapPath, relativeTo: stagingURL)
            guard FileManager.default.fileExists(atPath: mapURL!.path) else {
                throw OfflineRegionError.mapDataMissing
            }
            if let expectedMapChecksum = manifest.mapChecksum, !expectedMapChecksum.isEmpty {
                try validateChecksum(fileURL: mapURL!, expectedChecksum: expectedMapChecksum)
            }
        }
        
        logger.info("[OfflineRegionValidator] Package \(manifest.regionId) v\(manifest.version) validated successfully")
        
        return ValidatedRegionPackage(
            manifest: manifest,
            stagingDirectory: stagingURL,
            routingDatabaseURL: routingURL,
            mapDataURL: mapURL
        )
    }
    
    private func resolveAndValidatePath(_ path: String, relativeTo baseURL: URL) throws -> URL {
        // Prevent path traversal
        if path.contains("..") || path.hasPrefix("/") {
            logger.error("[OfflineRegionValidator] Path traversal attempt: \(path)")
            throw OfflineRegionError.invalidPackage
        }
        
        let resolved = baseURL.appendingPathComponent(path).standardizedFileURL
        
        // Ensure the resolved path is still inside the baseURL
        if !resolved.path.hasPrefix(baseURL.standardizedFileURL.path) {
            logger.error("[OfflineRegionValidator] Path escaped staging directory: \(path)")
            throw OfflineRegionError.invalidPackage
        }
        
        return resolved
    }
    
    private func validateChecksum(fileURL: URL, expectedChecksum: String) throws {
        logger.info("[OfflineRegionValidator] Validating checksum for \(fileURL.lastPathComponent)")
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1024 * 1024) { // 1MB chunks
            hasher.update(data: chunk)
        }
        let digest = hasher.finalize()
        let computedChecksum = digest.map { String(format: "%02x", $0) }.joined()
        
        if computedChecksum.lowercased() != expectedChecksum.lowercased() {
            logger.error("[OfflineRegionValidator] Checksum mismatch for \(fileURL.lastPathComponent). Expected: \(expectedChecksum), Got: \(computedChecksum)")
            throw OfflineRegionError.checksumMismatch(file: fileURL.lastPathComponent)
        }
    }
    
    private func validateRoutingDatabase(url: URL, manifest: OfflineRegionManifest) throws {
        logger.info("[OfflineRegionValidator] Deep validating SQLite routing database at \(url.lastPathComponent)")
        let db = RoutingDatabase(fileURL: url)
        
        do {
            try db.validate()
        } catch {
            throw OfflineRegionError.routingSchemaInvalid
        }
        
        let metadata = try db.metadata()
        if metadata.regionId != manifest.regionId {
            throw OfflineRegionError.routingMetadataMismatch("DB regionId (\(metadata.regionId)) does not match manifest (\(manifest.regionId))")
        }
        
        if metadata.graphVersion != manifest.version {
            throw OfflineRegionError.routingMetadataMismatch("DB version (\(metadata.graphVersion)) does not match manifest version (\(manifest.version))")
        }
    }
}
