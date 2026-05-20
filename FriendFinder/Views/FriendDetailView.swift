import PhotosUI
import SwiftUI
import UIKit

private struct EditableFriendImage: Identifiable {
  let id = UUID()
  let filename: String
  let image: UIImage
}

struct FriendDetailView: View {
  let friendId: String
  var coordinator: RecognitionCoordinator
  @ObservedObject var store: FriendsStore
  @State private var centroidText: String = ""
  @State private var computing: Bool = false
  @State private var selectedPhotoItems: [PhotosPickerItem] = []
  @State private var isAddingPhotos: Bool = false
  @State private var pendingCropImages: [UIImage] = []
  @State private var croppedImagesToSave: [UIImage] = []
  @State private var activeCropImage: QueuedCropImage?
  @State private var activeRecropImage: EditableFriendImage?
  @State private var pendingDeleteFilename: String?
  @State private var editableName: String = ""
  @State private var editableNickname: String = ""
  @State private var editableNote: String = ""
  @State private var detailsStatusText: String = ""

  private var friend: Friend? {
    store.friend(withId: friendId)
  }

  init(friend: Friend, coordinator: RecognitionCoordinator) {
    self.friendId = friend.id
    self.coordinator = coordinator
    self.store = coordinator.friendsStore
    if friend.centroidEmbedding != nil {
      self._centroidText = State(initialValue: "Centroid available")
    }
  }

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Text(friend?.name ?? "Friend")
          .font(.largeTitle)

        VStack(alignment: .leading, spacing: 8) {
          Text("Details")
            .font(.headline)

          TextField("Name", text: $editableName)
            .textFieldStyle(.roundedBorder)

          TextField("Nickname (optional)", text: $editableNickname)
            .textFieldStyle(.roundedBorder)

          TextField("Note (optional)", text: $editableNote, axis: .vertical)
            .lineLimit(2...5)
            .textFieldStyle(.roundedBorder)

          Button("Save details") {
            saveFriendDetails()
          }

          if !detailsStatusText.isEmpty {
            Text(detailsStatusText)
              .font(.caption)
              .foregroundColor(.secondary)
          }
        }

        Text("\((friend?.imageFileNames.count ?? 0)) training photo\((friend?.imageFileNames.count ?? 0) == 1 ? "" : "s")")
          .font(.subheadline)
          .foregroundColor(.secondary)

        if let friend, friend.imageFileNames.isEmpty {
          Text("No example images")
            .foregroundColor(.secondary)
        } else if let friend {
          LazyVStack(spacing: 12) {
            ForEach(friend.imageFileNames, id: \.self) { filename in
              if let img = store.loadImage(named: filename) {
                VStack(alignment: .leading, spacing: 8) {
                  Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

                  HStack(spacing: 12) {
                    Button("Re-crop this photo") {
                      activeRecropImage = EditableFriendImage(filename: filename, image: img)
                    }
                    .font(.subheadline)

                    Button("Delete this photo", role: .destructive) {
                      pendingDeleteFilename = filename
                    }
                    .font(.subheadline)
                  }
                }
              }
            }
          }
        }

        if computing {
          ProgressView("Computing centroid...")
        }

        if isAddingPhotos {
          ProgressView("Adding training photos...")
        }

        if activeCropImage != nil || !pendingCropImages.isEmpty {
          Text("Crop each selected photo before it is added to this friend.")
            .font(.caption)
            .foregroundColor(.secondary)
        }

        PhotosPicker(
          selection: $selectedPhotoItems,
          maxSelectionCount: 0,
          matching: .images,
          photoLibrary: .shared()
        ) {
          Text("Add more photos")
        }
        .padding(.top, 8)

        Button("Compute centroid from examples") {
          Task {
            await recomputeCentroid()
          }
        }
        .padding(.top, 12)

        if !centroidText.isEmpty {
          Text(centroidText).foregroundColor(.secondary)
        }

        Spacer()
      }
      .padding()
    }
    .navigationTitle(friend?.name ?? "Friend")
    .onAppear {
      syncEditableFieldsFromFriend()
    }
    .onChange(of: friend?.id) { _, _ in
      syncEditableFieldsFromFriend()
    }
    .onChange(of: selectedPhotoItems) { _, items in
      Task {
        await addTrainingPhotos(from: items)
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
        acceptCroppedTrainingImage(croppedImage)
      }
    }
    .fullScreenCover(item: $activeRecropImage) { recropImage in
      PhotoCropperView(
        sourceImage: recropImage.image,
        title: "Re-crop training photo",
        skipButtonTitle: "Cancel"
      ) {
        activeRecropImage = nil
      } onConfirm: { croppedImage in
        Task {
          await replaceExistingTrainingImage(croppedImage, filename: recropImage.filename)
        }
      }
    }
    .confirmationDialog(
      "Delete this training photo?",
      isPresented: Binding(
        get: { pendingDeleteFilename != nil },
        set: { isPresented in
          if !isPresented {
            pendingDeleteFilename = nil
          }
        }
      ),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        guard let filename = pendingDeleteFilename else { return }
        pendingDeleteFilename = nil
        Task {
          await deleteExistingTrainingImage(filename: filename)
        }
      }
      Button("Cancel", role: .cancel) {
        pendingDeleteFilename = nil
      }
    } message: {
      Text("This removes the photo from this friend and refreshes recognition data.")
    }
  }

  private func recomputeCentroid() async {
    guard let friend else { return }
    computing = true
    let centroid = await coordinator.computeCentroid(for: friend.id)
    centroidText = centroid != nil ? "Centroid set" : "Failed to compute centroid"
    computing = false
  }

  private func addTrainingPhotos(from items: [PhotosPickerItem]) async {
    guard !items.isEmpty else { return }

    isAddingPhotos = true
    centroidText = ""
    if pendingCropImages.isEmpty && activeCropImage == nil {
      croppedImagesToSave = []
    }

    for item in items {
      do {
        if let data = try await item.loadTransferable(type: Data.self),
          let image = UIImage.downsampledTrainingImage(from: data)
        {
          enqueueImagesForCropping([image])
        }
      } catch {
        centroidText = "Failed to load one or more selected photos"
      }
    }

    selectedPhotoItems = []
    isAddingPhotos = false
  }

  private func enqueueImagesForCropping(_ images: [UIImage]) {
    guard !images.isEmpty else { return }
    pendingCropImages.append(contentsOf: images)
    presentNextCropImageIfNeeded()
  }

  private func presentNextCropImageIfNeeded() {
    guard activeCropImage == nil else { return }

    if !pendingCropImages.isEmpty {
      activeCropImage = QueuedCropImage(image: pendingCropImages.removeFirst())
      return
    }

    guard !croppedImagesToSave.isEmpty else { return }
    Task {
      await saveCroppedTrainingImages()
    }
  }

  private func skipCurrentCropImage() {
    activeCropImage = nil
    presentNextCropImageIfNeeded()
  }

  private func acceptCroppedTrainingImage(_ image: UIImage) {
    croppedImagesToSave.append(image.trainingSized())
    activeCropImage = nil
    presentNextCropImageIfNeeded()
  }

  private func saveCroppedTrainingImages() async {
    guard let friend, !croppedImagesToSave.isEmpty else { return }

    isAddingPhotos = true
    defer {
      isAddingPhotos = false
      croppedImagesToSave = []
    }

    do {
      try await coordinator.addTrainingImages(croppedImagesToSave, for: friend.id)
      centroidText = "Added \(croppedImagesToSave.count) new photo\(croppedImagesToSave.count == 1 ? "" : "s") and refreshed centroid"
    } catch {
      centroidText = error.localizedDescription
    }
  }

  private func replaceExistingTrainingImage(_ image: UIImage, filename: String) async {
    guard let friend else { return }

    isAddingPhotos = true
    defer {
      isAddingPhotos = false
      activeRecropImage = nil
    }

    do {
      try await coordinator.replaceTrainingImage(image, filename: filename, for: friend.id)
      centroidText = "Re-cropped photo and refreshed centroid"
    } catch {
      centroidText = error.localizedDescription
    }
  }

  private func deleteExistingTrainingImage(filename: String) async {
    guard let friend else { return }

    isAddingPhotos = true
    defer {
      isAddingPhotos = false
    }

    await coordinator.deleteTrainingImage(filename: filename, for: friend.id)
    if let remaining = store.friend(withId: friend.id)?.imageFileNames.count, remaining > 0 {
      centroidText = "Deleted photo and refreshed centroid"
    } else {
      centroidText = "Deleted photo; no training photos remain"
    }
  }

  private func syncEditableFieldsFromFriend() {
    guard let friend else { return }
    editableName = friend.name
    editableNickname = friend.nickname ?? ""
    editableNote = friend.note ?? ""
  }

  private func saveFriendDetails() {
    guard let friend else { return }
    let normalizedName = editableName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalizedName.isEmpty else {
      detailsStatusText = "Name cannot be empty"
      return
    }

    coordinator.updateFriendDetails(
      id: friend.id,
      name: normalizedName,
      nickname: editableNickname.normalizedNilIfEmpty,
      note: editableNote.normalizedNilIfEmpty
    )
    detailsStatusText = "Saved"
  }
}

private extension String {
  var normalizedNilIfEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}
