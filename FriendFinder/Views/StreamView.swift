/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// StreamView.swift
//
// Main UI for video streaming from Meta wearable devices using the DAT SDK.
// This view demonstrates the complete streaming API: video streaming with real-time display, photo capture,
// and error handling.
//

import MWDATCore
import SwiftUI

struct StreamView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  var lastMatch: MatchResult?
  var wearablesVM: WearablesViewModel

  var body: some View {
    ZStack {
      // Black background for letterboxing/pillarboxing
      Color.black
        .edgesIgnoringSafeArea(.all)

      // Video backdrop
      if let videoFrame = viewModel.currentVideoFrame, viewModel.hasReceivedFirstFrame {
        GeometryReader { geometry in
          Image(uiImage: videoFrame)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .edgesIgnoringSafeArea(.all)
      } else {
        VStack(spacing: 14) {
          ProgressView()
            .scaleEffect(1.5)
            .foregroundStyle(.white)

          if viewModel.streamingStatus == .waiting {
            Text("Ready to stream. Press Capture on your glasses to start video.")
              .font(.system(size: 15, weight: .medium))
              .multilineTextAlignment(.center)
              .foregroundStyle(.white)
              .padding(.horizontal, 16)
              .padding(.vertical, 10)
              .background(Color.black.opacity(0.55))
              .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
              .padding(.horizontal, 24)
          }
        }
      }

      // Recognition overlay (top-right)
      VStack {
        HStack {
          Spacer()
          if let m = lastMatch {
            VStack(alignment: .trailing) {
              Text(m.name)
                .font(.headline)
                .padding(8)
                .background(Color.black.opacity(0.6))
                .foregroundColor(.white)
                .cornerRadius(8)
              Text(String(format: "%.3f", m.score))
                .font(.caption)
                .padding(6)
                .background(Color.black.opacity(0.5))
                .foregroundColor(.white)
                .cornerRadius(6)
            }
            .padding()
          }
        }
        Spacer()
      }

      // Bottom controls layer
      VStack {
        Spacer()
        ControlsView(viewModel: viewModel)
      }
      .padding(.all, 24)
    }
    .onDisappear {
      Task {
        if viewModel.streamingStatus != .stopped {
          await viewModel.stopSession()
        }
      }
    }
    // Show captured photos from DAT SDK in a preview sheet
    .sheet(isPresented: $viewModel.showPhotoPreview) {
      if let photo = viewModel.capturedPhoto {
        PhotoPreviewView(
          photo: photo,
          onDismiss: {
            viewModel.dismissPhotoPreview()
          }
        )
      }
    }
  }
}

// Extracted controls for clarity
struct ControlsView: View {
  @ObservedObject var viewModel: StreamSessionViewModel
  @State private var showingFriends: Bool = false

  var body: some View {
    // Controls row
    HStack(spacing: 8) {
      CustomButton(
        title: "Stop streaming",
        style: .destructive,
        isDisabled: false
      ) {
        Task {
          await viewModel.stopSession()
        }
      }

      // Photo button
      CircleButton(icon: "camera.fill", text: nil) {
        viewModel.capturePhoto()
      }
      .accessibilityIdentifier("capture_photo_button")

      // Friends manager
      Button(action: { showingFriends = true }) {
        Image(systemName: "person.3.fill")
      }
      .sheet(isPresented: $showingFriends) {
        FriendsView(store: viewModel.recognitionCoordinator.friendsStore, coordinator: viewModel.recognitionCoordinator)
      }
    }
  }
}
