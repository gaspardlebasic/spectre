import Observation
import SpectreCore
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
        static let chords = "chordSettings"
    }

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

    /// Les réglages du relevé d'accords.
    ///
    /// Ici et non dans `DisplaySettings` — donc pas par morceau — parce que ce sont
    /// des réglages d'**algorithme** : on les tourne en écoutant, on trouve ce qui
    /// marche pour la musique qu'on relève, et l'on veut le retrouver au morceau
    /// suivant. Enregistrés en JSON plutôt qu'en douze clés séparées : c'est un
    /// objet, il se relit d'un bloc, et son décodage tolère les champs manquants.
    var chords: ChordSettings {
        didSet {
            guard chords != oldValue else { return }
            if let data = try? JSONEncoder().encode(chords) {
                UserDefaults.standard.set(data, forKey: Key.chords)
            }
        }
    }

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
        chords = defaults.data(forKey: Key.chords)
            .flatMap { try? JSONDecoder().decode(ChordSettings.self, from: $0) }
            ?? ChordSettings()
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
            chordSection

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
        .frame(width: 480, height: 620)
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
        // Un réglage tourné doit s'entendre tout de suite : le relevé se refait sur
        // le morceau ouvert sans qu'on ait à rien redemander. Le chromagramme, lui,
        // est gardé — seul un changement de fenêtre le fait relire.
        .onChange(of: preferences.chords) { model.reloadChords() }
    }

    // MARK: Les accords

    /// Les réglages du relevé, tous ensemble.
    ///
    /// Ils parlent tous la même langue, celle de l'image : une raie est visible
    /// au-dessus d'une certaine clarté, elle est tenue si elle occupe assez de la
    /// mesure, elle est expliquée si une raie plus grave la porte dans ses
    /// harmoniques. Chacun dit donc ce qu'il change *à l'écran* plutôt que son rôle
    /// dans une formule.
    private var chordSection: some View {
        Section("Relevé des accords") {
            Picker("Portée", selection: $preferences.chords.scope) {
                ForEach(ChordSettings.Scope.allCases, id: \.rawValue) {
                    Text($0.label).tag($0)
                }
            }
            explain(preferences.chords.scope == .beat
                    ? """
                      Un accord est décidé sur chaque temps, puis la suite est lissée : \
                      changer d'accord coûte, rester ne coûte rien. Il sait montrer un \
                      changement au milieu d'une mesure, au prix de décisions prises sur \
                      très peu de matière — un temps porte rarement assez de notes tenues \
                      pour se décider seul.
                      """
                    : """
                      Un accord par mesure, décidé sur la mesure entière et sur rien \
                      d'autre : aucun lissage, aucune contagion d'une mesure à sa \
                      voisine. Et dès qu'une boucle est tracée, elle devient la seule \
                      portée du relevé : un accord, pour ce passage-là, du début à la fin \
                      de ce que vous avez sélectionné.
                      """)

            Picker("Vocabulaire", selection: $preferences.chords.vocabulary) {
                ForEach(ChordSettings.Vocabulary.allCases, id: \.rawValue) {
                    Text($0.label).tag($0)
                }
            }
            explain("""
                    Ce qu'on s'autorise à nommer. Ce n'est pas qu'une question de \
                    richesse : ce que le vocabulaire ne sait pas écrire ne disparaît \
                    pas de l'image pour autant, il se retrouve entouré en pointillés. \
                    Les enrichissements font tomber les raies sans explication de 7 à \
                    4 % sur un morceau réel. À l'inverse, restreindre est souvent ce \
                    qui améliore le plus un relevé : sur un morceau qui ne joue que \
                    des triades, interdire le reste supprime d'un coup toutes les \
                    erreurs possibles.
                    """)

            tuning("Clarté minimale d'une raie", $preferences.chords.clarity, 0...0.4)
            explain("""
                    À partir de quelle clarté un trait de l'image compte comme une note. \
                    C'est la même échelle que l'écran : 0 est le noir réglé, 1 le blanc. \
                    Le curseur de contraste fait donc le même travail — éclaircir \
                    l'image, c'est faire entrer des raies pâles dans le relevé, et les \
                    accords changent sous vos yeux pendant que vous le tirez.
                    """)

            tuning("Tenue minimale", $preferences.chords.hold, 0.3...1, percent: true)
            explain("""
                    Quelle part de la mesure — ou du passage sélectionné — une raie doit \
                    occuper pour être une note de l'accord. C'est ce qui sépare une \
                    harmonie d'une broderie : une note de passage, une anticipation du \
                    bassiste sur la barre, un trait de voix ne tiennent pas toute la \
                    mesure. Monté trop haut, plus rien ne tient et la ligne se vide.
                    """)

            tuning("Netteté d'une raie", $preferences.chords.prominence, 0...12)
            explain("""
                    De combien un trait doit se détacher du fond, en décibels, avant le \
                    demi-ton voisin. C'est ce qui distingue une note de la traînée d'une \
                    note : toute fenêtre d'analyse laisse des ondulations autour d'un \
                    pic, et sans cette exigence on relève une tenue un demi-ton à côté \
                    de chaque note franche. C'est le seul réglage qui fasse relire \
                    l'image ; les autres sont instantanés.
                    """)

            tuning("Décroissance supposée des harmoniques",
                   $preferences.chords.harmonicDrop, 0...20)
            tuning("Marge pour la croire jouée", $preferences.chords.mustExceedParent,
                   0...20)
            explain("""
                    Une note isolée peuple le spectre bien au-delà d'elle-même : son \
                    octave, sa quinte à la douzième, sa tierce majeure deux octaves plus \
                    haut. Une raie qu'une raie plus grave explique ainsi n'est pas \
                    entourée. Le premier curseur dit de combien on attend qu'une \
                    harmonique faiblisse à chaque doublement de rang ; le second, de \
                    combien une raie doit dépasser cette attente pour qu'on croie que \
                    quelqu'un joue là aussi. Baissez-les et l'accord se réduit à sa \
                    basse ; montez-les et chaque harmonique devient une note.
                    """)

            tuning("Prix d'une raie inexpliquée", $preferences.chords.unexplainedCost,
                   0...2)
            tuning("Prix d'une note absente", $preferences.chords.missingCost, 0...2)
            explain("""
                    Les deux plateaux de la balance. Le premier est le prix de laisser à \
                    l'écran une raie tenue que le nom n'explique pas — c'est lui qui fait \
                    l'adéquation, et le monter force le relevé à rendre compte de tout ce \
                    qu'on voit. Le second est le prix d'une note de l'accord qu'on ne \
                    voit pas : plus bas, parce qu'une quinte masquée est chose commune \
                    alors qu'une tierce inventée ne l'est pas.
                    """)

            tuning("La basse impose sa fondamentale", $preferences.chords.bassAgreement,
                   0...1)
            tuning("Basse étrangère à l'accord", $preferences.chords.bassContradiction,
                   0...1)
            explain("""
                    La basse est ici la raie tenue la plus grave de l'image — celle qu'on \
                    voit tout en bas. C'est elle qui sépare Do6 de La-7, qui sont \
                    pourtant les mêmes notes, et un renversement de son accord de base.
                    """)

            tuning("Prix des couleurs rares", $preferences.chords.rarityWeight, 0...3)
            explain("""
                    Ce que doit prouver une septième, une sixte ou un diminué pour \
                    l'emporter sur une simple triade. Zéro par défaut : une note qu'on ne \
                    voit pas coûte déjà quelque chose, et le relevé n'a plus besoin qu'on \
                    lui interdise la richesse.
                    """)

            tuning("Coût d'un changement d'accord", $preferences.chords.changeCost,
                   0...1.5)
                .disabled(preferences.chords.scope == .span)
            explain(preferences.chords.scope == .span
                    ? """
                      Sans effet ici : des mesures décidées séparément ne sont lissées \
                      par rien. Le réglage revient avec la portée « un accord par temps ».
                      """
                    : """
                      L'inertie du relevé. Monté, l'accord tient — au risque d'avaler les \
                      changements brefs. À zéro, chaque temps est libre, et deux accords \
                      voisins se mettent à clignoter d'un temps sur l'autre.
                      """)

            HStack {
                Spacer()
                Button("Rétablir les valeurs d'origine") {
                    preferences.chords = ChordSettings()
                }
                .disabled(preferences.chords == ChordSettings())
            }
        }
    }

    /// Un curseur, son intitulé et sa valeur. Double-cliquer sur l'intitulé ramène
    /// le réglage à sa valeur d'origine — un curseur continu ne la retrouve jamais
    /// tout seul.
    private func tuning(_ title: String, _ value: Binding<Double>,
                        _ range: ClosedRange<Double>,
                        percent: Bool = false) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                Slider(value: value, in: range)
                Text(percent ? String(format: "%.0f %%", value.wrappedValue * 100)
                             : String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
        } label: {
            Text(title)
        }
    }

    private func explain(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
    }

    private func swatch(_ pitchClass: Int) -> Color {
        let rgb = NotePalette.color(pitchClass: pitchClass, intensity: 0.85,
                                    saturation: model.display.noteSaturation,
                                    origin: preferences.hueOrigin)
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
    }
}
