import Foundation
import UIKit

struct Friend: Codable, Identifiable, Equatable {
    let id: String
    var name: String
    var nickname: String?
    var note: String?
    var imageFileNames: [String]
    var centroidEmbedding: [Float]?

    init(
        id: String = UUID().uuidString,
        name: String,
        nickname: String? = nil,
        note: String? = nil,
        imageFileNames: [String] = [],
        centroidEmbedding: [Float]? = nil
    ) {
        self.id = id
        self.name = name
        self.nickname = nickname
        self.note = note
        self.imageFileNames = imageFileNames
        self.centroidEmbedding = centroidEmbedding
    }
}

class FriendsStore: ObservableObject {
    @Published private(set) var friends: [Friend] = []

    private let storageURL: URL

    init(filename: String = "friends.json") {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.storageURL = docs.appendingPathComponent(filename)
        load()
    }

    func addFriend(name: String, nickname: String? = nil, note: String? = nil) -> Friend {
        let friend = Friend(name: name, nickname: nickname, note: note)
        friends.append(friend)
        save()
        return friend
    }

    func friend(withId id: String) -> Friend? {
        friends.first(where: { $0.id == id })
    }

    func deleteFriend(id: String) {
        friends.removeAll { $0.id == id }
        save()
    }

    func updateFriendDetails(id: String, name: String, nickname: String?, note: String?) {
        guard let idx = friends.firstIndex(where: { $0.id == id }) else { return }
        friends[idx].name = name
        friends[idx].nickname = nickname
        friends[idx].note = note
        save()
    }

    func addImage(_ image: UIImage, for friendId: String) throws -> String {
        try addImages([image], for: friendId).first ?? ""
    }

    func addImages(_ images: [UIImage], for friendId: String) throws -> [String] {
        guard let idx = friends.firstIndex(where: { $0.id == friendId }) else { return [] }

        let filenames = try images.map(writeImage)
        friends[idx].imageFileNames.append(contentsOf: filenames)
        save()
        return filenames
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
            save()
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
    private func save() {
        do {
            let data = try JSONEncoder().encode(friends)
            try data.write(to: storageURL)
        } catch {
            NSLog("[FriendsStore] Failed to save: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            self.friends = try JSONDecoder().decode([Friend].self, from: data)
        } catch {
            NSLog("[FriendsStore] Failed to load: \(error)")
            self.friends = []
        }
    }
}
