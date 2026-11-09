// Entry point for running the Swift Testing suites without SwiftPM.
// Only scripts/test.sh compiles this file; `swift test` ignores it.
import Testing

@main struct TestMain {
    static func main() async {
        await Testing.__swiftPMEntryPoint() as Never
    }
}
