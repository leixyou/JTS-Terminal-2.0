//
//  MobileTerminalView.swift
//  JTSTerminaliOS
//
//  Created by Codex on 2026/6/26.
//

import SwiftTerm
import SwiftUI
import UIKit

struct MobileTerminalView: UIViewRepresentable {
    @ObservedObject var controller: MobileTerminalController

    func makeUIView(context: Context) -> UIView {
        if MobileTerminalUITestSurface.isEnabled {
            return makeTestingTerminalView(coordinator: context.coordinator)
        }

        let terminalView = TerminalView(frame: .zero)
        terminalView.terminalDelegate = context.coordinator
        terminalView.nativeBackgroundColor = UIColor(red: 0.05, green: 0.055, blue: 0.06, alpha: 1)
        terminalView.nativeForegroundColor = UIColor(white: 0.92, alpha: 1)
        terminalView.caretColor = UIColor.systemGreen
        terminalView.allowMouseReporting = true
        terminalView.autocorrectionType = .no
        terminalView.autocapitalizationType = .none
        context.coordinator.synchronizeCurrentSize(of: terminalView)
        return terminalView
    }

    func updateUIView(_ terminalView: UIView, context: Context) {
        guard let terminalView = terminalView as? TerminalView else { return }
        context.coordinator.synchronizeCurrentSize(of: terminalView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stopSynchronizing()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    private func makeTestingTerminalView(coordinator: Coordinator) -> UITextView {
        let textView = UITextView(frame: .zero)
        textView.backgroundColor = UIColor(red: 0.05, green: 0.055, blue: 0.06, alpha: 1)
        textView.textColor = UIColor(white: 0.92, alpha: 1)
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.isEditable = false
        textView.isSelectable = false
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.accessibilityIdentifier = "mobile.terminalTestingSurface"
        coordinator.attachTestingTerminal(textView)
        return textView
    }

    final class Coordinator: NSObject, TerminalViewDelegate {
        private let controller: MobileTerminalController
        private var attachmentID: UUID?
        private var lastObservedSize: MobileTerminalSize?
        private var resizeTask: Task<Void, Never>?

        init(controller: MobileTerminalController) {
            self.controller = controller
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            let bytes = Array(data)
            Task { @MainActor in
                controller.send(ArraySlice(bytes))
            }
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            synchronize(source: source, size: MobileTerminalSize(cols: newCols, rows: newRows))
        }

        func synchronizeCurrentSize(of source: TerminalView) {
            guard hasUsableLayout(source) else { return }
            let terminal = source.getTerminal()
            synchronize(source: source, size: MobileTerminalSize(cols: terminal.cols, rows: terminal.rows))
        }

        func attachTestingTerminal(_ textView: UITextView) {
            Task { @MainActor [weak self, weak textView] in
                guard let self, let textView else { return }
                attachmentID = controller.attachTerminal { [weak textView] bytes in
                    guard let textView else { return }
                    textView.text += String(decoding: bytes, as: UTF8.self)
                }
            }
        }

        func stopSynchronizing() {
            resizeTask?.cancel()
            resizeTask = nil

            guard let attachmentID else { return }
            self.attachmentID = nil
            Task { @MainActor in
                controller.detachTerminal(attachmentID)
            }
        }

        private func synchronize(source: TerminalView, size: MobileTerminalSize) {
            guard hasUsableLayout(source) else { return }
            guard size.isUsable else { return }
            guard size != lastObservedSize || attachmentID == nil else { return }
            lastObservedSize = size

            resizeTask?.cancel()
            resizeTask = Task { @MainActor [weak self, weak source] in
                guard let self, let source else { return }

                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                guard hasUsableLayout(source) else { return }

                let terminal = source.getTerminal()
                let settledSize = MobileTerminalSize(cols: terminal.cols, rows: terminal.rows)
                guard settledSize.isUsable else { return }
                lastObservedSize = settledSize
                controller.resize(cols: settledSize.cols, rows: settledSize.rows)

                if attachmentID == nil {
                    attachmentID = controller.attachTerminal { [weak source] bytes in
                        source?.feed(byteArray: ArraySlice(bytes))
                    }
                }
            }
        }

        private func hasUsableLayout(_ source: TerminalView) -> Bool {
            source.bounds.width >= 44 && source.bounds.height >= 44
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            UIPasteboard.general.setData(content, forPasteboardType: "public.utf8-plain-text")
        }

        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link) else { return }
            UIApplication.shared.open(url)
        }
    }
}

private enum MobileTerminalUITestSurface {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains("-mobile-ui-testing-terminal")
    }
}
