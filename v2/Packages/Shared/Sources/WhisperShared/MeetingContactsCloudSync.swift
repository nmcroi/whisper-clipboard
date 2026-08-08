import Core
import Foundation

/// Kleine iCloud-KV-sync voor de herbruikbare Notulen-deelnemers. De nieuwste
/// volledige lijst wint; hetzelfde mechanisme wordt door Mac en iPhone gebruikt.
@MainActor
public final class MeetingContactsCloudSync {
    public var onRemoteChange: (([SavedMeetingContact]) -> Void)?

    private struct Payload: Codable {
        let updatedAt: Double
        let contacts: [SavedMeetingContact]
    }

    private let store: NSUbiquitousKeyValueStore
    private let defaults: UserDefaults
    private let updatedAtKey: String
    private let cloudKey = "whisperclip.meetingContacts.v1"
    private var localUpdatedAt: Double = 0
    private var observer: NSObjectProtocol?
    private var pending: Task<Void, Never>?

    public init(updatedAtKey: String, store: NSUbiquitousKeyValueStore = .default, defaults: UserDefaults = .standard) {
        self.updatedAtKey = updatedAtKey
        self.store = store
        self.defaults = defaults
    }

    public func start() {
        localUpdatedAt = defaults.double(forKey: updatedAtKey)
        observer = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: store,
            queue: .main
        ) { [weak self] note in
            let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String]
            MainActor.assumeIsolated {
                guard let self, keys == nil || keys?.contains(self.cloudKey) == true else { return }
                self.applyRemoteIfNewer()
            }
        }
        store.synchronize()
        applyRemoteIfNewer()
    }

    public func publish(_ contacts: [SavedMeetingContact]) {
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            let now = Date().timeIntervalSince1970
            guard let data = try? JSONEncoder().encode(Payload(updatedAt: now, contacts: contacts)) else { return }
            self.localUpdatedAt = now
            self.defaults.set(now, forKey: self.updatedAtKey)
            self.store.set(data, forKey: self.cloudKey)
            self.store.synchronize()
        }
    }

    private func applyRemoteIfNewer() {
        guard pending == nil,
              let data = store.data(forKey: cloudKey),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.updatedAt > localUpdatedAt else { return }
        localUpdatedAt = payload.updatedAt
        defaults.set(localUpdatedAt, forKey: updatedAtKey)
        onRemoteChange?(payload.contacts)
    }
}
