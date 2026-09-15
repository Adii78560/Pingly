import Foundation
@main
struct TestRunner {
    static func main() async {
        let tempDirStr = NSTemporaryDirectory()
        let tempDirectory = URL(fileURLWithPath: tempDirStr).appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        
        let manager = OfflineRegionManager(baseDirectory: tempDirectory)
        
        let sourceDB = "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite"
        let destDB = tempDirectory.appendingPathComponent("monaco.rgraph.sqlite")
        try! FileManager.default.copyItem(atPath: sourceDB, toPath: destDB.path)
        
        await manager.refreshRegions()
        
        let regions = await manager.installedRegions
        if let region = regions.first {
            print("region URL: \(region.databaseURL.path)")
            print("destDB URL: \(destDB.path)")
        } else {
            print("NO REGIONS!")
        }
    }
}
