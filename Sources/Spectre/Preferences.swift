import Observation
import SpectreCore
import SpectreModele
import SpectreMac
import SwiftUI

/// Les réglages qui valent pour l'application entière, et non pour un morceau.
///
/// Ils ne vivent donc **pas** dans `DisplaySettings`, qui est enregistré par morceau :
/// la taille du cache n'a rien à voir avec un fichier en particulier, et l'ancrage des
/// couleurs est un goût, pas une propriété de la musique. Ils vont dans les
/// préférences du système, où le panneau ⌘, les trouve et les laisse.
@Observable final class Preferences {
    static let shared = Preferences()

    private enum Key {
        static let cacheLimit = "cacheLimitBytes"
        static let hueOrigin = "hueOrigin"
    }

    /// La réattribution spectrale — voir `AnalysisSettings.reassignment`.
    ///
    /// Une constante, et non plus un réglage : elle est ce qui fait qu'un partiel
    /// tient sur une ligne au lieu de trois, et rien de ce qu'on gagne à
    /// l'éteindre — un peu de temps d'analyse, un fond moins granuleux — ne vaut
    /// l'image qu'elle rend. Un interrupteur qu'on ne touche jamais est un
    /// interrupteur qui coûte à lire.
    let reassignment = true

    /// Plafond du dossier des pistes séparées, en octets.
    var cacheLimit: Int {
        didSet {
            UserDefaults.standard.set(cacheLimit, forKey: Key.cacheLimit)
            StemStore.cacheLimit = cacheLimit
            // Le nouveau plafond s'applique tout de suite : le baisser sans faire le
            // ménage ne servirait à rien avant la prochaine séparation, c'est-à-dire
            // au moment où l'on aurait justement voulu de la place.
            //
            // En tâche de fond : le ménage parcourt le dossier et efface des centaines
            // de mégaoctets. Sur le fil principal il figerait la fenêtre — et ce serait
            // juste après avoir touché à un réglage, donc au pire moment.
            DispatchQueue.global(qos: .utility).async {
                StemStore.pruneCache(keeping: nil)
            }
        }
    }

    /// Classe de hauteur qui reçoit la première teinte du cycle des quintes.
    var hueOrigin: Int {
        didSet { UserDefaults.standard.set(hueOrigin, forKey: Key.hueOrigin) }
    }

    /// Les réglages du relevé d'accords, à leurs valeurs d'origine.
    ///
    /// Ils ont eu leur section dans ⌘, — douze curseurs et leurs explications. Ce
    /// sont des poids de fonction de coût : on ne les règle pas, on les accorde,
    /// et les accorder demande d'entendre ce qu'ils changent sur plusieurs
    /// morceaux. Les valeurs d'origine sont celles qui ont gagné cet accord ;
    /// les exposer ne servait qu'à les défaire.
    let chords = ChordSettings()

    /// Les paliers proposés. Un morceau de sept minutes coûte environ 250 Mo de
    /// pistes compressées, d'où des paliers qui se comptent en morceaux plutôt qu'en
    /// puissances de deux.
    static let cacheChoices: [Int] = [500_000_000, 1_000_000_000, 2_000_000_000,
                                      5_000_000_000, 10_000_000_000]

    private init() {
        let defaults = UserDefaults.standard
        let stored = defaults.integer(forKey: Key.cacheLimit)
        cacheLimit = stored > 0 ? stored : 1_000_000_000
        hueOrigin = defaults.integer(forKey: Key.hueOrigin)     // 0 = Do, par défaut
        StemStore.cacheLimit = cacheLimit
    }

    /// Ce que le dossier des pistes occupe réellement, en octets.
    func cacheUsage() -> Int { StemStore.cacheSize() }
}

/// Le panneau ⌘,.
struct SettingsView: View {
    @Bindable var preferences = Preferences.shared
    let model: AppModel
    /// Relevé à l'ouverture du panneau, puis après chaque ménage : parcourir le
    /// dossier à chaque image serait absurde pour un chiffre qui bouge une fois par
    /// morceau.
    @State private var usage = 0
    @State private var confirmingEmpty = false

    private static let formatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        Form {
            Section("Pistes séparées") {
                Picker("Taille maximale du cache", selection: $preferences.cacheLimit) {
                    ForEach(Preferences.cacheChoices, id: \.self) { choice in
                        Text(Self.formatter.string(fromByteCount: Int64(choice))).tag(choice)
                    }
                }
                LabeledContent("Occupé") {
                    HStack(spacing: 8) {
                        Text(Self.formatter.string(fromByteCount: Int64(usage)))
                            .monospacedDigit()
                        Button("Vider…") { confirmingEmpty = true }
                            .disabled(usage == 0)
                    }
                }
                Text("""
                     Un morceau de sept minutes coûte environ 250 Mo. Au-delà du \
                     plafond, les morceaux les moins récemment ouverts s'en vont \
                     entiers — jamais celui qu'on écoute — et se recalculent en une \
                     demi-minute.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Couleur des notes") {
                Picker("Première teinte", selection: $preferences.hueOrigin) {
                    ForEach(0..<12, id: \.self) { pitchClass in
                        Text(Pitch.names(flats: model.display.useFlats)[pitchClass])
                            .tag(pitchClass)
                    }
                }
                HStack(spacing: 3) {
                    ForEach(0..<12, id: \.self) { pitchClass in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(swatch(pitchClass))
                            .frame(height: 22)
                            .overlay(
                                Text(Pitch.names(flats: model.display.useFlats)[pitchClass])
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundStyle(.black.opacity(0.75)))
                    }
                }
                Text("""
                     Les douze teintes sont réparties selon le cycle des quintes : deux \
                     notes proches harmoniquement sont proches en couleur, un triton les \
                     met en opposition. Changer la première ne fait que tourner la série \
                     — ces rapports-là ne bougent pas.
                     """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Une hauteur fixe, et le panneau défile. Sans elle, la fenêtre des réglages
        // prend la taille de son contenu, s'arrête à ce que l'écran lui accorde et
        // coupe simplement le reste : les derniers réglages devenaient inatteignables.
        // Deux sections y tiennent largement, depuis que le relevé d'accords et
        // l'analyse ont rejoint les valeurs d'origine.
        .frame(width: 480, height: 400)
        // Vider, c'est jeter des minutes de GPU. Elles se refont, mais pas sur un clic
        // distrait : on demande.
        .confirmationDialog("Vider le cache des pistes séparées ?",
                            isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button("Vider", role: .destructive) {
                StemStore.emptyCache()
                usage = preferences.cacheUsage()
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Chaque morceau devra être séparé de nouveau, soit environ une "
                 + "demi-minute par morceau.")
        }
        .onAppear { usage = preferences.cacheUsage() }
        .onChange(of: preferences.cacheLimit) { usage = preferences.cacheUsage() }
    }

    private func swatch(_ pitchClass: Int) -> Color {
        let rgb = NotePalette.color(pitchClass: pitchClass, intensity: 0.85,
                                    saturation: model.display.noteSaturation,
                                    origin: preferences.hueOrigin)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}
