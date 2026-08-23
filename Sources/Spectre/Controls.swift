import AppKit
import SpectreCore
import SpectreModele
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
                        .frame(width: 320)
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
                    group("Détection du tempo",
                          "Estimée à l'ouverture d'après les attaques. Elle commande "
                          + "les barres de mesure, l'aimantation et le relevé des "
                          + "accords.") { tempo }
                    group("Lecture",
                          "Ce qui se joue, et comment. Cliquer dans l'image déplace "
                          + "la tête de lecture et fait sonner la raie désignée.") { playback }
                    group("Image",
                          "Ce que le spectrogramme montre : jusqu'où descendre dans "
                          + "le fond, et sur combien d'octaves l'étaler.") { image }
                    group("Affichage",
                          "Ce qui se pose autour de l'image : la ligne de batterie, "
                          + "les noms d'accords, l'écriture des touches noires.") { display }
                    group("Boucle",
                          "Tracer une boucle : glisser dans la réglette du haut, ou "
                          + "⇧ + glisser dans l'image. Glisser la zone jaune la "
                          + "déplace, ses bords l'étendent ; les bornes se posent sur "
                          + "la grille, et ⌘ pendant le geste les libère.") { loop }
                    if model.isSeparated || model.separating != nil {
                        group("Pistes",
                              "Les quatre pistes séparées, celles que la colonne de "
                              + "droite fait entendre.") { stems }
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
                        .frame(width: 44)
                        .help("Cliquer sur le chiffre pour le saisir : l'estimation "
                              + "se trompe surtout d'un facteur deux, qu'on corrige "
                              + "d'un chiffre.")
                    Text("BPM").font(.system(size: 10)).foregroundStyle(.secondary)
                    Stepper("") { model.nudgeTempo(by: 0.1) } onDecrement: { model.nudgeTempo(by: -0.1) }
                        .labelsHidden()
                        .help("Ajuster de 0,1 BPM — de quoi rattraper une grille qui dérive sur la longueur.")
                    Picker("", selection: Binding(get: { model.beatsPerBar },
                                                  set: { model.beatsPerBar = $0 })) {
                        ForEach([2, 3, 4, 5, 6, 7], id: \.self) { Text("\($0)/4").tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 62)
                    .help("Temps par mesure. Change l'espacement des barres, et le repère du premier temps.")
                    Button("1 ici") { model.setDownbeatAtPlayhead() }
                        .help("Poser le premier temps de la mesure à la tête de lecture (1)")
                    Button { model.recomputeTempo() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Relancer l'estimation, avec la signature choisie.")
                    Spacer(minLength: 0)
                }
            } else {
                HStack(spacing: 8) {
                    Text("tempo indéterminé").font(.system(size: 10)).foregroundStyle(.tertiary)
                    Button { model.recomputeTempo() } label: { Image(systemName: "arrow.clockwise") }
                        .help("Chercher une grille dans ce morceau. Sans elle, ni "
                              + "barres de mesure ni relevé d'accords.")
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
                .help("""
                      Lire ou mettre en pause (espace).
                      Cliquer dans l'image déplace la tête de lecture, et fait sonner la raie désignée.
                      """)
                PlayheadClock(model: model)
                Spacer()
            }
            // En pourcentage et non en « × » : c'est ainsi que se disent les
            // ralentis partout ailleurs — 75 % se compare tout de suite à 100 %,
            // là où ×0,75 demande un instant.
            slider("Vitesse", value: $model.player.speed, range: 0.25...1.5,
                   reset: 1, format: { String(format: "%.0f %%", $0 * 100) },
                   help: """
                   Ralentit ou accélère sans toucher à la hauteur.
                   Un cran ramène exactement à 100 %, où le traitement est retiré du chemin du son.
                   Double-clic sur le texte pour y revenir.
                   """)
            slider("Transposition", value: $model.player.transpose, range: -12...12,
                   reset: 0, format: {
                       // Un demi-ton entier s'écrit sans décimale ; une valeur
                       // intermédiaire, elle, doit se voir.
                       String(format: abs($0 - $0.rounded()) < 0.005 ? "%+.0f dt" : "%+.1f dt", $0)
                   },
                   help: """
                   Transpose sans toucher à la vitesse, en demi-tons.
                   Les valeurs intermédiaires recalent un enregistrement désaccordé.
                   Double-clic sur le texte pour revenir à +0.
                   """)
        }
    }

    private var image: some View {
        VStack(alignment: .leading, spacing: 8) {
            slider("Contraste", value: $model.display.floorDb, range: -120...(-40),
                   format: { String(format: "%.0f dB", $0) },
                   help: """
                   Niveau rendu noir. Le monter nettoie le fond,
                   et retire du même coup ce bruit de l'aimant du curseur.
                   """)
            // « Global » et « local » disent la seule chose qui les sépare : sur
            // quoi le réglage est mesuré. L'un relit le morceau entier, l'autre ce
            // que la fenêtre montre en ce moment.
            HStack(spacing: 8) {
                Button("Auto global") { model.restoreOpeningContrast() }
                    .disabled(model.spectrogram.columnCount == 0)
                    .help("Revenir au contraste mesuré sur le morceau entier à son "
                          + "ouverture — le repère d'où l'on est parti. K")
                Button("Auto local") { model.applyAutoContrast() }
                    .disabled(model.spectrogram.columnCount == 0)
                    .help("Régler noir, clair et pente d'après ce qui est à l'écran. ⇧K")
                Spacer()
            }
            .controlSize(.small)
            slider("Zoom vertical", value: Binding(get: { log2(model.verticalZoom) },
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
        }
    }

    private var display: some View {
        HStack(spacing: 8) {
            Toggle(isOn: $model.showDrumLane) {
                Label("Batterie", systemImage: "circle.grid.cross")
            }
            .toggleStyle(.button)
            .help("""
                  Relevé de la batterie, sous l'image : un trait par coup, une ligne par voie.
                  Le spectrogramme dit la hauteur, qu'une percussion n'a pas ; ces trois lignes disent quand, quoi et combien fort.
                  Elles valent surtout sur la piste de batterie isolée.
                  """)
            Toggle(isOn: $model.showChords) {
                Label("Accords", systemImage: "textformat.abc")
            }
            .toggleStyle(.button)
            .help("""
                  Noms d'accords, au pied de la grille : un par temps, par mesure ou par phrase selon le zoom.
                  Devinés sur la basse et l'accompagnement séparés — il faut donc que les quatre pistes soient calculées, et qu'une grille métrique existe.
                  Les survoler les fait entendre et entoure leurs notes dans le spectre ; la pâleur d'un nom dit l'incertitude du relevé.
                  """)
            Picker("", selection: $model.display.useFlats) {
                Text("♭").tag(true)
                Text("♯").tag(false)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 58)
            .help("L'écriture des touches noires : Mi♭ ou Ré♯.")
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
                    .help("""
                          Jouer le passage en boucle, sans trou à la reprise (L).
                          [ et ] posent le début et la fin à la tête de lecture.
                          """)
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
            }
        }
        .controlSize(.small)
    }

    private var stems: some View {
        HStack(spacing: 8) {
            if model.separating == nil, model.isSeparated {
                Button { model.forgetStems() } label: {
                    Label("Effacer les pistes", systemImage: "trash")
                }
                .controlSize(.small)
                .help("Repartir du mixage. Les pistes se recalculent en une "
                      + "demi-minute si vous y revenez.")
            } else if model.separating != nil {
                Text("séparation en cours").font(.system(size: 10)).foregroundStyle(.tertiary)
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
