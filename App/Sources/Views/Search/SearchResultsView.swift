import SwiftUI

/// Catalog entries matching the sidebar search, installed or not.
struct SearchResultsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let results = model.survey.lineup.search(model.searchText)
        Group {
            if results.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 20, alignment: .top)], spacing: 26) {
                        ForEach(results) { CatalogCard(entry: $0) }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
            }
        }
        .testContainer("screen.search")
        .navigationTitle("Search")
        .navigationSubtitle(Format.count(results.count, "Port") + " matching “\(model.searchText)”")
    }
}

#if DEBUG
#Preview("Search") {
    ScreenPreview(.library) { model, _ in model.searchText = "mario" }
}

#Preview("Search · No Results") {
    ScreenPreview(.library) { model, _ in model.searchText = "metroid" }
}
#endif
