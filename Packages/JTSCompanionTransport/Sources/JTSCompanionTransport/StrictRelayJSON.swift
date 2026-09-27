import Foundation
import JTSCompanionIPC

enum StrictRelayJSON {
    static func validate(_ data: Data, requiredKeys: Set<String>? = nil) throws {
        do { try StrictCompanionJSON.validate(data, requiredKeys: requiredKeys, maximumBytes: 160 * 1024) }
        catch { throw CompanionTransportError.invalidResponse }
    }
}
