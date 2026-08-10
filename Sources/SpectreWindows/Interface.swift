import CImGui
import Foundation
import SpectreCore

/// La barre d'outils, et le panneau d'affichage.
///
/// Elle ne décide de rien : elle montre l'état et rend ce qu'on lui a demandé.
/// Les réglages qui se modifient sur place — contraste, palette, tempo — passent
/// par `inout`, parce que les changer n'a aucune conséquence au-delà d'eux-mêmes.
/// Les gestes qui en ont une — ouvrir, lire, recalculer — reviennent dans
/// `Demandes` et sont exécutés par la boucle principale, qui seule sait dans
/// quel ordre.
///
/// C'est la même répartition que sur macOS, où la vue SwiftUI lie les réglages
/// et appelle `AppModel` pour le reste. Les deux interfaces ne partagent pas une
/// ligne de code, mais elles partagent leur découpage — et surtout tout ce qui
/// est en dessous.
enum Interface {

    struct Demandes {
        var ouvrir = false
        var lireOuPause = false
        var revenirAuDebut = false
        var bornerDebut = false
        var bornerFin = false
        var calerSurMesures = false
        var effacerBoucle = false
        var contrasteAuto = false
        var premierTempsIci = false
        var recalculerTempo = false
    }

    /// `0:12,34` — minutes, secondes, centièmes, comme sur macOS.
    static func instant(_ secondes: Double) -> String {
        guard secondes.isFinite, secondes >= 0 else { return "—" }
        let total = Int(secondes)
        let cents = Int((secondes - Double(total)) * 100)
        return String(format: "%d:%02d,%02d", total / 60, total % 60, cents)
    }

    // La police par défaut d'ImGui ne porte que le latin-1 : les caractères
    // au-delà — les flèches, les points de suspension typographiques, le gamma —
    // s'afficheraient en carrés. Les libellés restent donc dans cette limite,
    // ce qui n'empêche ni les accents ni les cédilles.

    /// Les articles d'une liste déroulante, tels qu'ImGui les veut : séparés par
    /// des zéros et terminés par deux.
    private static func articles(_ noms: [String]) -> [CChar] {
        var octets = [CChar]()
        for nom in noms {
            octets.append(contentsOf: nom.utf8CString)   // le zéro final est compris
        }
        octets.append(0)
        return octets
    }

    private static let palettes = articles(ColorMap.allCases.map(\.label))
    private static let signatures = articles(["2/4", "3/4", "4/4", "5/4", "6/4", "7/4"])

    static func dessine(largeur: Float,
                        nom: String?,
                        raie: (frequence: Double, note: String)?,
                        tete: Double, duree: Double, enLecture: Bool,
                        boucle: ClosedRange<Double>?,
                        boucleActive: inout Bool,
                        vitesse: inout Double,
                        transposition: inout Double,
                        tempo: inout TempoGrid?,
                        affichage: inout DisplaySettings,
                        panneauAffichage: inout Bool) -> Demandes {
        var d = Demandes()

        if spectre_ui_barre_debut("barre", largeur, 0) != 0 {
            // ── Transport
            if spectre_ui_bouton("Ouvrir...", 0) != 0 { d.ouvrir = true }
            spectre_ui_meme_ligne()
            if spectre_ui_bouton(enLecture ? "Pause" : "Lire", 68) != 0 { d.lireOuPause = true }
            spectre_ui_meme_ligne()
            if spectre_ui_bouton("|<", 26) != 0 { d.revenirAuDebut = true }
            spectre_ui_meme_ligne()
            spectre_ui_texte("\(instant(tete)) / \(instant(duree))")

            spectre_ui_separateur()

            // ── Boucle
            var active: Int32 = boucleActive ? 1 : 0
            _ = spectre_ui_case("Boucler", &active)
            boucleActive = active != 0
            spectre_ui_meme_ligne()
            if spectre_ui_bouton("[", 26) != 0 { d.bornerDebut = true }
            spectre_ui_meme_ligne()
            if spectre_ui_bouton("]", 26) != 0 { d.bornerFin = true }
            spectre_ui_meme_ligne()
            if let boucle {
                spectre_ui_texte_faible("\(instant(boucle.lowerBound)) - \(instant(boucle.upperBound))")
                spectre_ui_meme_ligne()
                if spectre_ui_bouton("Mesures", 0) != 0 { d.calerSurMesures = true }
                spectre_ui_meme_ligne()
                if spectre_ui_bouton("x", 26) != 0 { d.effacerBoucle = true }
            } else {
                spectre_ui_texte_faible("pas de boucle")
            }

            spectre_ui_separateur()

            // ── Ralenti et transposition
            //
            // Les crans sont ceux de la version macOS, et pour la même raison :
            // un curseur continu ne retrouve jamais exactement ×1, si bien que
            // le vocodeur reste en service pour un écart inaudible.
            var v = Float(vitesse)
            if spectre_ui_reglette("##vitesse", &v, 0.25, 2, "x%.2f", 110) != 0 {
                vitesse = Detent.speed(Double(v))
            }
            spectre_ui_meme_ligne()
            var t = Float(transposition)
            if spectre_ui_reglette("##transposition", &t, -12, 12, "%+.1f dt", 110) != 0 {
                transposition = Detent.transpose(Double(t))
            }
            if vitesse != 1 || transposition != 0 {
                spectre_ui_meme_ligne()
                if spectre_ui_bouton("Normal", 0) != 0 { vitesse = 1; transposition = 0 }
            }

            spectre_ui_separateur()

            // ── Tempo
            if var grille = tempo {
                var bpm = Float(grille.bpm)
                if spectre_ui_reglette("BPM", &bpm, 50, 200, "%.1f", 130) != 0 {
                    grille.bpm = Double(bpm)
                    // Un tempo dicté n'est plus une estimation : la confiance
                    // tombe à zéro, et le « ≈ » qui prévient d'une grille
                    // incertaine n'a plus lieu d'être.
                    grille.confidence = 0
                    tempo = grille
                }
                spectre_ui_meme_ligne()
                var signature = Int32(max(grille.beatsPerBar - 2, 0))
                if spectre_ui_liste("##signature", &signature, signatures, 68) != 0 {
                    grille.beatsPerBar = Int(signature) + 2
                    tempo = grille
                }
                spectre_ui_meme_ligne()
                if spectre_ui_bouton("1 ici", 0) != 0 { d.premierTempsIci = true }
                if grille.confidence > 0, grille.confidence < 2.2 {
                    spectre_ui_meme_ligne()
                    spectre_ui_texte_faible("~")
                }
            } else {
                spectre_ui_texte_faible("tempo indéterminé")
            }
            spectre_ui_meme_ligne()
            if spectre_ui_bouton("Tempo", 0) != 0 { d.recalculerTempo = true }

            spectre_ui_separateur()

            // ── Affichage
            if spectre_ui_bouton_bascule("Affichage", panneauAffichage ? 1 : 0, 0) != 0 {
                panneauAffichage.toggle()
            }
            spectre_ui_meme_ligne()
            if spectre_ui_bouton("Auto", 0) != 0 { d.contrasteAuto = true }

            // La note sous le curseur : c'est la lecture que l'on vient chercher,
            // et elle prend la place du nom du fichier quand elle est là.
            if let raie {
                spectre_ui_meme_ligne()
                // `noteName` compose un vrai signe moins, hors du latin-1 que
                // porte la police par défaut.
                let note = raie.note.replacingOccurrences(of: "\u{2212}", with: "-")
                spectre_ui_texte(String(format: "   %@  %.1f Hz", note, raie.frequence))
            } else if let nom {
                spectre_ui_meme_ligne()
                spectre_ui_texte_faible("   \(nom)")
            }
        }
        spectre_ui_barre_fin()

        if panneauAffichage {
            dessinePanneauAffichage(&affichage, y: spectre_ui_hauteur_barre() + 8)
        }
        return d
    }

    private static func dessinePanneauAffichage(_ affichage: inout DisplaySettings, y: Float) {
        guard spectre_ui_panneau_debut("Affichage", 12, y, 300) != 0 else {
            spectre_ui_panneau_fin()
            return
        }

        var plancher = Float(affichage.floorDb)
        if spectre_ui_reglette("Plancher", &plancher, -120, -20, "%.0f dB", 150) != 0 {
            affichage.floorDb = Double(min(plancher, Float(affichage.ceilingDb) - 1))
        }
        var plafond = Float(affichage.ceilingDb)
        if spectre_ui_reglette("Plafond", &plafond, -110, 0, "%.0f dB", 150) != 0 {
            affichage.ceilingDb = Double(max(plafond, Float(affichage.floorDb) + 1))
        }
        var gamma = Float(affichage.gamma)
        if spectre_ui_reglette("Courbe", &gamma, 0.3, 2.5, "%.2f", 150) != 0 {
            affichage.gamma = Double(gamma)
        }
        var pente = Float(affichage.tiltDbPerOctave)
        if spectre_ui_reglette("Pente", &pente, -6, 12, "%.1f dB/oct", 150) != 0 {
            affichage.tiltDbPerOctave = Double(pente)
        }

        spectre_ui_espace()

        var palette = Int32(affichage.colorMap.rawValue)
        if spectre_ui_liste("Palette", &palette, palettes, 150) != 0 {
            affichage.colorMap = ColorMap(rawValue: Int(palette)) ?? .notes
        }
        var saturation = Float(affichage.noteSaturation)
        if spectre_ui_reglette("Saturation", &saturation, 0, 2, "%.2f", 150) != 0 {
            affichage.noteSaturation = Double(saturation)
        }

        var bémols: Int32 = affichage.useFlats ? 1 : 0
        if spectre_ui_case("Bémols plutôt que dièses", &bémols) != 0 {
            affichage.useFlats = bémols != 0
        }

        spectre_ui_panneau_fin()
    }
}
