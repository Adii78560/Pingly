import Foundation

@MainActor
class OfflineMapService {
    static let shared = OfflineMapService()
    func syncWithFileSystem() {}
}

@MainActor
class SwiftDataService {
    static let shared = SwiftDataService()
}

@MainActor
class CloudSyncService {
    static let shared = CloudSyncService()
}

@main
struct UITestRunner {
    static func main() async {
        let tests = OfflineRegionUITests()
        await tests.runAllTests()
    }
}
