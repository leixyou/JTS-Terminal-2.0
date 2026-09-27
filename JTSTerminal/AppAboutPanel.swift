import AppKit

/// Uses the native, reusable About panel, independent of the active workspace.
@MainActor
enum AppAboutPanel {
    static func show(language: AppLanguage) {
        let bundle = Bundle.main
        let unknown = language.localized("Unavailable", "暂无信息")
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? unknown
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? unknown
        let metadata = buildMetadata(in: bundle)
        let date = metadata["BuildDateUTC"].flatMap { ISO8601DateFormatter().date(from: $0) }
        let dateText: String
        if let date {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: language.localeIdentifier)
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss zzz"
            dateText = formatter.string(from: date)
        } else {
            dateText = unknown
        }

        var details = [language.localized("Build date: \(dateText)", "构建日期：\(dateText)")]
        if let configuration = metadata["Configuration"], !configuration.isEmpty {
            details.append(language.localized("Configuration: \(configuration)", "构建类型：\(configuration)"))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: details.joined(separator: "\n"),
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        )

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "JTS Terminal",
            .applicationVersion: version,
            .version: build,
            .credits: credits
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    private static func buildMetadata(in bundle: Bundle) -> [String: String] {
        guard let url = bundle.url(forResource: "JTSBuildInfo", withExtension: "plist"),
              let data = try? Data(contentsOf: url),
              let metadata = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else { return [:] }
        return metadata as? [String: String] ?? [:]
    }
}
