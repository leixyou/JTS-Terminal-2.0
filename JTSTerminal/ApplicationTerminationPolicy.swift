import Foundation

nonisolated enum ApplicationTerminationPolicy {
    static func bypassesRemoteProcessConfirmation(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier
    ) -> Bool {
        #if JTS_UI_TEST_SUPPORT
        guard bundleIdentifier
                == UITestAppLanguageBootstrap.isolatedApplicationBundleIdentifier else {
            return false
        }
        let isInjectedXCTestHost =
            environment["XCTestConfigurationFilePath"] != nil
            && environment["XCTestBundlePath"] != nil
        let isIsolatedUITestApp =
            environment["JTS_TERMINAL_UI_TESTING"] == "1"
        return isInjectedXCTestHost || isIsolatedUITestApp
        #else
        return false
        #endif
    }
}
