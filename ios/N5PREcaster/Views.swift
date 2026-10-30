import SwiftUI
import AuthenticationServices

// MARK: Home

struct ContentView: View {
    @EnvironmentObject var dropbox: Dropbox
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var transcripts: Transcripts
    @State private var filter = ""
    @State private var showSettings = false
    @State private var showAdd = false
    @State private var renaming = ""
    @State private var arranging: ArrangeView.Kind?
    @State private var newName = ""
    @State private var markAll: [String] = []
    @AppStorage("markKeep") private var markKeep = 3

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !library.subjects.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Chip(title: "All", on: filter.isEmpty) { filter = "" }
                                    .contextMenu {
                                        Button { arranging = .subjects } label: { Label("Subject order", systemImage: "arrow.up.arrow.down") }
                                    }
                                ForEach(library.subjects, id: \.self) { c in
                                    Chip(title: c, on: filter == c) { filter = c }
                                        .contextMenu {
                                            Button {
                                                renaming = c
                                                newName = c
                                            } label: { Label("Rename subject", systemImage: "pencil") }
                                            Button { arranging = .subjects } label: { Label("Subject order", systemImage: "arrow.up.arrow.down") }
                                        }
                                }
                                if library.subjects.count > 1 {
                                    Chip(title: "\u{21C4} Order", on: false) { arranging = .subjects }
                                }
                            }
                        }
                    }

                    if !library.status.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(library.status).font(.system(size: 14)).foregroundStyle(Theme.muted)
                            if !dropbox.signedIn {
                                Button("Open Settings") { showSettings = true }
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                    }

                    if !filter.isEmpty {
                        let items = library.unplayed(in: filter)
                        if items.isEmpty {
                            Text(library.loading.isEmpty ? "Nothing new in \(filter)." : "Getting episodes…")
                                .foregroundStyle(Theme.muted)
                                .frame(maxWidth: .infinity)
                                .padding(28)
                        } else {
                            HStack {
                                Button("Mark all played") {
                                    let cut = Date().addingTimeInterval(-Double(markKeep) * 86400)
                                    markAll = items.filter { item in
                                        item.episode.guid != player.now?.episode.guid
                                            && (markKeep == 0 || (item.episode.date ?? .distantPast) < cut)
                                    }.map(\.episode.guid)
                                }
                                .buttonStyle(.bordered)
                                Spacer()
                                Picker("Keep", selection: $markKeep) {
                                    Text("Keep none").tag(0)
                                    Text("Keep last day").tag(1)
                                    Text("Keep last 3 days").tag(3)
                                    Text("Keep last 7 days").tag(7)
                                }
                                .pickerStyle(.menu)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .confirmationDialog(markAll.isEmpty ? "Nothing to mark" : "Mark \(markAll.count) episode\(markAll.count == 1 ? "" : "s") in \(filter) as played?",
                                                isPresented: Binding(get: { !markAll.isEmpty }, set: { if !$0 { markAll = [] } }),
                                                titleVisibility: .visible) {
                                Button("Mark played") { library.setPlayed(all: markAll); markAll = [] }
                                Button("Cancel", role: .cancel) { markAll = [] }
                            } message: {
                                Text(markKeep == 0 ? "Your other devices will see this too." : "Episodes from the last \(markKeep == 1 ? "day" : "\(markKeep) days") stay. Your other devices will see this too.")
                            }
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(items) { item in
                                    EpisodeRow(ep: item.episode, show: item.show, showName: true, subject: filter)
                                    Rectangle().fill(Theme.line).frame(height: 1)
                                }
                            }
                        }
                    }

                    let favs = filter.isEmpty ? library.favShows : []
                    if !favs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                SectionLabel("Favorites")
                                Spacer()
                                if favs.count > 1 {
                                    Button("Arrange") { arranging = .favorites }
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            ForEach(favs) { show in
                                FavCard(rank: (library.fav.firstIndex(of: show.id) ?? 0) + 1, show: show)
                            }
                        }
                    }

                    let others = filter.isEmpty ? library.allShows.filter { !library.fav.contains($0.id) } : []
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            SectionLabel("All shows").padding(.bottom, 4)
                            ForEach(others) { show in
                                NavigationLink(value: show) { ShowRow(show: show) }
                                    .buttonStyle(.plain)
                                Rectangle().fill(Theme.line).frame(height: 1)
                            }
                        }
                    }

                    if filter.isEmpty && favs.isEmpty && others.isEmpty && library.status.isEmpty {
                        Text(library.busy ? "Getting your list from Dropbox…" : "No shows here yet.")
                            .foregroundStyle(Theme.muted)
                            .frame(maxWidth: .infinity)
                            .padding(28)
                            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Theme.bg)
            .navigationTitle("Shows")
            .navigationDestination(for: Show.self) { ShowView(show: $0) }
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a show")
                        .disabled(!dropbox.signedIn)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Settings")
                }
            }
            .alert("Rename subject", isPresented: Binding(get: { !renaming.isEmpty }, set: { if !$0 { renaming = "" } })) {
                TextField("Subject", text: $newName)
                Button("Rename") {
                    let old = renaming, name = newName.trimmingCharacters(in: .whitespaces)
                    renaming = ""
                    Task {
                        await library.renameSubject(old, to: name)
                        if filter == old && library.subjects.contains(name) { filter = name }
                    }
                }
                Button("Cancel", role: .cancel) { renaming = "" }
            } message: {
                Text("Renames it on every show, on all your devices.")
            }
            .refreshable { await library.refreshAll(force: true) }
            .task(id: filter) {
                guard !filter.isEmpty else { return }
                for show in library.showsIn(filter) { await library.loadEpisodes(show) }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.now != nil { MiniPlayer() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(dropbox)
                .environmentObject(library)
                .environmentObject(library.downloads)
                .environmentObject(transcripts)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .sheet(item: $arranging) { kind in
            ArrangeView(kind: kind)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .sheet(isPresented: $showAdd) {
            AddShowView()
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .sheet(isPresented: $player.showFull) {
            PlayerView()
                .environmentObject(player)
                .environmentObject(library.downloads)
                .environmentObject(transcripts)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .task {
            await library.refreshAll()
            player.takeOtherDevicesEpisode()
            transcripts.scan()
        }
    }
}

struct FavCard: View {
    let rank: Int
    let show: Show
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player

    var body: some View {
        let latest = library.latestUnheard(show)
        let isCurrent = latest != nil && player.now?.episode.guid == latest?.guid
        HStack(spacing: 12) {
            NavigationLink(value: show) {
                HStack(spacing: 12) {
                    Text("\(rank)")
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22)
                    ArtView(url: show.art, size: 64, radius: 10)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(show.title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(Theme.fg)
                            .lineLimit(1)
                        Group {
                            if let ep = latest {
                                Text(ep.title)
                            } else {
                                Text(show.author)
                            }
                        }
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if isCurrent {
                    player.toggle()
                } else {
                    Task {
                        await library.loadEpisodes(show)
                        if let ep = library.latestUnheard(show) ?? library.episodes[show.id]?.first {
                            player.play(ep, show: show)
                        }
                    }
                }
            } label: {
                PlayCircle(playing: isCurrent && player.isPlaying)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Play the newest episode of \(show.title)")
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.surface))
        .task { await library.loadEpisodes(show) }
    }
}

struct ShowRow: View {
    let show: Show
    var body: some View {
        HStack(spacing: 12) {
            ArtView(url: show.art, size: 56, radius: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.fg)
                    .lineLimit(1)
                if !show.author.isEmpty {
                    Text(show.author).font(.system(size: 14)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct ArtView: View {
    let url: String
    var size: CGFloat
    var radius: CGFloat = 10
    var body: some View {
        AsyncImage(url: URL(string: url)) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Theme.surface2
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius))
    }
}

func skipSymbol(_ seconds: Double, forward: Bool) -> String {
    let base = forward ? "goforward" : "gobackward"
    let s = Int(seconds)
    return [5, 10, 15, 30, 45, 60, 75, 90].contains(s) ? "\(base).\(s)" : base
}

// MARK: Show

struct ShowView: View {
    let start: Show
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var tab = 0
    @State private var confirmRemove = false
    @State private var editSubjects = false
    @State private var aboutOpen = false

    init(show: Show) { start = show }

    /// The show as it is in the list now, so changes made here show at once.
    private var show: Show { library.shows[start.id] ?? start }
    private var isFav: Bool { library.fav.contains(show.id) }
    /// Read again whenever the episode list changes, since that's when the feed is saved.
    private var about: String { _ = library.episodes[start.id]; return Feeds.about(start.id) }
    private var keepChoice: Binding<Int> {
        Binding(get: { show.dlKeep ?? -1 },
                set: { v in Task { await library.setKeep(show.id, v < 0 ? nil : v) } })
    }

    private var episodes: [Episode] { library.episodes[show.id] ?? [] }
    private var shown: [Episode] { tab == 0 ? episodes.filter { !library.isPlayed($0.guid) } : episodes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 16) {
                    ArtView(url: show.art, size: 120, radius: 14)
                    VStack(alignment: .leading, spacing: 4) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { aboutOpen.toggle() }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(show.title)
                                    .font(.system(size: 22, weight: .bold))
                                    .foregroundStyle(Theme.fg)
                                    .multilineTextAlignment(.leading)
                                if !about.isEmpty {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(Theme.muted)
                                        .rotationEffect(.degrees(aboutOpen ? 90 : 0))
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint(aboutOpen ? "Hides the show's description" : "Shows the show's description")
                        if !show.author.isEmpty {
                            Text(show.author).font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                    }
                }

                if !about.isEmpty {
                    Text(about)
                        .font(.system(size: 14))
                        .foregroundStyle(aboutOpen ? Theme.fg : Theme.muted)
                        .lineLimit(aboutOpen ? nil : 2)
                        .fixedSize(horizontal: false, vertical: aboutOpen)
                        .textSelection(.enabled)
                        .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { aboutOpen.toggle() } }
                }

                if !library.status.isEmpty {
                    Text(library.status).font(.system(size: 14)).foregroundStyle(Theme.muted)
                }

                Segmented(options: ["New to me", "Recent"], selection: $tab)

                if episodes.isEmpty, let err = library.feedErrors[show.id] {
                    Text("Couldn't load episodes: \(err)").font(.system(size: 14)).foregroundStyle(Theme.muted)
                }
                if episodes.isEmpty && library.loading.contains(show.id) {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if tab == 0 && shown.isEmpty && !episodes.isEmpty {
                    Text("Nothing new. Recent lists every episode.")
                        .font(.system(size: 14)).foregroundStyle(Theme.muted)
                }

                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(shown) { ep in
                        EpisodeRow(ep: ep, show: show)
                        Rectangle().fill(Theme.line).frame(height: 1)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.bg, for: .navigationBar)
        .task { await library.loadEpisodes(show) }
        .refreshable { await library.loadEpisodes(show, force: true) }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if library.shows[start.id] != nil {
                    Menu {
                        Button {
                            Task { await library.setFavorite(show.id, !isFav) }
                        } label: {
                            Label(isFav ? "Remove from Favorites" : "Add to Favorites", systemImage: isFav ? "star.slash" : "star")
                        }
                        Picker(selection: keepChoice) {
                            Text("Past episodes per show (\(library.epCap > 0 ? library.epCap : 3))").tag(-1)
                            Text("None").tag(0)
                            ForEach([1, 2, 3, 5, 10], id: \.self) { n in Text("\(n)").tag(n) }
                        } label: {
                            Label("Downloads to keep: \(library.keepCount(show))", systemImage: "arrow.down.circle")
                        }
                        .pickerStyle(.menu)
                        Button { editSubjects = true } label: { Label("Subjects", systemImage: "tag") }
                        Divider()
                        Button(role: .destructive) { confirmRemove = true } label: { Label("Remove show", systemImage: "trash") }
                    } label: {
                        Image(systemName: library.busy ? "hourglass" : "ellipsis.circle")
                    }
                    .disabled(library.busy)
                }
            }
        }
        .confirmationDialog("Remove \(show.title)?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove show", role: .destructive) {
                Task {
                    await library.removeShow(show.id)
                    if library.shows[start.id] == nil { dismiss() }
                }
            }
        } message: {
            Text("It leaves your list on all your devices.")
        }
        .sheet(isPresented: $editSubjects) {
            SubjectsEditor(showId: show.id, chosen: show.cats)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

/// Drag to set the order of Favorites or of the subjects across the top.
struct ArrangeView: View {
    enum Kind: String, Identifiable {
        case favorites, subjects
        var id: String { rawValue }
    }
    let kind: Kind
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var items: [String] = []

    var body: some View {
        NavigationStack {
            List {
                ForEach(items, id: \.self) { id in
                    Text(kind == .favorites ? (library.shows[id]?.title ?? id) : id)
                        .foregroundStyle(Theme.fg)
                        .listRowBackground(Theme.surface)
                }
                .onMove { items.move(fromOffsets: $0, toOffset: $1) }
                if !library.status.isEmpty {
                    Text(library.status).font(.footnote).foregroundStyle(Theme.muted).listRowBackground(Theme.bg)
                }
            }
            .environment(\.editMode, .constant(.active))
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(kind == .favorites ? "Favorites order" : "Subject order")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                if kind == .subjects {
                    ToolbarItem(placement: .bottomBar) {
                        Button("Back to A to Z") {
                            items.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        Task {
                            if kind == .favorites { await library.setFavoriteOrder(items) } else { await library.setSubjectOrder(items) }
                            if library.status.isEmpty { dismiss() }
                        }
                    }
                    .disabled(library.busy)
                }
            }
        }
        .onAppear { items = kind == .favorites ? library.fav : library.subjects }
    }
}

/// Picks the subjects a show sits under, or adds a new one.
struct SubjectsEditor: View {
    let showId: String
    @State var chosen: [String]
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var newSubject = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(Set(library.subjects + chosen)).sorted(), id: \.self) { c in
                        Button {
                            if chosen.contains(c) { chosen.removeAll { $0 == c } } else { chosen.append(c) }
                        } label: {
                            HStack {
                                Text(c).foregroundStyle(Theme.fg)
                                Spacer()
                                if chosen.contains(c) { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                    HStack {
                        TextField("New subject", text: $newSubject)
                            .onSubmit(addNew)
                        Button("Add", action: addNew)
                            .disabled(newSubject.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .listRowBackground(Theme.surface)
                if !library.status.isEmpty {
                    Text(library.status).font(.footnote).foregroundStyle(Theme.muted).listRowBackground(Theme.bg)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Subjects")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        addNew()
                        Task {
                            await library.setSubjects(showId, chosen)
                            if library.status.isEmpty { dismiss() }
                        }
                    }
                    .disabled(library.busy)
                }
            }
        }
    }

    private func addNew() {
        let c = newSubject.trimmingCharacters(in: .whitespaces)
        if !c.isEmpty && !chosen.contains(c) { chosen.append(c) }
        newSubject = ""
    }
}

/// Finds shows on Podcast Index (or Apple's directory) and adds them to the list.
struct AddShowView: View {
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    @State private var term = ""
    @State private var results: [FoundShow] = []
    @State private var searching = false
    @State private var note = ""
    @State private var subject = ""
    @State private var newSubject = ""
    @State private var added: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Search for a show", text: $term)
                        .submitLabel(.search)
                        .onSubmit(run)
                    Picker("Subject", selection: $subject) {
                        Text("None").tag("")
                        ForEach(library.subjects, id: \.self) { Text($0).tag($0) }
                    }
                    TextField("Or a new subject", text: $newSubject)
                } footer: {
                    Text(library.hasPodcastIndex ? "Searches Podcast Index, then Apple's directory." : "Searches Apple's directory. Add your Podcast Index key in the web app to search there first.")
                }
                .listRowBackground(Theme.surface)

                if searching { ProgressView().frame(maxWidth: .infinity).listRowBackground(Theme.bg) }
                if !note.isEmpty { Text(note).foregroundStyle(Theme.muted).listRowBackground(Theme.bg) }
                if !library.status.isEmpty { Text(library.status).font(.footnote).foregroundStyle(Theme.muted).listRowBackground(Theme.bg) }

                ForEach(results) { f in
                    HStack(spacing: 12) {
                        ArtView(url: f.art, size: 52, radius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(f.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.fg).lineLimit(2)
                            Text(f.author.isEmpty ? f.source : "\(f.author) · \(f.source)")
                                .font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                        Spacer()
                        if added.contains(f.id) || library.isFollowed(f) {
                            Image(systemName: "checkmark").foregroundStyle(Theme.muted)
                        } else {
                            Button("Add") {
                                let subj = newSubject.trimmingCharacters(in: .whitespaces).isEmpty ? subject : newSubject
                                Task {
                                    await library.addShow(f, subject: subj)
                                    if library.isFollowed(f) { added.insert(f.id) }
                                }
                            }
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accentInk)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 36)
                            .background(Capsule().fill(Theme.accent))
                            .buttonStyle(.plain)
                            .disabled(library.busy)
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Add a show")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
    }

    private func run() {
        let q = term
        searching = true
        note = ""
        Task {
            do {
                results = try await library.search(q)
                if results.isEmpty { note = "No shows found." }
            } catch {
                note = "Search didn't work: \(error.localizedDescription)"
            }
            searching = false
        }
    }
}

struct EpisodeRow: View {
    let ep: Episode
    let show: Show
    var showName = false
    var subject: String? = nil
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @EnvironmentObject var downloads: Downloads
    @State private var open = false

    var body: some View {
        let played = library.isPlayed(ep.guid)
        let current = player.now?.episode.guid == ep.guid
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if showName {
                    Text(show.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                Text(detail(played: played, current: current))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(current ? Theme.accent : Theme.muted)
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(ep.title)
                            .font(.system(size: 16, weight: played ? Font.Weight.medium : Font.Weight.semibold))
                            .foregroundStyle(played ? Theme.muted : Theme.fg)
                            .lineLimit(open ? nil : 3)
                            .multilineTextAlignment(.leading)
                        if !ep.summary.isEmpty {
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.muted)
                                .rotationEffect(.degrees(open ? 90 : 0))
                        }
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint(open ? "Hides the description" : "Shows the full description")
                if !ep.summary.isEmpty {
                    Text(ep.summary)
                        .font(.system(size: 14))
                        .foregroundStyle(open ? Theme.fg : Theme.muted)
                        .lineLimit(open ? nil : 2)
                        .fixedSize(horizontal: false, vertical: open)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
            DownloadButton(ep: ep)
            Button {
                if current { player.toggle() } else { player.play(ep, show: show, subject: subject) }
            } label: {
                PlayCircle(playing: current && player.isPlaying, ghost: !current)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(current && player.isPlaying ? "Pause" : "Play \(ep.title)")
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .contextMenu {
            Button(played ? "Mark as not played" : "Mark as played") { library.setPlayed(ep.guid, !played) }
            if downloads.isDownloaded(ep.guid) {
                Button("Remove download", role: .destructive) { downloads.remove(ep.guid) }
            } else if downloads.progress[ep.guid] == nil {
                Button("Download") { downloads.start(ep) }
            }
        }
    }

    private func detail(played: Bool, current: Bool) -> String {
        var parts: [String] = []
        if let d = ep.date { parts.append(d.formatted(date: .abbreviated, time: .omitted)) }
        let pos = library.position(ep.guid)
        if played {
            parts.append("Played")
        } else if pos > 5 && ep.duration > 0 {
            parts.append("\(clock(max(0, ep.duration - pos))) left")
        } else if pos > 5 {
            parts.append("Started")
        } else if ep.duration > 0 {
            parts.append(clock(ep.duration))
        }
        if downloads.isDownloaded(ep.guid) { parts.append("Downloaded") }
        if current { parts.append(player.isPlaying ? "Playing" : "Paused") }
        return parts.joined(separator: " · ")
    }
}

/// Download, progress ring, or a filled mark once the episode is on the iPhone.
struct DownloadButton: View {
    let ep: Episode
    @EnvironmentObject var downloads: Downloads

    var body: some View {
        Group {
            if downloads.isDownloaded(ep.guid) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Theme.accent)
                    .accessibilityLabel("Downloaded")
            } else if let p = downloads.progress[ep.guid] {
                Button { downloads.cancel(ep.guid) } label: {
                    ZStack {
                        Circle().stroke(Theme.surface2, lineWidth: 3)
                        Circle().trim(from: 0, to: max(0.03, p))
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Image(systemName: "stop.fill").font(.system(size: 8)).foregroundStyle(Theme.fg)
                    }
                    .frame(width: 24, height: 24)
                }
                .accessibilityLabel("Stop download")
            } else {
                Button { downloads.start(ep) } label: {
                    Image(systemName: downloads.failed[ep.guid] == nil ? "arrow.down.circle" : "exclamationmark.arrow.circlepath")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.muted)
                }
                .accessibilityLabel(downloads.failed[ep.guid] == nil ? "Download" : "Download failed, try again")
            }
        }
        .buttonStyle(.plain)
        .frame(width: 36, height: 44)
    }
}

// MARK: Player

struct MiniPlayer: View {
    @EnvironmentObject var player: Player

    var body: some View {
        if let n = player.now {
            let chapter = player.currentChapter?.title ?? ""
            let progress = player.duration > 0 ? min(1, max(0, player.time / player.duration)) : 0
            VStack(spacing: 0) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Theme.surface2)
                        Rectangle().fill(Theme.accent).frame(width: geo.size.width * progress)
                    }
                }
                .frame(height: 2)
                HStack(spacing: 10) {
                    Group {
                        if let img = player.artwork {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            Theme.surface2
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(chapter.isEmpty ? n.episode.title : chapter)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.fg)
                            .lineLimit(1)
                        Text(n.showTitle).font(.system(size: 13)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Button { player.skip(-player.skipBack) } label: {
                        Image(systemName: skipSymbol(player.skipBack, forward: false))
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.fg)
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Skip back")
                    Button { player.toggle() } label: {
                        PlayCircle(size: 44, playing: player.isPlaying)
                    }
                    .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 66)
            }
            .background(Theme.surface)
            .contentShape(Rectangle())
            .onTapGesture { player.showFull = true }
        }
    }
}

struct PlayerView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var downloads: Downloads
    @EnvironmentObject var transcripts: Transcripts
    @State private var showTranscript = false
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    private let speeds: [Double] = [0.8, 1, 1.1, 1.2, 1.25, 1.3, 1.4, 1.5, 1.75, 2, 2.5, 3]

    private var shownTime: Double { scrubbing ? scrub : player.time }

    private func speedText(_ s: Double) -> String {
        String(format: s == s.rounded() ? "%.0f×" : (s * 10 == (s * 10).rounded() ? "%.1f×" : "%.2f×"), s)
    }

    var body: some View {
        ScrollView {
            if let n = player.now {
                VStack(spacing: 14) {
                    HStack {
                        Button { player.showFull = false } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(Theme.fg)
                                .frame(width: 44, height: 44)
                                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface2))
                        }
                        .accessibilityLabel("Close player")
                        Spacer()
                    }

                    Group {
                        if let img = player.artwork {
                            Image(uiImage: img).resizable().scaledToFill()
                        } else {
                            Theme.surface2
                        }
                    }
                    .frame(width: 300, height: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 18))
                    .shadow(color: .black.opacity(0.45), radius: 25, y: 18)
                    .padding(.vertical, 12)

                    VStack(spacing: 2) {
                        if let ch = player.currentChapter, !ch.title.isEmpty {
                            Text(ch.title)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                        }
                        Text(n.episode.title)
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Theme.fg)
                        Text(n.showTitle).font(.system(size: 15)).foregroundStyle(Theme.muted)
                    }
                    .multilineTextAlignment(.center)

                    VStack(spacing: 0) {
                        Slider(value: Binding(get: { shownTime }, set: { scrub = $0 }),
                               in: 0...max(player.duration, 1),
                               onEditingChanged: { editing in
                                   if editing {
                                       scrub = player.time
                                       scrubbing = true
                                   } else {
                                       player.seek(scrub)
                                       scrubbing = false
                                   }
                               })
                        .tint(Theme.accent)
                        HStack {
                            Text(clock(shownTime))
                            Spacer()
                            Text("-" + clock(max(0, player.duration - shownTime)))
                        }
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                    }

                    HStack(spacing: 22) {
                        Button { player.previousChapter() } label: {
                            Image(systemName: "backward.end.fill").font(.system(size: 20))
                        }
                        .disabled(player.chapters.isEmpty)
                        .opacity(player.chapters.isEmpty ? 0.35 : 1)
                        .accessibilityLabel("Previous chapter")
                        Button { player.skip(-player.skipBack) } label: {
                            Image(systemName: skipSymbol(player.skipBack, forward: false)).font(.system(size: 36))
                        }
                        .accessibilityLabel("Skip back")
                        Button { player.toggle() } label: {
                            PlayCircle(size: 80, playing: player.isPlaying)
                        }
                        .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                        Button { player.skip(player.skipFwd) } label: {
                            Image(systemName: skipSymbol(player.skipFwd, forward: true)).font(.system(size: 36))
                        }
                        .accessibilityLabel("Skip forward")
                        Button { player.nextChapter() } label: {
                            Image(systemName: "forward.end.fill").font(.system(size: 20))
                        }
                        .disabled(player.chapters.isEmpty)
                        .opacity(player.chapters.isEmpty ? 0.35 : 1)
                        .accessibilityLabel("Next chapter")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.fg)
                    .padding(.vertical, 8)

                    VStack(spacing: 2) {
                        Text("SPEED")
                            .font(.system(size: 11, weight: .semibold))
                            .kerning(0.5)
                            .foregroundStyle(Theme.muted)
                        Menu {
                            ForEach(speeds, id: \.self) { s in
                                Button {
                                    player.setRate(s)
                                } label: {
                                    if abs(s - player.rate) < 0.001 {
                                        Label(speedText(s), systemImage: "checkmark")
                                    } else {
                                        Text(speedText(s))
                                    }
                                }
                            }
                        } label: {
                            Text(speedText(player.rate))
                                .font(.system(size: 15))
                                .foregroundStyle(Theme.fg)
                                .frame(minWidth: 92, minHeight: 42)
                                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface2))
                        }
                    }

                    Button { showTranscript = true } label: {
                        Label("Transcript", systemImage: "text.quote")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.fg)
                            .padding(.horizontal, 14)
                            .frame(minHeight: 40)
                            .background(Capsule().fill(Theme.surface2))
                    }
                    .buttonStyle(.plain)

                    if !player.errorText.isEmpty {
                        Text(player.errorText).font(.footnote).foregroundStyle(Color(hex: 0xEF7D6D))
                    }

                    if !player.chapters.isEmpty {
                        ChapterList()
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            } else {
                Text("Nothing playing").foregroundStyle(Theme.muted).padding(.top, 40)
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .sheet(isPresented: $showTranscript) {
            TranscriptView()
                .environmentObject(player)
                .environmentObject(downloads)
                .environmentObject(transcripts)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}

struct TranscriptView: View {
    @EnvironmentObject var player: Player
    @EnvironmentObject var downloads: Downloads
    @EnvironmentObject var transcripts: Transcripts
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let ep = player.now?.episode {
                    if let f = transcripts.current, transcripts.currentGuid == ep.guid {
                        lines(f)
                    } else {
                        status(ep)
                    }
                } else {
                    Text("Nothing playing").foregroundStyle(Theme.muted)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
            .navigationTitle("Transcript")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task(id: player.now?.episode.guid) { await transcripts.loadCurrent(player.now?.episode) }
    }

    private func lines(_ f: TranscriptFile) -> some View {
        let at = f.segs.lastIndex { $0.s <= player.time + 0.3 }
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(f.segs.enumerated()), id: \.offset) { i, seg in
                        Text(seg.b)
                            .font(.system(size: 18, weight: i == at ? Font.Weight.semibold : Font.Weight.regular))
                            .foregroundStyle(i == at ? Theme.fg : Theme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            .onTapGesture { player.seek(seg.s) }
                            .id(i)
                    }
                }
                .padding(20)
            }
            .onAppear { if let at { proxy.scrollTo(at, anchor: .center) } }
            .onChange(of: at) { _, new in
                if let new { withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(new, anchor: .center) } }
            }
        }
    }

    @ViewBuilder
    private func status(_ ep: Episode) -> some View {
        VStack(spacing: 14) {
            if transcripts.working == ep.guid {
                ProgressView()
                Text("Making the transcript on this iPhone. It can take a few minutes for a long episode, and keeps going while you listen.")
            } else if transcripts.loadingCurrent {
                ProgressView()
            } else if transcripts.isQueued(ep.guid) {
                Text("Waiting for another transcript to finish first.")
            } else if downloads.isDownloaded(ep.guid) {
                if let err = transcripts.failed[ep.guid] {
                    Text("Couldn't make one: \(err)")
                } else if !(ep.transcript ?? "").isEmpty {
                    Text("This show publishes its own transcript, which the web app shows. You can still make one here.")
                } else {
                    Text("No transcript yet.")
                }
                Button("Make a transcript") { transcripts.make(ep) }
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accentInk)
                    .padding(.horizontal, 16)
                    .frame(minHeight: 44)
                    .background(Capsule().fill(Theme.accent))
                    .buttonStyle(.plain)
            } else {
                Text("Download this episode to make a transcript on the iPhone.")
                if downloads.progress[ep.guid] == nil {
                    Button("Download") { downloads.start(ep) }
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.accentInk)
                        .padding(.horizontal, 16)
                        .frame(minHeight: 44)
                        .background(Capsule().fill(Theme.accent))
                        .buttonStyle(.plain)
                } else {
                    ProgressView(value: downloads.progress[ep.guid] ?? 0).tint(Theme.accent).frame(width: 160)
                }
            }
            if !transcripts.note.isEmpty {
                Text(transcripts.note).font(.footnote)
            }
        }
        .font(.system(size: 15))
        .foregroundStyle(Theme.muted)
        .multilineTextAlignment(.center)
        .padding(28)
    }
}

struct ChapterList: View {
    @EnvironmentObject var player: Player

    var body: some View {
        let current = player.currentChapterIndex
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel("Chapters").padding(.bottom, 8)
            ForEach(Array(player.chapters.enumerated()), id: \.offset) { i, c in
                Button {
                    player.seek(c.start)
                    if !player.isPlaying { player.play() }
                } label: {
                    HStack(spacing: 10) {
                        Text(clock(c.start))
                            .font(.system(size: 14).monospacedDigit())
                            .foregroundStyle(Theme.muted)
                            .frame(minWidth: 52, alignment: .leading)
                        if !c.img.isEmpty { ArtView(url: c.img, size: 28, radius: 4) }
                        Text(c.title.isEmpty ? "Chapter \(i + 1)" : c.title)
                            .font(.system(size: 14, weight: i == current ? Font.Weight.bold : Font.Weight.regular))
                            .foregroundStyle(i == current ? Theme.accent : Theme.fg)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        .padding(.top, 10)
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var dropbox: Dropbox
    @EnvironmentObject var library: Library
    @EnvironmentObject var downloads: Downloads
    @EnvironmentObject var transcripts: Transcripts
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var codeMode = false
    @State private var code = ""
    @State private var working = false
    @State private var confirmMaster = false
    @State private var masterSummary = ""
    @State private var masterNote = ""

    /// A setting that saves to Dropbox when changed.
    private func prefBinding<T>(_ value: T, _ key: String) -> Binding<T> {
        Binding(get: { value }, set: { v in Task { await library.setPref(key, v) } })
    }

    private func describe(_ s: Library.ListSummary) -> String {
        "\(s.shows) shows, \(s.subjects) subjects, \(s.favorites) favorites"
    }

    private func askMaster() async {
        masterNote = "Checking Dropbox…"
        let mine = library.localSummary
        guard mine.shows >= 2 else {
            masterNote = "This iPhone has only \(mine.shows) show, so it doesn't look like your full list."
            return
        }
        do {
            let theirs = try await library.remoteSummary()
            masterSummary = "On this iPhone: \(describe(mine)). On Dropbox now: \(describe(theirs)). Your other devices will show exactly this iPhone's shows, subjects, favorites order and settings, and shows not on this iPhone leave them too. Listening spots and played marks aren't affected. Earlier copies in the web app can bring back the one replaced."
            masterNote = ""
            confirmMaster = true
        } catch {
            masterNote = "Couldn't check Dropbox: \(error.localizedDescription)"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if dropbox.signedIn {
                        Label("Signed in to Dropbox", systemImage: "checkmark.circle.fill")
                        if dropbox.needsWriteSignIn {
                            Text("Sign out and back in once so transcripts can be saved to Dropbox.")
                                .font(.footnote).foregroundStyle(Theme.accent)
                        }
                        Button("Bring in my list again") { Task { await library.refresh() } }
                        Button("Sign out of Dropbox", role: .destructive) {
                            dropbox.signOut()
                            message = ""
                        }
                    } else {
                        Button("Sign in with Dropbox") { Task { await signIn() } }
                        Button("Sign in with a code instead") {
                            codeMode = true
                            openURL(dropbox.authURL(redirect: false))
                        }
                        if codeMode {
                            TextField("Paste the code from Dropbox", text: $code)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Use this code") { Task { await useCode() } }
                                .disabled(code.isEmpty)
                        }
                    }
                    if working || library.busy { ProgressView() }
                    if !message.isEmpty {
                        Text(message).font(.footnote).foregroundStyle(Theme.muted)
                    }
                } header: {
                    Text("Dropbox")
                } footer: {
                    Text("Your list lives in your Dropbox, shared with the web app. Changes made here go straight into Dropbox's current copy.")
                }
                .listRowBackground(Theme.surface)

                Section("Your list") {
                    LabeledContent("Shows", value: "\(library.shows.count)")
                    LabeledContent("Subjects", value: "\(library.subjects.count)")
                    LabeledContent("Favorites", value: "\(library.fav.count)")
                    if !library.savedBy.isEmpty {
                        LabeledContent("Saved to Dropbox by", value: library.savedBy)
                    }
                    if !library.status.isEmpty {
                        Text(library.status).font(.footnote).foregroundStyle(Theme.muted)
                    }
                    if dropbox.signedIn {
                        Button("Use this iPhone's list everywhere") { Task { await askMaster() } }
                            .disabled(library.busy)
                    }
                    if !masterNote.isEmpty {
                        Text(masterNote).font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                .listRowBackground(Theme.surface)
                .confirmationDialog("Use this iPhone's list everywhere?", isPresented: $confirmMaster, titleVisibility: .visible) {
                    Button("Yes, use this iPhone's list") {
                        Task {
                            let ok = await library.useThisListEverywhere()
                            masterNote = ok ? "Dropbox now has this iPhone's list. Your other devices take it the next time they sync." : ""
                        }
                    }
                } message: {
                    Text(masterSummary)
                }

                Section {
                    Toggle("Download new Favorites episodes", isOn: $downloads.autoFavorites)
                    Toggle("Delete after listening", isOn: $downloads.deleteAfter)
                    LabeledContent("Space used", value: ByteCountFormatter.string(fromByteCount: downloads.bytesUsed, countStyle: .file))
                    Button("Remove all downloads", role: .destructive) { downloads.removeAll() }
                        .disabled(downloads.files.isEmpty)
                } header: {
                    Text("Downloads")
                } footer: {
                    Text("On Wi-Fi, each favorite's newest unplayed episodes download by themselves, up to the number set in the show's menu, also while the app is closed when iOS allows. Any episode can be downloaded with its arrow.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Toggle("Make transcripts for downloads", isOn: $transcripts.auto)
                    if !transcripts.note.isEmpty {
                        Text(transcripts.note).font(.footnote).foregroundStyle(Theme.muted)
                    }
                } header: {
                    Text("Transcripts")
                } footer: {
                    Text("Made on this iPhone with Apple's speech recognition (iOS 26), free and with nothing sent to the cloud, then saved to Dropbox so the web app has them too.")
                }
                .listRowBackground(Theme.surface)

                Section {
                    Picker("Skip back", selection: prefBinding(library.skipBack, "skipBack")) {
                        ForEach([5, 10, 15, 20, 30, 45, 60], id: \.self) { Text("\($0) sec").tag(Double($0)) }
                    }
                    Picker("Skip forward", selection: prefBinding(library.skipFwd, "skipFwd")) {
                        ForEach([10, 15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) sec").tag(Double($0)) }
                    }
                    Toggle("Play the next one when an episode ends", isOn: prefBinding(library.autoNext, "autoNext"))
                    Toggle("Skip ads marked in chapters", isOn: prefBinding(library.adSkip, "adSkip"))
                    Toggle("Trim long pauses", isOn: prefBinding(library.trim, "trim"))
                    if library.trim {
                        Picker("Pauses longer than", selection: prefBinding(library.trimMin, "trimMin")) {
                            ForEach([0.75, 1, 1.5, 2, 3], id: \.self) { v in Text("\(v.formatted()) sec").tag(v) }
                        }
                    }
                } header: {
                    Text("Playback")
                } footer: {
                    Text("Shared with the web app through Dropbox. The next episode comes from the subject you started in, or else the same show. On the iPhone, pauses are found from the episode's transcript, so trimming works on episodes that have one.")
                }
                .listRowBackground(Theme.surface)
                .disabled(!dropbox.signedIn || library.busy)

                Section {
                    LabeledContent("Version", value: "0.9.1")
                }
                .listRowBackground(Theme.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .toolbarBackground(Theme.bg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func signIn() async {
        working = true
        defer { working = false }
        do {
            let url = try await webAuth.authenticate(using: dropbox.authURL(redirect: true),
                                                     callbackURLScheme: Dropbox.scheme)
            try await dropbox.finish(callback: url)
            message = "Signed in."
            await library.refresh()
        } catch {
            message = "Sign-in didn't finish (\(error.localizedDescription)). If Dropbox showed an error, try Sign in with a code instead."
        }
    }

    private func useCode() async {
        working = true
        defer { working = false }
        do {
            try await dropbox.finish(pastedCode: code)
            code = ""
            codeMode = false
            message = "Signed in."
            await library.refresh()
        } catch {
            message = "That code didn't work (\(error.localizedDescription)). Tap Sign in with a code instead to get a fresh one."
        }
    }
}
