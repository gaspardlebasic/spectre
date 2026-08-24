import Foundation
import SpectreCore
import SpectreTextes
import SpectreModele
import SpectreToile

// La barre du bas : où l'on en est, et ce qui se passe.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE QU'ELLE DIT, ET CE QU'ELLE NE RÈGLE PAS
//
// Elle ne porte aucune commande, et c'est délibéré : les réglages vivent dans le
// panneau (`Panneau.swift`, `Reglages.swift`), qu'on déplie et qu'on referme. Une
// barre qui réglerait quelque chose devrait rester assez haute pour qu'on vise
// dedans, en permanence, au détriment de l'image — alors qu'on touche un curseur
// une fois par morceau.
//
// Ce qui est ici est ce qu'on veut savoir **pendant** qu'on travaille : où en est
// la lecture, à quelle vitesse, dans quel ton, à quel tempo, et ce que le modèle a
// à dire. Faute de message, elle rappelle les touches — parce qu'une interface qui
// cache ses raccourcis n'en a pas.
// ─────────────────────────────────────────────────────────────────────────────

public struct Barre<Lecteur: LecteurAudio> {
    let modele: AppModel<Lecteur>
    let pinceau: Pinceau
    let largeur: Double
    let haut: Double
    let hauteur: Double

    public init(modele: AppModel<Lecteur>, pinceau: Pinceau,
                largeur: Double, haut: Double, hauteur: Double) {
        self.modele = modele
        self.pinceau = pinceau
        self.largeur = largeur
        self.haut = haut
        self.hauteur = hauteur
    }

    public func dessiner() {
        pinceau.remplir(0, haut, largeur, hauteur, Pinceau.gris(0.09, 1))
        pinceau.tracer(0, haut + 0.25, largeur, haut + 0.25, Pinceau.blanc(0.10))
        let milieu = haut + hauteur / 2

        // ── À gauche : le temps, en chasse fixe pour qu'il ne tremble pas ──────
        var x = 12.0
        let position = AppModel<Lecteur>.format(modele.playhead)
        let duree = AppModel<Lecteur>.format(modele.duration)
        pinceau.texte(modele.player.isPlaying ? "▶" : "❚❚", x: x, y: milieu,
                      largeur: 16, taille: 10, Pinceau.blanc(0.75))
        x += 22
        pinceau.texte("\(position) / \(duree)", x: x, y: milieu, largeur: 150,
                      taille: 11, Pinceau.blanc(0.85), police: .chiffres)
        x += 160

        // ── Vitesse et transposition, quand elles ne sont pas neutres ─────────
        //
        // Le neutre ne s'affiche pas : une barre qui répète « ×1,00  +0 » à longueur
        // de journée apprend à ne plus être lue, et c'est précisément le jour où
        // l'on a oublié un ralenti qu'on aurait voulu la voir.
        if modele.player.speed != 1 {
            x += pinceau.etiquette(String(format: "×%.2f", modele.player.speed),
                                   x: x, y: milieu, taille: 10,
                                   Pinceau.rvb(0.55, 0.78, 1.0),
                                   fond: Pinceau.blanc(0.08)) + 16
        }
        if modele.player.transpose != 0 {
            x += pinceau.etiquette(String(format: "%+.1f ", modele.player.transpose)
                                   + T(.uniteDemiTonsLong),
                                   x: x, y: milieu, taille: 10,
                                   Pinceau.rvb(1.0, 0.78, 0.55),
                                   fond: Pinceau.blanc(0.08)) + 16
        }
        if let tempo = modele.tempo, tempo.bpm > 0 {
            pinceau.texte(String(format: "%.0f ", tempo.bpm) + T(.tempoBPM),
                          x: x, y: milieu,
                          largeur: 80, taille: 10, Pinceau.blanc(0.5))
            x += 78
        }
        if modele.loop != nil {
            pinceau.texte(modele.loopEnabled ? T(.winBarreBoucle)
                                             : T(.winBarreBoucleHorsService),
                          x: x, y: milieu, largeur: 130, taille: 10,
                          Pinceau.jaune(modele.loopEnabled ? 0.8 : 0.4))
            x += 130
        }

        // ── À droite : ce que le modèle a à dire, ou les touches ──────────────
        //
        // Un message chasse le rappel des touches, et pas l'inverse : ce qui vient
        // d'arriver importe plus que ce qu'on sait déjà.
        if let message = modele.player.message ?? modele.status ?? modele.separationError {
            pinceau.texte(message, x: largeur - 420, y: milieu, largeur: 408,
                          taille: 10, Pinceau.blanc(0.6), alignement: .droite)
        } else {
            pinceau.texte(T(.winBarreAide),
                          x: largeur - 480, y: milieu, largeur: 468, taille: 10,
                          Pinceau.blanc(0.32), alignement: .droite)
        }

        // ── L'avancement, sur toute la largeur ────────────────────────────────
        //
        // Une analyse dure quelques secondes et une séparation quelques minutes :
        // sans trait qui avance, les deux passent pour une fenêtre figée.
        if let avancement = modele.progress ?? modele.separating {
            pinceau.remplir(0, haut, largeur * min(max(avancement, 0), 1), 2,
                            Pinceau.rvb(0.35, 0.65, 1.0, 0.9))
        }
    }
}
