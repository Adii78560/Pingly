import Foundation
@main
struct TestRunner {
    static func main() async {
        do {
            try await OfflineRegionManagerTests.runAllTests()
            exit(0)
        } catch {
            exit(1)
        }
    }
}
