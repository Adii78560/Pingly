import Foundation
import CoreLocation

Task {
    let (passed, failed) = await RouteProgressTests.shared.runAllTests()
    if failed > 0 {
        exit(1)
    } else {
        exit(0)
    }
}
RunLoop.main.run()
