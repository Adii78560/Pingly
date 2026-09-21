import Foundation
import CoreLocation
import os

final class OfflineRegionManagerTests {
    
    var tempDirectory: URL!
    var manager: OfflineRegionManager!
    
    func setUp() throws {
        let tempDirStr = NSTemporaryDirectory()
        tempDirectory = URL(fileURLWithPath: tempDirStr).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        manager = OfflineRegionManager(baseDirectory: tempDirectory)
    }
    
    func tearDown() throws {
        try FileManager.default.removeItem(at: tempDirectory)
    }
    
    static func runAllTests() async throws {
        let tests = OfflineRegionManagerTests()
        var passed = 0
        
        do {
            try tests.setUp()
            try await tests.testDirectoryCreation()
            passed += 1
            
            try tests.tearDown()
            try tests.setUp()
            try await tests.testRegionDiscoveryAndValidation()
            passed += 1
            
            try tests.tearDown()
            try tests.setUp()
            try await tests.testCoordinateResolution()
            passed += 1
            
            try tests.tearDown()
            try tests.setUp()
            try await tests.testDuplicateVersionCleanup()
            passed += 1
            
            try tests.tearDown()
            try tests.setUp()
            try await tests.testDeleteRegion()
            passed += 1
            
            try tests.tearDown()
        } catch {
            try? tests.tearDown()
            throw error
        }
    }
    
    func testDirectoryCreation() async throws {
        let testDir = tempDirectory.appendingPathComponent("TestCreation")
        let testManager = OfflineRegionManager(baseDirectory: testDir)
        
        await testManager.refreshRegions()
        
        assert(FileManager.default.fileExists(atPath: testDir.path), "Manager should create its base directory if it doesn't exist.")
    }
    
    func testRegionDiscoveryAndValidation() async throws {
        let sourceDB = "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite"
        let destDB = tempDirectory.appendingPathComponent("monaco.rgraph.sqlite")
        try FileManager.default.copyItem(atPath: sourceDB, toPath: destDB.path)
        
        await manager.refreshRegions()
        
        let regions = await manager.installedRegions
        assert(regions.count == 1, "Expected 1 region")
        
        if let region = regions.first {
            assert(region.id == "custom_extract", "Expected custom_extract")
            assert(region.minLatitude > 0)
            assert(region.maxLatitude > 0)
            assert(region.minLongitude > 0)
            assert(region.maxLongitude > 0)
        }
    }
    
    func testCoordinateResolution() async throws {
        let sourceDB = "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite"
        let destDB = tempDirectory.appendingPathComponent("monaco.rgraph.sqlite")
        try FileManager.default.copyItem(atPath: sourceDB, toPath: destDB.path)
        
        await manager.refreshRegions()
        
        let inside = CLLocationCoordinate2D(latitude: 43.739, longitude: 7.427)
        let resolved = await manager.resolveRegion(for: inside)
        assert(resolved != nil, "Expected region to be resolved")
        assert(resolved?.id == "custom_extract", "Expected custom_extract")
        
        let outside = CLLocationCoordinate2D(latitude: 51.5, longitude: -0.1)
        let notResolved = await manager.resolveRegion(for: outside)
        assert(notResolved == nil, "Expected region to not be resolved")
    }
    
    func testDuplicateVersionCleanup() async throws {
        let sourceDB = "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite"
        let destDB1 = tempDirectory.appendingPathComponent("monaco-v1.rgraph.sqlite")
        let destDB2 = tempDirectory.appendingPathComponent("monaco-v2.rgraph.sqlite")
        
        try FileManager.default.copyItem(atPath: sourceDB, toPath: destDB1.path)
        try FileManager.default.copyItem(atPath: sourceDB, toPath: destDB2.path)
        
        var attributes = try FileManager.default.attributesOfItem(atPath: destDB2.path)
        attributes[.creationDate] = Date().addingTimeInterval(10)
        try FileManager.default.setAttributes(attributes, ofItemAtPath: destDB2.path)
        
        await manager.refreshRegions()
        
        let regions = await manager.installedRegions
        assert(regions.count == 1, "Should only keep one region for 'custom_extract'")
        assert(!FileManager.default.fileExists(atPath: destDB1.path), "Older duplicate should be deleted")
        assert(FileManager.default.fileExists(atPath: destDB2.path), "Newer duplicate should be kept")
    }
    
    func testDeleteRegion() async throws {
        let sourceDB = "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite"
        let destDB = tempDirectory.appendingPathComponent("monaco.rgraph.sqlite")
        try FileManager.default.copyItem(atPath: sourceDB, toPath: destDB.path)
        
        await manager.refreshRegions()
        var regions = await manager.installedRegions
        assert(regions.count == 1)
        
        try await manager.deleteRegion(id: "custom_extract")
        regions = await manager.installedRegions
        assert(regions.count == 0)
        assert(!FileManager.default.fileExists(atPath: destDB.path))
    }
}
