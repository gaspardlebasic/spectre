import Observation
import SpectreCore
import SpectreModele
import SpectreMac
import SpectreTextes
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
        static let langue = "langue"
        static let systemeDeNotes = "systemeDeNotes"
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

    // MARK: - La langue

    /// La langue choisie à la main. `nil` — le défaut — la fait suivre le système.
    ///
    /// Écrire la langue et la relire ne suffit pas : `Textes` est un état global, lu
    /// par des étages qui ne connaissent pas cette classe, et il faut donc le reposer
    /// à chaque changement. C'est fait ici, en un seul endroit.
    var choixDeLangue: Langue? {
        didSet {
            UserDefaults.standard.set(choixDeLangue?.rawValue, forKey: Key.langue)
            appliquer()
        }
    }

    /// Le système de noms de notes choisi à la main. `nil` le fait suivre la langue.
    ///
    /// Deux réglages et non un seul : un guitariste français qui a appris sur des
    /// grilles américaines veut son interface en français et ses accords en `Am`.
    var choixDeNotes: SystemeDeNotes? {
        didSet {
            UserDefaults.standard.set(choixDeNotes?.rawValue, forKey: Key.systemeDeNotes)
            appliquer()
        }
    }

    /// Ce que SwiftUI observe pour savoir que tous les textes ont changé sous lui.
    ///
    /// Sans ce compteur, rien ne bougerait à l'écran : les textes ne viennent pas
    /// d'un état observé mais d'un catalogue interrogé au moment du dessin, et
    /// SwiftUI n'a aucun moyen de le deviner. La vue racine et la fenêtre des
    /// réglages s'y accrochent par `.id(…)`, ce qui les refait entièrement — le seul
    /// geste qui garantisse qu'aucun intitulé ne reste dans l'ancienne langue.
    private(set) var revisionDeLangue = 0

    private func appliquer() {
        Textes.demarrer(choix: choixDeLangue, notes: choixDeNotes,
                        etiquettesDuSysteme: Self.languesDuSysteme)
        revisionDeLangue += 1
    }

    /// Ce que le Mac dit préférer, de la plus souhaitée à la moins.
    ///
    /// La liste entière et non la première : un Mac réglé en breton puis en allemand
    /// doit obtenir l'allemand, et non l'anglais du dernier recours.
    static var languesDuSysteme: [String] { Locale.preferredLanguages }

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
        choixDeLangue = defaults.string(forKey: Key.langue).flatMap(Langue.init(rawValue:))
        // `object(forKey:)` et non `integer(forKey:)` : le second rend zéro quand la
        // clé n'existe pas, et zéro est un système de notes valide — le réglage
        // « suit la langue » se serait perdu au premier lancement.
        choixDeNotes = (defaults.object(forKey: Key.systemeDeNotes) as? Int)
            .flatMap(SystemeDeNotes.init(rawValue:))
        StemStore.cacheLimit = cacheLimit
        Textes.demarrer(choix: choixDeLangue, notes: choixDeNotes,
                        etiquettesDuSysteme: Self.languesDuSysteme)
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
            // La langue vient en tête parce qu'elle commande tout le reste du
            // panneau : les deux sections d'en dessous changent d'intitulé avec elle.
            Section(T(.reglagesLangue)) {
                Picker(T(.reglagesLangueInterface), selection: $preferences.choixDeLangue) {
                    Text(T(.reglagesLangueSysteme)).tag(Langue?.none)
                    Divider()
                    ForEach(Langue.allCases, id: \.self) { langue in
                        Text(langue.nomNatif).tag(Langue?.some(langue))
                    }
                }
                .disabled(Textes.langueImposee)
                Picker(T(.reglagesNomDesNotes), selection: $preferences.choixDeNotes) {
                    Text(T(.reglagesNotesSelonLaLangue)).tag(SystemeDeNotes?.none)
                    Divider()
                    ForEach(SystemeDeNotes.allCases, id: \.self) { systeme in
                        Text(systeme.label).tag(SystemeDeNotes?.some(systeme))
                    }
                }
                // Les douze noms en clair. C'est le seul endroit où l'on voit, sans
                // ouvrir un morceau, que l'allemand appelle B le si bémol et H le si
                // naturel — ce qui est exactement ce qui surprend au premier essai.
                LabeledContent("") {
                    Text(Pitch.names(flats: model.display.useFlats)
                            .joined(separator: "  "))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Text(T(.reglagesLangueExplication))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if Textes.langueImposee {
                    Text(T(.reglagesLangueImposee))
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section(T(.reglagesPistesSeparees)) {
                Picker(T(.reglagesTailleMaximale), selection: $preferences.cacheLimit) {
                    ForEach(Preferences.cacheChoices, id: \.self) { choice in
                        Text(Self.formatter.string(fromByteCount: Int64(choice))).tag(choice)
                    }
                }
                LabeledContent(T(.reglagesOccupe)) {
                    HStack(spacing: 8) {
                        Text(Self.formatter.string(fromByteCount: Int64(usage)))
                            .monospacedDigit()
                        Button(T(.reglagesViderPoints)) { confirmingEmpty = true }
                            .disabled(usage == 0)
                    }
                }
                Text(T(.reglagesCacheExplication))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(T(.reglagesCouleurDesNotes)) {
                Picker(T(.reglagesPremiereTeinte), selection: $preferences.hueOrigin) {
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
                Text(T(.reglagesCouleursExplication))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Une hauteur fixe, et le panneau défile. Sans elle, la fenêtre des réglages
        // prend la taille de son contenu, s'arrête à ce que l'écran lui accorde et
        // coupe simplement le reste : les derniers réglages devenaient inatteignables.
        // Elle a grandi avec la section « Langue », et l'allemand y écrit plus long
        // que le français.
        .frame(width: 520, height: 520)
        // Tous les intitulés viennent du catalogue, que SwiftUI ne sait pas observer :
        // sans cette identité, changer de langue ne changerait rien à l'écran.
        .id(preferences.revisionDeLangue)
        // Vider, c'est jeter des minutes de GPU. Elles se refont, mais pas sur un clic
        // distrait : on demande.
        .confirmationDialog(T(.reglagesViderTitre),
                            isPresented: $confirmingEmpty, titleVisibility: .visible) {
            Button(T(.reglagesViderBouton), role: .destructive) {
                StemStore.emptyCache()
                usage = preferences.cacheUsage()
            }
            Button(T(.reglagesAnnuler), role: .cancel) {}
        } message: {
            Text(T(.reglagesViderMessage))
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
