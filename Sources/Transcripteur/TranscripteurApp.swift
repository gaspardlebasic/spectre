import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Trace de diagnostic : le journal unifié masque les chaînes interpolées.
func trace(_ message: String) {
    guard ProcessInfo.processInfo.environment["TRANSCRIPTEUR_TRACE"] != nil else { return }
    let line = "\(Date()) \(message)\n"
    if let data = line.data(using: .utf8) {
        let path = "/tmp/transcripteur.log"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}

/// Ouverture depuis le Finder (double-clic, glisser sur l'icône, `open -a`).
/// Le fichier peut arriver avant que la vue existe : on le met alors de côté.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    static var pending: URL?

    func application(_ application: NSApplication, open urls: [URL]) {
        trace("délégué open : \(urls)")
        guard let url = urls.first else { return }
        deliver(url)
    }

    /// Ancienne API, encore celle qu'emprunte `open -a` sur certaines versions.
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        trace("délégué openFile : \(filename)")
        deliver(URL(fileURLWithPath: filename))
        return true
    }

    private func deliver(_ url: URL) {
        if let model = AppDelegate.model {
            model.open(url)
        } else {
            AppDelegate.pending = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct TranscripteurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Transcripteur", id: "principale") {
            ContentView(model: model)
                .frame(minWidth: 720, minHeight: 420)
                .onAppear {
                    trace("onAppear")
                    AppDelegate.model = model
                    if let url = AppDelegate.pending {
                        AppDelegate.pending = nil
                        model.open(url)
                    }
                    // Lancement en ligne de commande : `Transcripteur fichier.wav`.
                    if let path = CommandLine.arguments.dropFirst().first(where: {
                        FileManager.default.fileExists(atPath: $0)
                    }) {
                        model.open(URL(fileURLWithPath: path))
                    }
                }
                // Chemin réellement emprunté par un double-clic dans le Finder :
                // SwiftUI capte l'évènement d'ouverture avant le délégué AppKit.
                .onOpenURL { trace("onOpenURL : \($0)"); model.open($0) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ouvrir…") { model.openPanel() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Lecture") {
                Button(model.player.isPlaying ? "Pause" : "Lire") { model.togglePlayback() }
                    .keyboardShortcut(.space, modifiers: [])
                Button("Revenir au début") { model.seek(to: 0) }
                    .keyboardShortcut(.home, modifiers: [])
            }
            CommandMenu("Boucle") {
                Button("Début ici") { model.setLoopStart(at: model.playhead) }
                    .keyboardShortcut("[", modifiers: [])
                Button("Fin ici") { model.setLoopEnd(at: model.playhead) }
                    .keyboardShortcut("]", modifiers: [])
                Button("Caler sur les mesures") { model.snapLoopToBars() }
                    .keyboardShortcut("b", modifiers: [])
                    .disabled(model.loop == nil || model.tempo == nil)
                Divider()
                Toggle("Boucler", isOn: Binding(get: { model.loopEnabled },
                                                set: { model.loopEnabled = $0 }))
                    .keyboardShortcut("l", modifiers: [])
                Button("Effacer la boucle") { model.loop = nil }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.loop == nil)
            }
            CommandMenu("Affichage") {
                Button("Contraste automatique") { model.applyAutoContrast() }
                    .keyboardShortcut("k", modifiers: [])
                Button("Contraste automatique sur tout le morceau") {
                    model.applyAutoContrast(wholePiece: true)
                }
                .keyboardShortcut("k", modifiers: [.shift])
            }
            CommandMenu("Tempo") {
                Button("Poser le premier temps ici") { model.setDownbeatAtPlayhead() }
                    .keyboardShortcut("t", modifiers: [])
                Divider()
                Button("Recalculer la grille") { model.recomputeTempo() }
                Divider()
                Button("Moitié") { model.scaleTempo(by: 0.5) }.disabled(model.tempo == nil)
                Button("Double") { model.scaleTempo(by: 2) }.disabled(model.tempo == nil)
            }
        }
    }
}

struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                SpectrogramSurface(model: model)
                TimelineOverlay(model: model)
                if model.spectrogram.columnCount == 0 { welcome }
                if let progress = model.progress { analysing(progress) }
            }
            controls
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                DispatchQueue.main.async { model.open(url) }
            }
            return true
        }
    }

    private var welcome: some View {
        VStack(spacing: 10) {
            Text("Déposer un fichier audio")
                .font(.system(size: 17, weight: .medium, design: .rounded))
            Text("ou ⌘O")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    private func analysing(_ progress: Double) -> some View {
        VStack(spacing: 8) {
            ProgressView(value: progress)
                .frame(width: 220)
            Text(model.status ?? "Analyse…")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(18)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        VStack(spacing: 6) {
            HStack(spacing: 14) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .disabled(model.duration == 0)
                .help("Espace")

                Text(AppModel.format(model.playhead))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 62, alignment: .leading)

                slider("Vitesse", value: $model.player.speed, range: 0.25...1.5,
                       format: { String(format: "×%.2f", $0) })
                slider("Ton", value: $model.player.transpose, range: -12...12,
                       format: { String(format: "%+.0f dt", $0) })

                Divider().frame(height: 16)
                loopControls

                Spacer(minLength: 8)
            }
            HStack(spacing: 14) {
                tempoControls

                Divider().frame(height: 16)

                slider("Contraste", value: $model.display.floorDb, range: -120...(-40),
                       format: { String(format: "%.0f dB", $0) })
                Button("Auto") { model.applyAutoContrast() }
                    .controlSize(.small)
                    .disabled(model.spectrogram.columnCount == 0)
                    .help("Régler noir, clair et pente sur ce qui est à l'écran")

                Picker("", selection: $model.display.colorMap) {
                    ForEach(ColorMap.allCases) { Text($0.label).tag($0) }
                }
                .labelsHidden()
                .frame(width: 178)

                Picker("", selection: $model.display.useFlats) {
                    Text("♭").tag(true)
                    Text("♯").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 62)
                .help("Nommer les touches noires par le bas ou par le haut")

                Spacer(minLength: 8)

                Text(model.status ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var loopControls: some View {
        HStack(spacing: 6) {
            Toggle(isOn: $model.loopEnabled) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .disabled(model.loop == nil)
            .help("Boucler (L)")

            if let loop = model.loop {
                Text("\(AppModel.format(loop.lowerBound)) → \(AppModel.format(loop.upperBound))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                Button("Mesures") { model.snapLoopToBars() }
                    .disabled(model.tempo == nil)
                    .help("Caler la boucle sur les mesures (B)")
                Button {
                    model.loop = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .help("Effacer la boucle (échap)")
            } else {
                Text("glisser dans la réglette")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
        .controlSize(.small)
    }

    private var tempoControls: some View {
        HStack(spacing: 6) {
            if let tempo = model.tempo {
                // Une estimation peu franche est annoncée comme telle : mieux vaut
                // un « à peu près » visible qu'une grille faussement assurée.
                Text(tempo.confidence > 0 && tempo.confidence < 2.2 ? "≈" : " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                Text(String(format: "%.1f BPM", tempo.bpm))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(width: 74, alignment: .leading)
                Stepper("") { model.nudgeTempo(by: 0.1) } onDecrement: { model.nudgeTempo(by: -0.1) }
                    .labelsHidden()
                Button("÷2") { model.scaleTempo(by: 0.5) }
                Button("×2") { model.scaleTempo(by: 2) }
                Picker("", selection: Binding(get: { model.beatsPerBar },
                                              set: { model.beatsPerBar = $0 })) {
                    ForEach([2, 3, 4, 5, 6, 7], id: \.self) { Text("\($0)/4").tag($0) }
                }
                .labelsHidden()
                .frame(width: 66)
                Button("1 ici") { model.setDownbeatAtPlayhead() }
                    .help("Poser le premier temps à la tête de lecture (T)")
                Button {
                    model.recomputeTempo()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Recalculer la grille, avec la signature choisie")
            } else {
                Text("tempo indéterminé")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Button {
                    model.recomputeTempo()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Chercher une grille")
                .disabled(model.spectrogram.columnCount == 0)
            }
        }
        .controlSize(.small)
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>,
                        format: @escaping (Double) -> String) -> some View {
        HStack(spacing: 5) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Slider(value: value, in: range).frame(width: 88)
            Text(format(value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 46, alignment: .leading)
        }
    }
}
