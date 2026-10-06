#if ENABLE_RDP_2
import Foundation

enum RelayStationMessage {
    static func text(_ code: String, language: AppLanguage) -> String {
        let message: (String, String)
        switch code {
        case "invalidInput", "invalidOrigin":
            message = ("Check the name and HTTPS address, then try again.", "请检查名称与 HTTPS 地址后重试。")
        case "stationNotFound":
            message = ("This relay station changed or was removed. Reload the list.", "此中转站已更改或移除，请重新读取列表。")
        case "stationAlreadyKnown":
            message = ("This relay address is already saved.", "此中转站地址已经保存。")
        case "capacityReached":
            message = ("The relay station limit has been reached. Remove an unused station first.", "已达到中转站数量上限，请先删除不再使用的中转站。")
        case "corruptState", "missingState":
            message = ("Saved relay data could not be read. The existing data has been preserved.", "无法读取已保存的中转站数据，原有数据已保留。")
        case "operationInProgress":
            message = ("Another operation is in progress. Wait for it to finish.", "另一项操作正在进行，请等待完成。")
        case "storageConflict":
            message = ("Saved data changed during this operation. Reload and try again.", "操作期间已保存的数据发生变化，请重新读取后重试。")
        case "storageUnavailable":
            message = ("The encrypted vault is unavailable. Unlock it and try again.", "加密凭据库暂不可用，请解锁后重试。")
        case "stationInUse":
            message = ("This relay is still used by saved devices and cannot be deleted.", "此中转站仍被设备使用，暂时不能删除。")
        case "deviceVerificationFailed":
            message = ("A device identity could not be verified through the new relay. Check its connection and relay admission, then retry.", "未能通过新中转站验证设备身份。请检查设备连接与中转站接入配置后重试。")
        case "migrationIncomplete":
            message = ("The new relay was saved, but device migration did not finish. Devices retain their previous relay. Check device connectivity and retry this change.", "新中转站已暂存，但设备迁移未完成。设备仍保留原中转站，请检查设备连接后重试此更改。")
        case "cleanupIncomplete":
            message = ("Device addresses were updated, but the previous relay record could not be removed. Reload to review the saved stations.", "设备地址已更新，但旧中转站记录未能移除。请重新读取并检查已保存的中转站。")
        case "redirectRejected":
            message = ("The address redirected elsewhere. Enter the relay's direct HTTPS address.", "此地址跳转到了其他地址，请填写中转站的直接 HTTPS 地址。")
        case "responseTooLarge", "invalidResponse":
            message = ("The server did not return a valid JTS Relay response. Check its address and configuration.", "服务器未返回有效的 JTS Relay 响应，请检查地址与配置。")
        case "unsupportedVersion":
            message = ("This relay uses an unsupported protocol version.", "此中转站使用了不受支持的协议版本。")
        case "serviceUnavailable":
            message = ("The relay service is unavailable. Check the server and try again.", "中转服务暂不可用，请检查服务器后重试。")
        case "timedOut":
            message = ("The relay did not respond in time. Check the network, address and port.", "中转站响应超时，请检查网络、地址与端口。")
        case "connectionFailed":
            message = ("Could not connect to the relay. Check the network, address and port.", "无法连接中转站，请检查网络、地址与端口。")
        case "cancelled":
            message = ("The operation was cancelled.", "操作已取消。")
        default:
            message = ("The operation could not be completed. Reload the saved stations and try again.", "操作未能完成，请重新读取中转站后重试。")
        }
        return language.localized(message.0, message.1)
    }
}
#endif
