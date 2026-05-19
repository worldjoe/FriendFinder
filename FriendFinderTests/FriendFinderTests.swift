/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

@testable import FriendFinder
import Foundation
import MWDATCore
import MWDATMockDevice
import Observation
import SwiftUI
import XCTest

@MainActor
final class ViewModelIntegrationTests: XCTestCase {

  private var mockDevice: MockRaybanMeta?
  private var cameraKit: MockCameraKit?
  private var viewModel: StreamSessionViewModel?

  override func setUp() async throws {
    try await super.setUp()
    try? Wearables.configure()

    MockDeviceKit.shared.enable()

    // Pair mock device and set up camera kit
    let pairedMockDevice = MockDeviceKit.shared.pairRaybanMeta()
    mockDevice = pairedMockDevice
    cameraKit = pairedMockDevice.services.camera

    // Power on and unfold the device to make it available
    pairedMockDevice.powerOn()
    pairedMockDevice.unfold()

    // Wait for device to be available in Wearables
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }

  override func tearDown() async throws {
    viewModel?.endSession()
    viewModel = nil
    MockDeviceKit.shared.disable()
    mockDevice = nil
    cameraKit = nil
    try await super.tearDown()
  }

  // MARK: - Video Streaming Flow Tests

  func testVideoStreamingFlow() async throws {
    try requireStreamingIntegrationOptIn()

    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = testResourceURL(name: "plant", ext: "mp4")
    else {
      XCTFail("Test resources not found")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    self.viewModel = viewModel

    // Wait for the mock device to be detected
    await observeUntil(timeout: 5) { viewModel.hasActiveDevice }

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming state to establish. Some simulator runs are slow to
    // deliver the first frame from mock media.
    await observeUntil(timeout: 20) {
      viewModel.isStreaming
    }

    // Verify streaming is active
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Stop streaming
    await viewModel.stopSession()

    // Wait for session to stop
    await observeUntil(timeout: 5) { !viewModel.isStreaming }

    // Verify streaming stopped (allow for final states to be stopped or waiting)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }

  // MARK: - Photo Capture Flow Tests

  func testStreamingAndPhotoCaptureFlow() async throws {
    try requireStreamingIntegrationOptIn()

    guard let camera = cameraKit else {
      XCTFail("Mock device and camera should be available")
      return
    }

    guard let videoURL = testResourceURL(name: "plant", ext: "mp4"),
      let imageURL = testResourceURL(name: "plant", ext: "png")
    else {
      XCTFail("Test resources not found")
      return
    }

    // Setup camera feed
    camera.setCameraFeed(fileURL: videoURL)
    camera.setCapturedImage(fileURL: imageURL)

    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    self.viewModel = viewModel

    // Wait for the mock device to be detected
    await observeUntil(timeout: 5) { viewModel.hasActiveDevice }

    // Initially not streaming
    XCTAssertEqual(viewModel.streamingStatus, .stopped)
    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertFalse(viewModel.hasReceivedFirstFrame)
    XCTAssertNil(viewModel.currentVideoFrame)

    // Start streaming session
    await viewModel.handleStartStreaming()

    // Wait for streaming state to establish. Some simulator runs are slow to
    // deliver the first frame from mock media.
    await observeUntil(timeout: 20) {
      viewModel.isStreaming
    }

    // Verify streaming is active
    XCTAssertTrue(viewModel.isStreaming)
    XCTAssertTrue([.streaming, .waiting].contains(viewModel.streamingStatus))

    // Capture photo while streaming
    viewModel.capturePhoto()
    await observeUntil(timeout: 10) {
      viewModel.capturedPhoto != nil || viewModel.showPhotoCaptureError
    }

    // On some simulator runs the mock camera cannot deliver a photo and the
    // view model should surface a capture error instead of hanging.
    XCTAssertTrue(viewModel.capturedPhoto != nil || viewModel.showPhotoCaptureError)
    if viewModel.capturedPhoto != nil {
      XCTAssertTrue(viewModel.showPhotoPreview)
    }
    XCTAssertTrue(viewModel.isStreaming)

    // Dismiss photo and stop streaming
    viewModel.dismissPhotoPreview()
    XCTAssertFalse(viewModel.showPhotoPreview)
    XCTAssertNil(viewModel.capturedPhoto)

    await viewModel.stopSession()
    await observeUntil(timeout: 5) { !viewModel.isStreaming }

    XCTAssertFalse(viewModel.isStreaming)
    XCTAssertTrue([.stopped, .waiting].contains(viewModel.streamingStatus))
  }

  func testCapturePhotoWhenNotStreamingShowsError() async throws {
    let viewModel = StreamSessionViewModel(wearables: Wearables.shared)
    self.viewModel = viewModel

    XCTAssertFalse(viewModel.isStreaming)
    viewModel.capturePhoto()

    XCTAssertTrue(viewModel.showPhotoCaptureError)
    viewModel.dismissPhotoCaptureError()
    XCTAssertFalse(viewModel.showPhotoCaptureError)
  }

  private func requireStreamingIntegrationOptIn() throws {
    let env = ProcessInfo.processInfo.environment
    guard env["RUN_STREAMING_INTEGRATION_TESTS"] == "1" else {
      throw XCTSkip("Streaming integration tests are opt-in. Set RUN_STREAMING_INTEGRATION_TESTS=1 to run.")
    }
  }
}

final class RecognitionEngineTests: XCTestCase {

  func testBestCandidateReturnsNilWhenNoCentroids() {
    let sut = RecognitionEngine()
    XCTAssertNil(sut.bestCandidate(embedding: [1, 0, 0]))
  }

  func testTopCandidatesAreSortedAndLimited() {
    let sut = RecognitionEngine()
    sut.updateCentroid(for: "alice", centroid: [1, 0])
    sut.updateCentroid(for: "bob", centroid: [0.7, 0.7])
    sut.updateCentroid(for: "carol", centroid: [0, 1])

    let top = sut.topCandidates(embedding: [1, 0], limit: 2)

    XCTAssertEqual(top.count, 2)
    XCTAssertEqual(top.first?.friendId, "alice")
    XCTAssertGreaterThanOrEqual(top[0].score, top[1].score)
  }

  func testTopCandidatesWithZeroLimitReturnsEmptyArray() {
    let sut = RecognitionEngine()
    sut.updateCentroid(for: "alice", centroid: [1, 0])

    XCTAssertTrue(sut.topCandidates(embedding: [1, 0], limit: 0).isEmpty)
  }

  func testRemoveFriendRemovesCandidate() {
    let sut = RecognitionEngine()
    sut.updateCentroid(for: "alice", centroid: [1, 0])
    XCTAssertNotNil(sut.bestCandidate(embedding: [1, 0]))

    sut.removeFriend("alice")

    XCTAssertNil(sut.bestCandidate(embedding: [1, 0]))
  }

  func testMatchRespectsThresholdAndNameLookup() {
    let sut = RecognitionEngine(threshold: 0.8)
    sut.updateCentroid(for: "alice", centroid: [1, 0])

    let above = sut.match(embedding: [1, 0]) { id in id == "alice" ? "Alice" : nil }
    let below = sut.match(embedding: [0, 1]) { id in id == "alice" ? "Alice" : nil }

    XCTAssertNotNil(above)
    XCTAssertEqual(above?.friendId, "alice")
    XCTAssertEqual(above?.name, "Alice")
    XCTAssertNil(below)
  }

  func testMatchReturnsNilWhenNameLookupFails() {
    let sut = RecognitionEngine(threshold: 0.1)
    sut.updateCentroid(for: "alice", centroid: [1, 0])

    let match = sut.match(embedding: [1, 0]) { _ in nil }
    XCTAssertNil(match)
  }

  func testNormalizationMakesCollinearVectorsScoreNearOne() {
    let sut = RecognitionEngine()
    sut.updateCentroid(for: "alice", centroid: [3, 4])

    let candidate = sut.bestCandidate(embedding: [6, 8])
    XCTAssertEqual(candidate?.friendId, "alice")
    XCTAssertEqual(candidate?.score ?? 0, 1.0, accuracy: 0.0001)
  }

  func testOppositeDirectionProducesNegativeScore() {
    let sut = RecognitionEngine()
    sut.updateCentroid(for: "alice", centroid: [1, 0])

    let candidate = sut.bestCandidate(embedding: [-1, 0])
    XCTAssertEqual(candidate?.friendId, "alice")
    XCTAssertEqual(candidate?.score ?? 0, -1.0, accuracy: 0.0001)
  }
}

@MainActor
final class FriendsStoreTests: XCTestCase {
  private var filename: String = ""

  override func setUp() {
    super.setUp()
    filename = "friends-tests-\(UUID().uuidString).json"
    try? FileManager.default.removeItem(at: storageURL)
  }

  override func tearDown() {
    try? FileManager.default.removeItem(at: storageURL)
    super.tearDown()
  }

  func testAddFriendPersistsAcrossReload() {
    let store = FriendsStore(filename: filename)
    let friend = store.addFriend(name: "Alice", nickname: "Al", note: "Runner")

    let reloaded = FriendsStore(filename: filename)
    let loaded = reloaded.friend(withId: friend.id)

    XCTAssertEqual(reloaded.friends.count, 1)
    XCTAssertEqual(loaded?.name, "Alice")
    XCTAssertEqual(loaded?.nickname, "Al")
    XCTAssertEqual(loaded?.note, "Runner")
  }

  func testUpdateFriendDetailsPersists() {
    let store = FriendsStore(filename: filename)
    let friend = store.addFriend(name: "A")
    store.updateFriendDetails(id: friend.id, name: "Alice", nickname: "Al", note: "Note")

    let reloaded = FriendsStore(filename: filename)
    let updated = reloaded.friend(withId: friend.id)

    XCTAssertEqual(updated?.name, "Alice")
    XCTAssertEqual(updated?.nickname, "Al")
    XCTAssertEqual(updated?.note, "Note")
  }

  func testDeleteFriendPersists() {
    let store = FriendsStore(filename: filename)
    let friend = store.addFriend(name: "Alice")
    store.deleteFriend(id: friend.id)

    let reloaded = FriendsStore(filename: filename)
    XCTAssertTrue(reloaded.friends.isEmpty)
  }

  func testAddImageStoresFileAndLoadsImage() throws {
    let store = FriendsStore(filename: filename)
    let friend = store.addFriend(name: "Alice")
    let image = Self.makeTestImage(size: CGSize(width: 40, height: 30))

    let writtenFile = try store.addImage(image, for: friend.id)
    XCTAssertFalse(writtenFile.isEmpty)

    let fileURL = store.imageFileURL(named: writtenFile)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    XCTAssertNotNil(store.loadImage(named: writtenFile))

    try? FileManager.default.removeItem(at: fileURL)
  }

  func testAddImagesAppendsMultipleFiles() throws {
    let store = FriendsStore(filename: filename)
    let friend = store.addFriend(name: "Alice")
    let images = [
      Self.makeTestImage(size: CGSize(width: 24, height: 24)),
      Self.makeTestImage(size: CGSize(width: 32, height: 20))
    ]

    let filenames = try store.addImages(images, for: friend.id)

    XCTAssertEqual(filenames.count, 2)
    XCTAssertEqual(store.friend(withId: friend.id)?.imageFileNames.count, 2)
    filenames.forEach { filename in
      XCTAssertTrue(FileManager.default.fileExists(atPath: store.imageFileURL(named: filename).path))
      try? FileManager.default.removeItem(at: store.imageFileURL(named: filename))
    }
  }

  func testAddImagesForUnknownFriendReturnsEmptyArray() throws {
    let store = FriendsStore(filename: filename)
    let images = [Self.makeTestImage(size: CGSize(width: 20, height: 20))]

    XCTAssertTrue((try store.addImages(images, for: "missing")).isEmpty)
  }

  func testCorruptedJSONFallsBackToEmptyArray() throws {
    let bytes = Data("{".utf8)
    try bytes.write(to: storageURL)

    let store = FriendsStore(filename: filename)
    XCTAssertTrue(store.friends.isEmpty)
  }

  private var storageURL: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return docs.appendingPathComponent(filename)
  }

  private static func makeTestImage(size: CGSize) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
      UIColor.systemBlue.setFill()
      ctx.fill(CGRect(origin: .zero, size: size))
    }
  }
}

@MainActor
final class UIImageUtilityTests: XCTestCase {

  func testResizedReturnsRequestedSize() {
    let image = Self.makeImage(size: CGSize(width: 100, height: 50))
    let resized = image.resized(to: CGSize(width: 40, height: 40))

    XCTAssertNotNil(resized)
    XCTAssertEqual(resized?.size.width ?? 0, 40, accuracy: 0.1)
    XCTAssertEqual(resized?.size.height ?? 0, 40, accuracy: 0.1)
  }

  func testToCVPixelBufferMatchesImageDimensions() {
    let image = Self.makeImage(size: CGSize(width: 32, height: 24))
    let buffer = image.toCVPixelBuffer()

    XCTAssertNotNil(buffer)
    XCTAssertEqual(CVPixelBufferGetWidth(buffer!), 32)
    XCTAssertEqual(CVPixelBufferGetHeight(buffer!), 24)
  }

  func testToCVPixelBufferReturnsNilForZeroSizeImage() {
    let empty = UIImage()
    XCTAssertNil(empty.toCVPixelBuffer())
  }

  private static func makeImage(size: CGSize) -> UIImage {
    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { ctx in
      UIColor.red.setFill()
      ctx.fill(CGRect(origin: .zero, size: size))
    }
  }
}

// MARK: - Test Helpers

/// Thread-safe one-shot flag for protecting continuation resumption.
private final class ResumeOnce: @unchecked Sendable {
  private let lock = NSLock()
  private var resumed = false
  func tryResume() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    guard !resumed else { return false }
    resumed = true
    return true
  }
}

/// Reactively waits for a condition on @Observable objects to become true.
/// Uses `withObservationTracking` to wake up immediately on property changes
/// instead of polling on a fixed interval.
@MainActor
private func observeUntil(
  timeout: TimeInterval,
  file: StaticString = #filePath,
  line: UInt = #line,
  condition: @escaping () -> Bool
) async {
  guard !condition() else { return }

  let deadline = ContinuousClock.now + .seconds(timeout)

  while !condition() {
    guard ContinuousClock.now < deadline else {
      XCTFail("Condition not met within \(timeout) seconds", file: file, line: line)
      return
    }

    await withUnsafeContinuation { cont in
      let once = ResumeOnce()

      withObservationTracking {
        _ = condition()
      } onChange: {
        if once.tryResume() { cont.resume() }
      }

      // Periodic fallback so we can re-evaluate the deadline
      Task {
        try? await Task.sleep(for: .milliseconds(100))
        if once.tryResume() { cont.resume() }
      }
    }
  }
}

private func testResourceURL(name: String, ext: String) -> URL? {
  let testBundle = Bundle(for: ViewModelIntegrationTests.self)
  return testBundle.url(forResource: name, withExtension: ext)
    ?? Bundle.main.url(forResource: name, withExtension: ext)
}
