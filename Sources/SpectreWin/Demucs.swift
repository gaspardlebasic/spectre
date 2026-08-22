import CPont
import Foundation
import SpectreCore

// La séparation des pistes sous Windows — le jumeau de `SpectreMac/DemucsEngine.swift`.
//
// ─────────────────────────────────────────────────────────────────────────────
// CE FICHIER EST COURT, ET C'EST LE RÉSULTAT QU'ON CHERCHAIT
//
// Le découpage en tranches, le recentrage, la mise en forme du spectre, le fondu
// enchaîné et le retour à l'échelle sont dans `SpectreCore/Demucs.swift` : ils ne
// connaissent aucun système, et les écrire deux fois aurait suffi pour que les deux
// plateformes séparent la même musique différemment. Ce qui reste ici est ce que
// Windows sait faire et que personne d'autre ne saurait : ouvrir un fichier en
// stéréo à 44,1 kHz, et exécuter un graphe.
//
// L'accélération matérielle n'y est pas. ONNX Runtime sait passer par DirectML,
// mais cela demande un second paquet — `Microsoft.ML.OnnxRuntime.DirectML`, qui
// remplace la DLL au lieu de s'y ajouter — et le fournisseur ne se choisit pas à
// l'exécution. Ce sera une étape à soi ; l'annoncer ici serait mentir sur ce que la
// séparation coûte.
// ─────────────────────────────────────────────────────────────────────────────

/// Où le réseau et le moteur d'inférence sont cherchés.
public enum Reseau {
    /// Le nom du réseau. Un seul, qui rend les quatre pistes d'un coup.
    public static let nom = "htdemucs"

    /// Le fichier `.onnx`, s'il est quelque part.
    ///
    /// Trois endroits, dans cet ordre : ce que `SPECTRE_MODELE` désigne — par où les
    /// vérifications atteignent celui du dépôt —, le dossier de l'application, puis
    /// `modeles/` dans le rangement, ce qui permet d'essayer un autre jeu de poids
    /// sans reconstruire.
    public static var fichier: URL? {
        let gestionnaire = FileManager.default
        if let impose = ProcessInfo.processInfo.environment["SPECTRE_MODELE"],
           gestionnaire.fileExists(atPath: impose) {
            return URL(fileURLWithPath: impose)
        }
        let voisin = dossierDeLApplication?.appendingPathComponent("\(nom).onnx")
        if let voisin, gestionnaire.fileExists(atPath: voisin.path) { return voisin }
        guard let rangement = Storage.root?
            .appendingPathComponent("modeles/\(nom).onnx") else { return nil }
        return gestionnaire.fileExists(atPath: rangement.path) ? rangement : nil
    }

    /// L'`onnxruntime.dll` à charger, s'il y en a une.
    ///
    /// À côté de l'exécutable en premier — c'est là que la distribution la pose — et
    /// dans `build/onnxruntime/<architecture>` ensuite, où `onnx.ps1` l'installe
    /// pendant qu'on travaille. `SPECTRE_ONNXRUNTIME` tranche pour qui veut en
    /// essayer une autre.
    public static var bibliotheque: URL? {
        let gestionnaire = FileManager.default
        if let impose = ProcessInfo.processInfo.environment["SPECTRE_ONNXRUNTIME"],
           gestionnaire.fileExists(atPath: impose) {
            return URL(fileURLWithPath: impose)
        }
        var candidats: [URL] = []
        if let voisin = dossierDeLApplication?.appendingPathComponent("onnxruntime.dll") {
            candidats.append(voisin)
        }
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "x64"
        #endif
        // Le dossier de construction est retrouvé depuis l'exécutable, qui vit dans
        // `.build/<triplet>/release` : trois dossiers plus haut, puis `build`. Sans
        // cela il faudrait poser la DLL à la main avant chaque essai.
        if let bin = dossierDeLApplication {
            candidats.append(bin.deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("build/onnxruntime/\(architecture)/onnxruntime.dll"))
        }
        return candidats.first { gestionnaire.fileExists(atPath: $0.path) }
    }

    /// Vrai quand la séparation peut réellement se faire : le moteur **et** les poids.
    ///
    /// Les deux manquent séparément et pour des raisons différentes — l'un se
    /// télécharge, l'autre se fabrique — mais le modèle ne veut savoir qu'une chose :
    /// peut-on proposer la séparation, ou faut-il l'annoncer absente.
    public static var disponible: Bool {
        spectre_reseau_disponible() != 0 && fichier != nil && bibliotheque != nil
    }

    private static var dossierDeLApplication: URL? {
        guard let chemin = Bundle.main.executablePath else { return nil }
        return URL(fileURLWithPath: chemin).deletingLastPathComponent()
    }
}

/// Le moteur d'inférence de Windows, vu du noyau.
///
/// Une classe et non une structure : elle possède une session ONNX, qu'il faut
/// refermer. Un `deinit` est le seul endroit où l'on peut en être sûr.
public final class MoteurONNX: MoteurDemucs {
    private let reseau: OpaquePointer

    public init(modele: URL, bibliotheque: URL) throws {
        var erreur = [CChar](repeating: 0, count: Int(SPECTRE_ERREUR_MAX))
        let ouvert = modele.path.withUTF16Terminé { chemin in
            bibliotheque.path.withUTF16Terminé { dll in
                erreur.withUnsafeMutableBufferPointer {
                    spectre_reseau_ouvrir(chemin, dll, $0.baseAddress)
                }
            }
        }
        guard let ouvert else {
            throw SeparationFailure.modelUnreadable(String(cString: erreur))
        }
        reseau = ouvert
    }

    deinit { spectre_reseau_fermer(reseau) }

    public func appliquer(mix: [Float], spec: [Float]) throws -> (zout: [Float], xt: [Float]) {
        let raies = DemucsFourier.bins
        let trames = DemucsFourier.frames(for: Demucs.segment)
        let voies = Stem.separated.count * Demucs.channels
        var zout = [Float](repeating: 0, count: voies * raies * trames * 2)
        var xt = [Float](repeating: 0, count: voies * Demucs.segment)
        var erreur = [CChar](repeating: 0, count: Int(SPECTRE_ERREUR_MAX))

        let bon = mix.withUnsafeBufferPointer { m in
            spec.withUnsafeBufferPointer { s in
                zout.withUnsafeMutableBufferPointer { z in
                    xt.withUnsafeMutableBufferPointer { x in
                        erreur.withUnsafeMutableBufferPointer { e in
                            spectre_reseau_appliquer(reseau, m.baseAddress, s.baseAddress,
                                                     Int32(Demucs.channels),
                                                     Int32(Demucs.segment),
                                                     Int32(raies), Int32(trames),
                                                     z.baseAddress, x.baseAddress,
                                                     e.baseAddress)
                        }
                    }
                }
            }
        }
        guard bon != 0 else { throw SeparationFailure.engine(String(cString: erreur)) }
        return (zout, xt)
    }
}

/// La séparation par Demucs, sous Windows.
public struct SeparateurWindows: StemSeparator {
    public init() {}

    public func separate(fileAt url: URL,
                         progress: @escaping (SeparationProgress) -> Void,
                         isCancelled: @escaping () -> Bool) throws -> SeparatedStems {
        guard let modele = Reseau.fichier else { throw SeparationFailure.modelMissing }
        guard spectre_reseau_disponible() != 0, let dll = Reseau.bibliotheque else {
            throw SeparationFailure.engine(
                "ONNX Runtime n'est pas installé — lancer .\\onnx.ps1.")
        }

        progress(SeparationProgress(fraction: 0, stage: "Lecture du morceau…"))
        let mix = try Self.lirePourLeReseau(url)

        // L'ouverture du réseau est le long moment muet : quelques secondes pour
        // relire les 166 Mo de poids et optimiser le graphe. Il n'y a rien à mesurer
        // là-dedans — c'est un seul appel qui rend la main quand il a fini — mais une
        // barre immobile à zéro sans un mot passe pour une panne.
        progress(SeparationProgress(fraction: 0, stage: "Ouverture du réseau…"))
        let moteur = try MoteurONNX(modele: modele, bibliotheque: dll)

        return try Demucs.separer(mix, par: moteur,
                                  avancement: progress, annule: isCancelled)
    }

    /// Charge le morceau tel que le réseau l'attend : stéréo, 44,1 kHz, flottant.
    ///
    /// Media Foundation fait la conversion — c'est ce que `spectre_mf_decoder_entrelace`
    /// lui demande. Le rééchantillonnage n'est pas une politesse : le réseau a appris
    /// à cette fréquence-là.
    ///
    /// **Le WAV ne prend pas le raccourci du décodeur**, contrairement à l'analyse :
    /// notre lecteur en Swift ne rééchantillonne pas, et un WAV à 48 kHz passerait
    /// donc au réseau tel quel. Media Foundation lit le WAV aussi bien, et la
    /// conversion est ce qu'on vient chercher ici.
    static func lirePourLeReseau(_ url: URL) throws -> [[Float]] {
        let resultat = url.path.withCString {
            spectre_mf_decoder_entrelace($0, Demucs.sampleRate, Int32(Demucs.channels))
        }
        guard resultat.code == 0, let bloc = resultat.echantillons else {
            let message = String(cString: spectre_mf_message(resultat.code))
            throw SeparationFailure.engine("« \(url.lastPathComponent) » : \(message)")
        }
        defer { spectre_mf_liberer(bloc) }

        let images = Int(resultat.images)
        let canaux = Int(resultat.canaux)
        guard images > 0, canaux == Demucs.channels else {
            throw SeparationFailure.engine("aucun échantillon lu")
        }
        var sortie = [[Float]](repeating: [Float](repeating: 0, count: images),
                               count: canaux)
        for c in 0..<canaux {
            sortie[c].withUnsafeMutableBufferPointer { destination in
                for i in 0..<images { destination[i] = bloc[i * canaux + c] }
            }
        }
        return sortie
    }
}
