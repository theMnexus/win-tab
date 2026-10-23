import AppKit
import QuickLookThumbnailing
import SwiftUI

/// QuickLook thumbnails for the Files tab: made at twice the tile size, at most 50 kept.
@MainActor
final class FileThumbnails: ObservableObject {
    static let shared = FileThumbnails()
    private let cache = NSCache<NSURL, NSImage>()
    private var pending = Set<URL>()
    @Published private(set) var version = 0
    private static let side: CGFloat = 36

    private init() { cache.countLimit = 50 }

    func image(for url: URL) -> NSImage {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        request(url)
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private func request(_ url: URL) {
        guard !pending.contains(url) else { return }
        pending.insert(url)
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: Self.side, height: Self.side), scale: 2,
                                                   representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
            let image = rep?.nsImage
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.pending.remove(url)
                    guard let image else { return }
                    self.cache.setObject(image, forKey: url as NSURL)
                    self.version += 1
                }
            }
        }
    }
}

/// The notch's Files tab, in cards: the files (select some, or act on all), the actions that fit
/// them grouped as Convert / Optimize / Organize, and the jobs running or done.
struct NotchFilesView: View {
    @ObservedObject var state: NotchState
    @ObservedObject private var shelf = FileShelf.shared
    @ObservedObject private var queue = FileJobQueue.shared
    @ObservedObject private var thumbnails = FileThumbnails.shared
    @ObservedObject private var heights = NotchTabHeights.shared
    @State private var selection = Set<URL>()
    @State private var renaming = false
    @State private var pattern = RenamePattern()
    @State private var lastRename: [RenameStep] = []
    @FocusState private var nameFocused: Bool

    /// Selected files, or all when none are selected.
    private var targets: [URL] {
        let picked = shelf.urls.filter(selection.contains)
        return picked.isEmpty ? shelf.urls : picked
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = shelf.notice { noticeBanner(notice) }
            if shelf.urls.isEmpty {
                dropZone
            } else {
                HStack(alignment: .top, spacing: 8) {
                    filesCard.frame(width: 184)
                    if renaming { renameCard } else { actionsCard }
                }
                .frame(maxHeight: .infinity)
                if !queue.jobs.isEmpty { jobsCard }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay {
            if state.dropTargeted && !shelf.urls.isEmpty { dropOverlay.transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.15), value: state.dropTargeted)
        .overlay(alignment: .bottom) {
            NotchResizeHandle(state: state, extra: $heights.files, maxExtra: NotchTabHeights.maxExtra,
                              defaultExtra: NotchTabHeights.filesDefault).offset(y: 12)
        }
        .onChange(of: shelf.urls) { _, urls in selection = selection.intersection(urls) }
    }

    // MARK: - Drop zone

    /// "Drop to add 3 files", over the cards while files are dragged onto the island.
    private var dropOverlay: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.blue.opacity(0.16))
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.black.opacity(0.55)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.blue, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .overlay {
                Label(dropTitle, systemImage: "plus.circle.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .allowsHitTesting(false)
    }

    private var dropTitle: String {
        state.dropCount > 0 ? "Drop to add \(state.dropCount) file\(state.dropCount == 1 ? "" : "s")" : "Drop to add"
    }

    private var dropZone: some View {
        let targeted = state.dropTargeted
        return VStack(spacing: 10) {
            Image(systemName: targeted ? "plus.circle.fill" : "tray.and.arrow.down.fill").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.blue.opacity(targeted ? 0.3 : 0.16)))
                .scaleEffect(targeted ? 1.12 : 1)
            VStack(spacing: 3) {
                Text(targeted ? dropTitle : "Drop files here").font(.system(size: 13, weight: .semibold))
                Text("or press ⌃⌥D with files selected in Finder").font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
            }
            HStack(spacing: 5) {
                ForEach(Self.features, id: \.title) { f in
                    HStack(spacing: 3) {
                        Image(systemName: f.symbol).foregroundStyle(f.tint)
                        Text(f.title)
                    }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 7).frame(height: 18)
                    .background(Capsule().fill(Color.white.opacity(0.05)))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(targeted ? Color.blue.opacity(0.12) : NotchInk.card))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(targeted ? Color.blue : .white.opacity(0.2), style: StrokeStyle(lineWidth: targeted ? 1.5 : 1.2, dash: [6, 5])))
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: targeted)
    }

    private static let features: [(title: String, symbol: String, tint: Color)] = [
        ("Convert", "arrow.triangle.2.circlepath", .blue), ("Compress", "arrow.down.right.and.arrow.up.left", .green),
        ("Resize", "aspectratio", .green), ("PDF", "doc.richtext", .blue), ("Zip", "doc.zipper", .orange),
        ("Rename", "character.cursor.ibeam", .orange),
    ]

    // MARK: - Files

    private var filesCard: some View {
        NotchCard(grows: true) {
            NotchCardHeader(title: "Files", symbol: "tray.full.fill",
                            detail: selection.isEmpty ? "\(shelf.urls.count)" : "\(selection.count) of \(shelf.urls.count)") {
                if selection.isEmpty {
                    NotchChip(title: "Clear", quiet: true, help: "Remove all from Files (the files stay where they are)") {
                        withAnimation(.easeOut(duration: 0.2)) { shelf.clear() }
                    }
                } else {
                    NotchChip(title: "Remove", quiet: true, help: "Remove the selected files from Files (they stay where they are)") {
                        withAnimation(.easeOut(duration: 0.2)) { shelf.remove(selection); selection = [] }
                    }
                }
                more
            }
            ScrollView(.vertical, showsIndicators: false) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 52, maximum: 64), spacing: 6)], spacing: 6) {
                    ForEach(shelf.urls, id: \.self) { url in
                        FileTile(url: url, image: thumbnails.image(for: url), picked: selection.contains(url)) {
                            if selection.contains(url) { selection.remove(url) } else { selection.insert(url) }
                        } remove: {
                            withAnimation(.easeOut(duration: 0.2)) { shelf.remove(url) }
                        }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                    }
                }
            }
        }
    }

    private var more: some View {
        Menu {
            Button("Select all") { selection = Set(shelf.urls) }
            Button("Select none") { selection = [] }
            if !lastRename.isEmpty {
                Divider()
                Button("Undo last rename") { undoRename() }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .bold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Select all or none, undo a rename")
    }

    // MARK: - Actions

    private var actionsCard: some View {
        let files = targets
        let kinds = Set(files.map(FileKind.of))
        let only = kinds.count == 1 ? kinds.first : nil
        let groups = Self.groups(for: only, count: files.count)
        return NotchCard(grows: true) {
            NotchCardHeader(title: "Actions", symbol: "wand.and.stars", tint: .purple,
                            detail: "for " + Self.describe(files.count, only, all: selection.isEmpty))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(groups, id: \.title) { group in
                        HStack(spacing: 5) {
                            Label { Text(group.title) } icon: { Image(systemName: group.symbol).foregroundStyle(group.tint) }
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: 72, alignment: .leading)
                            ForEach(group.actions, id: \.title) { chip($0, files) }
                            Spacer(minLength: 0)
                        }
                    }
                    if only == nil {
                        Text("Pick files of one kind to convert or optimize them.")
                            .font(.system(size: 10)).foregroundStyle(.white.opacity(0.4))
                    }
                }
            }
        }
    }

    private struct Action {
        enum Kind { case run(FileOperation), menu([(String, FileOperation)]), rename }
        let title: String
        var symbol: String?
        let kind: Kind
    }

    private struct ActionGroup {
        let title: String
        let symbol: String
        let tint: Color
        let actions: [Action]
    }

    /// What fits `kind` (nil: mixed kinds, so only Organize), in three groups; empty groups left out.
    private static func groups(for kind: FileKind?, count: Int) -> [ActionGroup] {
        var convert: [Action] = [], optimize: [Action] = [], organize: [Action] = []
        switch kind {
        case .image:
            convert = [Action(title: "Format", kind: .menu(ImageFormat.allCases.map { ($0.label, .convertImage($0)) })),
                       Action(title: "One PDF", symbol: "doc.richtext", kind: .run(.imagesToPDF))]
            optimize = [Action(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", kind: .run(.compressImage)),
                        Action(title: "Resize", kind: .menu(FileOperation.resizeEdges.map { ("\($0) px", .resizeImage(maxEdge: $0)) })),
                        Action(title: "Strip info", symbol: "eye.slash", kind: .run(.stripMetadata))]
        case .video:
            convert = [Action(title: "Format", kind: .menu(VideoContainer.allCases.map { ($0.label, .convertVideo($0)) })),
                       Action(title: "Audio only", symbol: "waveform", kind: .run(.toAudio))]
            optimize = [Action(title: "Compress", kind: .menu(VideoPreset.allCases.map { ($0.label, .compressVideo($0)) }))]
        case .audio:
            convert = [Action(title: "To M4A", symbol: "music.note", kind: .run(.toAudio))]
        case .pdf:
            convert = [Action(title: "To images", symbol: "photo.on.rectangle", kind: .run(.pdfToImages))]
            optimize = [Action(title: "Compress", symbol: "arrow.down.right.and.arrow.up.left", kind: .run(.compressPDF))]
            if count > 1 { organize.append(Action(title: "Merge", symbol: "doc.on.doc", kind: .run(.mergePDFs))) }
        case .archive:
            organize.append(Action(title: "Unzip", symbol: "shippingbox", kind: .run(.unzip)))
        default:
            break
        }
        organize += [Action(title: "Zip", symbol: "doc.zipper", kind: .run(.zip)),
                     Action(title: "Rename", symbol: "character.cursor.ibeam", kind: .rename)]
        return [ActionGroup(title: "Convert", symbol: "arrow.triangle.2.circlepath", tint: .blue, actions: convert),
                ActionGroup(title: "Optimize", symbol: "gauge.with.dots.needle.33percent", tint: .green, actions: optimize),
                ActionGroup(title: "Organize", symbol: "folder.fill", tint: .orange, actions: organize)]
            .filter { !$0.actions.isEmpty }
    }

    /// "all 3 images", "2 PDFs", "1 file".
    private static func describe(_ count: Int, _ kind: FileKind?, all: Bool) -> String {
        let noun: String
        switch kind {
        case .image: noun = "image"
        case .video: noun = "video"
        case .audio: noun = "audio file"
        case .pdf: noun = "PDF"
        case .archive: noun = "archive"
        default: noun = "file"
        }
        return (all && count > 1 ? "all " : "") + "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    @ViewBuilder private func chip(_ action: Action, _ files: [URL]) -> some View {
        switch action.kind {
        case .run(let op):
            NotchChip(title: action.title, symbol: action.symbol) { queue.enqueue(op, files: files) }
        case .menu(let items):
            NotchMenuChip(title: action.title) {
                ForEach(items.indices, id: \.self) { i in
                    Button(items[i].0) { queue.enqueue(items[i].1, files: files) }
                }
            }
        case .rename:
            NotchChip(title: action.title, symbol: action.symbol) { startRename() }
        }
    }

    // MARK: - Rename

    private var renameCard: some View {
        let files = targets
        let preview = ArchiveTool.renamePreview(files, pattern: pattern)
        return NotchCard(grows: true) {
            NotchCardHeader(title: "Rename", symbol: "character.cursor.ibeam", tint: .orange,
                            detail: Self.describe(files.count, nil, all: selection.isEmpty))
            HStack(spacing: 5) {
                field("New name (blank keeps it)", $pattern.newName).focused($nameFocused)
                field("ext", $pattern.newExtension, width: 52)
            }
            HStack(spacing: 5) {
                field("Find", $pattern.find)
                Image(systemName: "arrow.right").font(.system(size: 8, weight: .bold)).foregroundStyle(.white.opacity(0.4))
                field("Replace with", $pattern.replace)
            }
            HStack(spacing: 5) {
                Text(preview.first.map { "→ " + $0.to.lastPathComponent + (preview.count > 1 ? "  +\(preview.count - 1) more" : "") }
                     ?? "Type a name, or find and replace")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.55)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                NotchChip(title: "Cancel", quiet: true) { endRename() }
                NotchChip(title: "Rename", prominent: true) { applyRename(preview) }.disabled(preview.isEmpty)
            }
        }
        .onExitCommand { endRename() }
    }

    private func field(_ title: String, _ text: Binding<String>, width: CGFloat? = nil) -> some View {
        TextField(title, text: text)
            .textFieldStyle(.plain).font(.system(size: 10.5))
            .padding(.horizontal, 7)
            .frame(maxWidth: width ?? .infinity)
            .frame(width: width, height: 22)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.09)))
    }

    private func startRename() {
        pattern = RenamePattern()
        renaming = true
        state.replying = true
        // The panel becomes key on the next turn; focus after that.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true }
    }

    private func endRename() {
        renaming = false
        nameFocused = false
        if state.replying { state.replying = false }
    }

    private func applyRename(_ preview: [RenameStep]) {
        do {
            let applied = try ArchiveTool.rename(preview)
            applied.forEach { shelf.replace($0.from, with: $0.to) }
            selection = Set(selection.map { url in applied.first { $0.from == url }?.to ?? url })
            lastRename = applied
            shelf.notice = applied.isEmpty ? nil : "Renamed \(applied.count) · Undo is in the ⋯ menu"
            endRename()
        } catch {
            shelf.notice = FileToolError.from(error).errorDescription
        }
    }

    private func undoRename() {
        do {
            try ArchiveTool.undo(lastRename)
            lastRename.forEach { shelf.replace($0.to, with: $0.from) }
            lastRename = []
            shelf.notice = nil
        } catch {
            shelf.notice = FileToolError.from(error).errorDescription
        }
    }

    // MARK: - Jobs and notices

    private var jobsCard: some View {
        let running = queue.jobs.filter { !$0.state.isFinished }.count
        return NotchCard {
            NotchCardHeader(title: "Jobs", symbol: "gearshape.2.fill", tint: .green,
                            detail: running > 0 ? "\(running) running" : "all done") {
                if queue.jobs.contains(where: { $0.state.isFinished }) {
                    NotchChip(title: "Clear", quiet: true, help: "Clear finished jobs") { queue.clearFinished() }
                }
            }
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 3) {
                    ForEach(queue.jobs.reversed()) { JobRow(job: $0) }
                }
            }
            // Newest first, and kept in view as jobs are added or finish.
            .defaultScrollAnchor(.top)
            .frame(height: min(CGFloat(queue.jobs.count), 2.5) * 23)
        }
    }

    private func noticeBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
            Text(text).lineLimit(1)
            if text.contains("Automation") {
                Button("Open") { NSWorkspace.shared.open(NowPlayingMonitor.automationSettings) }.buttonStyle(.plain).underline()
            }
            Spacer(minLength: 0)
            Button { shelf.notice = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain).help("Dismiss")
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(.orange)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.13)))
    }
}

/// One file: thumbnail and name; click to select, double-click to open, drag out to use it,
/// × (on hover) to take it off the list.
private struct FileTile: View {
    let url: URL
    let image: NSImage
    let picked: Bool
    let toggle: () -> Void
    let remove: () -> Void
    @State private var hovering = false

    /// Corner buttons sit in a strip above the thumbnail, inside the tile: nothing overlaps the
    /// preview and nothing is cut off by the scroll view's edge.
    var body: some View {
        VStack(spacing: 3) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 28, height: 28)
            Text(url.lastPathComponent).font(.system(size: 8.5, weight: .medium)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(.white.opacity(picked ? 1 : 0.85))
        }
        .padding(.top, 16)
        .padding(.bottom, 5)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.white.opacity(picked ? 0.16 : hovering ? 0.09 : 0.05)))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(picked ? 0.9 : 0), lineWidth: 1.5))
        .overlay(alignment: .top) {
            HStack(spacing: 0) {
                if hovering {
                    Button(action: remove) {
                        Image(systemName: "xmark").font(.system(size: 6.5, weight: .heavy))
                            .frame(width: 13, height: 13)
                            .background(Circle().fill(Color(white: 0.28)))
                            .contentShape(Circle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .help("Remove from Files (the file stays where it is)")
                    .transition(.opacity)
                }
                Spacer(minLength: 0)
                if picked || hovering {
                    Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 11)).foregroundStyle(picked ? Color.accentColor : .white.opacity(0.45))
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, 3)
            .padding(.top, 3)
        }
        .contentShape(Rectangle())
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .onTapGesture(perform: toggle)
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help("\(url.path)\nClick to select · double-click to open · drag out to use")
    }
}

/// One job: what, on which file, then progress, the size change or the error.
private struct JobRow: View {
    let job: FileJobQueue.Job

    var body: some View {
        HStack(spacing: 6) {
            icon.frame(width: 14)
            Text(job.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1).truncationMode(.middle).frame(maxWidth: 170, alignment: .leading)
            Text(job.operation.title).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
            Spacer(minLength: 4)
            status
        }
        .frame(height: 20)
        .padding(.horizontal, 7)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    @ViewBuilder private var icon: some View {
        switch job.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.white.opacity(0.5))
        case .running: ProgressView().controlSize(.mini)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.white.opacity(0.5))
        }
    }

    @ViewBuilder private var status: some View {
        switch job.state {
        case .waiting, .running:
            ProgressView(value: Self.fraction(job.state)).progressViewStyle(.linear).frame(width: 90)
            Button { FileJobQueue.shared.cancel(job.id) } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.6)).help("Cancel")
        case .done(let outcome):
            Text(Self.change(outcome)).font(.system(size: 10.5, weight: .semibold, design: .rounded)).monospacedDigit()
            Button { NSWorkspace.shared.activateFileViewerSelecting(outcome.outputs) } label: { Image(systemName: "magnifyingglass") }
                .buttonStyle(.plain).foregroundStyle(.white.opacity(0.7)).help("Show in Finder")
        case .failed(let message):
            Text(message).font(.system(size: 10)).foregroundStyle(.orange).lineLimit(1)
        case .cancelled:
            Text("Cancelled").font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
        }
    }

    static func fraction(_ state: FileJobQueue.State) -> Double {
        if case .running(let p) = state { return p }
        return 0
    }

    /// "2.4 MB → 640 KB (−73%)".
    static func change(_ o: FileOutcome) -> String {
        let f = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        guard o.bytesBefore > 0 else { return f(o.bytesAfter) }
        let pct = Int((Double(o.bytesAfter - o.bytesBefore) / Double(o.bytesBefore) * 100).rounded())
        return "\(f(o.bytesBefore)) → \(f(o.bytesAfter)) (\(pct > 0 ? "+" : "")\(pct)%)"
    }
}
