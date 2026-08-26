import AppKit
import SpectreCore
import SpectreModele
import SpectreMac
import SpectreTextes
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
        ConteneurDeVerre(espacement: 14) {
            HStack(alignment: .top, spacing: 10) {
                if panelOpen {
                    ControlPanel(model: model) { close() }
                        .frame(width: 320)
                        .verre(.regulier, in: .rect(cornerRadius: 24))
                        .identiteDeVerre("reglages", in: glass)
                        .transition(.opacity)
                        .onHover { model.pointerOverControls = $0 }
                }
                VStack(spacing: 10) {
                    if !panelOpen {
                        Button { open() } label: {
                            VStack(spacing: 1) {
                                Image(systemName: "slider.horizontal.3")
                                    .font(.system(size: 14))
                                Text(T(.panneauReglages)).font(.system(size: 8, weight: .medium))
                            }
                            // Même largeur que le sélecteur : deux objets alignés
                            // l'un sous l'autre et de largeurs voisines mais
                            // inégales se lisent comme un défaut d'alignement.
                            .frame(width: StemColumn.width, height: 40)
                            .contentShape(.capsule)
                        }
                        .buttonStyle(.plain)
                        .verre(.clairInteractif, in: .capsule)
                        .identiteDeVerre("reglages", in: glass)
                        .onHover { model.pointerOverControls = $0 }
                        .help(T(.panneauOuvrirAide))
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
        .verre(.clair, in: .capsule)
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
        .help(stem.help + T(.pisteDecocherAide))
    }
}

// MARK: Le panneau

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

/// Ce qu'on règle une fois par morceau : le tempo, la lecture, l'image,
/// l'affichage. Groupé par ce à quoi cela sert, chaque groupe portant son nom.
///
/// ─────────────────────────────────────────────────────────────────────────
/// TOUT CE QUI EXPLIQUE EST DANS UNE INFOBULLE
///
/// Le panneau a porté ses explications en clair, sous chaque commande, et
/// chaque raccourci sur sa propre ligne. C'était juste une fois : à la
/// première ouverture. Ensuite, on connaît ses réglages, et la phrase qui les
/// décrit n'est plus qu'une hauteur à faire défiler entre le tempo et le
/// contraste — au point de rendre le panneau plus long que la fenêtre.
///
/// Elles sont donc toutes passées en infobulle, sans en perdre une : survoler
/// une commande dit encore ce qu'elle change et par quelle touche on la
/// double. Ce qui reste à l'écran est ce qui **se règle**, et rien d'autre.
/// ─────────────────────────────────────────────────────────────────────────
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
                VStack(alignment: .leading, spacing: 16) {
                    group(T(.groupeTempo), T(.groupeTempoAide)) { tempo }
                    group(T(.groupeLecture), T(.groupeLectureAide)) { playback }
                    group(T(.groupeImage), T(.groupeImageAide)) { image }
                    group(T(.groupeAffichage), T(.groupeAffichageAide)) { display }
                    group(T(.groupeBoucle), T(.groupeBoucleAide)) { loop }
                    if model.isSeparated || model.separating != nil {
                        group(T(.groupePistes), T(.groupePistesAide)) { stems }
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
            Text(T(.panneauReglages)).font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .medium))
                    .frame(width: 22, height: 22)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .help(T(.panneauReplierAide))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// Un intitulé de groupe. Ce à quoi il sert se lit en le survolant : c'est la
    /// phrase qui était écrite dessous, et qui prenait deux lignes chaque fois
    /// qu'on ouvrait le panneau pour tourner un seul curseur.
    private func group<C: View>(_ title: String, _ note: String,
                                @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(.tertiary)
                .textCase(.uppercase)
                .help(note)
            content()
        }
    }

    // MARK: Groupes

    /// Le tempo, tout entier sur une ligne : le chiffre, les deux flèches, la
    /// signature, le premier temps, et de quoi relancer l'estimation.
    ///
    /// Sur une ligne parce que c'est **une** question — sur quelle grille ce
    /// morceau est-il écrit — et qu'on y répond d'un coup : on lit le chiffre, on
    /// le double s'il est faux, on pose le 1 au bon endroit, c'est fini.
    private var tempo: some View {
        Group {
            if model.tempo != nil {
                HStack(spacing: 5) {
                    // Une estimation peu franche est annoncée comme telle : mieux
                    // vaut un « à peu près » visible qu'une grille faussement
                    // assurée.
                    if let t = model.tempo, t.confidence > 0, t.confidence < 2.2 {
                        Text("≈").font(.system(size: 11)).foregroundStyle(.orange)
                            .help(T(.tempoEstimationFloue))
                    }
                    // Le tempo se tape. L'estimation se trompe le plus souvent d'un
                    // facteur deux, et l'écrire est alors plus direct que de
                    // chercher le bon bouton.
                    TextField("", value: Binding(get: { model.tempo?.bpm ?? 120 },
                                                 set: { model.setTempo($0) }),
                              format: .number.precision(.fractionLength(0...1)))
                        .font(.system(size: 11, design: .monospaced))
                        .multilineTextAlignment(.trailing)
                        .frame(width: 44)
                        .help(T(.tempoChampAide))
                    Text(T(.tempoBPM)).font(.system(size: 10)).foregroundStyle(.secondary)
                    Stepper("") { model.nudgeTempo(by: 0.1) } onDecrement: { model.nudgeTempo(by: -0.1) }
                        .labelsHidden()
                        .help(T(.tempoPasAide))
                    Picker("", selection: Binding(get: { model.beatsPerBar },
                                                  set: { model.beatsPerBar = $0 })) {
                        ForEach([2, 3, 4, 5, 6, 7], id: \.self) { Text("\($0)/4").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 62)
                    .help(T(.tempoSignatureAide))
                    Button(T(.tempoUnIci)) { model.setDownbeatAtPlayhead() }
                        .help(T(.tempoUnIciAide))
                    Button { model.recomputeTempo() } label: { Image(systemName: "arrow.clockwise") }
                        .help(T(.tempoRelancerAide))
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    Text(T(.tempoIndetermine)).font(.system(size: 10)).foregroundStyle(.tertiary)
                    Button { model.recomputeTempo() } label: { Image(systemName: "arrow.clockwise") }
                        .help(T(.tempoChercherAide))
                        .disabled(model.spectrogram.columnCount == 0)
                    Spacer()
                }
            }
        }
        .controlSize(.small)
    }

    private var playback: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 9) {
                Button { model.togglePlayback() } label: {
                    Image(systemName: model.player.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 18)
                }
                .disabled(model.duration == 0)
                .help(T(.lectureLireAide))
                PlayheadClock(model: model)
                Spacer()
            }
            // En pourcentage et non en « × » : c'est ainsi que se disent les
            // ralentis partout ailleurs — 75 % se compare tout de suite à 100 %,
            // là où ×0,75 demande un instant.
            slider(T(.lectureVitesse), value: $model.player.speed, range: 0.25...1.5,
                   reset: 1, format: { String(format: "%.0f %%", $0 * 100) },
                   help: T(.lectureVitesseAide))
            slider(T(.lectureTransposition), value: $model.player.transpose, range: -12...12,
                   reset: 0, format: {
                       // Un demi-ton entier s'écrit sans décimale ; une valeur
                       // intermédiaire, elle, doit se voir.
                       String(format: abs($0 - $0.rounded()) < 0.005 ? "%+.0f " : "%+.1f ", $0)
                           + T(.uniteDemiTons)
                   },
                   help: T(.lectureTranspositionAide))
        }
    }

    private var image: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider(T(.imageContraste), value: $model.display.floorDb, range: -120...(-40),
                   format: { String(format: "%.0f dB", $0) },
                   help: T(.imageContrasteAide))
            // « Global » et « local » disent la seule chose qui les sépare : sur
            // quoi le réglage est mesuré. L'un relit le morceau entier, l'autre ce
            // que la fenêtre montre en ce moment.
            HStack(spacing: 8) {
                Button(T(.imageAutoGlobal)) { model.restoreOpeningContrast() }
                    .disabled(model.spectrogram.columnCount == 0)
                    .help(T(.imageAutoGlobalAide))
                Button(T(.imageAutoLocal)) { model.applyAutoContrast() }
                    .disabled(model.spectrogram.columnCount == 0)
                    .help(T(.imageAutoLocalAide))
                Spacer()
            }
            .controlSize(.small)
            slider(T(.imageZoomVertical), value: Binding(get: { log2(model.verticalZoom) },
                                                   set: { model.verticalZoom = pow(2, $0) }),
                   // 16× au maximum : au-delà, la vue butterait sur sa propre
                   // limite et le curseur continuerait de bouger sans effet.
                   range: 0...4, reset: 0,
                   format: { _ in String(format: "%.1f ", model.visibleOctaves)
                                 + T(.uniteOctaves) },
                   help: T(.imageZoomVerticalAide))
        }
    }

    private var display: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $model.showDrumLane) {
                Label(T(.affichageBatterie), systemImage: "circle.grid.cross")
            }
            .toggleStyle(.button)
            .help(T(.affichageBatterieAide))
            Toggle(isOn: $model.showChords) {
                Label(T(.affichageAccords), systemImage: "textformat.abc")
            }
            .toggleStyle(.button)
            .help(T(.affichageAccordsAide))
            Picker("", selection: $model.display.useFlats) {
                Text("♭").tag(true)
                Text("♯").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 58)
            .help(T(.affichageTouchesNoiresAide))
            Spacer()
        }
        .controlSize(.small)
    }

    private var loop: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: $model.loopEnabled) { Image(systemName: "repeat") }
                    .toggleStyle(.button)
                    .disabled(model.loop == nil)
                    .help(T(.boucleJouerAide))
                if model.loop != nil {
                    Button(T(.boucleMesures)) { model.snapLoopToBars() }
                        .disabled(model.tempo == nil)
                        .help(T(.boucleAuxMesuresAide))
                    Button { model.loop = nil } label: { Image(systemName: "xmark") }
                        .help(T(.boucleEffacerAide))
                }
                Spacer()
            }
            if let loop = model.loop {
                Text("\(AppModel.format(loop.lowerBound)) → \(AppModel.format(loop.upperBound))")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .controlSize(.small)
    }

    private var stems: some View {
        HStack(spacing: 8) {
            if model.separating == nil, model.isSeparated {
                Button { model.forgetStems() } label: {
                    Label(T(.pistesEffacerLesPistes), systemImage: "trash")
                }
                .controlSize(.small)
                .help(T(.pistesEffacerAide))
            } else if model.separating != nil {
                Text(T(.pistesSeparationEnCours)).font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
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

// MARK: Le verre, et ce qui le remplace en dessous de macOS 26

// Spectre s'ouvre depuis macOS 15, et Liquid Glass n'existe qu'à partir de 26.
// Les six appels au verre passent donc par les trois enveloppes ci-dessous, qui
// sont **le seul endroit du dépôt où `#available` parle d'interface**. Les vues
// au-dessus ne savent pas sur quel système elles tournent, et c'est ce qui évite
// d'entretenir deux interfaces au lieu d'une.
//
// Le repli n'imite pas le verre — il n'y arriverait pas, et un faux verre se
// remarque plus qu'une surface franche. Il garde ce à quoi le verre sert ici :
// **laisser voir le spectrogramme qu'il couvre**. D'où deux traitements et non
// un seul, exactement comme au-dessus : le panneau des réglages dépolit ce qu'il
// couvre (un matériau translucide), le sélecteur de pistes ne fait que se poser
// dessus (un voile clair et un liseré, les raies continuent de passer).

/// Les trois verres employés dans ce fichier. Un simple `enum` parce que le type
/// `Glass` de SwiftUI n'existe pas avant macOS 26 : il ne peut donc pas figurer
/// dans une signature que le système d'en dessous doit lire.
enum Verre {
    /// Le panneau : il dépolit, on ne lit pas au travers.
    case regulier
    /// Le sélecteur de pistes : posé sur l'image sans la troubler.
    case clair
    /// Le bouton des réglages : du verre clair qui répond au survol.
    case clairInteractif
}

extension View {
    /// Pose l'un des trois verres, ou ce qui le remplace en dessous de macOS 26.
    @ViewBuilder
    func verre<S: InsettableShape>(_ style: Verre, in forme: S) -> some View {
        if #available(macOS 26, *) {
            switch style {
            case .regulier: glassEffect(.regular, in: forme)
            case .clair: glassEffect(.clear, in: forme)
            case .clairInteractif: glassEffect(.clear.interactive(), in: forme)
            }
        } else {
            // Le liseré est ce qui donne un bord à une surface sans ombre portée.
            // Sans lui, un voile à 8 % sur du noir n'a pas de contour du tout.
            background(fond(style), in: forme)
                .overlay(forme.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
                .clipShape(forme)
        }
    }

    /// Ce que le verre devient : un matériau pour le panneau, un voile pour ce qui
    /// se pose sur l'image.
    private func fond(_ style: Verre) -> AnyShapeStyle {
        switch style {
        case .regulier: AnyShapeStyle(.ultraThinMaterial)
        case .clair, .clairInteractif: AnyShapeStyle(Color.white.opacity(0.10))
        }
    }

    /// Le lien qui fait qu'ouvrir le panneau déplie le bouton au lieu d'ajouter une
    /// seconde forme. En dessous de macOS 26 il n'y a pas de morphose : la
    /// transition d'opacité déjà posée sur le panneau suffit à ce que l'échange se
    /// lise.
    @ViewBuilder
    func identiteDeVerre(_ nom: String, in espace: Namespace.ID) -> some View {
        if #available(macOS 26, *) {
            glassEffectID(nom, in: espace)
        } else {
            self
        }
    }
}

/// L'espace où plusieurs morceaux de verre se reconnaissent comme un seul. En
/// dessous de macOS 26, il ne reste que ce que le conteneur contenait.
struct ConteneurDeVerre<Contenu: View>: View {
    let espacement: CGFloat
    @ViewBuilder let contenu: Contenu

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: espacement) { contenu }
        } else {
            contenu
        }
    }
}
