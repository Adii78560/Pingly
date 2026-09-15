import Foundation
import CryptoKit

class OfflineRegionPackageTests {
    let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
    let sourceDB = "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite"
    
    func setUp() throws {
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
    }
    
    func createMockPackage(regionId: String = "custom_extract", version: String = "1.0", formatVersion: Int = 1, dbPath: String = "routing.rgraph.sqlite", manipulateManifest: ((inout [String: Any]) -> Void)? = nil) throws -> URL {
        let packageDir = tempDirectory.appendingPathComponent("\(UUID().uuidString).relyvoregion")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)
        
        // Copy DB if we're not simulating a missing one
        let destDB = packageDir.appendingPathComponent(dbPath)
        if FileManager.default.fileExists(atPath: sourceDB) {
            try? FileManager.default.copyItem(atPath: sourceDB, toPath: destDB.path)
            
            // Update the graph_version in the metadata table so it matches our mock version
            #if os(macOS)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
            process.arguments = [destDB.path, "UPDATE metadata SET value = '\(version)' WHERE key = 'graph_version';"]
            try process.run()
            process.waitUntilExit()
            #endif
        }
        
        // Calculate Checksum if DB exists
        var checksum: String? = nil
        if FileManager.default.fileExists(atPath: destDB.path) {
            let handle = try FileHandle(forReadingFrom: destDB)
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 1024 * 1024) {
                hasher.update(data: chunk)
            }
            try handle.close()
            let digest = hasher.finalize()
            checksum = digest.map { String(format: "%02x", $0) }.joined()
        }
        
        var manifestDict: [String: Any] = [
            "packageFormatVersion": formatVersion,
            "regionId": regionId,
            "version": version,
            "displayName": "Test Region",
            "minLatitude": 43.7,
            "maxLatitude": 43.8,
            "minLongitude": 7.4,
            "maxLongitude": 7.5,
            "routingDatabase": dbPath,
            "routingChecksum": checksum as Any
        ]
        
        manipulateManifest?(&manifestDict)
        
        let manifestData = try JSONSerialization.data(withJSONObject: manifestDict, options: .prettyPrinted)
        try manifestData.write(to: packageDir.appendingPathComponent("manifest.json"))
        
        return packageDir
    }
    
    func testValidPackageValidation() async throws {
        let package = try createMockPackage()
        let validator = OfflineRegionPackageValidator()
        let result = try await validator.validate(stagingURL: package)
        
        assert(result.manifest.regionId == "custom_extract")
        assert(result.manifest.version == "1.0")
    }
    
    func testMissingManifest() async throws {
        let package = try createMockPackage()
        try FileManager.default.removeItem(at: package.appendingPathComponent("manifest.json"))
        
        let validator = OfflineRegionPackageValidator()
        do {
            _ = try await validator.validate(stagingURL: package)
            assertionFailure("Expected manifestMissing error")
        } catch OfflineRegionError.manifestMissing {
            // Success
        } catch {
            assertionFailure("Unexpected error: \(error)")
        }
    }
    
    func testMalformedManifest() async throws {
        let package = try createMockPackage()
        try "invalid json".write(to: package.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        
        let validator = OfflineRegionPackageValidator()
        do {
            _ = try await validator.validate(stagingURL: package)
            assertionFailure("Expected manifestMalformed error")
        } catch OfflineRegionError.manifestMalformed(_) {
            // Success
        } catch {
            assertionFailure("Unexpected error: \(error)")
        }
    }
    
    func testPathTraversalRejected() async throws {
        let package = try createMockPackage(dbPath: "../escaped.sqlite")
        // Note: createMockPackage actually puts the DB inside the package for convenience, but the manifest says "../escaped.sqlite"
        let validator = OfflineRegionPackageValidator()
        do {
            _ = try await validator.validate(stagingURL: package)
            assertionFailure("Expected invalidPackage error for traversal")
        } catch OfflineRegionError.invalidPackage {
            // Success
        } catch {
            assertionFailure("Unexpected error: \(error)")
        }
    }
    
    func testSuccessfulInstallation() async throws {
        let package = try createMockPackage(version: "1.0")
        let manager = OfflineRegionManager(baseDirectory: tempDirectory)
        let installer = OfflineRegionPackageInstaller(routingDirectory: tempDirectory, mapsDirectory: tempDirectory, regionManager: manager)
        
        try await installer.installRegionPackage(from: package)
        
        let regions = await manager.installedRegions
        let isInstalled = regions.contains(where: { $0.id == "custom_extract" && $0.version == "1.0" })
        assert(isInstalled, "Region should be installed. Got: \(regions)")
    }
    
    func testDowngradeRejected() async throws {
        let manager = OfflineRegionManager(baseDirectory: tempDirectory)
        let installer = OfflineRegionPackageInstaller(routingDirectory: tempDirectory, mapsDirectory: tempDirectory, regionManager: manager)
        
        // First install v2.0
        let package2 = try createMockPackage(version: "2.0")
        try await installer.installRegionPackage(from: package2)
        
        // Try installing v1.0
        let package1 = try createMockPackage(version: "1.0")
        do {
            try await installer.installRegionPackage(from: package1)
            assertionFailure("Expected downgradeRejected error")
        } catch OfflineRegionError.downgradeRejected {
            // Success
        } catch {
            assertionFailure("Unexpected error: \(error)")
        }
    }
}
