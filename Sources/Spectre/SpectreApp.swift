import AppKit
import SpectreCore
import SpectreModele
import SpectreMac
import SpectreTextes
import SwiftUI
import UniformTypeIdentifiers

/// Trace de diagnostic : le journal unifié d'Apple masque les chaînes interpolées.
///
/// Elle écrivait dans `/tmp/spectre.log`, qui n'existait que sur le Mac et que
/// personne d'autre n'allait lire. Elle passe maintenant par `Journal`, comme
/// Windows et Linux — c'est l'étape 1 de `docs/RAPPORTS.md` : **un seul endroit où
/// ça s'écrit**, sur les trois systèmes. Ce qui reste d'ici est la porte
/// `SPECTRE_TRACE`, parce que ces lignes-là sont bavardes et n'ont d'intérêt que
/// pour qui les cherche.
func trace(_ message: String) {
    guard ProcessInfo.processInfo.environment["SPECTRE_TRACE"] != nil else { return }
    Journal.note(message)
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

    /// Quitter ne doit pas coûter les réglages en cours : la position de lecture,
    /// elle, n'est écrite qu'à ce moment-là.
    ///
    /// C'est la plateforme qui sait *quand* l'application s'en va — ici la
    /// notification d'AppKit, ailleurs `WM_CLOSE` — et le modèle qui sait *quoi*
    /// enregistrer. Le modèle s'abonnait lui-même à cette notification ; il ne le
    /// peut plus depuis qu'il ne connaît plus AppKit, et c'est très bien ainsi.
    func applicationWillTerminate(_ notification: Notification) {
        AppDelegate.model?.applicationVaSeFermer()
    }
}

/// Point d'entrée. Avant d'ouvrir une fenêtre, on regarde si la ligne de commande
/// demande autre chose — séparer un morceau sans interface, par exemple.
@main
struct Entry {
    static func main() {
        // Le journal avant tout le reste : ce qu'on cherche est toujours ce qui
        // s'est dit avant que l'application ne se taise. Le numéro de version vient
        // du paquet, seule des trois plateformes à en porter un que le programme
        // puisse lire — voir `docs/PAQUETS.md`.
        Journal.ouvrir(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"]
                                as? String)
        // La langue ensuite, avant tout ce qui s'affiche — y compris les deux
        // commandes en ligne ci-dessous, dont les messages sortent du même
        // catalogue que la fenêtre. `Preferences.shared` la pose en s'ouvrant.
        _ = Preferences.shared
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--separer"), flag + 1 < arguments.count {
            let destination = arguments.firstIndex(of: "--vers").flatMap {
                $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
            }
            exit(SeparationCommand.run(path: arguments[flag + 1], into: destination,
                                       accelerated: !arguments.contains("--processeur")))
        }
        if let flag = arguments.firstIndex(of: "--accords"), flag + 1 < arguments.count {
            exit(ChordsCommand.run(path: arguments[flag + 1], arguments: arguments))
        }
        SpectreApp.main()
    }
}

struct SpectreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    /// Observé pour la seule langue. Les intitulés des menus sont bâtis dans ce
    /// corps de scène, et rien d'autre n'apprendrait à SwiftUI qu'ils ont changé.
    @State private var preferences = Preferences.shared

    var body: some Scene {
        Window("Spectre", id: "principale") {
            ContentView(model: model)
                .id(preferences.revisionDeLangue)
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
                // Lu ici, et surtout **pas** en tête du corps de scène : lire un état
                // observé à ce niveau-là fait recréer la fenêtre à chaque évaluation,
                // et `navigationTitle` n'y survit pas — la barre de titre reste sur
                // « Spectre » au lieu de porter le nom du morceau. `essai.sh` l'a
                // attrapé, ce qui est exactement ce qu'on lui demande.
                let _ = preferences.revisionDeLangue
                Button(T(.menuOuvrir)) { model.openPanel() }
                    .keyboardShortcut("o")
                Menu(T(.menuOuvrirRecemment)) {
                    // Le nom du fichier sans son extension : dans un menu, « .mp3 »
                    // répété dix fois n'aide personne à reconnaître un morceau.
                    ForEach(model.recentFiles, id: \.self) { url in
                        Button(url.deletingPathExtension().lastPathComponent) {
                            model.open(url)
                        }
                    }
                    if !model.recentFiles.isEmpty {
                        Divider()
                        Button(T(.menuViderLeMenu)) { model.clearRecentFiles() }
                    }
                }
                .disabled(model.recentFiles.isEmpty)
            }
            CommandMenu(T(.menuLecture)) {
                Button(model.player.isPlaying ? T(.lecturePause) : T(.lectureLire)) {
                    model.togglePlayback()
                }
                .keyboardShortcut(.space, modifiers: [])
                Button(T(.lectureRevenirAuDebut)) { model.seek(to: 0) }
                    .keyboardShortcut(.home, modifiers: [])
            }
            CommandMenu(T(.menuBoucle)) {
                Button(T(.boucleDebutIci)) { model.setLoopStart(at: model.playhead) }
                    .keyboardShortcut("[", modifiers: [])
                Button(T(.boucleFinIci)) { model.setLoopEnd(at: model.playhead) }
                    .keyboardShortcut("]", modifiers: [])
                Button(T(.boucleCalerSurMesures)) { model.snapLoopToBars() }
                    .keyboardShortcut("b", modifiers: [])
                    .disabled(model.loop == nil || model.tempo == nil)
                Divider()
                Toggle(T(.boucleBoucler), isOn: Binding(get: { model.loopEnabled },
                                                        set: { model.loopEnabled = $0 }))
                    .keyboardShortcut("l", modifiers: [])
                Button(T(.boucleEffacerLaBoucle)) { model.loop = nil }
                    .keyboardShortcut(.escape, modifiers: [])
                    .disabled(model.loop == nil)
            }
            CommandMenu(T(.menuAffichage)) {
                // Le panneau se replie ; sans entrée de menu, son bouton serait le
                // seul chemin vers lui, et un bouton qui disparaît en s'ouvrant
                // n'est pas un chemin.
                Button(T(.menuPanneauDeReglages)) {
                    NotificationCenter.default.post(name: .toggleControlPanel, object: nil)
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                Divider()
                // K ramène au repère, ⇧K s'adapte à ce qu'on regarde. L'ancien ⇧K
                // — le réglage automatique sur tout le morceau — a disparu : c'est
                // exactement ce que K rend maintenant, à ceci près qu'il le rend
                // tel qu'il était à l'ouverture plutôt que recalculé sur la piste
                // qu'on affiche à cet instant.
                Button(T(.menuContrasteOuverture)) { model.restoreOpeningContrast() }
                    .keyboardShortcut("k", modifiers: [])
                Button(T(.menuContrasteAutomatique)) {
                    model.applyAutoContrast()
                }
                .keyboardShortcut("k", modifiers: [.shift])
            }
            CommandMenu(T(.menuTempo)) {
                // « 1 » comme le premier temps, et comme l'intitulé du bouton du
                // panneau : la touche et l'étiquette disent la même chose.
                Button(T(.menuPoserLePremierTemps)) { model.setDownbeatAtPlayhead() }
                    .keyboardShortcut("1", modifiers: [])
                Divider()
                Button(T(.menuRecalculerLaGrille)) { model.recomputeTempo() }
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
                PlayheadLine(model: model)
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
            Text(T(.accueilDeposer))
                .font(.system(size: 17, weight: .medium, design: .rounded))
            Text(T(.accueilRaccourci))
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.white.opacity(0.7))
    }

    private func analysing(_ progress: Double) -> some View {
        VStack(spacing: 8) {
            ProgressView(value: progress)
                .frame(width: 220)
            Text(model.status ?? T(.accueilAnalyse))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))
        }
        .padding(18)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }
}
