import Foundation
import Accelerate
import UIKit

struct MatchResult {
    let friendId: String
    let name: String
    let score: Float
}

/// Simple k-NN recognition engine using centroid embeddings per friend and cosine similarity.
class RecognitionEngine {
    private var friendsCentroids: [String: [Float]] = [:]
    let threshold: Float

    init(threshold: Float = 0.65) {
        self.threshold = threshold
    }

    func updateCentroid(for friendId: String, centroid: [Float]) {
        friendsCentroids[friendId] = centroid
    }

    func removeFriend(_ friendId: String) {
        friendsCentroids.removeValue(forKey: friendId)
    }

    func resetCentroids() {
        friendsCentroids.removeAll()
    }

    func bestCandidate(embedding: [Float]) -> (friendId: String, score: Float)? {
        topCandidates(embedding: embedding, limit: 1).first
    }

    /// Returns candidates sorted descending by cosine score.
    func topCandidates(embedding: [Float], limit: Int = 2) -> [(friendId: String, score: Float)] {
        guard !friendsCentroids.isEmpty else { return [] }
        let normalized = l2Normalize(embedding)

        var scored: [(friendId: String, score: Float)] = []
        scored.reserveCapacity(friendsCentroids.count)

        for (id, centroid) in friendsCentroids {
            let normCentroid = l2Normalize(centroid)
            let score = dot(normalized, normCentroid)
            scored.append((friendId: id, score: score))
        }

        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(max(0, limit)))
    }

    /// Compare an embedding against stored centroids and return best match if above threshold
    func match(embedding: [Float], friendNameById: (String) -> String?) -> MatchResult? {
        if let candidate = bestCandidate(embedding: embedding),
           candidate.score >= threshold,
           let name = friendNameById(candidate.friendId) {
            return MatchResult(friendId: candidate.friendId, name: name, score: candidate.score)
        }
        return nil
    }

    private func dot(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count)
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    private func l2Normalize(_ v: [Float]) -> [Float] {
        var result = v
        var norm: Float = 0
        vDSP_dotpr(v, 1, v, 1, &norm, vDSP_Length(v.count))
        norm = sqrt(norm)
        if norm == 0 { return result }
        var inv = 1.0 / norm
        vDSP_vsmul(v, 1, &inv, &result, 1, vDSP_Length(v.count))
        return result
    }
}
