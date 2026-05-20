import Foundation
import UIKit
import ZIPFoundation

struct Friend: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var nickname: String?
    var note: String?
    var imageFileNames: [String]
    var centroidEmbedding: [Float]?
    var updatedAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        nickname: String? = nil,
        note: String? = nil,
        imageFileNames: [String] = [],
        centroidEmbedding: [Float]? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.note = note
        self.imageFileNames = imageFileNames
        self.centroidEmbedding = centroidEmbedding
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case nickname
        case note
        case imageFileNames
        case centroidEmbedding
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        nickname = try container.decodeIfPresent(String.self, forKey: .nickname)
        note = try container.decodeIfPresent(String.self, forKey: .note)
        imageFileNames = try container.decodeIfPresent([String].self, forKey: .imageFileNames) ?? []
        centroidEmbedding = try container.decodeIfPresent([Float].self, forKey: .centroidEmbedding)
        updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date.distantPast
    }
}

enum FriendsMergeStrategy {
    case mergeByIdNewestTimestampWins
    case replaceAll
}

struct FriendsTransferResult {
    let importedCount: Int
    let mergedCount: Int
    let copiedImages: Int
    let missingImages: [String]
    let importedFriendIDs: [String]
}

private struct DeletedFriendTombstone: Codable {
    let id: String
    let deletedAt: Date
}

private struct FriendsSyncPackage: Codable {
    let version: Int
    let exportedAt: Date
    let friends: [Friend]
    let tombstones: [DeletedFriendTombstone]

    init(version: Int, exportedAt: Date, friends: [Friend], tombstones: [DeletedFriendTombstone] = []) {
        self.version = version
        self.exportedAt = exportedAt
        self.friends = friends
        self.tombstones = tombstones
    }

    enum CodingKeys: String, CodingKey {
        case version
        case exportedAt
        case friends
        case tombstones
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decode(Int.self, forKey: .version)
        exportedAt = try container.decode(Date.self, forKey: .exportedAt)
        friends = try container.decode([Friend].self, forKey: .friends)
        tombstones = try container.decodeIfPresent([DeletedFriendTombstone].self, forKey: .tombstones) ?? []
    }
}

@MainActor
class FriendsStore: ObservableObject {
    @Published private(set) var friends: [Friend] = []
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastSyncError: String?
    @Published private(set) var iCloudAvailable: Bool = false

    private let storageURL: URL
    private let tombstoneStorageURL: URL
    private let packageFilename = "friends-package.json"
    private let packageImagesFolderName = "images"
    private let packageFolderName = "FriendFinderSync"
    private var autoSyncTask: Task<Void, Never>?
    private var lastObservedRemoteModificationDate: Date?
    private var tombstonesById: [String: Date] = [:]

    init(filename: String = "friends.json") {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storageURL = docs.appendingPathComponent(filename)
        self.tombstoneStorageURL = docs.appendingPathComponent("friends_tombstones.json")
        load()
        loadTombstones()
    }

    func addFriend(name: String, nickname: String? = nil, note: String? = nil) -> Friend {
        let friend = Friend(name: name, nickname: nickname, note: note)
        friends.append(friend)
        save(triggerSync: true)
        return friend
    }

    func friend(withId id: String) -> Friend? {
        friends.first(where: { $0.id == id })
    }

    func deleteFriend(id: String) {
        friends.removeAll { $0.id == id }
        tombstonesById[id] = Date()
        save(triggerSync: true)
    }

    func updateFriendDetails(id: String, name: String, nickname: String?, note: String?) {
        guard let idx = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[idx].name = name
        friends[idx].nickname = nickname
        friends[idx].note = note
        friends[idx].updatedAt = Date()
        save(triggerSync: true)
    }

    func addImage(_ image: UIImage, for friendId: String) throws -> String {
        try addImages([image], for: friendId).first ?? ""
    }

    func addImages(_ images: [UIImage], for friendId: String) throws -> [String] {
        guard let idx = friends.firstIndex(where: { $0.id == friendId }) else { return [] }

        let filenames = try images.map(writeImage)
        friends[idx].imageFileNames.append(contentsOf: filenames)
        friends[idx].updatedAt = Date()
        save(triggerSync: true)
        return filenames
    }

    func replaceImage(named filename: String, with image: UIImage, for friendId: String) throws {
        guard let idx = friends.firstIndex(where: { $0.id == friendId }) else { return }
        guard friends[idx].imageFileNames.contains(filename) else { return }

        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "FriendsStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
        }

        let fileURL = imageFileURL(named: filename)
        try data.write(to: fileURL, options: .atomic)
        friends[idx].updatedAt = Date()
        save(triggerSync: true)
    }

    func removeImage(named filename: String, for friendId: String) {
        guard let idx = friends.firstIndex(where: { $0.id == friendId }) else { return }
        guard let imageIndex = friends[idx].imageFileNames.firstIndex(of: filename) else { return }

        friends[idx].imageFileNames.remove(at: imageIndex)

        let fileURL = imageFileURL(named: filename)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try? FileManager.default.removeItem(at: fileURL)
        }

        friends[idx].updatedAt = Date()
        save(triggerSync: true)
    }

    func loadImage(named filename: String) -> UIImage? {
        let fileURL = imageFileURL(named: filename)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return UIImage(data: data)
    }

    func imageFileURL(named filename: String) -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(filename)
    }

    func setCentroid(_ centroid: [Float], for friendId: String) {
        if let idx = friends.firstIndex(where: { $0.id == friendId }) {
            friends[idx].centroidEmbedding = centroid
            friends[idx].updatedAt = Date()
            save(triggerSync: true)
        }
    }

    func clearCentroid(for friendId: String) {
        if let idx = friends.firstIndex(where: { $0.id == friendId }) {
            friends[idx].centroidEmbedding = nil
            friends[idx].updatedAt = Date()
            save(triggerSync: true)
        }
    }

    func startAutoSync(pollIntervalSeconds: UInt64 = 20) {
        guard autoSyncTask == nil else { return }
        autoSyncTask = Task { [weak self] in
            await self?.syncNow()
            while Task.isCancelled == false {
                try? await Task.sleep(nanoseconds: pollIntervalSeconds * 1_000_000_000)
                await self?.syncNow()
            }
        }
    }

    func stopAutoSync() {
        autoSyncTask?.cancel()
        autoSyncTask = nil
    }

    func exportPackage(to directoryURL: URL) throws {
        try exportCurrentStateToPackage(directory: directoryURL)
    }

    func exportPackageZIP(to zipFileURL: URL) throws {
        let packageDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("friends-package-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: packageDirectory, withIntermediateDirectories: true)
        try exportCurrentStateToPackage(directory: packageDirectory)

        let zipRootDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("friends-package-zip-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: zipRootDirectory, withIntermediateDirectories: true)
        let folderForZip = zipRootDirectory.appendingPathComponent("FriendFinderPackage", isDirectory: true)
        try FileManager.default.copyItem(at: packageDirectory, to: folderForZip)

        if FileManager.default.fileExists(atPath: zipFileURL.path) {
            try FileManager.default.removeItem(at: zipFileURL)
        }
        try FileManager.default.zipItem(at: folderForZip, to: zipFileURL)
    }

    func exportFriendsJSON(to url: URL) throws {
        let data = try makeJSONData(for: friends)
        try data.write(to: url, options: .atomic)
    }

    @discardableResult
    func importFriendsJSON(from url: URL, strategy: FriendsMergeStrategy = .mergeByIdNewestTimestampWins) throws -> FriendsTransferResult {
        let data = try Data(contentsOf: url)
        let decodedFriends = try decodeFriendsPayload(from: data)
        return applyImportedFriends(decodedFriends, strategy: strategy, importedImagesFolder: nil)
    }

    @discardableResult
    func importPackage(from packageDirectory: URL, strategy: FriendsMergeStrategy = .mergeByIdNewestTimestampWins) throws -> FriendsTransferResult {
        let packageURL = packageDirectory.appendingPathComponent(packageFilename)
        let data = try Data(contentsOf: packageURL)
        let package = try JSONDecoder.friendsStoreDecoder.decode(FriendsSyncPackage.self, from: data)
        let imagesFolder = packageDirectory.appendingPathComponent(packageImagesFolderName, isDirectory: true)
        return applyImportedFriends(
            package.friends,
            strategy: strategy,
            importedImagesFolder: imagesFolder,
            incomingTombstones: package.tombstones
        )
    }

    @discardableResult
    func importPackageZIP(from zipFileURL: URL, strategy: FriendsMergeStrategy = .mergeByIdNewestTimestampWins) throws -> FriendsTransferResult {
        let unzipDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("friends-package-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: unzipDirectory, withIntermediateDirectories: true)
        try FileManager.default.unzipItem(at: zipFileURL, to: unzipDirectory)

        let directPackageJSON = unzipDirectory.appendingPathComponent(packageFilename)
        if FileManager.default.fileExists(atPath: directPackageJSON.path) {
            return try importPackage(from: unzipDirectory, strategy: strategy)
        }

        let children = try FileManager.default.contentsOfDirectory(at: unzipDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        for child in children {
            let candidate = child.appendingPathComponent(packageFilename)
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try importPackage(from: child, strategy: strategy)
            }
        }

        throw NSError(
            domain: "FriendsStore",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "ZIP does not contain a valid FriendFinder package"]
        )
    }

    func syncNow() async {
        guard let remoteFolder = iCloudPackageDirectoryURL() else {
            iCloudAvailable = false
            return
        }
        iCloudAvailable = true

        do {
            try FileManager.default.createDirectory(at: remoteFolder, withIntermediateDirectories: true)
        } catch {
            lastSyncError = "Failed to prepare iCloud folder: \(error.localizedDescription)"
            return
        }

        let remotePackageURL = remoteFolder.appendingPathComponent(packageFilename)
        await importIfRemotePackageChanged(remotePackageURL: remotePackageURL)

        do {
            try exportCurrentStateToPackage(directory: remoteFolder)
            lastSyncAt = Date()
            lastSyncError = nil
        } catch {
            lastSyncError = "Failed to sync to iCloud: \(error.localizedDescription)"
        }
    }

    private func writeImage(_ image: UIImage) throws -> String {
        guard let data = image.jpegData(compressionQuality: 0.85) else {
            throw NSError(domain: "FriendsStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode image"])
        }
        let filename = "img_\(UUID().uuidString).jpg"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = docs.appendingPathComponent(filename)
        try data.write(to: fileURL)
        return filename
    }

    // MARK: - Persistence
    private func save(triggerSync: Bool) {
        do {
            let data = try makeJSONData(for: friends)
            try data.write(to: storageURL, options: .atomic)
            try saveTombstones()
            if triggerSync {
                Task {
                    await syncNow()
                }
            }
        } catch {
            NSLog("[FriendsStore] Failed to save: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            self.friends = try decodeFriendsPayload(from: data)
        } catch {
            NSLog("[FriendsStore] Failed to load: \(error)")
            self.friends = []
        }
    }

    private func loadTombstones() {
        guard FileManager.default.fileExists(atPath: tombstoneStorageURL.path) else { return }
        do {
            let data = try Data(contentsOf: tombstoneStorageURL)
            let decoded = try JSONDecoder.friendsStoreDecoder.decode([DeletedFriendTombstone].self, from: data)
            tombstonesById = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0.deletedAt) })
        } catch {
            NSLog("[FriendsStore] Failed to load tombstones: \(error)")
            tombstonesById = [:]
        }
    }

    private func saveTombstones() throws {
        let tombstones = tombstonesById.map { DeletedFriendTombstone(id: $0.key, deletedAt: $0.value) }
            .sorted { $0.deletedAt > $1.deletedAt }
        let data = try JSONEncoder.friendsStoreEncoder.encode(tombstones)
        try data.write(to: tombstoneStorageURL, options: .atomic)
    }

    private func decodeFriendsPayload(from data: Data) throws -> [Friend] {
        if let plainFriends = try? JSONDecoder.friendsStoreDecoder.decode([Friend].self, from: data) {
            return plainFriends
        }

        let package = try JSONDecoder.friendsStoreDecoder.decode(FriendsSyncPackage.self, from: data)
        return package.friends
    }

    private func makeJSONData(for friends: [Friend]) throws -> Data {
        let encoder = JSONEncoder.friendsStoreEncoder
        return try encoder.encode(friends)
    }

    private func exportCurrentStateToPackage(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let imagesDirectory = directory.appendingPathComponent(packageImagesFolderName, isDirectory: true)
        try FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)

        for friend in friends {
            for imageFile in friend.imageFileNames {
                let sourceURL = imageFileURL(named: imageFile)
                let targetURL = imagesDirectory.appendingPathComponent(imageFile)
                guard FileManager.default.fileExists(atPath: sourceURL.path) else { continue }
                if FileManager.default.fileExists(atPath: targetURL.path) {
                    try FileManager.default.removeItem(at: targetURL)
                }
                try FileManager.default.copyItem(at: sourceURL, to: targetURL)
            }
        }

        let tombstones = tombstonesById.map { DeletedFriendTombstone(id: $0.key, deletedAt: $0.value) }
        let package = FriendsSyncPackage(version: 2, exportedAt: Date(), friends: friends, tombstones: tombstones)
        let data = try JSONEncoder.friendsStoreEncoder.encode(package)
        let packageURL = directory.appendingPathComponent(packageFilename)
        try data.write(to: packageURL, options: .atomic)
    }

    @discardableResult
    private func applyImportedFriends(
        _ incomingFriends: [Friend],
        strategy: FriendsMergeStrategy,
        importedImagesFolder: URL?,
        incomingTombstones: [DeletedFriendTombstone] = []
    ) -> FriendsTransferResult {
        var copiedImages = 0
        var missingImages: [String] = []

        if let importedImagesFolder {
            for friend in incomingFriends {
                for imageName in friend.imageFileNames {
                    let source = importedImagesFolder.appendingPathComponent(imageName)
                    let destination = imageFileURL(named: imageName)
                    if FileManager.default.fileExists(atPath: source.path) == false {
                        missingImages.append(imageName)
                        continue
                    }
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            try FileManager.default.removeItem(at: destination)
                        }
                        try FileManager.default.copyItem(at: source, to: destination)
                        copiedImages += 1
                    } catch {
                        missingImages.append(imageName)
                    }
                }
            }
        }

        let mergedFriends: [Friend]
        switch strategy {
        case .replaceAll:
            tombstonesById.removeAll()
            mergedFriends = incomingFriends
        case .mergeByIdNewestTimestampWins:
            var byId: [String: Friend] = [:]
            for local in friends {
                byId[local.id] = local
            }

            for tombstone in incomingTombstones {
                let localTombstoneDate = tombstonesById[tombstone.id] ?? .distantPast
                guard tombstone.deletedAt > localTombstoneDate else { continue }

                if let localFriend = byId[tombstone.id] {
                    if tombstone.deletedAt >= localFriend.updatedAt {
                        byId.removeValue(forKey: tombstone.id)
                        tombstonesById[tombstone.id] = tombstone.deletedAt
                    }
                } else {
                    tombstonesById[tombstone.id] = tombstone.deletedAt
                }
            }

            var mergedCount = 0
            for incoming in incomingFriends {
                if let tombstoneDate = tombstonesById[incoming.id], tombstoneDate >= incoming.updatedAt {
                    continue
                }

                if let current = byId[incoming.id] {
                    let winner = preferredFriend(local: current, incoming: incoming)
                    if winner != current {
                        mergedCount += 1
                    }
                    byId[incoming.id] = winner
                } else {
                    byId[incoming.id] = incoming
                    mergedCount += 1
                }

                if let tombstoneDate = tombstonesById[incoming.id], incoming.updatedAt > tombstoneDate {
                    tombstonesById.removeValue(forKey: incoming.id)
                }
            }
            friends = byId.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            save(triggerSync: false)
            return FriendsTransferResult(
                importedCount: incomingFriends.count,
                mergedCount: mergedCount,
                copiedImages: copiedImages,
                missingImages: missingImages,
                importedFriendIDs: incomingFriends.map(\.id)
            )
        }

        friends = mergedFriends.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        save(triggerSync: false)
        return FriendsTransferResult(
            importedCount: incomingFriends.count,
            mergedCount: incomingFriends.count,
            copiedImages: copiedImages,
            missingImages: missingImages,
            importedFriendIDs: incomingFriends.map(\.id)
        )
    }

    private func preferredFriend(local: Friend, incoming: Friend) -> Friend {
        if incoming.updatedAt > local.updatedAt {
            return incoming
        }
        return local
    }

    private func importIfRemotePackageChanged(remotePackageURL: URL) async {
        guard FileManager.default.fileExists(atPath: remotePackageURL.path) else {
            return
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: remotePackageURL.path)
        let modificationDate = attributes?[.modificationDate] as? Date
        if let modificationDate,
           let previousDate = lastObservedRemoteModificationDate,
           modificationDate <= previousDate {
            return
        }

        let packageFolder = remotePackageURL.deletingLastPathComponent()
        do {
            let packageData = try Data(contentsOf: remotePackageURL)
            let package = try JSONDecoder.friendsStoreDecoder.decode(FriendsSyncPackage.self, from: packageData)
            let imagesFolder = packageFolder.appendingPathComponent(packageImagesFolderName, isDirectory: true)
            _ = applyImportedFriends(
                package.friends,
                strategy: .mergeByIdNewestTimestampWins,
                importedImagesFolder: imagesFolder,
                incomingTombstones: package.tombstones
            )
            lastObservedRemoteModificationDate = modificationDate ?? Date()
            lastSyncAt = Date()
            lastSyncError = nil
        } catch {
            lastSyncError = "Failed to import from iCloud: \(error.localizedDescription)"
        }
    }

    private func iCloudPackageDirectoryURL() -> URL? {
        guard let ubiquityRoot = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        return ubiquityRoot
            .appendingPathComponent("Documents", isDirectory: true)
            .appendingPathComponent(packageFolderName, isDirectory: true)
    }
}

private extension JSONEncoder {
    static var friendsStoreEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var friendsStoreDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
