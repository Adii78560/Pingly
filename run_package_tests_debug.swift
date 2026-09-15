import Foundation

@MainActor
class OfflineMapService {
    static let shared = OfflineMapService()
    func syncWithFileSystem() {}
}

@main
struct PackageTestRunner {
    static func main() async {
        let tempDirectory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let manager = OfflineRegionManager(baseDirectory: tempDirectory)
        let installer = OfflineRegionPackageInstaller(routingDirectory: tempDirectory, mapsDirectory: tempDirectory, regionManager: manager)
        let tests = OfflineRegionPackageTests()
        
        do {
            let package2 = try tests.createMockPackage(version: "2.0")
            try await installer.installRegionPackage(from: package2)
            
            let regionsAfterV2 = await manager.installedRegions
            print("Regions after v2: \(regionsAfterV2.map { "\($0.id) v\($0.version)" })")
            
            let package1 = try tests.createMockPackage(version: "1.0")
            do {
                try await installer.installRegionPackage(from: package1)
                print("❌ ERROR: Downgrade succeeded!")
            } catch OfflineRegionError.downgradeRejected {
                print("✅ Downgrade rejected properly.")
            } catch {
                print("❌ Unexpected error: \(error)")
            }
        } catch {
            print("❌ TEST FAILED: \(error)")
        }
    }
}
