//
//  RemotePathBar.swift
//  JTSTerminal
//

import SwiftUI

/// Splits a remote path into clickable breadcrumb components. Each
/// component's `path` is the folder that clicking it lists.
nonisolated enum RemotePathComponents {
    struct Component: Equatable, Identifiable {
        let title: String
        let path: String

        var id: String { path }
    }

    static func components(of rawPath: String) -> [Component] {
        let path = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, path != "~" else {
            return [Component(title: "~", path: "~")]
        }

        var result: [Component] = []
        var current = ""
        var remainder = Substring(path)
        if path.hasPrefix("~/") {
            current = "~"
            remainder = path.dropFirst(2)
            result.append(Component(title: "~", path: "~"))
        } else if path.hasPrefix("/") {
            current = "/"
            remainder = path.dropFirst()
            result.append(Component(title: "/", path: "/"))
        }

        for part in remainder.split(separator: "/", omittingEmptySubsequences: true) {
            let name = String(part)
            if current.isEmpty {
                current = name
            } else if current.hasSuffix("/") {
                current += name
            } else {
                current += "/" + name
            }
            result.append(Component(title: name, path: current))
        }
        return result
    }
}

/// The Files path bar: breadcrumbs like Finder's path bar; click the empty
/// part of the bar to type a path instead. A typed path is used only when
/// you press Return; Escape or clicking away keeps the current folder.
struct RemotePathBar: View {
    @Environment(\.appLanguage) private var language
    let path: String
    let isEnabled: Bool
    let navigate: (String) -> Void
    @State private var isEditing = false
    @State private var draft = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                TextField(language.localized("Remote path", "远程路径"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($isFieldFocused)
                    .onSubmit {
                        isEditing = false
                        navigate(draft)
                    }
                    .onExitCommand {
                        isEditing = false
                    }
                    .onChange(of: isFieldFocused) { _, isFocused in
                        if !isFocused {
                            isEditing = false
                        }
                    }
                    .task {
                        isFieldFocused = true
                    }
                    .accessibilityIdentifier("remote-files-path-field")
            } else {
                breadcrumbs
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var breadcrumbs: some View {
        let components = RemotePathComponents.components(of: path)
        return ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(components) { component in
                    Button {
                        navigate(component.path)
                    } label: {
                        if component.path == "~" {
                            Label(language.localized("Home", "主目录"), systemImage: "house")
                                .labelStyle(.iconOnly)
                        } else {
                            Text(component.title)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.borderless)
                    .fontWeight(component == components.last ? Font.Weight.semibold : Font.Weight.regular)
                    .disabled(!isEnabled)
                    .help(component.path)

                    if component != components.last {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        .defaultScrollAnchor(.trailing)
        .frame(height: 24)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard isEnabled else { return }
            beginEditing()
        }
        .help(language.localized(
            "Click a folder to open it, or click the empty part of the bar to type a path.",
            "点按文件夹即可打开；点按路径栏空白处可以输入路径。"
        ))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("remote-files-path-bar")
        .accessibilityAction(named: Text(language.localized("Edit Path", "编辑路径"))) {
            beginEditing()
        }
    }

    private func beginEditing() {
        draft = path
        isEditing = true
    }
}
