import AppKit

@MainActor
enum LocalTransferFoldersPanel {
    static func show(language: AppLanguage) {
        let store = LocalTransferAccessStore()
        do {
            let folders = try store.folders()
            let alert = NSAlert()
            alert.messageText = language.localized("Local Transfer Folders", "本地传输文件夹")
            alert.informativeText = language.localized(
                "Downloads, Pictures, Music and Movies are available by default, without selecting them here. Add other folders below for repeated MCP uploads and downloads. Removing a saved folder stops future reuse; running transfers keep their current access.",
                "下载、图片、音乐和影片文件夹默认可用，无需在此授权。可在下方添加其他常用的 MCP 上传和下载文件夹。移除保存的文件夹会停止后续复用，正在进行的传输保留本次授权。"
            )
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 480, height: 26))
            picker.addItems(withTitles: folders.map(\.path))
            if folders.isEmpty {
                picker.addItem(withTitle: language.localized("No saved folders", "尚未保存文件夹"))
                picker.isEnabled = false
            }
            alert.accessoryView = picker
            alert.addButton(withTitle: language.localized("Add Folder…", "添加文件夹…"))
            alert.addButton(withTitle: language.localized("Done", "完成"))
            if !folders.isEmpty {
                alert.addButton(withTitle: language.localized("Remove Selected", "移除所选授权"))
            }
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = language.localized("Authorize Folder", "授权文件夹")
                panel.message = language.localized(
                    "Choose a folder for repeated MCP uploads and downloads. JTS Terminal will remember access to its contents.",
                    "选择常用于 MCP 上传和下载的文件夹。JTS Terminal 将记住对其内容的访问权限。"
                )
                if panel.runModal() == .OK, let url = panel.url {
                    try store.authorize(url)
                }
            case .alertThirdButtonReturn:
                try store.revoke(folders[picker.indexOfSelectedItem])
            default: break
            }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
