import Darwin
import Foundation

@main
@MainActor
enum CompanionEntryPoint {
    static func main() async {
        let arguments = Set(CommandLine.arguments.dropFirst())
        if arguments.contains("--diagnose-ro") || arguments.contains("--diagnostics") || arguments.contains("--capture-diagnostic") {
            let status = await CompanionDiagnostics.run(captureFrame: arguments.contains("--capture-diagnostic"))
            exit(status)
        }
        JTSMacCompanionApp.main()
    }
}
