import Foundation
import CloudKit

/// Manages iCloud sync for TemporalBoard using a single CKRecord in a
/// custom private-database zone.
///
/// ## Xcode Project Configuration Required
/// 1. **Signing & Capabilities** → add **iCloud**, check **CloudKit**.
///    The default container `iCloud.<bundle-id>` will be used.
/// 2. **Signing & Capabilities** → add **Push Notifications**.
/// 3. **Signing & Capabilities** → add **Background Modes** →
///    check **Remote notifications**.
final class CloudKitManager {
    
    static let shared = CloudKitManager()
    
    // MARK: - Configuration
    
    // Local-only mode:
    // Keep CloudKit code in the project, but never initialize container/database.
    private lazy var container: CKContainer? = nil
    private let zoneID = CKRecordZone.ID(zoneName: "TemporalBoardZone")
    private let recordType = "Board"
    private let recordName = "main-board"
    
    private var privateDB: CKDatabase? { nil }
    private var recordID: CKRecord.ID {
        CKRecord.ID(recordName: recordName, zoneID: zoneID)
    }
    
    /// Called on the main thread when a remote change notification arrives.
    /// Set by BoardViewModel to trigger `pullFromCloud()`.
    var onRemoteChange: (() -> Void)?
    
    /// Whether the user's iCloud account is available.
    private(set) var isAvailable = false
    
    private init() {}
    
    // MARK: - Setup
    
    /// Check iCloud availability, create the custom zone, and subscribe
    /// to remote changes.  Safe to call multiple times.
    func setup() {
        // Cloud sync intentionally disabled for local-only testing.
        isAvailable = false
        return
    }
    
    private func createZoneIfNeeded() {
        let zone = CKRecordZone(zoneID: zoneID)
        let op = CKModifyRecordZonesOperation(recordZonesToSave: [zone])
        op.modifyRecordZonesResultBlock = { [weak self] result in
            if case .success = result {
                self?.subscribeToChanges()
            }
        }
        op.qualityOfService = .utility
        privateDB?.add(op)
    }
    
    private func subscribeToChanges() {
        let sub = CKDatabaseSubscription(subscriptionID: "board-changes")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        
        privateDB?.save(sub) { _, error in
            // .serverRejectedRequest means the subscription already exists — OK.
            if let ck = error as? CKError, ck.code != .serverRejectedRequest {
                print("[CloudKit] Subscription error: \(ck.localizedDescription)")
            }
        }
    }
    
    // MARK: - Save
    
    /// Push board data to the private iCloud database.
    /// The drawing is stored as a `CKAsset`; timers as JSON `Data`.
    func save(drawingData: Data,
              timersData: Data,
              completion: @escaping (Bool) -> Void) {
        // Cloud sync intentionally disabled for local-only testing.
        completion(true)
        return
    }
    
    // MARK: - Fetch
    
    /// Snapshot of board data returned from iCloud.
    struct BoardSnapshot {
        let drawingData: Data?
        let timersData: Data?
        let lastModified: Date?
    }
    
    /// Pull the latest board from the private iCloud database.
    func fetch(completion: @escaping (BoardSnapshot?) -> Void) {
        // Cloud sync intentionally disabled for local-only testing.
        completion(nil)
        return
    }
    
    // MARK: - Remote Notifications
    
    /// Call from `AppDelegate.didReceiveRemoteNotification`.
    func handleRemoteNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.onRemoteChange?()
        }
    }
}
