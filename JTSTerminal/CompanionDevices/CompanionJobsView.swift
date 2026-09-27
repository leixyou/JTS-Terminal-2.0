#if ENABLE_RDP_2
import AppKit
import SwiftUI
import JTSCompanionIPC

struct CompanionJobsView: View {
    let model: CompanionDevicesModel
    let route: CompanionDeviceRoute
    let language: AppLanguage
    @State private var script = ""
    @State private var directory = "C:\\"
    @State private var timeoutMinutes = 5
    @State private var allowDisconnected = false
    @State private var selectedJob: UUID?
    private func t(_ en: String, _ zh: String) -> String { language.localized(en, zh) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("PowerShell tasks", "PowerShell 任务")).font(.headline)
            Text(t("Runs with the Windows worker account's permissions. The working folder does not restrict the script's access.",
                   "脚本使用 Windows 工作账户的实际权限；工作目录不会限制脚本能访问的范围。"))
                .font(.caption).foregroundStyle(.secondary)
            TextField(t("Working directory", "工作目录"), text: $directory).textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("companion-job-directory")
            TextEditor(text: $script).font(.body.monospaced()).frame(minHeight: 100, maxHeight: 180)
                .border(Color(nsColor: .separatorColor)).accessibilityLabel(t("PowerShell script", "PowerShell 脚本"))
                .accessibilityIdentifier("companion-job-script")
            HStack {
                Stepper(t("Deadline: \(timeoutMinutes) minutes", "最长运行 \(timeoutMinutes) 分钟"), value: $timeoutMinutes, in: 1...1440)
                Spacer()
                Button(t("Run task", "运行任务")) {
                    let submittedScript = script
                    let submittedDirectory = directory
                    let seconds = timeoutMinutes * 60
                    let detached = allowDisconnected
                    let target = route.deviceID
                    Task {
                        if let id = await model.submitJob(script: submittedScript, directory: submittedDirectory,
                            timeoutSeconds: seconds, allowDisconnected: detached, deviceID: target) {
                            selectedJob = id; script = ""
                        }
                    }
                }.buttonStyle(.borderedProminent).disabled(!model.canSubmitJob || script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("companion-job-submit")
            }
            Toggle(t("Allow this task to continue after disconnect (up to its deadline)", "允许此任务在断开后继续运行，直到截止时间"), isOn: $allowDisconnected)
                .toggleStyle(.checkbox)
            Text(t("By default Windows is asked to cancel on connection loss. Closing this window preserves the connection. A lost connection does not confirm process termination; reconnect and query the saved task ID.",
                   "默认由 Windows 在连接断开时取消任务。关闭本窗口会保留连接。连接丢失不能证明进程已停止；重连后应使用已保存的任务 ID 查询。"))
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if route.jobs.isEmpty {
                Text(t("No tasks saved for this device.", "此设备尚无已保存的任务。")).foregroundStyle(.secondary)
            } else {
                ForEach(route.jobs) { job in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Button { selectedJob = selectedJob == job.id ? nil : job.id } label: {
                                Label(job.id.uuidString.lowercased(), systemImage: selectedJob == job.id ? "chevron.down" : "chevron.right")
                                    .font(.caption.monospaced())
                            }.buttonStyle(.plain)
                            Spacer()
                            Text(stateLabel(job)).font(.caption)
                        }
                        if let verified = job.verifiedAt {
                            Text(t("Last remote observation: ", "上次远端确认：") + verified.formatted())
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if selectedJob == job.id { details(job) }
                    }.padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }
            }
        }
        .onChange(of: route.deviceID) { _, _ in script = ""; selectedJob = nil; allowDisconnected = false }
        .onDisappear { script = "" }
    }

    @ViewBuilder private func details(_ job: CompanionDeviceJob) -> some View {
        Text(t("Grant: ", "授权：") + job.metadata.grantID.uuidString.lowercased()).font(.caption.monospaced()).textSelection(.enabled)
        Text(t("Deadline: ", "截止时间：") + job.metadata.deadline.formatted()).font(.caption)
        Text(job.metadata.allowDisconnected ? t("May continue while disconnected", "允许断开后继续") : t("Cancellation requested on disconnect", "断开时请求取消"))
            .font(.caption).foregroundStyle(.secondary)
        if let error = job.errorCode { Text(error).font(.caption.monospaced()).foregroundStyle(.red) }
        if let code = job.receipt?.resultCode { Text(code).font(.caption.monospaced()).textSelection(.enabled) }
        if route.verifiedGrant != job.metadata.grantID {
            Text(t("Verify this task's grant before querying or cancelling it.", "查询或取消前，需先验证此任务对应的授权。"))
                .font(.caption).foregroundStyle(.secondary)
        }
        HStack {
            Button(t("Refresh state", "查询状态")) { Task { await model.refreshJob(job.id, deviceID: route.deviceID) } }
                .disabled(!can(job, "job.get"))
            Button(t("Request cancellation", "请求取消"), role: .destructive) { Task { await model.cancelJob(job.id, deviceID: route.deviceID) } }
                .disabled(!can(job, "job.cancel") || job.isTerminal)
            Button(t("Read next output", "读取后续输出")) { Task { await model.readJobOutput(job.id, deviceID: route.deviceID) } }
                .disabled(!can(job, "job.output") || job.receipt?.dataExpired == true || job.output.count >= 1_048_576)
            Button(t("Clear output", "清除输出")) { job.output = Data() }.disabled(job.output.isEmpty)
        }.controlSize(.small)
        if job.isTerminal {
            Button(t("Remove completed task from this Mac", "从本机移除已结束任务记录")) {
                Task { await model.forgetFinishedJob(job.id, deviceID: route.deviceID) }
            }.controlSize(.small).disabled(route.busy)
        }
        if job.receipt?.dataExpired == true {
            Text(t("Windows has expired this task's output.", "Windows 已清理此任务的输出。")).font(.caption)
        }
        if !job.output.isEmpty {
            ScrollView([.horizontal, .vertical]) {
                Text(String(decoding: job.output, as: UTF8.self)).font(.caption.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(minHeight: 80, maxHeight: 240)
        }
        Text(t("Scripts and output are kept only in memory; the encrypted vault saves task IDs and policy metadata for recovery.",
               "脚本和输出仅保留在内存；加密凭据库仅保存用于恢复的任务 ID 与策略信息。"))
            .font(.caption2).foregroundStyle(.secondary)
    }
    private func can(_ job: CompanionDeviceJob, _ capability: String) -> Bool {
        route.hasRoute && !route.busy && route.verifiedGrant == job.metadata.grantID && route.capabilities.contains(capability)
    }
    private func stateLabel(_ job: CompanionDeviceJob) -> String {
        guard let state = job.receipt?.state else { return t("Remote status unconfirmed", "远端状态未确认") }
        let label: String
        switch state {
        case .queued: label = t("Queued", "排队中")
        case .running: label = t("Running", "运行中")
        case .cancelling: label = t("Cancelling · stop not yet confirmed", "取消中 · 尚未确认停止")
        case .succeeded: label = t("Succeeded", "成功")
        case .failed: label = t("Failed", "失败")
        case .cancelled: label = t("Cancelled", "已取消")
        case .expired: label = t("Expired", "已过期")
        case .interrupted: label = t("Interrupted", "已中断")
        }
        return route.hasRoute ? label : t("Last known: ", "上次状态：") + label
    }
}
#endif
