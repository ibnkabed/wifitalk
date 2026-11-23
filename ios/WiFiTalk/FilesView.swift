import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The transfer folder, browsed from the phone.
///
/// Everything here is one folder on the computer and whatever the user has
/// dropped inside it. The phone asks for paths relative to that folder and
/// never for anything else, so the worst a bug here can reach is the folder
/// itself.
@MainActor
final class FileBrowser: ObservableObject {
    @Published private(set) var listing: RemoteFileListing?
    @Published private(set) var isLoading = false
    @Published private(set) var message = ""
    @Published private(set) var isError = false
    /// The share sheet opens on this the moment a download finishes.
    @Published var downloaded: URL?
    /// `nil` when nothing is moving; otherwise the label and how far it is.
    @Published private(set) var transfer: (label: String, fraction: Double)?

    private var model: AppModel?

    /// Takes the companion the rest of the app is already paired with, and
    /// shows the top of the folder.
    func start(with model: AppModel) async {
        self.model = model
        await load("")
    }

    var path: String { listing?.path ?? "" }
    var entries: [RemoteFile] { listing?.entries ?? [] }
    var folderName: String {
        let current = path
        if current.isEmpty { return "مجلد الإرسال" }
        return current.split(separator: "/").last.map(String.init) ?? current
    }
    var canGoUp: Bool { !path.isEmpty }

    func load(_ relative: String? = nil, quietly: Bool = false) async {
        guard let model else { return }
        let target = relative ?? path
        if !quietly { isLoading = true }
        defer { isLoading = false }
        do {
            listing = try await model.transferClient().listFiles(target)
            if !quietly { report("") }
        } catch {
            report(error.localizedDescription, failed: true)
        }
    }

    func open(_ entry: RemoteFile) async {
        guard entry.isDirectory else { return }
        await load(entry.path)
    }

    func goUp() async {
        await load(listing?.parent ?? "")
    }

    /// Brings one file down and hands it to the share sheet, which is where
    /// iOS lets it be saved into Files or the photo library.
    func download(_ entry: RemoteFile) async {
        guard let model, !entry.isDirectory else { return }
        transfer = (label: "جلب \(entry.name)", fraction: 0)
        defer { transfer = nil }
        do {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("WiFiTalkDownloads", isDirectory: true)
            let url = try await model.transferClient().downloadFile(
                entry, into: directory
            ) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, let current = self.transfer else { return }
                    self.transfer = (label: current.label, fraction: fraction)
                }
            }
            downloaded = url
            report("جاهز: \(entry.name)")
        } catch {
            report(error.localizedDescription, failed: true)
        }
    }

    /// Sends one file into the folder that is open right now.
    func send(_ url: URL, name: String, securityScoped: Bool = false) async {
        guard let model else { return }
        let opened = securityScoped && url.startAccessingSecurityScopedResource()
        defer { if opened { url.stopAccessingSecurityScopedResource() } }
        transfer = (label: "إرسال \(name)", fraction: 0)
        defer { transfer = nil }
        do {
            let result = try await model.transferClient().uploadFile(
                at: url, name: name, subpath: path
            ) { [weak self] fraction in
                Task { @MainActor in
                    guard let self, let current = self.transfer else { return }
                    self.transfer = (label: current.label, fraction: fraction)
                }
            }
            await load(quietly: true)
            report("وصل إلى الكمبيوتر: \(result.name)")
        } catch {
            report(error.localizedDescription, failed: true)
        }
    }

    /// Photos and camera shots arrive as bytes with no name of their own, so
    /// they are written out once under a stamped name and sent from there.
    func send(data: Data, name: String) async {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            report(error.localizedDescription, failed: true)
            return
        }
        await send(url, name: name)
        try? FileManager.default.removeItem(at: url)
    }

    private func report(_ text: String, failed: Bool = false) {
        message = text
        isError = failed
    }
}

/// A name no two shots can share, and one Windows is happy to hold.
func stampedName(prefix: String, extension suffix: String) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return "\(prefix)-\(formatter.string(from: Date())).\(suffix)"
}

struct FilesView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = FileBrowser()
    @State private var showFileImporter = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showPhotoPicker = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color(red: 0.027, green: 0.043, blue: 0.071).ignoresSafeArea()
                VStack(spacing: 0) {
                    pathBar
                    if let transfer = browser.transfer {
                        VStack(spacing: 4) {
                            Text(transfer.label)
                                .font(.caption2)
                                .lineLimit(1)
                            ProgressView(value: transfer.fraction)
                                .tint(.cyan)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                    }
                    listBody
                    if !browser.message.isEmpty {
                        Text(browser.message)
                            .font(.caption2)
                            .foregroundStyle(browser.isError ? .red : .secondary)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    sendBar
                }
            }
            .navigationTitle("نقل الملفات")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("تم") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await browser.load() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task { await browser.start(with: model) }
        .fileImporter(
            isPresented: $showFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task {
                    for url in urls {
                        await browser.send(
                            url, name: url.lastPathComponent, securityScoped: true
                        )
                    }
                }
            case .failure:
                break
            }
        }
        .photosPicker(
            isPresented: $showPhotoPicker,
            selection: $photoItems,
            maxSelectionCount: 10,
            matching: .any(of: [.images, .videos])
        )
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            Task { await sendPicked(items) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { data in
                Task { await browser.send(data: data, name: stampedName(prefix: "photo", extension: "jpg")) }
            }
            .ignoresSafeArea()
        }
        .sheet(item: Binding(
            get: { browser.downloaded.map(SharedFile.init) },
            set: { if $0 == nil { browser.downloaded = nil } }
        )) { shared in
            ShareSheet(url: shared.url)
        }
    }

    private var pathBar: some View {
        HStack(spacing: 8) {
            Button {
                Task { await browser.goUp() }
            } label: {
                Image(systemName: "chevron.up")
                    .font(.caption.bold())
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(browser.canGoUp ? Color.cyan : Color.secondary)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            .disabled(!browser.canGoUp)

            Image(systemName: "folder.fill").foregroundStyle(.cyan)
            Text(browser.folderName)
                .font(.subheadline.bold())
                .lineLimit(1)
            Spacer()
            if browser.isLoading { ProgressView().controlSize(.small) }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var listBody: some View {
        if browser.entries.isEmpty && !browser.isLoading {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 44))
                    .foregroundStyle(.secondary)
                Text("لا شيء هنا بعد")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("الصق أي ملف في مجلد الإرسال على الكمبيوتر، أو أرسل من الجوال بالزر بالأسفل.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
                Spacer()
            }
        } else {
            List {
                ForEach(browser.entries) { entry in
                    Button {
                        Task {
                            if entry.isDirectory {
                                await browser.open(entry)
                            } else {
                                await browser.download(entry)
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: entry.icon)
                                .foregroundStyle(entry.isDirectory ? Color.cyan : Color.secondary)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text("\(entry.sizeLabel) · \(entry.modifiedLabel)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: entry.isDirectory
                                ? "chevron.left"
                                : "arrow.down.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Color(red: 0.055, green: 0.098, blue: 0.17))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .refreshable { await browser.load() }
        }
    }

    /// The three ways in, as three buttons rather than one menu: a menu would
    /// hide the camera behind a press and a read.
    private var sendBar: some View {
        HStack(spacing: 8) {
            SendButton(title: "ملف", icon: "doc") { showFileImporter = true }
            SendButton(title: "من الاستوديو", icon: "photo.on.rectangle") {
                showPhotoPicker = true
            }
            SendButton(title: "التقاط صورة", icon: "camera") { showCamera = true }
                .disabled(!UIImagePickerController.isSourceTypeAvailable(.camera))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    private func sendPicked(_ items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let type = item.supportedContentTypes.first
            let isVideo = type?.conforms(to: .movie) == true
            let suffix = type?.preferredFilenameExtension ?? (isVideo ? "mov" : "jpg")
            await browser.send(
                data: data,
                name: stampedName(prefix: isVideo ? "video" : "photo", extension: suffix)
            )
        }
    }
}

private struct SendButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.caption2.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 42)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color(red: 0.68, green: 0.77, blue: 0.88))
        .background(Color(red: 0.055, green: 0.098, blue: 0.17), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.1)))
    }
}

/// `sheet(item:)` needs something identifiable; a URL is not.
private struct SharedFile: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Shared with the command button, which can hand over several files at once.
struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]

    init(url: URL) { self.urls = [url] }
    init(urls: [URL]) { self.urls = urls }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// The camera, handed back as JPEG bytes.
private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onFinish: { dismiss() })
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (Data) -> Void
        private let onFinish: () -> Void

        init(onCapture: @escaping (Data) -> Void, onFinish: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onFinish = onFinish
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage,
               let data = image.jpegData(compressionQuality: 0.9) {
                onCapture(data)
            }
            onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish()
        }
    }
}
