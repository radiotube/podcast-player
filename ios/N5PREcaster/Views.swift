import SwiftUI
import AuthenticationServices

// MARK: Home

struct ContentView: View {
    @EnvironmentObject var dropbox: Dropbox
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @State private var pick = "Favorites"
    @State private var showSettings = false

    private var choices: [String] { ["Favorites"] + library.subjects + ["All shows"] }

    private var list: [Show] {
        if pick == "Favorites" { return library.favShows }
        if pick == "All shows" || !library.subjects.contains(pick) { return library.allShows }
        return library.showsIn(pick)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(choices, id: \.self) { c in
                                Button(c) { pick = c }
                                    .buttonStyle(.bordered)
                                    .tint(pick == c ? Color.accentColor : Color.gray)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                    }
                    .listRowInsets(EdgeInsets())
                }
                if !library.status.isEmpty {
                    Section {
                        Text(library.status).font(.footnote).foregroundStyle(.secondary)
                        if !dropbox.signedIn {
                            Button("Open Settings") { showSettings = true }
                        }
                    }
                }
                Section {
                    ForEach(list) { show in
                        NavigationLink(value: show) { ShowRow(show: show) }
                    }
                } footer: {
                    if list.isEmpty && library.status.isEmpty {
                        Text(library.busy ? "Getting your list from Dropbox…" : "No shows here yet.")
                    }
                }
            }
            .navigationTitle("N5PREcaster")
            .navigationDestination(for: Show.self) { ShowView(show: $0) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                        .accessibilityLabel("Settings")
                }
            }
            .refreshable { await library.refresh() }
        }
        .safeAreaInset(edge: .bottom) {
            if player.now != nil { MiniPlayer() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(dropbox)
                .environmentObject(library)
        }
        .sheet(isPresented: $player.showFull) {
            PlayerView().environmentObject(player)
        }
        .task { await library.refresh(force: false) }
    }
}

struct ShowRow: View {
    let show: Show
    var body: some View {
        HStack(spacing: 12) {
            ArtView(url: show.art, size: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(show.title).font(.headline).lineLimit(2)
                if !show.author.isEmpty {
                    Text(show.author).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct ArtView: View {
    let url: String
    var size: CGFloat
    var body: some View {
        AsyncImage(url: URL(string: url)) { img in
            img.resizable().scaledToFill()
        } placeholder: {
            Color.gray.opacity(0.2)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.15))
    }
}

func skipSymbol(_ seconds: Double, forward: Bool) -> String {
    let base = forward ? "goforward" : "gobackward"
    let s = Int(seconds)
    return [5, 10, 15, 30, 45, 60, 75, 90].contains(s) ? "\(base).\(s)" : base
}

// MARK: Show

struct ShowView: View {
    let show: Show
    @EnvironmentObject var library: Library
    @State private var tab = 0

    private var episodes: [Episode] { library.episodes[show.id] ?? [] }
    private var shown: [Episode] { tab == 0 ? episodes.filter { !library.isPlayed($0.guid) } : episodes }

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    ArtView(url: show.art, size: 88)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.title).font(.title3.bold())
                        if !show.author.isEmpty {
                            Text(show.author).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Episodes", selection: $tab) {
                    Text("New to me").tag(0)
                    Text("Recent").tag(1)
                }
                .pickerStyle(.segmented)
            }
            if episodes.isEmpty, let err = library.feedErrors[show.id] {
                Section { Text("Couldn't load episodes: \(err)").foregroundStyle(.secondary) }
            }
            if episodes.isEmpty && library.loading.contains(show.id) {
                Section { ProgressView() }
            }
            Section {
                ForEach(shown) { ep in EpisodeRow(ep: ep, show: show) }
            } footer: {
                if tab == 0 && shown.isEmpty && !episodes.isEmpty {
                    Text("Nothing new. Recent lists every episode.")
                }
            }
        }
        .navigationTitle(show.title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await library.loadEpisodes(show) }
        .refreshable { await library.loadEpisodes(show, force: true) }
    }
}

struct EpisodeRow: View {
    let ep: Episode
    let show: Show
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player

    var body: some View {
        let played = library.isPlayed(ep.guid)
        Button {
            player.play(ep, show: show)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(ep.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(played ? Color.secondary : Color.primary)
                    .lineLimit(3)
                Text(detail(played: played)).font(.caption).foregroundStyle(.secondary)
                if !ep.summary.isEmpty {
                    Text(ep.summary).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
        }
        .swipeActions {
            Button(played ? "Not played" : "Played") { library.setPlayed(ep.guid, !played) }
                .tint(.blue)
        }
        .contextMenu {
            Button(played ? "Mark as not played" : "Mark as played") { library.setPlayed(ep.guid, !played) }
        }
    }

    private func detail(played: Bool) -> String {
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
        if player.now?.episode.guid == ep.guid { parts.append(player.isPlaying ? "Playing" : "Paused") }
        return parts.joined(separator: " · ")
    }
}

// MARK: Player

struct MiniPlayer: View {
    @EnvironmentObject var player: Player

    var body: some View {
        if let n = player.now {
            let chapter = player.currentChapter?.title ?? ""
            HStack(spacing: 12) {
                Group {
                    if let img = player.artwork {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else {
                        Color.gray.opacity(0.3)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(chapter.isEmpty ? n.episode.title : chapter)
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Text(n.showTitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                Button { player.skip(player.skipFwd) } label: {
                    Image(systemName: skipSymbol(player.skipFwd, forward: true)).font(.title3)
                }
                .accessibilityLabel("Skip forward")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial)
            .contentShape(Rectangle())
            .onTapGesture { player.showFull = true }
        }
    }
}

struct PlayerView: View {
    @EnvironmentObject var player: Player
    @State private var scrub: Double = 0
    @State private var scrubbing = false
    private let speeds: [Double] = [0.8, 1, 1.1, 1.2, 1.25, 1.3, 1.4, 1.5, 1.75, 2, 2.5, 3]

    private var shownTime: Double { scrubbing ? scrub : player.time }

    private func speedText(_ s: Double) -> String {
        String(format: s == s.rounded() ? "%.0f×" : (s * 10 == (s * 10).rounded() ? "%.1f×" : "%.2f×"), s)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let n = player.now {
                    VStack(spacing: 14) {
                        Group {
                            if let img = player.artwork {
                                Image(uiImage: img).resizable().scaledToFit()
                            } else {
                                Color.gray.opacity(0.2).aspectRatio(1, contentMode: .fit)
                            }
                        }
                        .frame(maxWidth: 300, maxHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                        if let ch = player.currentChapter, !ch.title.isEmpty {
                            Text(ch.title).font(.headline).multilineTextAlignment(.center)
                        }
                        Text(n.episode.title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center)
                        Text(n.showTitle).font(.subheadline).foregroundStyle(.secondary)

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
                        HStack {
                            Text(clock(shownTime))
                            Spacer()
                            Text("-" + clock(max(0, player.duration - shownTime)))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)

                        HStack(spacing: 26) {
                            Button { player.previousChapter() } label: { Image(systemName: "backward.end.fill").font(.title3) }
                                .disabled(player.chapters.isEmpty)
                                .accessibilityLabel("Previous chapter")
                            Button { player.skip(-player.skipBack) } label: {
                                Image(systemName: skipSymbol(player.skipBack, forward: false)).font(.title)
                            }
                            .accessibilityLabel("Skip back")
                            Button { player.toggle() } label: {
                                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.system(size: 64))
                            }
                            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")
                            Button { player.skip(player.skipFwd) } label: {
                                Image(systemName: skipSymbol(player.skipFwd, forward: true)).font(.title)
                            }
                            .accessibilityLabel("Skip forward")
                            Button { player.nextChapter() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                                .disabled(player.chapters.isEmpty)
                                .accessibilityLabel("Next chapter")
                        }
                        .buttonStyle(.plain)

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
                            Text("Speed " + speedText(player.rate))
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(Color.gray.opacity(0.2)))
                        }

                        if !player.errorText.isEmpty {
                            Text(player.errorText).font(.footnote).foregroundStyle(.red)
                        }

                        if !player.chapters.isEmpty {
                            ChapterList()
                        }
                    }
                    .padding()
                } else {
                    Text("Nothing playing").foregroundStyle(.secondary).padding(.top, 40)
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { player.showFull = false }
                }
            }
        }
    }
}

struct ChapterList: View {
    @EnvironmentObject var player: Player

    var body: some View {
        let current = player.currentChapterIndex
        VStack(alignment: .leading, spacing: 0) {
            Text("Chapters").font(.headline).padding(.bottom, 6)
            ForEach(Array(player.chapters.enumerated()), id: \.offset) { i, c in
                Button {
                    player.seek(c.start)
                    if !player.isPlaying { player.play() }
                } label: {
                    HStack(spacing: 10) {
                        if !c.img.isEmpty { ArtView(url: c.img, size: 36) }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title.isEmpty ? "Chapter \(i + 1)" : c.title)
                                .fontWeight(i == current ? Font.Weight.bold : Font.Weight.regular)
                                .multilineTextAlignment(.leading)
                            Text(clock(c.start)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        if i == current {
                            Image(systemName: "speaker.wave.2.fill").foregroundStyle(Color.accentColor)
                        }
                    }
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }
}

// MARK: Settings

struct SettingsView: View {
    @EnvironmentObject var dropbox: Dropbox
    @EnvironmentObject var library: Library
    @Environment(\.webAuthenticationSession) private var webAuth
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var codeMode = false
    @State private var code = ""
    @State private var working = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if dropbox.signedIn {
                        Label("Signed in to Dropbox", systemImage: "checkmark.circle.fill")
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
                        Text(message).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Dropbox")
                } footer: {
                    Text("This app reads the list the web app keeps in your Dropbox. It never changes that list.")
                }

                Section("Your list") {
                    LabeledContent("Shows", value: "\(library.shows.count)")
                    LabeledContent("Subjects", value: "\(library.subjects.count)")
                    LabeledContent("Favorites", value: "\(library.fav.count)")
                    if !library.savedBy.isEmpty {
                        LabeledContent("Saved to Dropbox by", value: library.savedBy)
                    }
                    if !library.status.isEmpty {
                        Text(library.status).font(.footnote).foregroundStyle(.secondary)
                    }
                }

                Section("Playback") {
                    LabeledContent("Skip back", value: "\(Int(library.skipBack)) seconds")
                    LabeledContent("Skip forward", value: "\(Int(library.skipFwd)) seconds")
                }

                Section {
                    LabeledContent("Version", value: "0.1, first native build")
                }
            }
            .navigationTitle("Settings")
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
