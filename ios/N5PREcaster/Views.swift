import SwiftUI
import AuthenticationServices

// MARK: Home

struct ContentView: View {
    @EnvironmentObject var dropbox: Dropbox
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player
    @State private var filter = ""
    @State private var showSettings = false

    private func inFilter(_ show: Show) -> Bool {
        filter.isEmpty || show.cats.contains(filter)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if !library.subjects.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Chip(title: "All", on: filter.isEmpty) { filter = "" }
                                ForEach(library.subjects, id: \.self) { c in
                                    Chip(title: c, on: filter == c) { filter = c }
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

                    let favs = library.favShows.filter(inFilter)
                    if !favs.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            SectionLabel("Favorites")
                            ForEach(favs) { show in
                                FavCard(rank: (library.fav.firstIndex(of: show.id) ?? 0) + 1, show: show)
                            }
                        }
                    }

                    let others = library.allShows.filter { !library.fav.contains($0.id) && inFilter($0) }
                    if !others.isEmpty {
                        VStack(alignment: .leading, spacing: 0) {
                            SectionLabel(filter.isEmpty ? "All shows" : filter).padding(.bottom, 4)
                            ForEach(others) { show in
                                NavigationLink(value: show) { ShowRow(show: show) }
                                    .buttonStyle(.plain)
                                Rectangle().fill(Theme.line).frame(height: 1)
                            }
                        }
                    }

                    if favs.isEmpty && others.isEmpty && library.status.isEmpty {
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Settings")
                }
            }
            .refreshable { await library.refresh() }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if player.now != nil { MiniPlayer() }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(dropbox)
                .environmentObject(library)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .sheet(isPresented: $player.showFull) {
            PlayerView()
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .task { await library.refresh(force: false) }
    }
}

struct FavCard: View {
    let rank: Int
    let show: Show
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player

    var body: some View {
        let latest = library.latestUnheard(show)
        let loaded = library.episodes[show.id] != nil
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
                            } else if loaded {
                                Text("All caught up")
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
    let show: Show
    @EnvironmentObject var library: Library
    @State private var tab = 0

    private var episodes: [Episode] { library.episodes[show.id] ?? [] }
    private var shown: [Episode] { tab == 0 ? episodes.filter { !library.isPlayed($0.guid) } : episodes }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .bottom, spacing: 16) {
                    ArtView(url: show.art, size: 120, radius: 14)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(show.title)
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(Theme.fg)
                        if !show.author.isEmpty {
                            Text(show.author).font(.system(size: 14)).foregroundStyle(Theme.muted)
                        }
                    }
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
    }
}

struct EpisodeRow: View {
    let ep: Episode
    let show: Show
    @EnvironmentObject var library: Library
    @EnvironmentObject var player: Player

    var body: some View {
        let played = library.isPlayed(ep.guid)
        let current = player.now?.episode.guid == ep.guid
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(detail(played: played, current: current))
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(current ? Theme.accent : Theme.muted)
                Text(ep.title)
                    .font(.system(size: 16, weight: played ? Font.Weight.medium : Font.Weight.semibold))
                    .foregroundStyle(played ? Theme.muted : Theme.fg)
                    .lineLimit(3)
                if !ep.summary.isEmpty {
                    Text(ep.summary)
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            Button {
                if current { player.toggle() } else { player.play(ep, show: show) }
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
        if current { parts.append(player.isPlaying ? "Playing" : "Paused") }
        return parts.joined(separator: " · ")
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
                        Text(message).font(.footnote).foregroundStyle(Theme.muted)
                    }
                } header: {
                    Text("Dropbox")
                } footer: {
                    Text("This app reads the list the web app keeps in your Dropbox. It never changes that list.")
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
                }
                .listRowBackground(Theme.surface)

                Section("Playback") {
                    LabeledContent("Skip back", value: "\(Int(library.skipBack)) seconds")
                    LabeledContent("Skip forward", value: "\(Int(library.skipFwd)) seconds")
                }
                .listRowBackground(Theme.surface)

                Section {
                    LabeledContent("Version", value: "0.2, first native build")
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
