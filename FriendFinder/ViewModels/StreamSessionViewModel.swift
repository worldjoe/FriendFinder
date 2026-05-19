/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

import MWDATCamera
import MWDATCore
import MWDATDisplay
import SwiftUI
import os
import Combine
import Foundation

enum StreamingStatus {
  case streaming
  case waiting
  case stopped
}

private struct GlassesDisplaySnapshot: Equatable {
  let nameText: String
  let nicknameText: String?
  let secondaryLines: [String]
  let infoText: String?
  let captureButtonTitle: String
}

/// ViewModel for video streaming UI. Delegates device management to DeviceSessionManager.
@MainActor
final class StreamSessionViewModel: ObservableObject {
  // MARK: - State

  @Published var currentVideoFrame: UIImage?
  @Published var hasReceivedFirstFrame: Bool = false
  @Published var streamingStatus: StreamingStatus = .stopped
  @Published var showError: Bool = false
  @Published var errorMessage: String = ""
  @Published var requiresDATAppUpdate: Bool = false
  @Published private(set) var hasActiveDevice: Bool = false

  @Published var capturedPhoto: UIImage?
  @Published var showPhotoPreview: Bool = false
  @Published var showPhotoCaptureError: Bool = false
  @Published var isCapturingPhoto: Bool = false

  var isDeviceSessionReady: Bool { sessionManager.isReady }

  var isStreaming: Bool { streamingStatus != .stopped }

  // MARK: - Private

  private let sessionManager: DeviceSessionManager
  private let wearables: WearablesInterface
  private var deviceSession: DeviceSession?
  private var stream: MWDATCamera.Stream?
  private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "com.example.FriendFinder", category: "StreamSessionViewModel")
  private var receivedFrameCount: Int = 0
  private var isStartingSession: Bool = false
  private var activeDeviceTask: Task<Void, Never>?

  private var stateListenerToken: AnyListenerToken?
  private var videoFrameListenerToken: AnyListenerToken?
  private var errorListenerToken: AnyListenerToken?
  private var photoDataListenerToken: AnyListenerToken?
  private var displayStateListenerToken: AnyListenerToken?
  private var display: Display?
  private var displayState: DisplayState = .stopped
  private var isDisplayConnected: Bool = false
  private var desiredDisplaySnapshot: GlassesDisplaySnapshot?
  private var lastSentDisplaySnapshot: GlassesDisplaySnapshot?
  private var displayRefreshTask: Task<Void, Never>?
  private var consecutiveDisplaySendFailures: Int = 0

  // Recognition
  let recognitionCoordinator: RecognitionCoordinator
  private var recognitionMatchCancellable: AnyCancellable?
  private var recognitionLogsCancellable: AnyCancellable?
  private var recognitionFaceStateCancellable: AnyCancellable?
  private var recognitionAttemptStateCancellable: AnyCancellable?
  @Published var lastMatch: MatchResult?
  @Published var recognitionLogs: [String] = []
  private var hasFoundFace: Bool = false
  private var isAttemptingMatchFace: Bool = false

  // MARK: - Init

  init(wearables: WearablesInterface) {
    self.wearables = wearables
    self.sessionManager = DeviceSessionManager(wearables: wearables)
    self.recognitionCoordinator = RecognitionCoordinator()
    self.hasActiveDevice = sessionManager.hasActiveDevice

    activeDeviceTask = Task { @MainActor [weak self] in
      guard let self else { return }
      for await isActive in self.sessionManager.activeDeviceStateStream() {
        self.hasActiveDevice = isActive
      }
    }

    // Observe recognition coordinator
    recognitionMatchCancellable = recognitionCoordinator.$lastMatch.sink { [weak self] m in
      Task { @MainActor in
        self?.lastMatch = m
        self?.queueDisplayRefresh()
      }
    }
    recognitionLogsCancellable = recognitionCoordinator.$logs.sink { [weak self] logs in
      Task { @MainActor in self?.recognitionLogs = logs }
    }
    recognitionFaceStateCancellable = recognitionCoordinator.$hasFoundFace.sink { [weak self] hasFoundFace in
      Task { @MainActor in
        self?.hasFoundFace = hasFoundFace
        self?.queueDisplayRefresh()
      }
    }
    recognitionAttemptStateCancellable = recognitionCoordinator.$isAttemptingMatch.sink { [weak self] isAttemptingMatch in
      Task { @MainActor in
        self?.isAttemptingMatchFace = isAttemptingMatch
        self?.queueDisplayRefresh()
      }
    }
  }

  deinit {
    activeDeviceTask?.cancel()
    recognitionMatchCancellable?.cancel()
    recognitionLogsCancellable?.cancel()
    recognitionFaceStateCancellable?.cancel()
    recognitionAttemptStateCancellable?.cancel()
    displayRefreshTask?.cancel()
  }

  // MARK: - Public API

  func handleStartStreaming() async {
    logger.debug("handleStartStreaming() called")
    let session: DeviceSession
    do {
      session = try await sessionManager.getSession()
      requiresDATAppUpdate = false
    } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
      requiresDATAppUpdate = true
      showError(DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription)
      return
    } catch {
      showError("Failed to start session: \(error.localizedDescription)")
      return
    }

    guard session.state == .started else {
      showError("Device session is not ready. Please try again.")
      return
    }

    deviceSession = session
    streamingStatus = .waiting
    Task { @MainActor [weak self] in
      await self?.ensureDisplayAttached(to: session)
      self?.queueDisplayRefresh()
    }
  }

  func toggleCaptureFromDisplay() async {
    if stream == nil {
      await startSession()
    } else {
      await stopStreamingOnly()
    }
  }

  func stopSession() async {
    await stopStreamingOnly()
    streamingStatus = .stopped
    queueDisplayRefresh()
    await detachDisplay()
    deviceSession = nil
  }

  /// Stops both the stream and the underlying device session. Call in test tearDown.
  func endSession() {
    stream = nil
    clearListeners()
    streamingStatus = .stopped
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    queueDisplayRefresh()
    Task { @MainActor [weak self] in
      await self?.detachDisplay()
      self?.deviceSession = nil
    }
    sessionManager.cleanup()
  }

  func capturePhoto() {
    requestPhotoCapture()
  }

  func dismissError() {
    showError = false
    errorMessage = ""
  }

  func dismissPhotoCaptureError() {
    showPhotoCaptureError = false
  }

  func dismissPhotoPreview() {
    showPhotoPreview = false
    capturedPhoto = nil
  }

  // MARK: - Private

  private func requestCameraPermissionIfNeeded() async -> Bool {
    let permission = Permission.camera
    do {
      var status = try await wearables.checkPermissionStatus(permission)
      if status != .granted {
        status = try await wearables.requestPermission(permission)
      }
      if status == .granted {
        return true
      }
      showError("Permission denied")
      return false
    } catch {
      showError("Permission error: \(error.description)")
      return false
    }
  }

  private func stopStreamingOnly() async {
    guard let activeStream = stream else {
      currentVideoFrame = nil
      hasReceivedFirstFrame = false
      await recognitionCoordinator.stopRecognition()
      hasFoundFace = false
      isAttemptingMatchFace = false
      queueDisplayRefresh()
      return
    }
    stream = nil
    clearListeners()
    streamingStatus = .waiting
    currentVideoFrame = nil
    hasReceivedFirstFrame = false
    isCapturingPhoto = false
    queueDisplayRefresh()
    await activeStream.stop()
    await recognitionCoordinator.stopRecognition()
    hasFoundFace = false
    isAttemptingMatchFace = false
    queueDisplayRefresh()
  }

  private func startSession() async {
    logger.debug("startSession() called")
    guard await requestCameraPermissionIfNeeded() else { return }

    let session: DeviceSession
    if let deviceSession, deviceSession.state == .started {
      session = deviceSession
    } else {
      do {
        session = try await sessionManager.getSession()
        requiresDATAppUpdate = false
      } catch DeviceSessionError.datAppOnTheGlassesUpdateRequired {
        requiresDATAppUpdate = true
        showError(DeviceSessionError.datAppOnTheGlassesUpdateRequired.localizedDescription)
        return
      } catch {
        showError("Failed to start session: \(error.localizedDescription)")
        return
      }
      deviceSession = session
    }

    guard session.state == .started else {
      showError("Device session is not ready. Please try again.")
      logger.debug("Device session not in .started state")
      return
    }

    if stream != nil {
      queueDisplayRefresh()
      return
    }

    await recognitionCoordinator.startRecognition()

    // Prevent concurrent start attempts
    if isStartingSession {
      logger.debug("startSession() already in progress — ignoring duplicate call")
      return
    }
    isStartingSession = true
    defer { isStartingSession = false }

    let config = StreamConfiguration(
      videoCodec: VideoCodec.raw,
      resolution: StreamingResolution.low,
      frameRate: 24
    )

    // Try a few times to add/start the stream in case the accessory is still
    // finishing internal setup (EASession race). Small delays between attempts
    // improve robustness against transient failures observed in logs.
    let maxAttempts = 3
    var started = false
    for attempt in 1...maxAttempts {
      do {
        logger.debug("Stream start attempt \(attempt)/\(maxAttempts)")
        if let newStream = try session.addStream(config: config) {
          stream = newStream
          streamingStatus = .waiting
          logger.debug("Stream created, starting listeners and requesting start")
          setupListeners(for: newStream)
          await newStream.start()
          started = true
          break
        } else {
          logger.debug("deviceSession.addStream returned nil on attempt \(attempt)")
        }
      } catch {
        logger.error("Stream start attempt \(attempt) failed: \(error.localizedDescription)")
      }

      // Small backoff before retrying
      try? await Task.sleep(nanoseconds: 250_000_000) // 250ms
    }

    if !started {
      showError("Failed to start stream after \(maxAttempts) attempts")
      return
    }

    Task { @MainActor [weak self] in
      await self?.ensureDisplayAttached(to: session)
    }
    queueDisplayRefresh()
  }

  private func setupListeners(for stream: MWDATCamera.Stream) {
    stateListenerToken = stream.statePublisher.listen { [weak self] state in
      Task { @MainActor in self?.handleStateChange(state) }
    }

    // Convert frames to UIImage off the main thread to avoid main-thread I/O.
    videoFrameListenerToken = stream.videoFramePublisher.listen { [weak self] frame in
      let weakSelf = self
      Task.detached(priority: .userInitiated) {
        var extracted: UIImage? = nil
        if let videoFrame = frame as MWDATCamera.VideoFrame? {
          extracted = videoFrame.makeUIImage()
        } else if let imageAny = (frame as AnyObject).value(forKey: "image") as? UIImage {
          extracted = imageAny
        }

        if let image = extracted {
          // Update UI preview on main actor
          await MainActor.run {
            guard let strong = weakSelf else { return }
            strong.receivedFrameCount += 1
            //strong.logger.debug("Received video frame #\(strong.receivedFrameCount)")
            strong.currentVideoFrame = image
            if !strong.hasReceivedFirstFrame {
              strong.hasReceivedFirstFrame = true
            }
          }

          // Forward to recognition pipeline on the main actor if enabled
          if let strong = weakSelf {
            Task { @MainActor in
              strong.recognitionCoordinator.processFrame(image)
            }
          }
        }
      }
    }

    errorListenerToken = stream.errorPublisher.listen { [weak self] error in
      Task { @MainActor in self?.handleError(error) }
    }

    photoDataListenerToken = stream.photoDataPublisher.listen { [weak self] data in
      Task { @MainActor in self?.handlePhotoData(data) }
    }
  }

  private func clearListeners() {
    stateListenerToken = nil
    videoFrameListenerToken = nil
    errorListenerToken = nil
    photoDataListenerToken = nil
  }

  private func handleStateChange(_ state: StreamState) {
    logger.debug("Stream state changed:")
    switch state {
    case .stopped:
      currentVideoFrame = nil
      streamingStatus = display == nil ? .stopped : .waiting
    case .waitingForDevice, .starting, .stopping, .paused:
      streamingStatus = .waiting
    case .streaming:
      streamingStatus = .streaming
    }
    queueDisplayRefresh()
  }

  private func handleVideoFrame(_ frame: VideoFrame) {
    if let image = frame.makeUIImage() {
      currentVideoFrame = image
      if !hasReceivedFirstFrame {
        hasReceivedFirstFrame = true
      }
    }
  }

  private func handleError(_ error: StreamError) {
    let message = error.localizedDescription
    logger.error("Stream error: \(message, privacy: .public)")
    if message != errorMessage {
      showError(message)
    }
  }

  private func handlePhotoData(_ data: PhotoData) {
    isCapturingPhoto = false
    if let image = UIImage(data: data.data) {
      capturedPhoto = image
      showPhotoPreview = true
    }
  }

  private func requestPhotoCapture() {
    guard !isCapturingPhoto, streamingStatus == .streaming else {
      showPhotoCaptureError = true
      return
    }

    isCapturingPhoto = true

    let success = stream?.capturePhoto(format: .jpeg) ?? false
    if !success {
      isCapturingPhoto = false
      showPhotoCaptureError = true
    }
  }

  private func showError(_ message: String) {
    errorMessage = message
    showError = true
  }

  private func ensureDisplayAttached(to deviceSession: DeviceSession) async {
    guard display == nil else { return }

    do {
      let capability = try deviceSession.addDisplay()
      displayStateListenerToken = capability.statePublisher.listen { [weak self] state in
        Task { @MainActor in
          self?.handleDisplayStateChange(state)
        }
      }
      display = capability
      await capability.start()
    } catch {
      logger.error("Failed to attach display capability: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func handleDisplayStateChange(_ state: DisplayState) {
    displayState = state
    switch state {
    case .starting:
      isDisplayConnected = false
    case .started:
      isDisplayConnected = true
      consecutiveDisplaySendFailures = 0
      queueDisplayRefresh()
    case .stopping:
      isDisplayConnected = false
    case .stopped:
      isDisplayConnected = false
      displayStateListenerToken = nil
      display = nil
      lastSentDisplaySnapshot = nil
      consecutiveDisplaySendFailures = 0
    }
  }

  private func detachDisplay() async {
    displayRefreshTask?.cancel()
    displayRefreshTask = nil
    displayStateListenerToken = nil
    displayState = .stopped
    isDisplayConnected = false
    lastSentDisplaySnapshot = nil
    desiredDisplaySnapshot = nil
    consecutiveDisplaySendFailures = 0
    if let display {
      await display.stop()
    }
    self.display = nil
  }

  private func queueDisplayRefresh() {
    desiredDisplaySnapshot = makeDisplaySnapshot()
    guard displayRefreshTask == nil else { return }

    displayRefreshTask = Task { @MainActor [weak self] in
      guard let self else { return }
      await self.refreshDisplayIfNeeded()
      self.displayRefreshTask = nil

      if self.desiredDisplaySnapshot != nil,
        self.display != nil,
        self.isDisplayConnected,
        !Task.isCancelled
      {
        self.queueDisplayRefresh()
      }
    }
  }

  private func refreshDisplayIfNeeded() async {
    while !Task.isCancelled {
      guard let display, isDisplayConnected, let snapshot = desiredDisplaySnapshot else { return }

      if snapshot == lastSentDisplaySnapshot {
        desiredDisplaySnapshot = nil
        continue
      }

      desiredDisplaySnapshot = nil

      do {
        try await display.send(makeDisplayView(snapshot: snapshot))
        lastSentDisplaySnapshot = snapshot
        consecutiveDisplaySendFailures = 0
      } catch {
        desiredDisplaySnapshot = snapshot
        consecutiveDisplaySendFailures += 1

        let message = (error as? DisplayError)?.description ?? error.localizedDescription
        logger.error(
          "Failed to send display content while display state was \(self.displayStateDescription(self.displayState), privacy: .public): \(message, privacy: .public)"
        )

        if consecutiveDisplaySendFailures >= 3 {
          return
        }

        try? await Task.sleep(nanoseconds: 300_000_000)
      }
    }
  }

  private func displayStateDescription(_ state: DisplayState) -> String {
    switch state {
    case .starting:
      return "starting"
    case .started:
      return "started"
    case .stopping:
      return "stopping"
    case .stopped:
      return "stopped"
    }
  }

  private func makeDisplaySnapshot() -> GlassesDisplaySnapshot {
    let matchedFriend = lastMatch.flatMap { match in
      recognitionCoordinator.friendsStore.friend(withId: match.friendId)
    }

    let nameText = matchedFriend?.name
      ?? lastMatch?.name
      ?? "No recent match"
    let nicknameText = matchedFriend?.nickname?.nonEmptyTrimmed

    let noteText = matchedFriend?.note?.nonEmptyTrimmed
    let infoText = [noteText].compactMap { $0 }.joined(separator: " • ").nonEmptyTrimmed

    let streamLine: String
    switch streamingStatus {
    case .streaming:
      streamLine = "Stream: live"
    case .waiting:
      streamLine = stream == nil ? "Stream: ready" : "Stream: waiting"
    case .stopped:
      streamLine = "Stream: stopped"
    }

    let faceLine = "Face: \(hasFoundFace ? "detected" : "scanning") • Match: \(isAttemptingMatchFace ? "running" : "idle")"
    let confidenceLine = lastMatch.map { String(format: "Confidence: %.3f", $0.score) } ?? "Confidence: -"
    let secondaryLines = [faceLine, "\(streamLine) • \(confidenceLine)"]

    return GlassesDisplaySnapshot(
      nameText: nameText,
      nicknameText: nicknameText,
      secondaryLines: secondaryLines,
      infoText: infoText,
      captureButtonTitle: stream == nil ? "Capture" : "Stop"
    )
  }

  private func makeDisplayView(snapshot: GlassesDisplaySnapshot) -> FlexBox {
    FlexBox(direction: .column, spacing: 12) {
      FlexBox(direction: .column, spacing: 4) {
        MWDATDisplay.Text("Recent match", style: .meta, color: .secondary)
        MWDATDisplay.Text(snapshot.nameText, style: .heading)

        if let nicknameText = snapshot.nicknameText {
          MWDATDisplay.Text("Nickname: \(nicknameText)", style: .body)
        }

        if let infoText = snapshot.infoText {
          MWDATDisplay.Text("Info: \(infoText)", style: .body)
        }
      }
      .padding(16)
      .background(.card)

      if !snapshot.secondaryLines.isEmpty {
        FlexBox(direction: .column, spacing: 8) {
          MWDATDisplay.Text("Debug", style: .meta, color: .secondary)
          for line in snapshot.secondaryLines {
            MWDATDisplay.Text(line, style: .body)
          }
        }
        .padding(16)
        .background(.card)
      }

      FlexBox(direction: .column, spacing: 0) {
        MWDATDisplay.Text(snapshot.captureButtonTitle, style: .heading)
      }
      .padding(16)
      .background(.card)
      .onTap { [weak self] in
        Task { @MainActor [weak self] in
          await self?.toggleCaptureFromDisplay()
        }
      }
    }
  }

}

private extension String {
  var nonEmptyTrimmed: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
