import AppKit
import Darwin
import Foundation
import XCTest

struct UITestTargetApplicationDescriptor: Equatable {
    let bundleURL: URL
    let executableURL: URL
    let bundleIdentifier: String

    var usesIsolatedIdentity: Bool {
        bundleIdentifier == UITestTargetApplication.isolatedBundleIdentifier
    }
}

struct UITestRunningApplicationIdentity: Equatable {
    let bundleIdentifier: String?
    let bundleURL: URL?
    let isGUIApplication: Bool
}

enum UITestTargetApplicationError: LocalizedError, Equatable {
    case missingBuiltProductsDirectories
    case unsafeBuiltProductsDirectory(String)
    case missingTargetApplication
    case ambiguousTargetApplications([String])
    case unsafeTargetApplication(String)
    case unexpectedBundleIdentifier(String)
    case productionIdentityRequiresFormalSmoke
    case formalSmokeRequiresProductionIdentity
    case invalidFormalSmokeMode
    case formalSmokeRoutingRequiresMarker
    case incompleteFormalSmokeRouting
    case conflictingRunningApplication

    var errorDescription: String? {
        switch self {
        case .missingBuiltProductsDirectories:
            return "The UI test runner did not provide its built-products directory."
        case let .unsafeBuiltProductsDirectory(path):
            return "The UI test built-products directory is unsafe: \(path)"
        case .missingTargetApplication:
            return "The UI test target application is missing from the built-products directory."
        case let .ambiguousTargetApplications(paths):
            return "The UI test target application is ambiguous: \(paths.joined(separator: ", "))"
        case let .unsafeTargetApplication(path):
            return "The UI test target application is unsafe: \(path)"
        case let .unexpectedBundleIdentifier(identifier):
            return "The UI test target has an unexpected bundle identifier: \(identifier)"
        case .productionIdentityRequiresFormalSmoke:
            return "The production application identity is reserved for the formal App Review smoke test."
        case .formalSmokeRequiresProductionIdentity:
            return "The formal App Review smoke test requires the production application identity."
        case .invalidFormalSmokeMode:
            return "The formal App Review smoke mode marker is invalid."
        case .formalSmokeRoutingRequiresMarker:
            return "App Review smoke routing is present without the formal production-identity marker."
        case .incompleteFormalSmokeRouting:
            return "The formal App Review smoke routing configuration is incomplete."
        case .conflictingRunningApplication:
            return "Close the stale UI-test host before retrying; tests never terminate another running application."
        }
    }
}

enum UITestTargetApplication {
    static let productionBundleIdentifier = "com.lljts.JTSTerminal"
    static let isolatedBundleIdentifier = "com.lljts.JTSTerminal.UITesting"
    static let builtProductsDirectoriesKey = "__XCODE_BUILT_PRODUCTS_DIR_PATHS"
    static let formalProductionIdentityKey =
        "JTS_TERMINAL_UI_TEST_FORMAL_PRODUCTION_IDENTITY"
    static let applicationLanguageStorageKey = "appLanguage.v1"

    private static let applicationBundleName = "JTS Terminal.app"
    private static let executableName = "JTS Terminal"
    private static let maximumInfoPlistSize: off_t = 1_048_576
    private static let runningApplicationSettleTimeout: TimeInterval = 2

    static func makeApplication(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> XCUIApplication {
        let descriptor = try resolveDescriptor(environment: environment)
        let deadline = Date().addingTimeInterval(
            runningApplicationSettleTimeout
        )
        while true {
            let runningApplications = NSWorkspace.shared.runningApplications.map {
                UITestRunningApplicationIdentity(
                    bundleIdentifier: $0.bundleIdentifier,
                    bundleURL: $0.bundleURL,
                    isGUIApplication: $0.activationPolicy != .prohibited
                )
            }
            if !hasConflictingRunningApplication(
                descriptor: descriptor,
                runningApplications: runningApplications
            ) {
                return XCUIApplication(url: descriptor.bundleURL)
            }
            guard Date() < deadline else {
                throw UITestTargetApplicationError
                    .conflictingRunningApplication
            }
            // XCUIApplication.terminate() can finish before LaunchServices
            // removes the exact test app from NSWorkspace's snapshot. Wait
            // briefly for that read-only state to settle; never terminate an
            // application that this test did not launch.
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    static func terminateApplicationLaunchedByThisTest(
        _ application: XCUIApplication,
        timeout: TimeInterval = 5
    ) -> Bool {
        application.terminate()

        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            if application.state == .notRunning {
                return true
            }
            if Date() >= deadline {
                return false
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while true
    }

    static func deterministicLanguageLaunchArguments(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String] {
        guard environment[formalProductionIdentityKey] == "1" else {
            return []
        }
        // The formal App Review smoke intentionally uses the production
        // bundle identity so it can exercise the real sandbox vault. It does
        // not test language switching, so an argument-domain value gives that
        // one run deterministic English without mutating production defaults.
        return ["-\(applicationLanguageStorageKey)", "en"]
    }

    static func resolveDescriptor(
        environment: [String: String],
        currentUserID: uid_t = getuid()
    ) throws -> UITestTargetApplicationDescriptor {
        guard let rawDirectories = environment[builtProductsDirectoriesKey],
              !rawDirectories.isEmpty else {
            throw UITestTargetApplicationError.missingBuiltProductsDirectories
        }

        let directoryPaths = rawDirectories
            .split(separator: ":", omittingEmptySubsequences: true)
            .map(String.init)
        guard !directoryPaths.isEmpty, directoryPaths.count <= 16 else {
            throw UITestTargetApplicationError.missingBuiltProductsDirectories
        }

        var candidates: [UITestTargetApplicationDescriptor] = []
        for directoryPath in directoryPaths {
            let directoryURL = URL(
                fileURLWithPath: directoryPath,
                isDirectory: true
            ).standardizedFileURL
            guard directoryPath.hasPrefix("/"),
                  directoryURL.path.utf8.count < Int(PATH_MAX),
                  try isOwnedNode(
                      at: directoryURL,
                      expectedType: S_IFDIR,
                      currentUserID: currentUserID
                  ),
                  directoryURL.resolvingSymlinksInPath().standardizedFileURL
                      == directoryURL else {
                throw UITestTargetApplicationError
                    .unsafeBuiltProductsDirectory(directoryPath)
            }

            let applicationURL = directoryURL
                .appendingPathComponent(applicationBundleName, isDirectory: true)
            var applicationMetadata = stat()
            guard Darwin.lstat(applicationURL.path, &applicationMetadata) == 0 else {
                if errno == ENOENT {
                    continue
                }
                throw UITestTargetApplicationError
                    .unsafeTargetApplication(applicationURL.path)
            }
            candidates.append(
                try descriptor(
                    at: applicationURL,
                    currentUserID: currentUserID
                )
            )
        }

        guard !candidates.isEmpty else {
            throw UITestTargetApplicationError.missingTargetApplication
        }
        guard candidates.count == 1 else {
            throw UITestTargetApplicationError.ambiguousTargetApplications(
                candidates.map(\.bundleURL.path).sorted()
            )
        }
        let descriptor = candidates[0]
        try validateIdentityMode(
            descriptor: descriptor,
            environment: environment
        )
        return descriptor
    }

    static func hasConflictingRunningApplication(
        descriptor: UITestTargetApplicationDescriptor,
        runningApplications: [UITestRunningApplicationIdentity]
    ) -> Bool {
        let targetURL = descriptor.bundleURL
            .resolvingSymlinksInPath()
            .standardizedFileURL

        return runningApplications.contains { application in
            let hasTargetPath = application.bundleURL.map {
                $0.resolvingSymlinksInPath().standardizedFileURL == targetURL
            } ?? false
            if hasTargetPath {
                return true
            }

            if descriptor.usesIsolatedIdentity {
                return application.bundleIdentifier == isolatedBundleIdentifier
            }
            return application.isGUIApplication
                && application.bundleIdentifier == productionBundleIdentifier
        }
    }

    private static func descriptor(
        at applicationURL: URL,
        currentUserID: uid_t
    ) throws -> UITestTargetApplicationDescriptor {
        let standardizedApplicationURL = applicationURL.standardizedFileURL
        guard standardizedApplicationURL.resolvingSymlinksInPath()
                  .standardizedFileURL == standardizedApplicationURL,
              try isOwnedNode(
                  at: standardizedApplicationURL,
                  expectedType: S_IFDIR,
                  currentUserID: currentUserID
              ) else {
            throw UITestTargetApplicationError
                .unsafeTargetApplication(applicationURL.path)
        }

        let contentsURL = standardizedApplicationURL
            .appendingPathComponent("Contents", isDirectory: true)
        let executableDirectoryURL = contentsURL
            .appendingPathComponent("MacOS", isDirectory: true)
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        let executableURL = executableDirectoryURL
            .appendingPathComponent(executableName)
        let optionalLaunchDirectories = [
            "Frameworks",
            "Helpers",
            "Library",
            "PlugIns",
            "XPCServices",
        ].map {
            contentsURL.appendingPathComponent($0, isDirectory: true)
        }
        guard try isOwnedNode(
                  at: contentsURL,
                  expectedType: S_IFDIR,
                  currentUserID: currentUserID
              ),
              try isOwnedNode(
                  at: executableDirectoryURL,
                  expectedType: S_IFDIR,
                  currentUserID: currentUserID
              ),
              try optionalLaunchDirectories.allSatisfy({
                  try isOwnedDirectoryIfPresent(
                      at: $0,
                      currentUserID: currentUserID
                  )
              }),
              try isOwnedNode(
                  at: infoPlistURL,
                  expectedType: S_IFREG,
                  currentUserID: currentUserID,
                  maximumSize: maximumInfoPlistSize
              ),
              try isOwnedNode(
                  at: executableURL,
                  expectedType: S_IFREG,
                  currentUserID: currentUserID
              ) else {
            throw UITestTargetApplicationError
                .unsafeTargetApplication(applicationURL.path)
        }

        let data = try Data(contentsOf: infoPlistURL, options: [.mappedIfSafe])
        guard let propertyList = try PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ) as? [String: Any],
              propertyList[kCFBundleExecutableKey as String] as? String
                == executableName,
              let bundleIdentifier =
                propertyList[kCFBundleIdentifierKey as String] as? String else {
            throw UITestTargetApplicationError
                .unsafeTargetApplication(applicationURL.path)
        }
        guard bundleIdentifier == isolatedBundleIdentifier
                || bundleIdentifier == productionBundleIdentifier else {
            throw UITestTargetApplicationError
                .unexpectedBundleIdentifier(bundleIdentifier)
        }

        return UITestTargetApplicationDescriptor(
            bundleURL: standardizedApplicationURL,
            executableURL: executableURL,
            bundleIdentifier: bundleIdentifier
        )
    }

    private static func validateIdentityMode(
        descriptor: UITestTargetApplicationDescriptor,
        environment: [String: String]
    ) throws {
        switch environment[formalProductionIdentityKey] {
        case nil:
            guard descriptor.usesIsolatedIdentity else {
                throw UITestTargetApplicationError
                    .productionIdentityRequiresFormalSmoke
            }
            do {
                guard try AppReviewSSHSmokeConfigurationEnvironment
                    .loadIfAvailable(environment: environment) == nil else {
                    throw UITestTargetApplicationError
                        .formalSmokeRoutingRequiresMarker
                }
            } catch let error as UITestTargetApplicationError {
                throw error
            } catch {
                throw UITestTargetApplicationError
                    .formalSmokeRoutingRequiresMarker
            }
        case "1":
            guard !descriptor.usesIsolatedIdentity else {
                throw UITestTargetApplicationError
                    .formalSmokeRequiresProductionIdentity
            }
            let hasCompleteRouting: Bool
            do {
                hasCompleteRouting =
                    try AppReviewSSHSmokeConfigurationEnvironment
                    .loadIfAvailable(environment: environment) != nil
            } catch {
                throw UITestTargetApplicationError.incompleteFormalSmokeRouting
            }
            guard hasCompleteRouting else {
                throw UITestTargetApplicationError.incompleteFormalSmokeRouting
            }
        default:
            throw UITestTargetApplicationError.invalidFormalSmokeMode
        }
    }

    private static func isOwnedNode(
        at url: URL,
        expectedType: mode_t,
        currentUserID: uid_t,
        maximumSize: off_t? = nil
    ) throws -> Bool {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            return false
        }
        guard metadata.st_uid == currentUserID,
              metadata.st_mode & S_IFMT == expectedType,
              metadata.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            return false
        }
        if let maximumSize {
            return metadata.st_size > 0 && metadata.st_size <= maximumSize
        }
        return true
    }

    private static func isOwnedDirectoryIfPresent(
        at url: URL,
        currentUserID: uid_t
    ) throws -> Bool {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0 else {
            return errno == ENOENT
        }
        return metadata.st_uid == currentUserID
            && metadata.st_mode & S_IFMT == S_IFDIR
            && metadata.st_mode & (S_IWGRP | S_IWOTH) == 0
    }
}
