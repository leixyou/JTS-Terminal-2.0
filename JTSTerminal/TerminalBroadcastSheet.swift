//
//  TerminalBroadcastSheet.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/28.
//

import SwiftUI

struct TerminalBroadcastSheet: View {
    @Environment(\.appLanguage) private var language
    @ObservedObject var coordinator: TerminalBroadcastCoordinator

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            Group {
                switch coordinator.phase {
                case .selection:
                    selectionStep
                case .review:
                    reviewStep
                case .running:
                    runningStep
                case .results:
                    resultsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 560, idealHeight: 640)
        .interactiveDismissDisabled(coordinator.phase == .running)
        .accessibilityIdentifier("terminal-multi-exec-sheet")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "rectangle.3.group.bubble")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(language.localized("Multi-Exec", "批量执行"))
                    .font(.title2.weight(.semibold))
                Text(stepSubtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(stepLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
    }

    private var selectionStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(language.localized("Ready terminal panes", "已就绪的终端窗格"))
                    .font(.headline)

                Spacer()

                Button(language.localized("Select All Ready", "全选已就绪")) {
                    coordinator.selectAllEligible()
                }
                .disabled(coordinator.eligibleTargets.isEmpty)

                Button(language.localized("Clear", "清除")) {
                    coordinator.clearSelection()
                }
                .disabled(coordinator.selectedTargetIDs.isEmpty)
            }

            targetList

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(language.localized("Command", "命令"))
                        .font(.headline)
                    Spacer()
                    Text("\(coordinator.command.count)/\(TerminalMCPCommandRequest.maximumCommandCharacters)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                TextEditor(text: $coordinator.command)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                            .allowsHitTesting(false)
                    }
                    .frame(minHeight: 100, maxHeight: 140)
                    .accessibilityLabel(
                        language.localized("Command", "命令")
                    )
                    .accessibilityIdentifier("terminal-multi-exec-command-editor")

                Text(language.localized(
                    "Multi-Exec does not add the command or captured output to command history, audit logs, macros, or the clipboard. Closing the panel releases its command and result references.",
                    "批量执行不会把命令或捕获的输出写入命令历史、审计日志、宏或剪贴板。关闭面板后会释放其命令和结果引用。"
                ))
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            errorBanner
        }
        .padding(22)
    }

    private var targetList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Color.clear.frame(width: 22, height: 1)
                Text(language.localized("Server / pane", "服务器 / 窗格"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(language.localized("Process", "进程"))
                    .frame(width: 100, alignment: .leading)
                Text(language.localized("Status", "状态"))
                    .frame(width: 110, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if coordinator.targets.isEmpty {
                ContentUnavailableView(
                    language.localized("No open terminal panes", "没有已打开的终端窗格"),
                    systemImage: "terminal",
                    description: Text(language.localized(
                        "Open and start at least two SSH or Local Shell panes, then mark each one Multi-Exec Ready.",
                        "请打开并启动至少两个 SSH 或本地 Shell 窗格，然后分别标记为“批量执行就绪”。"
                    ))
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(coordinator.targets) { target in
                            targetRow(target)
                            Divider()
                        }
                    }
                }
            }
        }
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(minHeight: 160, maxHeight: 230)
    }

    private func targetRow(_ target: TerminalBroadcastTarget) -> some View {
        let availability = target.availability
        return HStack(spacing: 12) {
            Toggle(
                "",
                isOn: Binding(
                    get: { coordinator.selectedTargetIDs.contains(target.id) },
                    set: { coordinator.setSelected($0, targetID: target.id) }
                )
            )
            .labelsHidden()
            .disabled(!availability.isEligible)
            .frame(width: 22)
            .accessibilityLabel(language.localized(
                "Select \(target.profileName), \(localizedPaneTitle(target.paneTitle))",
                "选择 \(target.profileName)，\(localizedPaneTitle(target.paneTitle))"
            ))

            VStack(alignment: .leading, spacing: 2) {
                Text(target.profileName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text("\(target.address) · \(localizedPaneTitle(target.paneTitle))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(target.reviewedPID.map { "PID \($0)" } ?? "—")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 100, alignment: .leading)

            Label(availabilityLabel(availability), systemImage: availabilitySymbol(availability))
                .font(.caption.weight(.medium))
                .foregroundStyle(availabilityColor(availability))
                .frame(width: 110, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label(
                    language.localized(
                        "Review the exact targets and command before anything is sent.",
                        "发送前请核对准确的目标和命令。"
                    ),
                    systemImage: "checklist"
                )
                .font(.headline)

                VStack(alignment: .leading, spacing: 10) {
                    Text(language.localized("Targets", "目标"))
                        .font(.headline)

                    ForEach(coordinator.selectedTargets) { target in
                        HStack {
                            Image(systemName: "terminal.fill")
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(target.profileName)
                                    .font(.callout.weight(.medium))
                                Text("\(target.address) · \(localizedPaneTitle(target.paneTitle)) · \(target.reviewedPID.map { "PID \($0)" } ?? "PID —")")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(14)
                .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(language.localized("Command", "命令"))
                            .font(.headline)
                        Spacer()
                        Toggle(
                            language.localized("Reveal", "显示"),
                            isOn: Binding(
                                get: { !coordinator.masksCommandInReview },
                                set: { coordinator.masksCommandInReview = !$0 }
                            )
                        )
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }

                    ScrollView([.horizontal, .vertical]) {
                        if coordinator.masksCommandInReview {
                            Text(reviewCommandText)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.disabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            Text(reviewCommandText)
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(minHeight: 90, maxHeight: 150)
                    .padding(12)
                    .background(
                        Color(nsColor: .textBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 8)
                    )
                }

                Label(
                    language.localized(
                        "Multi-Exec is best effort, not a transaction: there is no rollback. Each command runs in the pane's current shell and may run as root.",
                        "批量执行是尽力执行，不是事务：不会自动回滚。命令会在各窗格当前 shell 中运行，并可能以 root 身份执行。"
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
                .padding(14)
                .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                Toggle(
                    language.localized(
                        "I confirm every selected pane is currently at a shell prompt.",
                        "我确认每个已选窗格当前都位于 shell 提示符。"
                    ),
                    isOn: $coordinator.didConfirmPromptState
                )
                .font(.callout.weight(.medium))
                .accessibilityIdentifier("terminal-multi-exec-confirm-toggle")

                errorBanner
            }
            .padding(22)
        }
    }

    private var runningStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(language.localized("Per-pane progress", "各窗格执行进度"))
                    .font(.headline)
                Spacer()
                Text(resultSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            ProgressView(
                value: Double(completedResultCount),
                total: Double(max(coordinator.results.count, 1))
            )
            .accessibilityLabel(language.localized(
                "Multi-Exec progress",
                "批量执行进度"
            ))
            .accessibilityValue(language.localized(
                "\(completedResultCount) of \(coordinator.results.count) completed",
                "已完成 \(completedResultCount)，共 \(coordinator.results.count)"
            ))

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(coordinator.results) { result in
                        resultRow(result)
                    }
                }
            }
            .accessibilityIdentifier("terminal-multi-exec-progress-list")

            Text(language.localized(
                "This panel stays open until every pane reports a result.",
                "所有窗格返回结果前，本面板会保持打开。"
            ))
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(22)
    }

    private var resultsStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(language.localized("Per-pane results", "各窗格执行结果"))
                    .font(.headline)
                Spacer()
                Text(resultSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(coordinator.results) { result in
                        resultRow(result)
                    }
                }
            }

            Text(language.localized(
                "Closing this panel releases its command and captured-result references.",
                "关闭本面板后，会释放其命令和捕获结果的引用。"
            ))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(22)
    }

    private func resultRow(_ result: TerminalBroadcastPaneResult) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 8) {
                if result.status == .queued {
                    Text(language.localized("Waiting to start", "等待开始"))
                        .foregroundStyle(.secondary)
                } else if result.status == .running {
                    Text(language.localized("Command is running", "命令执行中"))
                        .foregroundStyle(.secondary)
                } else {
                    if let errorMessage = result.errorMessage, !errorMessage.isEmpty {
                        Text(localizedBroadcastMessage(errorMessage))
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                    if !result.stdout.isEmpty {
                        ScrollView([.horizontal, .vertical]) {
                            Text(result.stdout)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: 180)
                    } else if result.errorMessage == nil {
                        Text(language.localized("No output", "无输出"))
                            .foregroundStyle(.secondary)
                    }
                }
                if result.truncated {
                    Label(
                        language.localized("Output was truncated to 64 KiB.", "输出已截断为 64 KiB。"),
                        systemImage: "scissors"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: resultSymbol(result.status))
                    .foregroundStyle(resultColor(result.status))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(
                        "\(result.profileName) · \(localizedPaneTitle(result.paneTitle))"
                    )
                        .font(.callout.weight(.medium))
                    Text(resultMetadata(result))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(
                "\(result.profileName), \(localizedPaneTitle(result.paneTitle))"
            )
            .accessibilityValue(resultMetadata(result))
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityIdentifier("terminal-multi-exec-result-\(result.id.uuidString)")
    }

    @ViewBuilder
    private var errorBanner: some View {
        if !coordinator.errorMessage.isEmpty {
            Label(
                localizedBroadcastMessage(coordinator.errorMessage),
                systemImage: "exclamationmark.triangle.fill"
            )
                .font(.callout)
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityIdentifier("terminal-multi-exec-error")
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch coordinator.phase {
            case .selection:
                Button(language.localized("Cancel", "取消"), role: .cancel) {
                    coordinator.close()
                }
                Spacer()
                Text(language.localized(
                    "\(coordinator.selectedTargetIDs.count) selected",
                    "已选择 \(coordinator.selectedTargetIDs.count) 个"
                ))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                Button(language.localized("Review", "审阅")) {
                    coordinator.review()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.canReview)
                .accessibilityIdentifier("terminal-multi-exec-review-button")

            case .review:
                Button(language.localized("Back", "返回")) {
                    coordinator.returnToSelection()
                }
                Spacer()
                Button(language.localized(
                    "Run on \(coordinator.selectedTargets.count) Panes",
                    "在 \(coordinator.selectedTargets.count) 个窗格执行"
                )) {
                    coordinator.runConfirmedBatch()
                }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.canRun)
                .accessibilityIdentifier("terminal-multi-exec-run-button")

            case .running:
                Spacer()
                Text(language.localized("Do not close the terminal panes.", "请勿关闭终端窗格。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()

            case .results:
                Spacer()
                Button(language.localized("Close and Clear", "关闭并清除")) {
                    coordinator.close()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("terminal-multi-exec-close-button")
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
    }

    private var stepLabel: String {
        switch coordinator.phase {
        case .selection:
            return language.localized("Step 1 of 2", "第 1 步，共 2 步")
        case .review:
            return language.localized("Step 2 of 2", "第 2 步，共 2 步")
        case .running:
            return language.localized("Running", "执行中")
        case .results:
            return language.localized("Results", "结果")
        }
    }

    private var stepSubtitle: String {
        switch coordinator.phase {
        case .selection:
            return language.localized(
                "Choose explicitly prepared panes and enter one command.",
                "选择已明确准备好的窗格，并输入一条命令。"
            )
        case .review:
            return language.localized(
                "Confirm shell state, targets, and command.",
                "确认 shell 状态、目标和命令。"
            )
        case .running:
            return language.localized(
                "Commands are serialized inside each pane.",
                "命令会在每个窗格内串行执行。"
            )
        case .results:
            return language.localized(
                "Inspect success or failure for every pane.",
                "逐一检查每个窗格的成功或失败状态。"
            )
        }
    }

    private var reviewCommandText: String {
        guard coordinator.masksCommandInReview else { return coordinator.command }
        let count = min(max(coordinator.command.count, 1), 160)
        return String(repeating: "•", count: count)
    }

    private var resultSummary: String {
        language.localized(
            "\(completedResultCount)/\(coordinator.results.count) completed",
            "\(completedResultCount)/\(coordinator.results.count) 已完成"
        )
    }

    private var completedResultCount: Int {
        coordinator.results.filter {
            ![.queued, .running].contains($0.status)
        }.count
    }

    private func availabilityLabel(_ availability: TerminalBroadcastAvailability) -> String {
        switch availability {
        case .ready:
            return language.localized("Ready", "就绪")
        case .notStarted:
            return language.localized("Stopped", "未运行")
        case .transitioning:
            return language.localized("Connecting", "连接中")
        case .notReady:
            return language.localized("Not Ready", "未就绪")
        case .busy:
            return language.localized("Busy", "忙碌")
        case .processChanged:
            return language.localized("Changed", "已变化")
        case .recoveryRequired:
            return language.localized("Recovery Required", "需要确认恢复")
        }
    }

    private func availabilitySymbol(_ availability: TerminalBroadcastAvailability) -> String {
        switch availability {
        case .ready:
            return "checkmark.circle.fill"
        case .notStarted:
            return "stop.circle"
        case .transitioning:
            return "arrow.triangle.2.circlepath"
        case .notReady:
            return "circle"
        case .busy:
            return "clock.fill"
        case .processChanged:
            return "exclamationmark.arrow.triangle.2.circlepath"
        case .recoveryRequired:
            return "exclamationmark.triangle.fill"
        }
    }

    private func availabilityColor(_ availability: TerminalBroadcastAvailability) -> Color {
        switch availability {
        case .ready:
            return .green
        case .transitioning, .busy:
            return .orange
        case .processChanged, .recoveryRequired:
            return .red
        case .notStarted, .notReady:
            return .secondary
        }
    }

    private func resultSymbol(_ status: TerminalBroadcastPaneResult.Status) -> String {
        switch status {
        case .queued:
            return "circle.dotted"
        case .running:
            return "hourglass"
        case .succeeded:
            return "checkmark.circle.fill"
        case .nonZeroExit:
            return "exclamationmark.circle.fill"
        case .timedOut:
            return "clock.badge.exclamationmark.fill"
        case .notSent:
            return "nosign"
        case .disconnected:
            return "bolt.slash.fill"
        case .partialSend:
            return "exclamationmark.octagon.fill"
        case .cancelled:
            return "xmark.circle"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private func resultColor(_ status: TerminalBroadcastPaneResult.Status) -> Color {
        switch status {
        case .succeeded:
            return .green
        case .queued, .running:
            return .secondary
        case .nonZeroExit, .timedOut:
            return .orange
        case .notSent, .disconnected, .partialSend, .cancelled, .failed:
            return .red
        }
    }

    private func resultMetadata(_ result: TerminalBroadcastPaneResult) -> String {
        let duration = "\(result.durationMs) ms"
        switch result.status {
        case .queued:
            return language.localized("Queued", "排队中")
        case .running:
            return language.localized("Running", "执行中")
        case .succeeded:
            return language.localized(
                "Exit \(result.exitCode ?? -1) · \(duration)",
                "退出码 \(result.exitCode ?? -1) · \(duration)"
            )
        case .nonZeroExit:
            return language.localized(
                "Non-zero exit \(result.exitCode ?? -1) · \(duration)",
                "非零退出码 \(result.exitCode ?? -1) · \(duration)"
            )
        case .timedOut:
            return language.localized("Timed out · \(duration)", "超时 · \(duration)")
        case .notSent:
            return language.localized("Not sent · \(duration)", "未发送 · \(duration)")
        case .disconnected:
            return language.localized("Disconnected · \(duration)", "已断开 · \(duration)")
        case .partialSend:
            return language.localized(
                "Interrupted after sending began · \(duration)",
                "开始发送后被中断 · \(duration)"
            )
        case .cancelled:
            return language.localized("Cancelled · \(duration)", "已取消 · \(duration)")
        case .failed:
            return language.localized("Failed · \(duration)", "失败 · \(duration)")
        }
    }

    private func localizedPaneTitle(_ title: String) -> String {
        let prefix = "Terminal tab "
        guard title.hasPrefix(prefix) else { return title }

        let suffix = String(title.dropFirst(prefix.count))
        let components = suffix.components(separatedBy: ", pane ")
        guard let tabNumber = Int(components[0]) else { return title }
        if components.count == 1 {
            return language.localized(
                "Terminal tab \(tabNumber)",
                "终端标签页 \(tabNumber)"
            )
        }
        guard components.count == 2,
              let paneNumber = Int(components[1]) else {
            return title
        }
        return language.localized(
            "Terminal tab \(tabNumber), pane \(paneNumber)",
            "终端标签页 \(tabNumber)，窗格 \(paneNumber)"
        )
    }

    private func localizedBroadcastMessage(_ message: String) -> String {
        switch message {
        case "Terminal command cannot be empty.":
            return language.localized(
                message,
                "终端命令不能为空。"
            )
        case "Terminal command exceeds \(TerminalMCPCommandRequest.maximumCommandCharacters) characters.":
            return language.localized(
                message,
                "终端命令不能超过 \(TerminalMCPCommandRequest.maximumCommandCharacters) 个字符。"
            )
        case "Terminal command contains unsupported control characters.":
            return language.localized(
                message,
                "终端命令包含不支持的控制字符。"
            )
        case "Select at least \(TerminalBroadcastPolicy.minimumTargetCount) ready terminal panes.":
            return language.localized(
                message,
                "请至少选择 \(TerminalBroadcastPolicy.minimumTargetCount) 个已就绪的终端窗格。"
            )
        case "A Multi-Exec batch can include at most \(TerminalBroadcastPolicy.maximumTargetCount) panes.":
            return language.localized(
                message,
                "一次批量执行最多可包含 \(TerminalBroadcastPolicy.maximumTargetCount) 个窗格。"
            )
        case "One or more selected panes changed. Reopen Multi-Exec and review the current targets.":
            return language.localized(
                message,
                "一个或多个已选窗格发生变化。请重新打开批量执行并核对当前目标。"
            )
        case "The command or target selection changed after review. Nothing was sent.":
            return language.localized(
                message,
                "审阅后命令或目标选择发生变化，未发送任何内容。"
            )
        case "A selected pane changed after review. Nothing was sent.":
            return language.localized(
                message,
                "审阅后有已选窗格发生变化，未发送任何内容。"
            )
        case "A selected pane became busy or reconnected. Nothing was sent.":
            return language.localized(
                message,
                "有已选窗格变为忙碌或已重新连接，未发送任何内容。"
            )
        case "Multi-Exec was cancelled before this pane started.":
            return language.localized(
                message,
                "批量执行在此窗格开始前已取消。"
            )
        case "The terminal process was unavailable before any command bytes were sent.":
            return language.localized(
                message,
                "发送任何命令字节前，终端进程已不可用。"
            )
        case "Multi-Exec was cancelled.",
             "Terminal command execution was cancelled.":
            return language.localized(
                message,
                "批量执行已取消。"
            )
        case "The authorized terminal session is not running.":
            return language.localized(
                message,
                "已授权的终端会话未在运行。"
            )
        case "Could not parse terminal command result from the PTY transcript.":
            return language.localized(
                message,
                "无法从 PTY 记录中解析终端命令结果。"
            )
        case "The terminal changed after Multi-Exec review. No command was sent to this pane.":
            return language.localized(
                message,
                "批量执行审阅后终端发生变化，未向此窗格发送命令。"
            )
        case "Terminal automation is unavailable while an interactive password prompt is active.":
            return language.localized(
                message,
                "交互式密码提示处于活动状态时，终端自动化不可用。"
            )
        case "The terminal process changed before the command started.":
            return language.localized(
                message,
                "命令开始前终端进程已发生变化。"
            )
        case "The terminal process changed while the command was running.":
            return language.localized(
                message,
                "命令运行期间终端进程发生变化。"
            )
        case "The Multi-Exec reservation expired before the command started.":
            return language.localized(
                message,
                "命令开始前批量执行预留已失效。"
            )
        case "The Multi-Exec reservation expired while the command was running.":
            return language.localized(
                message,
                "命令运行期间批量执行预留已失效。"
            )
        case "Terminal automation is paused because the previous command may still own the shell. Return the pane to a shell prompt manually, then confirm recovery in the pane header.":
            return language.localized(
                message,
                "终端自动化已暂停，因为上一条命令可能仍占用 shell。请手动让窗格返回 shell 提示符，然后在窗格标题栏确认恢复。"
            )
        default:
            return message
        }
    }
}
