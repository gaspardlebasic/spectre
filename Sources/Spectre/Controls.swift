import AppKit
import SpectreCore
import SpectreMac
import SwiftUI

// Les commandes, posées sur l'image plutôt que sous elle.
//
// Une barre en pied de fenêtre prend sa hauteur en permanence, pour des réglages
// qu'on touche une fois par morceau. Le spectrogramme, lui, se lit d'autant mieux
// qu'il est grand. D'où ce partage : ce qui sert à chaque instant — quelle piste
// on écoute — reste visible en flottant sur l'image ; tout le reste vit dans un
// panneau qu'on déplie et qu'on referme.
//
// Le verre de macOS 26 rend ce partage tenable. Un panneau opaque posé sur un
// spectrogramme le cacherait ; du verre laisse voir ce qu'il couvre, et le
// sélecteur de pistes, en verre *clair*, se pose sur l'image sans la trouer.

/// Tout ce qui flotte au bord droit : le panneau, le bouton qui l'ouvre, et la
/// colonne des pistes.
struct ControlOverlay: View {
    @Bindable var model: AppModel
    @State private var panelOpen = false
    /// L'espace où le bouton rond et le panneau se reconnaissent comme un seul
    /// morceau de verre : ouvrir ne fait pas apparaître une deuxième forme, cela
    /// déplie la première.
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                if panelOpen {
                    ControlPanel(model: model) { close() }
                        .frame(width: 296)
                        .glassEffect(.regular, in: .rect(cornerRadius: 24))
                        .glassEffectID("reglages", in: glass)
                        .transition(.opacity)
                        .onHover { model.pointerOverControls = $0 }
                }
                VStack(spacing: 10) {
                    if !panelOpen {
                        Button { open() } label: {
                            VStack(spacing: 1) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 14))
                                Text("Réglages").font(.system(size: 8, weight: .medium))
                            }
                            // Même largeur que le sélecteur : deux objets alignés
                            // l'un sous l'autre et de largeurs voisines mais
                            // inégales se lisent comme un défaut d'alignement.
                            .frame(width: StemColumn.width, height: 40)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.clear.interactive(), in: .capsule)
                        .glassEffectID("reglages", in: glass)
                        .onHover { model.pointerOverControls = $0 }
                        .help("Lecture, boucle, tempo, affichage — ⌘⌥R")
                    }
                    StemColumn(model: model)
                }
            }
        }
        // Pas de `frame(maxWidth: .infinity)` sur cette vue : elle ne fait que la
        // taille de ce qu'elle contient. Étalée sur toute l'image elle n'aurait
        // l'air de rien, mais s'interposerait entre la souris et le spectrogramme —
        // le zoom, le clic de position et la sélection de plage passeraient tous
        // par elle.
        .padding(12)
        // Ce qui flotte est posé sur un spectrogramme, c'est-à-dire sur du noir,
        // quelle que soit l'apparence choisie pour le système. En apparence claire,
        // `.primary` est noir : les intitulés disparaîtraient dans l'image. On
        // force donc le clair-obscur ici, et nulle part ailleurs.
        .environment(\.colorScheme, .dark)
        .onReceive(NotificationCenter.default.publisher(for: .toggleControlPanel)) { _ in
            panelOpen ? close() : open()
        }
    }

    // Le ressort est volontairement court : le panneau se déplie du bouton, et un
    // mouvement lent donnerait l'impression d'attendre quelque chose.
    private func open() { withAnimation(.spring(duration: 0.35)) { panelOpen = true } }
    private func close() { withAnimation(.spring(duration: 0.3)) { panelOpen = false } }
}

extension Notification.Name {
    static let toggleControlPanel = Notification.Name("SpectreToggleControlPanel")
}

// MARK: Le sélecteur de pistes

/// Les quatre pistes, en colonne, toujours à l'écran.
///
/// Verre *clair* et non *régulier* : régulier dépolit ce qu'il couvre, et ce qu'il
/// couvre ici est justement l'image qu'on est en train de lire. Le verre clair
/// n'en garde que la réfraction et un liseré ; les raies continuent de passer
/// dessous, ce qui est la seule raison acceptable de poser quelque chose sur un
/// spectrogramme.
struct StemColumn: View {
    @Bindable var model: AppModel

    /// Du haut vers le bas : voix, accompagnement, basse, batterie. C'est l'ordre
    /// des hauteurs, celui qu'on a déjà sous les yeux dans l'image — et non
    /// l'ordre où le réseau rend ses sorties, qui n'a de sens que pour lui.
    private static let order: [Stem] = [.vocals, .other, .bass, .drums]

    /// Largeur commune au sélecteur et au bouton des réglages, et de quoi faire
    /// coïncider les arrondis.
    ///
    /// Le verre extérieur est une **capsule** : ses extrémités sont des
    /// demi-cercles de rayon `width / 2`. Pour que le premier et le dernier bouton
    /// épousent cette courbe au lieu de la croiser, leur arrondi extérieur vaut ce
    /// rayon **moins la marge** — c'est la règle des coins concentriques, et c'est
    /// ce qui fait qu'un bouton inscrit dans une capsule n'a pas l'air d'y avoir
    /// été posé de travers.
    static let width = 62.0
    private static let inset = 4.0
    private static let buttonWidth = width - 2 * inset
    private static let buttonHeight = 40.0
    private static let outerRadius = width / 2
    private static let domeRadius = outerRadius - inset
    private static let innerRadius = 9.0

    var body: some View {
        VStack(spacing: 3) {
            ForEach(Array(Self.order.enumerated()), id: \.element) { index, stem in
                button(for: stem, first: index == 0,
                       last: index == Self.order.count - 1)
            }
        }
        .padding(Self.inset)
        .glassEffect(.clear, in: .capsule)
        .onHover { model.pointerOverControls = $0 }
    }

    private func button(for stem: Stem, first: Bool, last: Bool) -> some View {
        // La sélection dit ce qu'on **garde**. La dernière piste cochée ne se
        // décoche pas : il ne resterait rien à écouter.
        let on = model.selection.contains(stem)
        let locked = model.spectrogram.columnCount == 0 || model.selection == [stem]
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: first ? Self.domeRadius : Self.innerRadius,
            bottomLeadingRadius: last ? Self.domeRadius : Self.innerRadius,
            bottomTrailingRadius: last ? Self.domeRadius : Self.innerRadius,
            topTrailingRadius: first ? Self.domeRadius : Self.innerRadius)
        return Button { model.toggle(stem) } label: {
            VStack(spacing: 1) {
                Image(systemName: stem.symbol).font(.system(size: 14))
                Text(stem.label).font(.system(size: 8, weight: .medium))
            }
            .frame(width: Self.buttonWidth, height: Self.buttonHeight)
            .foregroundStyle(on ? Color.primary : Color.primary.opacity(0.5))
            .background(on ? Color.primary.opacity(0.16) : .clear, in: shape)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(locked)
        .opacity(locked && !on ? 0.5 : 1)
        .help(stem.help + "\nDécocher retire cette piste ; ce qui reste est joué ensemble.")
    }
}

// MARK: Le panneau

/// Ce qu'on règle une fois par morceau : la lecture, la boucle, le tempo,
/// l'affichage. Groupé par ce à quoi cela sert, chaque groupe portant son nom —
/// cela coûte quelques points de hauteur et fait gagner la question « où est réglé
/// le tempo, déjà ? ».
/// L'heure de lecture, dans sa propre vue.
///
/// Elle change à chaque image pendant la lecture. Écrite au milieu du groupe
/// « Lecture », elle en refaisait tout le contenu — deux curseurs et leurs
/// légendes — pour changer un chiffre de seconde en seconde.
private struct PlayheadClock: View {
    let model: AppModel

    var body: some View {
        Text(AppModel.format(model.playhead))
            .font(.system(size: 11, design: .monospaced))
    }
}

struct ControlPanel: View {
    @Bindable var model: AppModel
    let close: () -> Void
    /// Hauteur réelle du contenu, relevée à l'affichage. Sans elle, la vue
    /// défilante réclamerait toute la hauteur offerte et le verre s'étirerait sur
    /// tout le bord droit, à moitié vide — un panneau doit faire la taille de ce
    /// qu'il contient, et ne défiler que lorsqu'il n'y tient plus.
    @State private var contentHeight: CGFloat = 0

    private struct ContentHeight: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.4)
            ScrollView {
                // Le tempo vient en premier parce que **tout le reste en dépend** :
                // sans grille, pas de barres de mesure, pas d'accords, pas de
                // boucle calée. C'est le premier réglage qu'on vérifie en ouvrant
                // un morceau, et une estimation fausse d'un facteur deux se corrige
                // ici en un chiffre.
                VStack(alignment: .leading, spacing: 18) {
                    group("Détection du tempo",
                          "Estimée à l'ouverture d'après les attaques. Elle commande "
                          + "les barres de mesure, l'aimantation et le relevé des "
                          + "accords.") { tempo }
                    group("Lecture", nil) { playback }
                    group("Boucle",
                          "Tracer une boucle : glisser dans la réglette du haut, ou "
                          + "⇧ + glisser dans l'image.") { loop }
                    group("Affichage", nil) { display }
                    if model.isSeparated || model.separating != nil {
                        group("Pistes", nil) { stems }
                    }
                }
                .padding(14)
                .background(GeometryReader { geometry in
                    Color.clear.preference(key: ContentHeight.self,
                                           value: geometry.size.height)
                })
            }
            .frame(maxHeight: contentHeight == 0 ? nil : contentHeight)
            .scrollBounceBehavior(.basedOnSize)
            .onPreferenceChange(ContentHeight.self) { contentHeight = $0 }
            if let status = model.status, !status.isEmpty {
                Divider().opacity(0.4)
                Text(status)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("Réglages").font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help("Replier le panneau — ⌘⌥R")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Un intitulé de groupe, et la phrase qui dit à quoi il sert.
    private func group<C: View>(_ title: String, _ note: String?,
                                @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
            if let note { caption(note) }
            content()
        }
    }

    /// Une explication, écrite sous ce qu'elle explique.
    ///
    /// Les infobulles disaient déjà tout cela, mais il faut savoir qu'il y a
    /// quelque chose à survoler pour les lire — ce qui suppose de savoir ce qu'on
    /// cherche. Un panneau qu'on ouvre une fois par morceau peut se permettre les
    /// quelques points de hauteur que coûte une phrase.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// La même chose, précédée de la touche qui fait la même chose au clavier.
    private func caption(_ shortcut: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(shortcut)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 4))
                .fixedSize()
            caption(text)
        }
    }

    // MARK: Groupes

    private var playback: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .disabled(model.duration == 0)
                .help("Lire ou mettre en pause (espace)")
                PlayheadClock(model: model)
                Spacer()
            }
            caption("espace", "Lire ou mettre en pause. Cliquer dans l'image déplace "
                    + "la tête de lecture, et fait sonner la raie désignée.")
            slider("Vitesse", value: $model.player.speed, range: 0.25...1.5,
                   reset: 1, format: { String(format: "×%.2f", $0) },
                   help: """
                   Ralentit ou accélère sans toucher à la hauteur.
                   Un cran ramène exactement à ×1,00, où le traitement est retiré du chemin du son.
                   Double-clic sur le texte pour y revenir.
                   """)
            caption("Ralentit sans toucher à la hauteur. Un cran ramène exactement à "
                    + "×1,00, où le traitement quitte le chemin du son.")
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
            caption("Transpose sans toucher à la vitesse. Les valeurs intermédiaires "
                    + "recalent un enregistrement désaccordé ; double-clic sur "
                    + "l'intitulé pour revenir au neutre.")
        }
    }

    private var loop: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: $model.loopEnabled) { Image(systemName: "repeat") }
                    .toggleStyle(.button)
                    .disabled(model.loop == nil)
                    .help("Jouer le passage en boucle, sans trou à la reprise (L)")
                if model.loop != nil {
                    Button("Mesures") { model.snapLoopToBars() }
                        .disabled(model.tempo == nil)
                        .help("Étendre la boucle aux mesures qui l'encadrent (B)")
                    Button { model.loop = nil } label: { Image(systemName: "xmark") }
                        .help("Effacer la boucle (échap)")
                }
                Spacer()
            }
            if let loop = model.loop {
                Text("\(AppModel.format(loop.lowerBound)) → \(AppModel.format(loop.upperBound))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                caption("Glisser la zone jaune la déplace, ses bords l'étendent. Les "
                        + "bornes se posent sur la grille ; ⌘ pendant le geste les "
                        + "libère.")
            }
            caption("L", "Jouer le passage en boucle, sans trou à la reprise.")
            caption("[  ]", "Poser le début et la fin à la tête de lecture.")
            caption("B", "Étendre la boucle aux mesures qui l'encadrent.")
            caption("échap", "Effacer la boucle.")
        }
        .controlSize(.small)
    }

    private var tempo: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.tempo != nil {
                HStack(spacing: 6) {
                    // Une estimation peu franche est annoncée comme telle : mieux
                    // vaut un « à peu près » visible qu'une grille faussement
                    // assurée.
                    if let t = model.tempo, t.confidence > 0, t.confidence < 2.2 {
                        Text("≈").font(.system(size: 11)).foregroundStyle(.orange)
                            .help("L'estimation n'est pas franche sur ce morceau : la grille est à vérifier.")
                    }
                    // Le tempo se tape. L'estimation se trompe le plus souvent d'un
                    // facteur deux, et l'écrire est alors plus direct que de
                    // chercher le bon bouton.
                    TextField("", value: Binding(get: { model.tempo?.bpm ?? 120 },
                                                 set: { model.setTempo($0) }),
                              format: .number.precision(.fractionLength(0...1)))
                        .font(.system(size: 11, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 46)
                    Text("BPM").font(.system(size: 10)).foregroundStyle(.secondary)
                    Stepper("") { model.nudgeTempo(by: 0.1) } onDecrement: { model.nudgeTempo(by: -0.1) }
                        .labelsHidden()
                        .help("Ajuster de 0,1 BPM — de quoi rattraper une grille qui dérive sur la longueur.")
                    Spacer()
                    Button { model.recomputeTempo() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Relancer l'estimation, avec la signature choisie.")
                }
                caption("Cliquer sur le chiffre pour le saisir : l'estimation se "
                        + "trompe surtout d'un facteur deux, qu'on corrige d'un "
                        + "chiffre. Les flèches ajustent de 0,1 BPM, de quoi "
                        + "rattraper une grille qui dérive sur la longueur.")
                HStack(spacing: 8) {
                    Picker("", selection: Binding(get: { model.beatsPerBar },
                                                  set: { model.beatsPerBar = $0 })) {
                        ForEach([2, 3, 4, 5, 6, 7], id: \.self) { Text("\($0)/4").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 70)
                    .help("Temps par mesure. Change l'espacement des barres, et le repère du premier temps.")
                    Button("1 ici") { model.setDownbeatAtPlayhead() }
                        .help("Poser le premier temps à la tête de lecture (1)")
                    Spacer()
                }
                caption("Temps par mesure : change l'espacement des barres, et le "
                        + "repère du premier temps.")
                caption("1", "Poser le premier temps de la mesure à la tête de lecture.")
            } else {
                HStack(spacing: 8) {
                    Text("tempo indéterminé").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Button { model.recomputeTempo() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Chercher une grille dans ce morceau.")
                        .disabled(model.spectrogram.columnCount == 0)
                    Spacer()
                }
                caption("Aucune grille trouvée dans ce morceau. Sans elle, ni barres "
                        + "de mesure ni relevé d'accords.")
            }
        }
        .controlSize(.small)
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("Contraste", value: $model.display.floorDb, range: -120...(-40),
                   format: { String(format: "%.0f dB", $0) },
                   help: """
                   Niveau rendu noir. Le monter nettoie le fond,
                   et retire du même coup ce bruit de l'aimant du curseur.
                   """)
            HStack(spacing: 8) {
                Button("Ouverture") { model.restoreOpeningContrast() }
                    .controlSize(.small)
                    .disabled(model.spectrogram.columnCount == 0)
                    .help("Revenir au contraste mesuré sur le morceau entier à son "
                          + "ouverture — le repère d'où l'on est parti. K")
                Button("Auto") { model.applyAutoContrast() }
                    .controlSize(.small)
                    .disabled(model.spectrogram.columnCount == 0)
                    .help("Régler noir, clair et pente d'après ce qui est à l'écran. ⇧K")
                Spacer()
            }
            caption("Le niveau rendu noir. Le monter nettoie le fond, et retire du "
                    + "même coup ce bruit de l'aimantation du curseur.")
            caption("K", "Revenir au contraste mesuré à l'ouverture du morceau ; "
                    + "⇧K le règle d'après ce qui est à l'écran.")
            slider("Zoom", value: Binding(get: { log2(model.verticalZoom) },
                                          set: { model.verticalZoom = pow(2, $0) }),
                   // 16× au maximum : au-delà, la vue butterait sur sa propre
                   // limite et le curseur continuerait de bouger sans effet.
                   range: 0...4, reset: 0,
                   format: { _ in String(format: "%.1f oct", model.visibleOctaves) },
                   help: """
                   Étale l'axe des fréquences ; la valeur donne le nombre d'octaves visibles.
                   Au trackpad : ⇧ + pincement, ou ⇧ + molette — ancré sous le curseur.
                   La lecture est filtrée sur la bande visible.
                   """)
            caption("Nombre d'octaves visibles. Au trackpad : ⇧ + pincement ou "
                    + "⇧ + molette, ancré sous le curseur. La lecture est filtrée sur "
                    + "la bande visible.")

            Picker("", selection: $model.display.colorMap) {
                ForEach(ColorMap.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .controlSize(.small)
            caption("Couleur des raies. « Notes » donne une teinte à chaque demi-ton, "
                    + "réparties selon le cycle des quintes : deux notes proches "
                    + "harmoniquement le sont aussi en couleur.")

            HStack(spacing: 8) {
                Toggle(isOn: $model.showDrumLane) {
                    Image(systemName: "circle.grid.cross").frame(width: 17)
                }
                .toggleStyle(.button)
                .help("""
                      Relevé de la batterie, sous l'image : un trait par coup, une ligne par voie.
                      Le spectrogramme dit la hauteur, qu'une percussion n'a pas ; ces trois lignes disent quand, quoi et combien fort.
                      Elles valent surtout sur la piste de batterie isolée.
                      """)
                Toggle(isOn: $model.showChords) {
                    Image(systemName: "textformat.abc").frame(width: 17)
                }
                .toggleStyle(.button)
                .help("""
                      Noms d'accords, au pied de la grille : un par temps, par mesure ou par phrase selon le zoom.
                      Devinés sur la basse et l'accompagnement séparés — il faut donc que les quatre pistes soient calculées, et qu'une grille métrique existe.
                      La pâleur d'un nom dit l'incertitude du relevé.
                      Comment ils sont devinés se règle dans ⌘, — dont une portée « un accord par mesure, ou par sélection ».
                      """)
                Picker("", selection: $model.display.useFlats) {
                    Text("♭").tag(true)
                    Text("♯").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 62)
                Spacer()
            }
            .controlSize(.small)
            caption("Ligne de batterie sous l'image ; noms d'accords au pied de la "
                    + "grille — les survoler les fait entendre et entoure leurs notes "
                    + "dans le spectre. À droite, l'écriture des touches noires : "
                    + "Mi♭ ou Ré♯.")
        }
    }

    private var stems: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if model.separating == nil, model.isSeparated {
                    Button { model.forgetStems() } label: {
                        Label("Effacer les pistes", systemImage: "trash")
                    }
                    .controlSize(.small)
                } else if model.separating != nil {
                    Text("séparation en cours").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
                Spacer()
            }
            if model.separating == nil, model.isSeparated {
                caption("Repartir du mixage. Les pistes se recalculent en une "
                        + "demi-minute si vous y revenez.")
            }
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
        let restore = { if let reset { value.wrappedValue = reset } }
        return VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2, perform: restore)
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .onTapGesture(count: 2, perform: restore)
            }
            Slider(value: value, in: range).controlSize(.small)
        }
        .help(help)
    }
}
