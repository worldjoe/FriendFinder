import PhotosUI
import SwiftUI
import UIKit

struct AddFriendView: View {
  var coordinator: RecognitionCoordinator
  @Binding var isPresented: Bool

  @State private var name: String = ""
  @State private var nickname: String = ""
  @State private var note: String = ""
  @State private var selectedPhotoItems: [PhotosPickerItem] = []
  @State private var pickedImages: [UIImage] = []
  @State private var pendingCropImages: [UIImage] = []
  @State private var activeCropImage: QueuedCropImage?
  @State private var isSaving = false
  @State private var isLoadingPhotos = false
  @State private var loadErrorMessage: String?

  var body: some View {
    NavigationView {
      Form {
        Section(header: Text("Profile")) {
          TextField("Friend name", text: $name)
          TextField("Nickname (optional)", text: $nickname)
          TextField("Note (optional)", text: $note, axis: .vertical)
            .lineLimit(2...5)
        }

        Section(header: Text("Training photos")) {
          if pickedImages.isEmpty {
            Text("Select one or more clear example photos for better matching.")
              .foregroundColor(.secondary)
          } else {
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 12) {
                ForEach(Array(pickedImages.enumerated()), id: \.offset) { index, image in
                  ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                      .resizable()
                      .scaledToFill()
                      .frame(width: 120, height: 120)
                      .clipped()
                      .cornerRadius(12)

                    Button {
                      pickedImages.remove(at: index)
                    } label: {
                      Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.white, .black.opacity(0.7))
                        .font(.title3)
                    }
                    .offset(x: 6, y: -6)
                  }
                }
              }
              .padding(.vertical, 4)
            }

            Text("\(pickedImages.count) photo\(pickedImages.count == 1 ? "" : "s") selected")
              .font(.caption)
              .foregroundColor(.secondary)
          }

          if isLoadingPhotos {
            ProgressView("Loading photos...")
          }

          if activeCropImage != nil || !pendingCropImages.isEmpty {
            Text("Crop each selected photo before saving.")
              .font(.caption)
              .foregroundColor(.secondary)
          }

          PhotosPicker(
            selection: $selectedPhotoItems,
            maxSelectionCount: 0,
            matching: .images,
            photoLibrary: .shared()
          ) {
            Text(pickedImages.isEmpty ? "Select photos" : "Add more photos")
          }

          if let loadErrorMessage {
            Text(loadErrorMessage)
              .font(.caption)
              .foregroundColor(.red)
          }
        }
      }
      .navigationTitle("Add friend")
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") { isPresented = false }
        }
        ToolbarItem(placement: .confirmationAction) {
          Button("Save") { Task { await save() } }
            .disabled(name.isEmpty || isSaving || isLoadingPhotos || activeCropImage != nil || !pendingCropImages.isEmpty)
        }
      }
      .onChange(of: selectedPhotoItems) { _, items in
        Task {
          await appendSelectedPhotos(from: items)
        }
      }
      .fullScreenCover(item: $activeCropImage) { cropImage in
        PhotoCropperView(
          sourceImage: cropImage.image,
          title: "Crop training photo",
          skipButtonTitle: "Skip"
        ) {
          skipCurrentCropImage()
        } onConfirm: { croppedImage in
          acceptCroppedImage(croppedImage)
        }
      }
    }
  }

  private func save() async {
    isSaving = true
    defer { isSaving = false }

    do {
      _ = try await coordinator.createFriend(
        name: name,
        nickname: nickname.normalizedNilIfEmpty,
        note: note.normalizedNilIfEmpty,
        images: pickedImages
      )
      isPresented = false
    } catch {
      loadErrorMessage = error.localizedDescription
    }
  }

  private func appendSelectedPhotos(from items: [PhotosPickerItem]) async {
    guard !items.isEmpty else { return }

    isLoadingPhotos = true
    loadErrorMessage = nil

    var loadedImages: [UIImage] = []
    for item in items {
      do {
        if let data = try await item.loadTransferable(type: Data.self),
          let image = UIImage(data: data)
        {
          loadedImages.append(image)
        }
      } catch {
        loadErrorMessage = "Failed to load one or more selected photos."
      }
    }

    selectedPhotoItems = []
    isLoadingPhotos = false
    enqueueImagesForCropping(loadedImages)
  }

  private func enqueueImagesForCropping(_ images: [UIImage]) {
    guard !images.isEmpty else { return }
    pendingCropImages.append(contentsOf: images)
    presentNextCropImageIfNeeded()
  }

  private func presentNextCropImageIfNeeded() {
    guard activeCropImage == nil, !pendingCropImages.isEmpty else { return }
    activeCropImage = QueuedCropImage(image: pendingCropImages.removeFirst())
  }

  private func skipCurrentCropImage() {
    activeCropImage = nil
    presentNextCropImageIfNeeded()
  }

  private func acceptCroppedImage(_ image: UIImage) {
    pickedImages.append(image)
    activeCropImage = nil
    presentNextCropImageIfNeeded()
  }
}

private extension String {
  var normalizedNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
