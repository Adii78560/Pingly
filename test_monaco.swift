import Foundation
import CoreLocation

// Dump error for monaco test
Task {
    let db = RoutingDatabase(fileURL: URL(fileURLWithPath: "/Users/adityarai/Desktop/Pingly/RoutingPipeline/monaco.rgraph.sqlite"))
    let service = OfflineRoutingService(database: db)
    do {
        let start = CLLocationCoordinate2D(latitude: 43.7384, longitude: 7.4246)
        let end = CLLocationCoordinate2D(latitude: 43.7400, longitude: 7.4260)
        let route = try await service.calculateRoute(from: start, to: end)
        print("SUCCESS")
    } catch {
        print("ERROR: \(error)")
    }
    exit(0)
}
RunLoop.main.run()
