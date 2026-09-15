import Foundation

@MainActor
class OfflineMapService {
    static let shared = OfflineMapService()
    func syncWithFileSystem() {
        print("Mock Map Service Sync")
    }
}

@main
struct PackageTestRunner {
    static func main() async {
        print("\n--- Starting Offline Region Package Tests ---")
        
        do {
            let tests = OfflineRegionPackageTests()
            try tests.setUp()
            
            try await tests.testValidPackageValidation()
            print("✅ testValidPackageValidation passed")
            
            try await tests.testMissingManifest()
            print("✅ testMissingManifest passed")
            
            try await tests.testMalformedManifest()
            print("✅ testMalformedManifest passed")
            
            try await tests.testPathTraversalRejected()
            print("✅ testPathTraversalRejected passed")
            
            try await tests.testSuccessfulInstallation()
            print("✅ testSuccessfulInstallation passed")
            
            try await tests.testDowngradeRejected()
            print("✅ testDowngradeRejected passed")
            
            tests.tearDown()
        } catch {
            print("❌ TEST FAILED: \(error)")
            exit(1)
        }
        
        print("--- Offline Region Package Tests Complete ---\n")
    }
}
