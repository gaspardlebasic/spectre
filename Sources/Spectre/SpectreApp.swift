import AppKit
import SpectreCore
import SpectreMac
import SwiftUI
import UniformTypeIdentifiers

/// Trace de diagnostic : le journal unifié masque les chaînes interpolées.
func trace(_ message: String) {
    guard ProcessInfo.processInfo.environment["SPECTRE_TRACE"] != nil else { return }
    let line = "\(Date()) \(message)\n"
    if let data = line.data(using: .utf8) {
        let path = "/tmp/spectre.log"
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

/// Point d'entrée. Avant d'ouvrir une fenêtre, on regarde si la ligne de commande
/// demande autre chose — séparer un morceau sans interface, par exemple.
@main
struct Entry {
    static func main() {
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--separer"), flag + 1 < arguments.count {
            let destination = arguments.firstIndex(of: "--vers").flatMap {
                $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
            }
            exit(SeparationCommand.run(path: arguments[flag + 1], into: destination,
                                       accelerated: !arguments.contains("--processeur")))
        }
        SpectreApp.main()
    }
}

struct SpectreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Spectre", id: "principale") {
            ContentView(model: model)
                .frame(minWidth: 860, minHeight: 460)
                // La barre de titre nomme le morceau ouvert, pas le programme :
                // c'est ce qu'on cherche en regardant une fenêtre parmi d'autres.
                // `navigationDocument` y ajoute l'icône du fichier et son chemin.
                .navigationTitle(model.title)
                .modifier(DocumentProxy(url: model.fileURL))
                .onAppear {
                    trace("onAppear")
                    AppDelegate.model = model
                    if let url = AppDelegate.pending {
                        AppDelegate.pending = nil
                        model.open(url)
                    }
                    // Lancement en ligne de commande : `Spectre fichier.wav`.
                    if let path = CommandLine.arguments.dropFirst().first(where: {
                        FileManager.default.fileExists(atPath: $0)
                    }) {
                        model.open(URL(fileURLWithPath: path))
                    }
                    model.reopenLastFile()
                }
                // Chemin réellement emprunté par un double-clic dans le Finder :
                // SwiftUI capte l'évènement d'ouverture avant le délégué AppKit.
                .onOpenURL { trace("onOpenURL : \($0)"); model.open($0) }
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ouvrir…") { model.openPanel() }
                    .keyboardShortcut("o")
                Menu("Ouvrir récemment") {
                    // Le nom du fichier sans son extension : dans un menu, « .mp3 »
                    // répété dix fois n'aide personne à reconnaître un morceau.
                    ForEach(model.recentFiles, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            model.open(url)
                        }
                    }
                    if !model.recentFiles.isEmpty {
                        Divider()
                        Button("Vider le menu") { model.clearRecentFiles() }
                    }
                }
                .disabled(model.recentFiles.isEmpty)
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
                // Le panneau se replie ; sans entrée de menu, son bouton serait le
                // seul chemin vers lui, et un bouton qui disparaît en s'ouvrant
                // n'est pas un chemin.
                Button("Panneau de réglages") {
                    NotificationCenter.default.post(name: .toggleControlPanel, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                Button("Contraste automatique") { model.applyAutoContrast() }
                    .keyboardShortcut("k", modifiers: [])
                Button("Contraste automatique sur tout le morceau") {
                    model.applyAutoContrast(wholePiece: true)
                }
                .keyboardShortcut("k", modifiers: [.shift])
            }
            CommandMenu("Tempo") {
                // « 1 » comme le premier temps, et comme l'intitulé du bouton du
                // panneau : la touche et l'étiquette disent la même chose.
                Button("Poser le premier temps ici") { model.setDownbeatAtPlayhead() }
                    .keyboardShortcut("1", modifiers: [])
                Divider()
                Button("Recalculer la grille") { model.recomputeTempo() }
            }
        }

        // ⌘, : le raccourci que macOS attend. `Settings` l'installe seul, avec son
        // entrée dans le menu de l'application — rien à déclarer.
        Settings { SettingsView(model: model) }
    }
}

/// Ajoute l'icône du fichier et son chemin à la barre de titre — mais seulement
/// quand il y a un fichier : sans cela, une fenêtre vide afficherait la racine du
/// disque.
private struct DocumentProxy: ViewModifier {
    let url: URL?

    func body(content: Content) -> some View {
        if let url {
            content.navigationDocument(url)
        } else {
            content
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
            // Les commandes flottent sur l'image au lieu de lui prendre une bande
            // en pied de fenêtre : le spectrogramme se lit d'autant mieux qu'il
            // est grand, et ces réglages-là se touchent une fois par morceau.
            // Sur l'image seule, pas sur la pile : le panneau n'a rien à faire
            // par-dessus la piste de batterie.
            .overlay(alignment: .topTrailing) { ControlOverlay(model: model) }
            // Une piste à part, sous l'image, et non un calque par-dessus : la
            // batterie ne se lit pas sur l'axe des hauteurs, et lui prendre le bas
            // du spectrogramme reviendrait à cacher les graves pour montrer ce qui
            // n'en dépend pas.
            if model.showDrumLane, model.spectrogram.columnCount > 0 {
                DrumLaneView(model: model)
            }
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
}
