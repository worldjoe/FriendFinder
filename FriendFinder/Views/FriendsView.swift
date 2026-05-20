import SwiftUI
import UniformTypeIdentifiers

private struct FriendsJSONDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let fileData = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = fileData
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

private struct FriendsZIPDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.zip] }
  var data: Data

  init(data: Data) {
    self.data = data
  }

  init(configuration: ReadConfiguration) throws {
    guard let fileData = configuration.file.regularFileContents else {
      throw CocoaError(.fileReadCorruptFile)
    }
    self.data = fileData
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}

struct FriendsView: View {
  @ObservedObject var store: FriendsStore
  var coordinator: RecognitionCoordinator
  @Environment(\.presentationMode) var presentationMode

  @State private var showingAdd = false
  @State private var showingImporter = false
  @State private var showingExporter = false
  @State private var showingZIPExporter = false
  @State private var exportDocument = FriendsJSONDocument(data: Data("[]".utf8))
  @State private var zipExportDocument = FriendsZIPDocument(data: Data())
  @State private var importExportMessage = ""
  @State private var showingResultAlert = false
  @State private var isSyncing = false
  private let syncDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
  }()

  init(store: FriendsStore, coordinator: RecognitionCoordinator) {
    self.store = store
    self.coordinator = coordinator
  }

  var body: some View {
    NavigationView {
      List {
        Section {
          HStack {
            Image(systemName: store.iCloudAvailable ? "icloud.fill" : "icloud.slash")
              .foregroundStyle(store.iCloudAvailable ? .green : .secondary)
            Text(store.iCloudAvailable ? "iCloud available" : "iCloud unavailable")
            Spacer()
          }

          HStack {
            Text("Last sync")
            Spacer()
            if let lastSyncAt = store.lastSyncAt {
              Text(syncDateFormatter.localizedString(for: lastSyncAt, relativeTo: Date()))
                .foregroundColor(.secondary)
            } else {
              Text("Never")
                .foregroundColor(.secondary)
            }
          }

          if let syncError = store.lastSyncError {
            HStack(alignment: .top) {
              Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
              Text(syncError)
                .font(.footnote)
                .foregroundColor(.secondary)
            }
          }
        } header: {
          Text("Sync")
        }

        ForEach(store.friends) { friend in
          NavigationLink(destination: FriendDetailView(friend: friend, coordinator: coordinator)) {
            HStack {
              if let first = friend.imageFileNames.first, let img = store.loadImage(named: first) {
                Image(uiImage: img)
                  .resizable()
                  .frame(width: 48, height: 48)
                  .cornerRadius(6)
              } else {
                Rectangle()
                  .fill(Color.secondary)
                  .frame(width: 48, height: 48)
                  .cornerRadius(6)
              }
              VStack(alignment: .leading) {
                Text(friend.name)
                  .font(.headline)
                Text("\(friend.imageFileNames.count) photo\(friend.imageFileNames.count == 1 ? "" : "s")")
                  .font(.caption)
                  .foregroundColor(.secondary)
                if friend.centroidEmbedding != nil {
                  Text("Has centroid")
                    .font(.caption)
                    .foregroundColor(.secondary)
                }
              }
            }
          }
        }
        .onDelete { idx in
          for i in idx {
            let friend = store.friends[i]
            coordinator.deleteFriend(id: friend.id)
          }
        }
      }
      .navigationTitle("Friends")
      .toolbar {
        ToolbarItem(placement: .navigationBarLeading) {
          Button("Close") { presentationMode.wrappedValue.dismiss() }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Menu {
            Button("Import JSON or Package") {
              showingImporter = true
            }
            Button("Export ZIP (JSON + images)") {
              exportZIP()
            }
            Button("Export JSON only") {
              exportJSON()
            }
            Button("Sync with iCloud Now") {
              triggerSync()
            }
          } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
          }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
          Button(action: { showingAdd = true }) { Image(systemName: "plus") }
        }
      }
      .sheet(isPresented: $showingAdd) {
        AddFriendView(coordinator: coordinator, isPresented: $showingAdd)
      }
      .fileImporter(
        isPresented: $showingImporter,
        allowedContentTypes: [.zip, .json, .folder],
        allowsMultipleSelection: false
      ) { result in
        handleImportSelection(result)
      }
      .fileExporter(
        isPresented: $showingExporter,
        document: exportDocument,
        contentType: .json,
        defaultFilename: "friends"
      ) { result in
        switch result {
        case .success:
          importExportMessage = "Exported friends.json successfully."
        case .failure(let error):
          importExportMessage = "Export failed: \(error.localizedDescription)"
        }
        showingResultAlert = true
      }
      .fileExporter(
        isPresented: $showingZIPExporter,
        document: zipExportDocument,
        contentType: .zip,
        defaultFilename: "friends-package"
      ) { result in
        switch result {
        case .success:
          importExportMessage = "Exported friends-package.zip successfully."
        case .failure(let error):
          importExportMessage = "ZIP export failed: \(error.localizedDescription)"
        }
        showingResultAlert = true
      }
      .overlay(alignment: .bottom) {
        if isSyncing {
          ProgressView("Syncing iCloud...")
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .padding(.bottom, 12)
        }
      }
      .alert("Friends Transfer", isPresented: $showingResultAlert) {
        Button("OK", role: .cancel) {}
      } message: {
        Text(importExportMessage)
      }
    }
  }

  private func exportJSON() {
    do {
      let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("friends-export-\(UUID().uuidString).json")
      try coordinator.exportFriendsJSON(to: tempURL)
      let data = try Data(contentsOf: tempURL)
      exportDocument = FriendsJSONDocument(data: data)
      showingExporter = true
    } catch {
      importExportMessage = "Export failed: \(error.localizedDescription)"
      showingResultAlert = true
    }
  }

  private func exportZIP() {
    do {
      let tempZIP = FileManager.default.temporaryDirectory
        .appendingPathComponent("friends-package-\(UUID().uuidString).zip")
      try coordinator.exportFriendsZIP(to: tempZIP)
      let zipData = try Data(contentsOf: tempZIP)
      zipExportDocument = FriendsZIPDocument(data: zipData)
      showingZIPExporter = true
    } catch {
      importExportMessage = "ZIP export failed: \(error.localizedDescription)"
      showingResultAlert = true
    }
  }

  private func triggerSync() {
    isSyncing = true
    Task {
      await coordinator.syncNow()
      isSyncing = false
      if let syncError = store.lastSyncError {
        importExportMessage = "Sync failed: \(syncError)"
      } else {
        importExportMessage = "Sync complete."
      }
      showingResultAlert = true
    }
  }

  private func handleImportSelection(_ result: Result<[URL], Error>) {
    Task {
      do {
        isSyncing = true
        let urls = try result.get()
        guard let selectedURL = urls.first else {
          isSyncing = false
          return
        }
        let hasAccess = selectedURL.startAccessingSecurityScopedResource()
        defer {
          if hasAccess {
            selectedURL.stopAccessingSecurityScopedResource()
          }
          isSyncing = false
        }

        let values = try selectedURL.resourceValues(forKeys: [.isDirectoryKey])
        let transferResult: FriendsTransferResult
        let isZip = selectedURL.pathExtension.lowercased() == "zip"
        if isZip {
          transferResult = try await coordinator.importFriendsZIP(from: selectedURL, strategy: .mergeByIdNewestTimestampWins)
        } else if values.isDirectory == true {
          transferResult = try await coordinator.importFriendsPackage(from: selectedURL, strategy: .mergeByIdNewestTimestampWins)
        } else {
          transferResult = try await coordinator.importFriendsJSON(from: selectedURL, strategy: .mergeByIdNewestTimestampWins)
        }

        importExportMessage = "Imported \(transferResult.importedCount) friends, merged \(transferResult.mergedCount), copied \(transferResult.copiedImages) images, and recalculated recognition for imported friends."
        if transferResult.missingImages.isEmpty == false {
          importExportMessage += " Missing images: \(transferResult.missingImages.count)."
        }
        showingResultAlert = true
      } catch {
        isSyncing = false
        importExportMessage = "Import failed: \(error.localizedDescription)"
        showingResultAlert = true
      }
    }
  }
}
