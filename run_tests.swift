import Foundation

Task {
    let (passed, failed) = await RoutingTests.shared.runAllTests()
    if failed > 0 {
        exit(1)
    } else {
        exit(0)
    }
}
RunLoop.main.run()
