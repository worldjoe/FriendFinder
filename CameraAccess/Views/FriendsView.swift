import SwiftUI

struct FriendsView: View {
  @ObservedObject var store: FriendsStore
  var coordinator: RecognitionCoordinator
  @Environment(\.presentationMode) var presentationMode

  @State private var showingAdd = false

  init(store: FriendsStore, coordinator: RecognitionCoordinator) {
    self.store = store
    self.coordinator = coordinator
  }

  var body: some View {
    NavigationView {
      List {
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
          Button(action: { showingAdd = true }) { Image(systemName: "plus") }
        }
      }
      .sheet(isPresented: $showingAdd) {
        AddFriendView(coordinator: coordinator, isPresented: $showingAdd)
      }
    }
  }
}
