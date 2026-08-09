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
            let variant = arguments.firstIndex(of: "--modele").flatMap {
                $0 + 1 < arguments.count ? SeparationModel(rawValue: arguments[$0 + 1]) : nil
            } ?? .fine
            exit(SeparationCommand.run(path: arguments[flag + 1], into: destination,
                                       variant: variant))
        }
        TranscripteurApp.main()
    }
}

struct TranscripteurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Transcripteur", id: "principale") {
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

    // MARK: Barre de commandes

    /// Les commandes sont groupées par ce à quoi elles servent, chaque groupe
    /// portant son nom. Cela coûte une dizaine de points de hauteur et fait gagner
    /// la question « où est réglé le tempo, déjà ? ».
    private var controls: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .bottom, spacing: 14) {
                section("Lecture") { playbackControls }
                separator
                section("Boucle") { loopControls }
                separator
                section("Tempo") { tempoControls }
                Spacer(minLength: 0)
            }
            HStack(alignment: .bottom, spacing: 14) {
                section("Pistes") { stemControls }
                separator
                section("Affichage") { displayControls }
                Spacer(minLength: 8)
                Text(model.status ?? "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var separator: some View {
        Divider().frame(height: 22)
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            HStack(spacing: 9) { content() }
        }
    }

    private var playbackControls: some View {
        Group {
            Button {
                model.togglePlayback()
            } label: {
                Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 18)
            }
            .disabled(model.duration == 0)
            .help("Lire ou mettre en pause (espace)")

            Text(AppModel.format(model.playhead))
                .font(.system(size: 11, design: .monospaced))
                .fixedSize()
                .frame(width: 62, alignment: .leading)
                .help("Position de lecture. Cliquer dans l'image la déplace, et fait sonner la raie désignée.")

            slider("Vitesse", value: $model.player.speed, range: 0.25...1.5,
                   reset: 1, format: { String(format: "×%.2f", $0) },
                   help: """
                   Ralentit ou accélère sans toucher à la hauteur.
                   Un cran ramène exactement à ×1,00, où le traitement est retiré du chemin du son.
                   Double-clic sur le texte pour y revenir.
                   """)
            slider("Ton", value: $model.player.transpose, range: -12...12,
                   reset: 0, format: {
                       // Un demi-ton entier s'écrit sans décimale ; une valeur
                       // intermédiaire, elle, doit se voir.
                       String(format: abs($0 - $0.rounded()) < 0.005 ? "%+.0f dt" : "%+.1f dt", $0)
                   },
                   help: """
                   Transpose sans toucher à la vitesse, en demi-tons.
                   Les valeurs intermédiaires servent à recaler un enregistrement désaccordé.
                   Double-clic sur le texte pour revenir à +0.
                   """)
        }
    }

    private var loopControls: some View {
        Group {
            Toggle(isOn: $model.loopEnabled) {
                Image(systemName: "repeat")
            }
            .toggleStyle(.button)
            .disabled(model.loop == nil)
            .help("Jouer le passage en boucle, sans trou à la reprise (L)")

            if let loop = model.loop {
                Text("\(AppModel.format(loop.lowerBound)) → \(AppModel.format(loop.upperBound))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize()
                    .help("""
                          Glisser la zone jaune la déplace, ses bords l'étendent.
                          Les bornes se posent sur la grille ; ⌘ pendant le geste les libère.
                          """)
                Button("Mesures") { model.snapLoopToBars() }
                    .disabled(model.tempo == nil)
                    .help("Étendre la boucle aux mesures qui l'encadrent (B)")
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
                    .help("Tracer une boucle : glisser dans la bande du haut, ou ⇧ + glisser dans l'image. [ et ] posent ses bornes à la tête de lecture.")
            }
        }
        .controlSize(.small)
    }

    private var tempoControls: some View {
        Group {
            if let tempo = model.tempo {
                // Une estimation peu franche est annoncée comme telle : mieux vaut
                // un « à peu près » visible qu'une grille faussement assurée.
                Text(tempo.confidence > 0 && tempo.confidence < 2.2 ? "≈" : " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .help("L'estimation n'est pas franche sur ce morceau : la grille est à vérifier.")
                Text(String(format: "%.1f BPM", tempo.bpm))
                    .font(.system(size: 11, design: .monospaced))
                    .fixedSize()
                    .frame(width: 74, alignment: .leading)
                    .help("Tempo estimé à l'ouverture à partir des attaques du morceau.")
                Stepper("") { model.nudgeTempo(by: 0.1) } onDecrement: { model.nudgeTempo(by: -0.1) }
                    .labelsHidden()
                    .help("Ajuster de 0,1 BPM — de quoi rattraper une grille qui dérive sur la longueur.")
                Button("÷2") { model.scaleTempo(by: 0.5) }
                    .help("Moitié du tempo : l'erreur la plus courante de l'estimation.")
                Button("×2") { model.scaleTempo(by: 2) }
                    .help("Double du tempo : l'autre erreur courante.")
                Picker("", selection: Binding(get: { model.beatsPerBar },
                                              set: { model.beatsPerBar = $0 })) {
                    ForEach([2, 3, 4, 5, 6, 7], id: \.self) { Text("\($0)/4").tag($0) }
                }
                .labelsHidden()
                .frame(width: 66)
                .help("Temps par mesure. Change l'espacement des barres, et le repère du premier temps.")
                Button("1 ici") { model.setDownbeatAtPlayhead() }
                    .help("Poser le premier temps à la tête de lecture (T)")
                Button {
                    model.recomputeTempo()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Relancer l'estimation, avec la signature choisie.")
            } else {
                Text("tempo indéterminé")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Button {
                    model.recomputeTempo()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Chercher une grille dans ce morceau.")
                .disabled(model.spectrogram.columnCount == 0)
            }
        }
        .controlSize(.small)
    }

    /// Le sélecteur de piste, et l'avancement quand un calcul est en cours.
    ///
    /// L'avancement est volontairement discret — une barre fine à côté du
    /// sélecteur, pas un voile sur l'image : la séparation dure des minutes et on
    /// doit pouvoir continuer à travailler sur le mixage pendant ce temps.
    private var stemControls: some View {
        Group {
            // Quatre bascules, toutes allumées au départ : la sélection dit ce
            // qu'on **garde**. C'est le geste courant — retirer la voix pour
            // travailler l'accompagnement, la batterie pour entendre l'harmonie —
            // et c'est le décochage qui déclenche le calcul.
            ForEach(Stem.separated) { stem in
                Toggle(isOn: Binding(get: { model.selection.contains(stem) },
                                     set: { _ in model.toggle(stem) })) {
                    Image(systemName: stem.symbol).frame(width: 17)
                }
                .toggleStyle(.button)
                // La dernière piste cochée ne se décoche pas : il ne resterait rien
                // à écouter. Le bouton inerte le dit mieux qu'un clic sans effet.
                .disabled(model.spectrogram.columnCount == 0 || model.selection == [stem])
                .help(stem.help + "\nDécocher retire cette piste ; ce qui reste est joué ensemble.")
            }

            if let progress = model.separating {
                ProgressView(value: progress)
                    .frame(width: 64)
                    .help("Séparation en cours. L'application reste utilisable.")
                // Le chiffre à côté de la barre : sur un calcul de plusieurs
                // minutes, une barre seule ne dit pas si elle avance encore.
                // Largeur fixe et chiffres à chasse fixe, sans quoi le voisinage
                // tressauterait à chaque pour cent.
                Text("\(Int((progress * 100).rounded())) %")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .leading)
            } else if model.isSeparated {
                Button {
                    model.forgetStems()
                } label: {
                    Image(systemName: "trash")
                }
                .help("Effacer les pistes de ce morceau et repartir du mixage.")
            }

            Picker("", selection: $model.separationModel) {
                ForEach(SeparationModel.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 116)
            .disabled(model.separating != nil)
            .help("""
                  Quelle variante de Demucs sépare le morceau.
                  Rapide : un seul réseau rend les quatre pistes.
                  Affiné : un réseau par instrument, quatre fois plus long, un peu plus net.
                  Les pistes des deux variantes coexistent, on peut donc comparer sans tout recalculer.
                  """)
        }
        .controlSize(.small)
    }

    private var displayControls: some View {
        Group {
            slider("Contraste", value: $model.display.floorDb, range: -120...(-40),
                   format: { String(format: "%.0f dB", $0) },
                   help: """
                   Niveau rendu noir. Le monter nettoie le fond,
                   et retire du même coup ce bruit de l'aimant du curseur.
                   """)
            Button("Auto") { model.applyAutoContrast() }
                .controlSize(.small)
                .disabled(model.spectrogram.columnCount == 0)
                .help("""
                      Règle noir, clair et pente d'après ce qui est à l'écran (K).
                      La pente est ajustée sur les niveaux de raies, pour que graves et aigus ressortent pareillement.
                      ⇧K le fait sur tout le morceau.
                      """)

            slider("Zoom", value: Binding(get: { log2(model.verticalZoom) },
                                          set: { model.verticalZoom = pow(2, $0) }),
                   // 16× au maximum : au-delà, la vue butterait sur sa propre
                   // limite et le curseur continuerait de bouger sans effet.
                   range: 0...4,
                   reset: 0,
                   format: { _ in String(format: "%.1f oct", model.visibleOctaves) },
                   help: """
                   Étale l'axe des fréquences ; la valeur donne le nombre d'octaves visibles.
                   Au trackpad : ⇧ + pincement, ou ⇧ + molette — ancré sous le curseur.
                   La lecture est filtrée sur la bande visible.
                   """)

            Picker("", selection: $model.display.colorMap) {
                ForEach(ColorMap.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .frame(width: 178)
            .help("Couleur des raies. « Notes » donne une teinte à chaque demi-ton, réparties selon le cycle des quintes.")

            Picker("", selection: $model.display.useFlats) {
                Text("♭").tag(true)
                Text("♯").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 62)
            .help("Nommer les touches noires par le bas (Mi♭) ou par le haut (Ré♯).")
        }
    }

    /// Un curseur, son intitulé et sa valeur. Double-cliquer sur l'un ou l'autre
    /// texte ramène le réglage à sa valeur neutre — un curseur continu ne la
    /// retrouve jamais tout seul.
    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>,
                        reset: Double? = nil,
                        format: @escaping (Double) -> String,
                        help: String) -> some View {
        let restore = {
            if let reset { value.wrappedValue = reset }
        }
        return HStack(spacing: 5) {
            // `fixedSize` : sans lui, la barre serrée coupe les intitulés en
            // colonnes d'une lettre plutôt que de les laisser prendre leur place.
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize()
                .onTapGesture(count: 2, perform: restore)
            Slider(value: value, in: range).frame(width: 84)
            Text(format(value.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(width: 48, alignment: .leading)
                .onTapGesture(count: 2, perform: restore)
        }
        .help(help)
    }
}
