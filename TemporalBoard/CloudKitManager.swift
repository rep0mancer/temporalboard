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
    
    private let container = CKContainer.default()
    private let zoneID = CKRecordZone.ID(zoneName: "TemporalBoardZone")
    private let recordType = "Board"
    private let recordName = "main-board"
    
    private var privateDB: CKDatabase { container.privateCloudDatabase }
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
        container.accountStatus { [weak self] status, _ in
            guard let self = self else { return }
            guard status == .available else {
                self.isAvailable = false
                return
            }
            self.isAvailable = true
            self.createZoneIfNeeded()
        }
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
        privateDB.add(op)
    }
    
    private func subscribeToChanges() {
        let sub = CKDatabaseSubscription(subscriptionID: "board-changes")
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true
        sub.notificationInfo = info
        
        privateDB.save(sub) { _, error in
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
        guard isAvailable else { completion(false); return }
        
        // Fetch the existing record first so we carry the server change tag
        // and avoid "server record changed" conflicts on save.
        privateDB.fetch(withRecordID: recordID) { [weak self] existing, fetchError in
            guard let self = self else { completion(false); return }
            
            let record: CKRecord
            if let existing = existing {
                record = existing
            } else if let ckError = fetchError as? CKError,
                      ckError.code == .unknownItem {
                // Record doesn't exist yet — create a fresh one.
                record = CKRecord(recordType: self.recordType, recordID: self.recordID)
            } else if let fetchError = fetchError {
                // Any other fetch error (network, auth, quota, etc.) —
                // fail early instead of masking the root cause.
                print("[CloudKit] Pre-save fetch failed: \(fetchError.localizedDescription)")
                completion(false)
                return
            } else {
                record = CKRecord(recordType: self.recordType, recordID: self.recordID)
            }
            
            // Drawing → CKAsset via a temporary file.
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString + ".drawing")
            do {
                try drawingData.write(to: tempURL)
            } catch {
                completion(false)
                return
            }
            
            record["drawingAsset"] = CKAsset(fileURL: tempURL)
            record["timersJSON"]   = timersData as NSData
            record["lastModified"] = Date() as NSDate
            
            self.privateDB.save(record) { _, error in
                try? FileManager.default.removeItem(at: tempURL)
                if let error = error {
                    print("[CloudKit] Save failed: \(error.localizedDescription)")
                }
                completion(error == nil)
            }
        }
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
        guard isAvailable else { completion(nil); return }
        
        privateDB.fetch(withRecordID: recordID) { record, error in
            if let ck = error as? CKError, ck.code == .unknownItem {
                // No record yet — first sync from this account.
                completion(BoardSnapshot(drawingData: nil,
                                         timersData: nil,
                                         lastModified: nil))
                return
            }
            guard let record = record else {
                if let error = error {
                    print("[CloudKit] Fetch failed: \(error.localizedDescription)")
                }
                completion(nil)
                return
            }
            
            var drawingData: Data?
            if let asset = record["drawingAsset"] as? CKAsset,
               let url = asset.fileURL {
                drawingData = try? Data(contentsOf: url)
            }
            
            let timersData = record["timersJSON"] as? Data
            let lastModified = record["lastModified"] as? Date
            
            completion(BoardSnapshot(drawingData: drawingData,
                                     timersData: timersData,
                                     lastModified: lastModified))
        }
    }
    
    // MARK: - Remote Notifications
    
    /// Call from `AppDelegate.didReceiveRemoteNotification`.
    func handleRemoteNotification() {
        DispatchQueue.main.async { [weak self] in
            self?.onRemoteChange?()
        }
    }
}
