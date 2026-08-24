import Foundation
import SpectreCore
import SpectreTextes
import SpectreModele
import SpectreToile

// Les repères dessinés par-dessus le spectrogramme.
//
// ─────────────────────────────────────────────────────────────────────────────
// LE PENDANT EXACT DE `TimelineOverlay`
//
// Chaque fonction ici a son homonyme dans `Sources/Spectre/TimelineView.swift`,
// dans le même ordre, avec les mêmes seuils et les mêmes opacités. Les deux se
// lisent l'une contre l'autre — c'est délibéré, et c'est ce qui permettra de voir
// qu'elles ont divergé le jour où l'une des deux changera.
//
// Ce qui change, c'est l'outil : `GraphicsContext` de SwiftUI d'un côté, Direct2D
// de l'autre, derrière `Pinceau` qui en reprend le vocabulaire. Ce qui ne change
// pas, c'est **d'où viennent les nombres** : `model.point(ofTime:)`,
// `model.tempo`, `model.chords`, `model.snap`. Aucune décision n'est prise ici.
// ─────────────────────────────────────────────────────────────────────────────

/// Hauteur de la bande de batterie, en bas de la fenêtre. La même que sur le Mac —
/// `drumLaneHeight` — où elle est une vue à part sous le spectrogramme. Trois
/// rangées de dix-sept points, plus les écarts : soixante-deux exactement, et pas
/// une de plus, sinon la bande garde une lisière noire qui a l'air d'un oubli.
public let hauteurDeLaBatterie = 62.0
/// Hauteur de la barre d'état, tout en bas.
public let hauteurDeLaBarre = 30.0
/// Hauteur de la réglette du haut, en points. La même valeur que dans la vue
/// macOS. Elle est ici, avec les deux autres, parce qu'elle décide à la fois de ce
/// qui se dessine et de l'endroit où un glisser trace une boucle plutôt que de
/// déplacer la tête : les deux doivent lire le même nombre, sinon la zone sensible
/// se décolle de la zone dessinée.
public let hauteurDeLaReglette = 20.0

public struct Frise<Lecteur: LecteurAudio> {
    let modele: AppModel<Lecteur>
    let pinceau: Pinceau
    /// Taille de la zone du spectrogramme, en points — barre et batterie exclues.
    let largeur: Double
    let hauteur: Double

    public init(modele: AppModel<Lecteur>, pinceau: Pinceau,
                largeur: Double, hauteur: Double) {
        self.modele = modele
        self.pinceau = pinceau
        self.largeur = largeur
        self.hauteur = hauteur
    }

    var bandeDesAccords: Double { Reglages.chordBandHeight }

    public func dessiner() {
        guard modele.spectrogram.columnCount > 0 else {
            attente()
            return
        }
        grilleMetrique()
        octaves()
        accords()
        notesDeLAccord()
        boucle()
        reglette()
        teteDeLecture()
        aimantation()
    }

    // MARK: Rien à montrer

    /// Une fenêtre vide sans explication passe pour une panne.
    private func attente() {
        let message = modele.status ?? T(.winFriseOuvrir)
        pinceau.texte(message, x: 0, y: hauteur / 2, largeur: largeur, taille: 13,
                      Pinceau.blanc(0.55), alignement: .centre)
        if let avancement = modele.progress, avancement > 0 {
            let l = largeur * 0.4
            let x = (largeur - l) / 2
            let y = hauteur / 2 + 22
            pinceau.remplir(x, y, l, 3, Pinceau.blanc(0.15))
            pinceau.remplir(x, y, l * min(max(avancement, 0), 1), 3, Pinceau.blanc(0.7))
        }
    }

    // MARK: Grille métrique

    /// Mesures, temps, ou subdivisions : la densité suit le zoom, de sorte qu'on ne
    /// voie jamais une bouillie de traits ni une grille absente.
    private func grilleMetrique() {
        guard modele.display.showGrid, let tempo = modele.tempo, tempo.bpm > 0 else { return }
        let pointsParTemps = tempo.beatSeconds
            / modele.spectrogram.secondsPerColumn / modele.viewport.columnsPerPoint
        guard pointsParTemps > 0.5 else { return }

        let tempsParMesure = Double(max(tempo.beatsPerBar, 1))
        // Le pas est celui du modèle : ce qu'on dessine est exactement ce sur quoi
        // la boucle s'aimante.
        guard let subdivision = modele.gridUnit else { return }

        let premier = (tempo.beat(at: modele.time(atPoint: 0)) / subdivision)
            .rounded(.down) * subdivision
        let dernier = tempo.beat(at: modele.time(atPoint: largeur))
        var temps = premier
        while temps <= dernier {
            defer { temps += subdivision }
            let instant = tempo.time(ofBeat: temps)
            guard instant >= 0 else { continue }
            let x = modele.point(ofTime: instant)
            // Quatre degrés de clarté pour quatre degrés de découpage. La phrase est
            // le seul trait qu'on lise encore quand on regarde le morceau entier ;
            // zoomé, elle donne le « un » de chaque groupe de quatre mesures, qu'on
            // cherchait jusqu'ici en comptant.
            let phrase = tempo.opensPhrase(temps)
            let mesure = tempo.opensBar(temps)
            let surLeTemps = abs(temps.rounded() - temps) < 1e-6
            let couleur = phrase ? Pinceau.blanc(0.38)
                : mesure ? Pinceau.blanc(0.24)
                : surLeTemps ? Pinceau.blanc(0.11) : Pinceau.blanc(0.05)
            pinceau.vertical(x: x, de: hauteurDeLaReglette, a: hauteur, couleur,
                             epaisseur: mesure ? 0.75 : 0.5)
        }

        // Numéros de mesure : tous tant qu'ils ont la place, sinon un par phrase.
        // Une grille sans un seul numéro ne dit plus où l'on est, et c'est
        // précisément dézoomé qu'on se le demande.
        let pointsParMesure = pointsParTemps * tempsParMesure
        let parPhrase = Double(TempoGrid.barsPerPhrase)
        let pas: Double = pointsParMesure >= 44 ? 1
            : pointsParMesure * parPhrase >= 32 ? parPhrase : 0
        guard pas > 0 else { return }
        var mesure = (tempo.beat(at: modele.time(atPoint: 0)) / (tempsParMesure * pas))
            .rounded(.down) * pas
        while tempo.time(ofBeat: mesure * tempsParMesure) <= modele.time(atPoint: largeur) {
            defer { mesure += pas }
            let instant = tempo.time(ofBeat: mesure * tempsParMesure)
            guard instant >= 0 else { continue }
            pinceau.texte("\(Int(mesure) + 1)",
                          x: modele.point(ofTime: instant) + 4,
                          y: hauteurDeLaReglette + 9, largeur: 40, taille: 9,
                          Pinceau.blanc(0.38))
        }
    }

    // MARK: Octaves

    private func octaves() {
        guard modele.display.showGrid else { return }
        let geometrie = modele.spectrogram.layout
        for repere in Pitch.octaveMarkers(from: geometrie.minFrequency,
                                          to: geometrie.maxFrequency,
                                          referenceA: modele.display.referenceA) {
            let y = modele.point(ofFrequency: repere.frequency)
            guard y > hauteurDeLaReglette + 6, y < hauteur else { continue }
            pinceau.tracer(0, y, largeur, y, Pinceau.blanc(0.16))
            pinceau.texte(repere.label, x: 8, y: y - 7, largeur: 60, taille: 9,
                          Pinceau.blanc(0.5))
        }
    }

    // MARK: Accords

    private func accords() {
        // Une bande vide sans explication passe pour une panne. Elle dit donc ce qui
        // manque — la séparation, ou la grille — plutôt que de rester muette.
        let haut = hauteur - bandeDesAccords
        if let avis = modele.chordNotice {
            pinceau.remplir(0, haut, largeur, bandeDesAccords, Pinceau.noir(0.55))
            pinceau.texte(avis, x: 0, y: haut + bandeDesAccords / 2, largeur: largeur,
                          taille: 10, Pinceau.blanc(0.45), alignement: .centre)
            return
        }
        guard modele.showChords, !modele.chords.isEmpty,
              let tempo = modele.tempo, tempo.bpm > 0, let unite = modele.gridUnit
        else { return }
        // Sous le temps, on ne descend pas : personne ne change d'accord à la double
        // croche, et quatre noms par temps seraient illisibles.
        let groupe = max(1, Int(unite.rounded()))
        let etiquettes = modele.chords.labels(from: modele.time(atPoint: 0),
                                              to: modele.time(atPoint: largeur),
                                              grouping: groupe)
        guard !etiquettes.isEmpty else { return }

        // Un fond, sinon les noms se perdent dans les graves de l'image — qui sont
        // justement la partie la plus dense, et celle qui les touche.
        pinceau.remplir(0, haut, largeur, bandeDesAccords, Pinceau.noir(0.55))

        var occupe = -Double.infinity
        for segment in etiquettes {
            guard let accord = segment.chord else { continue }
            let x = modele.point(ofTime: segment.start)
            guard x < largeur else { break }
            // La marge de confiance se lit sur la pâleur : un accord deviné de
            // justesse ne doit pas s'afficher du même ton qu'un accord évident.
            let opacite = 0.45 + 0.5 * segment.confidence
            let nom = accord.label(flats: modele.display.useFlats)
            let l = pinceau.largeur(nom, taille: 11)
            guard x + l > 0 else { continue }
            // Deux noms ne se chevauchent jamais : celui qui n'a pas la place est
            // sauté, et son trait de grille reste seul. Mieux vaut un nom manquant
            // qu'une bouillie de lettres.
            guard x >= occupe + 6 else { continue }
            occupe = x + l
            pinceau.texte(nom, x: x + 3, y: haut + bandeDesAccords / 2, largeur: l + 4,
                          taille: 11, Pinceau.blanc(opacite))
        }
    }

    /// Les raies sur lesquelles l'accord survolé a été décidé, entourées et nommées.
    ///
    /// **Toutes celles qui ont compté, à toutes leurs octaves** — c'est le contrat du
    /// relevé par raies : le cadre ne montre pas une idée de l'accord, il montre les
    /// traits mêmes que le relevé a lus dans cette image.
    private func notesDeLAccord() {
        guard let segment = modele.hoveredChord, let accord = segment.chord else { return }
        let notes = modele.hoveredChordNotes
        guard !notes.isEmpty else { return }

        let x0 = max(modele.point(ofTime: segment.start), 0)
        let x1 = min(modele.point(ofTime: segment.end), largeur)
        guard x1 > x0 else { return }

        // La durée de l'accord s'éclaire à peine : c'est le cadre de lecture, pas
        // l'information.
        pinceau.remplir(x0, hauteurDeLaReglette, x1 - x0,
                        hauteur - hauteurDeLaReglette - bandeDesAccords,
                        Pinceau.blanc(0.05))

        for note in notes {
            let frequence = Pitch.frequency(ofMidi: Double(note.midi),
                                            referenceA: modele.display.referenceA)
            let y = modele.point(ofFrequency: frequence)
            // La hauteur du cadre est celle d'un demi-ton à ce zoom-là : il entoure
            // exactement ce qu'il désigne, et grandit quand on grossit l'image.
            let demi = abs(modele.point(ofFrequency: Pitch.frequency(
                ofMidi: Double(note.midi) - 0.5,
                referenceA: modele.display.referenceA)) - y)
            let epaisseur = min(max(demi * 2, 3), 40)
            guard y + epaisseur > hauteurDeLaReglette,
                  y - epaisseur < hauteur - bandeDesAccords else { continue }

            let couleur = couleurDeNote(note.pitchClass)
            let opacite: Double
            var trait = 1.0
            var pointille = false
            switch note.role {
            case .root: opacite = 0.95; trait = 1.5
            case .chord: opacite = 0.7
            case .extra:
                opacite = 0.6
                // Pointillés : tenue, mais étrangère au nom. On la montre pour qu'on
                // voie ce que le relevé a dû laisser de côté.
                pointille = true
            }
            pinceau.cadre(x0, y - epaisseur / 2, x1 - x0, epaisseur,
                          teinte(couleur, opacite), epaisseur: trait, pointille: pointille)

            // Le nom se pose à gauche du cadre quand la place existe, dedans sinon.
            let nom = note.name(flats: modele.display.useFlats)
                + (note.role == .extra ? " ?" : "")
            let l = pinceau.largeur(nom, taille: 10)
            let gauche = x0 - l - 5
            let couleurDuNom = teinte(couleur, note.role == .extra ? 0.75 : 1)
            if gauche > 2 {
                pinceau.etiquette(nom, x: gauche, y: y, taille: 10, couleurDuNom)
            } else {
                pinceau.etiquette(nom, x: x0 + 5, y: y, taille: 10, couleurDuNom)
            }
        }

        // Et le nom de l'accord lui-même, en grand, pour qu'on sache ce qu'on regarde.
        pinceau.texte(accord.label(flats: modele.display.useFlats),
                      x: x0 + 4, y: hauteurDeLaReglette + 12, largeur: 200, taille: 13,
                      Pinceau.blanc(0.9))
    }

    /// La teinte suit la rotation choisie dans les préférences : un cadre doit avoir
    /// la couleur de la raie qu'il entoure, pas une autre.
    private func couleurDeNote(_ classe: Int) -> (r: Double, g: Double, b: Double) {
        NotePalette.color(pitchClass: ((classe % 12) + 12) % 12,
                          intensity: 0.9,
                          saturation: modele.display.noteSaturation,
                          origin: modele.préférences.hueOrigin)
    }

    private func teinte(_ c: (r: Double, g: Double, b: Double), _ opacite: Double) -> UInt32 {
        Pinceau.rvb(c.r, c.g, c.b, opacite)
    }

    // MARK: Boucle

    private func boucle() {
        guard let plage = modele.loop else { return }
        let x0 = modele.point(ofTime: plage.lowerBound)
        let x1 = modele.point(ofTime: plage.upperBound)
        let active = modele.loopEnabled

        // Ce qui est hors de la boucle s'assombrit : on voit d'un coup d'œil ce qui
        // va être joué, sans avoir à lire deux traits.
        let dehors = Pinceau.noir(active ? 0.42 : 0.18)
        pinceau.remplir(0, hauteurDeLaReglette, max(x0, 0),
                        hauteur - hauteurDeLaReglette, dehors)
        pinceau.remplir(min(x1, largeur), hauteurDeLaReglette, max(largeur - x1, 0),
                        hauteur - hauteurDeLaReglette, dehors)

        let bord = Pinceau.jaune(active ? 0.9 : 0.4)
        for x in [x0, x1] {
            pinceau.vertical(x: x, de: 0, a: hauteur, bord, epaisseur: 1)
        }
        pinceau.remplir(x0, 0, max(x1 - x0, 0), hauteurDeLaReglette,
                        Pinceau.jaune(active ? 0.3 : 0.12))

        // Longueur du passage, en secondes et — si la grille est là — en mesures.
        var nom = AppModel<Lecteur>.format(plage.upperBound - plage.lowerBound)
        if let tempo = modele.tempo, tempo.barSeconds > 0 {
            let mesures = (plage.upperBound - plage.lowerBound) / tempo.barSeconds
            nom += String(format: "  ·  %.2g ", mesures) + T(.uniteMesures)
        }
        guard x1 - x0 > 90 else { return }
        pinceau.texte(nom, x: x0, y: hauteurDeLaReglette / 2, largeur: x1 - x0,
                      taille: 9, Pinceau.noir(0.8), alignement: .centre)
    }

    // MARK: Réglette

    private func reglette() {
        pinceau.remplir(0, 0, largeur, hauteurDeLaReglette, Pinceau.noir(0.45))

        let secondes = modele.spectrogram.secondsPerColumn * modele.viewport.columnsPerPoint
        let candidats: [Double] = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        let pas = candidats.first { $0 >= secondes * 90 } ?? 600
        var t = (modele.time(atPoint: 0) / pas).rounded(.down) * pas
        let fin = modele.time(atPoint: largeur)
        while t <= fin {
            defer { t += pas }
            guard t >= 0 else { continue }
            let x = modele.point(ofTime: t)
            pinceau.vertical(x: x, de: 0, a: hauteurDeLaReglette, Pinceau.blanc(0.3))
            pinceau.texte(AppModel<Lecteur>.format(t), x: x + 4, y: hauteurDeLaReglette / 2,
                          largeur: 60, taille: 9, Pinceau.blanc(0.6), police: .chiffres)
        }
    }

    // MARK: Tête de lecture

    /// Sur le Mac, elle est un calque à part — un rectangle que le compositeur
    /// décale, pour ne pas refaire la grille et les accords à chaque image. Ici tout
    /// est redessiné de toute façon à chaque image, et un trait de plus ne coûte
    /// rien : la raison d'être du calque disparaît avec le compositeur.
    private func teteDeLecture() {
        let x = modele.point(ofTime: modele.playhead)
        guard x >= 0, x <= largeur else { return }
        pinceau.vertical(x: x, de: 0, a: hauteur, Pinceau.blanc(0.85), epaisseur: 1)
    }

    // MARK: Aimantation

    /// Le curseur ne dit pas ce qu'il y a « sous le pixel » mais quelle raie est la
    /// plus proche — comme un graphique en courbe qui accroche le point de donnée
    /// voisin. Les régions rendues noires par les réglages n'attirent rien.
    private func aimantation() {
        guard let survol = modele.hover else { return }
        let texte: String
        let ancre: CGPoint

        if let accroche = modele.snap {
            let x = modele.point(ofTime: accroche.time)
            let y = modele.point(ofFrequency: accroche.frequency)
            ancre = CGPoint(x: x, y: y)

            pinceau.tracer(survol.x, survol.y, x, y, Pinceau.blanc(0.35))
            pinceau.tracer(0, y, largeur, y, Pinceau.blanc(0.3), pointille: true)
            pinceau.cercle(x, y, rayon: 4.5, Pinceau.blanc(1), epaisseur: 1.5)

            texte = String(format: "%@   %.1f Hz   %@",
                           Pitch.noteName(for: accroche.frequency,
                                          referenceA: modele.display.referenceA,
                                          flats: modele.display.useFlats,
                                          withOctave: false),
                           accroche.frequency, AppModel<Lecteur>.format(accroche.time))
        } else {
            // Rien d'assez clair alentour : on retombe sur la lecture brute.
            let frequence = modele.frequency(atPoint: survol.y)
            ancre = survol
            pinceau.tracer(0, survol.y, largeur, survol.y, Pinceau.blanc(0.18))
            texte = String(format: "%.1f Hz   %@", frequence,
                           AppModel<Lecteur>.format(modele.time(atPoint: survol.x)))
        }

        let l = pinceau.largeur(texte, taille: 11)
        let x = min(max(ancre.x + 12, 4), largeur - l - 14)
        let y = max(ancre.y - 20, hauteurDeLaReglette + 12)
        pinceau.remplir(x - 5, y - 9, l + 10, 18, Pinceau.noir(0.6))
        pinceau.texte(texte, x: x, y: y, largeur: l + 4, taille: 11)
    }
}
