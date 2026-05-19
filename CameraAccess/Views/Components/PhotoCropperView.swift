import SwiftUI
import UIKit

struct QueuedCropImage: Identifiable {
  let id = UUID()
  let image: UIImage
}

struct PhotoCropperView: View {
  let sourceImage: UIImage
  let title: String
  let skipButtonTitle: String
  let onSkip: () -> Void
  let onConfirm: (UIImage) -> Void

  @State private var zoomScale: CGFloat = 1
  @State private var committedZoomScale: CGFloat = 1
  @State private var offset: CGSize = .zero
  @State private var committedOffset: CGSize = .zero

  private let maxZoomScale: CGFloat = 5
  private let normalizedImage: UIImage

  init(
    sourceImage: UIImage,
    title: String = "Crop Photo",
    skipButtonTitle: String = "Skip",
    onSkip: @escaping () -> Void,
    onConfirm: @escaping (UIImage) -> Void
  ) {
    self.sourceImage = sourceImage
    self.title = title
    self.skipButtonTitle = skipButtonTitle
    self.onSkip = onSkip
    self.onConfirm = onConfirm
    self.normalizedImage = sourceImage.normalizedForCropping()
  }

  var body: some View {
    NavigationStack {
      GeometryReader { geometry in
        let horizontalPadding: CGFloat = 20
        let verticalPadding: CGFloat = 24
        let cropSide = max(120, min(geometry.size.width - (horizontalPadding * 2), geometry.size.height - 280))

        VStack(spacing: 20) {
          Text("Move and zoom to keep only the part of the photo you want to train with.")
            .font(.subheadline)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal)

          Spacer(minLength: 0)

          cropCanvas(cropSide: cropSide)
            .frame(width: cropSide, height: cropSide)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

          Text("Only the cropped image will be saved.")
            .font(.footnote)
            .foregroundColor(.secondary)
            .padding(.bottom, verticalPadding)
        }
        .padding(.top, verticalPadding)
        .padding(.horizontal, horizontalPadding)
        .background(Color.black.ignoresSafeArea())
        .onAppear {
          resetCropState(for: cropSide)
        }
        .onChange(of: geometry.size) { _, _ in
          resetCropState(for: cropSide)
        }
        .toolbar {
          ToolbarItem(placement: .topBarLeading) {
            Button(skipButtonTitle) {
              onSkip()
            }
          }

          ToolbarItem(placement: .principal) {
            Text(title)
              .font(.headline)
              .foregroundStyle(.white)
          }

          ToolbarItem(placement: .topBarTrailing) {
            Button("Use Crop") {
              guard let cropped = normalizedImage.croppedSquareImage(
                scale: zoomScale,
                offset: offset,
                cropSide: cropSide
              ) else { return }
              onConfirm(cropped)
            }
            .fontWeight(.semibold)
          }
        }
      }
      .toolbarBackground(.black, for: .navigationBar)
      .toolbarBackground(.visible, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
    }
  }

  @ViewBuilder
  private func cropCanvas(cropSide: CGFloat) -> some View {
    let baseSize = normalizedImage.baseDisplaySize(forCropSide: cropSide)
    let renderedSize = CGSize(width: baseSize.width * zoomScale, height: baseSize.height * zoomScale)

    ZStack {
      Color.black

      Image(uiImage: normalizedImage)
        .resizable()
        .frame(width: renderedSize.width, height: renderedSize.height)
        .position(
          x: (cropSide / 2) + offset.width,
          y: (cropSide / 2) + offset.height
        )
        .gesture(dragGesture(cropSide: cropSide))
        .simultaneousGesture(magnificationGesture(cropSide: cropSide))

      RoundedRectangle(cornerRadius: 24, style: .continuous)
        .strokeBorder(.white, lineWidth: 2)
        .frame(width: cropSide, height: cropSide)
        .allowsHitTesting(false)
    }
    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
  }

  private func dragGesture(cropSide: CGFloat) -> some Gesture {
    DragGesture()
      .onChanged { value in
        let proposed = CGSize(
          width: committedOffset.width + value.translation.width,
          height: committedOffset.height + value.translation.height
        )
        offset = normalizedImage.clampedCropOffset(
          proposed,
          scale: zoomScale,
          cropSide: cropSide
        )
      }
      .onEnded { _ in
        committedOffset = offset
      }
  }

  private func magnificationGesture(cropSide: CGFloat) -> some Gesture {
    MagnifyGesture()
      .onChanged { value in
        let proposedScale = min(max(1, committedZoomScale * value.magnification), maxZoomScale)
        zoomScale = proposedScale
        offset = normalizedImage.clampedCropOffset(
          committedOffset,
          scale: proposedScale,
          cropSide: cropSide
        )
      }
      .onEnded { _ in
        committedZoomScale = zoomScale
        committedOffset = offset
      }
  }

  private func resetCropState(for cropSide: CGFloat) {
    zoomScale = 1
    committedZoomScale = 1
    offset = .zero
    committedOffset = .zero
    offset = normalizedImage.clampedCropOffset(.zero, scale: zoomScale, cropSide: cropSide)
    committedOffset = offset
  }
}

private extension UIImage {
  func normalizedForCropping() -> UIImage {
    guard imageOrientation != .up else { return self }

    let renderer = UIGraphicsImageRenderer(size: size)
    return renderer.image { _ in
      draw(in: CGRect(origin: .zero, size: size))
    }
  }

  func baseDisplaySize(forCropSide cropSide: CGFloat) -> CGSize {
    // Start by fitting the full image inside the crop widget.
    let baseScale = min(cropSide / size.width, cropSide / size.height)
    return CGSize(width: size.width * baseScale, height: size.height * baseScale)
  }

  func clampedCropOffset(_ proposedOffset: CGSize, scale: CGFloat, cropSide: CGFloat) -> CGSize {
    let baseSize = baseDisplaySize(forCropSide: cropSide)
    let renderedSize = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    let maxX = max(0, (renderedSize.width - cropSide) / 2)
    let maxY = max(0, (renderedSize.height - cropSide) / 2)

    return CGSize(
      width: min(max(proposedOffset.width, -maxX), maxX),
      height: min(max(proposedOffset.height, -maxY), maxY)
    )
  }

  func croppedSquareImage(scale: CGFloat, offset: CGSize, cropSide: CGFloat) -> UIImage? {
    let image = normalizedForCropping()
    guard let cgImage = image.cgImage else { return nil }

    let baseSize = image.baseDisplaySize(forCropSide: cropSide)
    let renderedSize = CGSize(width: baseSize.width * scale, height: baseSize.height * scale)
    let origin = CGPoint(
      x: (cropSide - renderedSize.width) / 2 + offset.width,
      y: (cropSide - renderedSize.height) / 2 + offset.height
    )

    let imageRectInPoints = CGRect(
      x: -origin.x * image.size.width / renderedSize.width,
      y: -origin.y * image.size.height / renderedSize.height,
      width: cropSide * image.size.width / renderedSize.width,
      height: cropSide * image.size.height / renderedSize.height
    )

    let pointToPixelX = CGFloat(cgImage.width) / image.size.width
    let pointToPixelY = CGFloat(cgImage.height) / image.size.height
    let maxPixelRect = CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height)

    let pixelRect = CGRect(
      x: imageRectInPoints.origin.x * pointToPixelX,
      y: imageRectInPoints.origin.y * pointToPixelY,
      width: imageRectInPoints.size.width * pointToPixelX,
      height: imageRectInPoints.size.height * pointToPixelY
    )
    .integral
    .intersection(maxPixelRect)

    guard !pixelRect.isNull,
      pixelRect.width > 0,
      pixelRect.height > 0,
      let croppedCGImage = cgImage.cropping(to: pixelRect)
    else {
      return nil
    }

    return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: .up)
  }
}
