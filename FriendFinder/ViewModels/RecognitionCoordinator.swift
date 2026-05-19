import Foundation
import UIKit
import Combine

@MainActor
class RecognitionCoordinator: ObservableObject {
    @Published var isRunning: Bool = false
    @Published var lastMatch: MatchResult?
    @Published var logs: [String] = []
    @Published var hasFoundFace: Bool = false
    @Published var isAttemptingMatch: Bool = false

    private let faceProcessor: FaceProcessor
    private let recognitionEngine: RecognitionEngine
    let friendsStore: FriendsStore

    private var previewCancellable: AnyCancellable?
    private var lastShown: [String: Date] = [:]
    private let debounceInterval: TimeInterval = 8.0
    private let minScoreMarginVsSecondBest: Float = 0.03

    init(faceProcessor: FaceProcessor = FaceProcessor(modelName: "FaceNet", throttleFPS: 1.0),
         recognitionEngine: RecognitionEngine = RecognitionEngine(threshold: 0.65),
         friendsStore: FriendsStore = FriendsStore()) {
        self.faceProcessor = faceProcessor
        self.recognitionEngine = recognitionEngine
        self.friendsStore = friendsStore

        // Load friend centroids into recognition engine
        for friend in friendsStore.friends {
            if let centroid = friend.centroidEmbedding {
                recognitionEngine.updateCentroid(for: friend.id, centroid: centroid)
            }
        }

        faceProcessor.onEmbedding = { [weak self] embedding, _ in
            Task { @MainActor in
                await self?.handleEmbedding(embedding)
            }
        }
        faceProcessor.onFaceDetected = { [weak self] in
            Task { @MainActor in
                self?.handleFaceDetected()
            }
        }
        faceProcessor.onNoFaceDetected = { [weak self] in
            Task { @MainActor in
                self?.handleNoFaceDetected()
            }
        }
    }

    // MARK: - Friends API helpers
    func addFriend(name: String, nickname: String? = nil, note: String? = nil) -> Friend {
        let f = friendsStore.addFriend(name: name, nickname: nickname, note: note)
        return f
    }

    @discardableResult
    func createFriend(name: String, nickname: String? = nil, note: String? = nil, images: [UIImage]) async throws -> Friend {
        let friend = friendsStore.addFriend(name: name, nickname: nickname, note: note)
        if !images.isEmpty {
            _ = try friendsStore.addImages(images.map { $0.trainingSized() }, for: friend.id)
            _ = await computeCentroid(for: friend.id)
        }
        return friend
    }

    func updateFriendDetails(id: String, name: String, nickname: String?, note: String?) {
        friendsStore.updateFriendDetails(id: id, name: name, nickname: nickname, note: note)
    }

    func deleteFriend(id: String) {
        friendsStore.deleteFriend(id: id)
        recognitionEngine.removeFriend(id)
    }

    func addImage(_ image: UIImage, for friendId: String) throws -> String {
        let filename = try friendsStore.addImage(image, for: friendId)
        return filename
    }

    func addTrainingImages(_ images: [UIImage], for friendId: String) async throws {
        guard !images.isEmpty else { return }
        _ = try friendsStore.addImages(images.map { $0.trainingSized() }, for: friendId)
        _ = await computeCentroid(for: friendId)
    }

    /// Compute centroid embeddings for a friend by running the model on stored images.
    func computeCentroid(for friendId: String) async -> [Float]? {
        guard let friend = friendsStore.friends.first(where: { $0.id == friendId }) else { return nil }
        var embeddings: [[Float]] = []
        let enrollmentProcessor = FaceProcessor(modelName: "FaceNet", throttleFPS: 10.0)

        for filename in friend.imageFileNames {
            if let img = friendsStore.loadImage(named: filename) {
                let trainingImage = img.trainingSized()
                if let vec = await enrollmentProcessor.embedding(from: trainingImage), !vec.isEmpty {
                    embeddings.append(vec)
                }
            }
        }

        guard !embeddings.isEmpty else { return nil }
        let count = embeddings.count
        let dim = embeddings[0].count
        var centroid = [Float](repeating: 0, count: dim)
        for e in embeddings {
            for i in 0..<dim { centroid[i] += e[i] }
        }
        for i in 0..<dim { centroid[i] /= Float(count) }

        friendsStore.setCentroid(centroid, for: friendId)
        recognitionEngine.updateCentroid(for: friendId, centroid: centroid)
        return centroid
    }

    func startRecognition() async {
        if isRunning { return }
        // In debug builds you may enable MockDeviceKit manually if needed.

        isRunning = true
        hasFoundFace = false
        isAttemptingMatch = false
        logs.insert("Recognition started", at: 0)
    }

    func stopRecognition() async {
        if !isRunning { return }
        isRunning = false
        hasFoundFace = false
        isAttemptingMatch = false
        logs.insert("Recognition stopped", at: 0)
    }

    /// Public helper for callers that have UIImage frames to process
    func processFrame(_ image: UIImage) {
        faceProcessor.process(image: image)
    }

    private func handleFaceDetected() {
        hasFoundFace = true
        isAttemptingMatch = true
    }

    private func handleNoFaceDetected() {
        hasFoundFace = false
        isAttemptingMatch = false
    }

    private func handleEmbedding(_ embedding: [Float]) async {
        let topCandidates = recognitionEngine.topCandidates(embedding: embedding, limit: 2)

        guard let candidate = topCandidates.first else {
            isAttemptingMatch = false
            logs.insert("No trained friends available for matching", at: 0)
            return
        }

        let secondBestScore = topCandidates.count > 1 ? topCandidates[1].score : -1
        let scoreMargin = candidate.score - secondBestScore

        guard scoreMargin >= minScoreMarginVsSecondBest else {
            isAttemptingMatch = false
            logs.insert(
                "Best score margin \(String(format: "%.3f", scoreMargin)) below required \(String(format: "%.3f", minScoreMarginVsSecondBest))",
                at: 0
            )
            return
        }

        guard candidate.score >= recognitionEngine.threshold,
              let name = self.friendsStore.friends.first(where: { $0.id == candidate.friendId })?.name
        else {
            isAttemptingMatch = false
            let candidateName = self.friendsStore.friends.first(where: { $0.id == candidate.friendId })?.name ?? "Unknown"
            logs.insert(
                "Best candidate \(candidateName) score \(String(format: "%.3f", candidate.score)) below threshold \(String(format: "%.3f", recognitionEngine.threshold))",
                at: 0
            )
            return
        }

        let m = MatchResult(friendId: candidate.friendId, name: name, score: candidate.score)

        // Debounce per friend id
        let now = Date()
        if let last = lastShown[m.friendId], now.timeIntervalSince(last) < debounceInterval {
            isAttemptingMatch = false
            logs.insert("Debounced match for \(m.name) (score: \(String(format: "%.3f", m.score)))", at: 0)
            return
        }
        lastShown[m.friendId] = now

        isAttemptingMatch = false
        lastMatch = m
        logs.insert("Matched \(m.name) with score \(String(format: "%.3f", m.score))", at: 0)

        // In DisplayAccess we sent the name to the device display. FriendFinder may want to surface this locally.
    }
}
