import Foundation
@testable import JTSCompanionDevices

actor DeviceTestPersistence: CompanionDevicePersistence {
    var raw: String?
    var creates = 0, replacements = 0
    var loadError: Error?
    var replacementError: Error?
    var creationError: Error?
    private var hold = false
    private var held: CheckedContinuation<String?, Never>?
    private var heldSignal: CheckedContinuation<Void, Never>?

    init(_ raw: String? = nil) { self.raw = raw }
    func load() async throws -> String? {
        if let loadError { throw loadError }
        if hold {
            return await withCheckedContinuation { value in
                held = value; heldSignal?.resume(); heldSignal = nil
            }
        }
        return raw
    }
    func create(_ value: String) throws {
        creates += 1
        if let creationError { throw creationError }
        guard raw == nil else { throw CompanionDevicePersistenceError.alreadyExists }
        raw = value
    }
    func replace(expected: String, with value: String) throws {
        replacements += 1
        if let replacementError { throw replacementError }
        guard raw == expected else { throw CompanionDevicePersistenceError.conflict }
        raw = value
    }
    func put(_ value: String?) { raw = value }
    func failLoad(_ error: Error?) { loadError = error }
    func failReplace(_ error: Error?) { replacementError = error }
    func failCreate(_ error: Error?) { creationError = error }
    func holdLoad() { hold = true }
    func waitForHeldLoad() async {
        if held != nil { return }
        await withCheckedContinuation { heldSignal = $0 }
    }
    func releaseLoad() { hold = false; held?.resume(returning: raw); held = nil }
}

struct PrivateTestError: Error, CustomStringConvertible {
    var description: String { "PRIVATE_PASSWORD_DO_NOT_EXPOSE" }
}
