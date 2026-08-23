import Foundation
import SpectreTextes

// Ce que la séparation de pistes est, indépendamment de qui la calcule.
//
// Ces types vivaient dans `SpectreMac`, où ils étaient nés. Ils n'ont pourtant
// jamais rien connu d'Apple : une erreur, un jeu de pistes, un avancement, et ce
// qu'un moteur doit savoir faire. Les laisser là-haut aurait obligé Windows à les
// récrire — quatre types identiques dans deux modules, qui auraient divergé au
// premier message d'erreur reformulé.

/// Ce qui peut échouer entre le clic sur une piste et son apparition à l'écran.
public enum SeparationFailure: LocalizedError {
    case modelMissing
    case modelUnreadable(String)
    case noSourceFile
    case cannotWrite(URL)
    case cancelled
    case engine(String)

    public var errorDescription: String? {
        switch self {
        case .modelMissing:
            T(.erreurModeleAbsent)
        case .modelUnreadable(let why):
            T(.erreurModeleIllisible, why)
        case .noSourceFile:
            T(.erreurAucunMorceau)
        case .cannotWrite(let url):
            T(.erreurEcritureImpossible, url.lastPathComponent)
        case .cancelled:
            T(.erreurInterrompue)
        case .engine(let why):
            T(.erreurSeparationEchouee, why)
        }
    }
}

/// Où en est un calcul qui dure des minutes.
///
/// La fraction ne suffit pas. Avant la première tranche il se passe une dizaine de
/// secondes — le décodage, puis surtout l'ouverture du réseau, des centaines de
/// mégaoctets relus du disque — pendant lesquelles il n'y a rien à mesurer : c'est
/// un seul appel opaque au moteur d'inférence, qui rend la main quand il a fini.
/// Une barre immobile à zéro fait alors croire que rien ne se passe, ou que quelque
/// chose est bloqué. Le nom de l'étape, lui, se dit toujours.
public struct SeparationProgress {
    /// De 0 à 1. Reste à zéro tant qu'aucune tranche n'est finie.
    public var fraction: Double
    /// Ce qui se passe en ce moment, à montrer tel quel.
    public var stage: String

    public init(fraction: Double, stage: String) {
        self.fraction = fraction
        self.stage = stage
    }
}

/// Les pistes rendues, **et la fréquence à laquelle elles ont été rendues**.
///
/// Les deux voyagent ensemble, et c'est tout l'objet de ce type. Elles ne le
/// faisaient pas : les pistes seules revenaient du moteur, et celui qui les écrivait
/// devait retrouver leur fréquence de son côté. Il la lisait sur le fichier d'origine
/// — ce qui est faux, puisque Demucs a appris à 44,1 kHz et y ramène tout ce qu'on
/// lui donne. Un morceau à 48 kHz produisait donc des pistes à 44,1 kHz étiquetées
/// 48 kHz : jouées 8,8 % trop vite, un demi-ton et demi trop haut, et une durée
/// annoncée de 299 s pour 325 s de musique.
///
/// Le défaut ne se voyait que sur les fichiers qui ne sont pas à 44,1 kHz, et
/// seulement une fois une piste décochée — tant que tout est coché, c'est le fichier
/// d'origine qui est joué. D'où six mois de silence.
public struct SeparatedStems {
    /// Celle des `channels`, pas celle du fichier d'entrée.
    public var sampleRate: Double
    public var channels: [Stem: [[Float]]]

    public init(sampleRate: Double, channels: [Stem: [[Float]]]) {
        self.sampleRate = sampleRate
        self.channels = channels
    }
}

/// Ce qu'un moteur de séparation doit savoir faire.
///
/// L'entrée est le **fichier**, pas le signal mono déjà chargé : Demucs est entraîné
/// sur de la stéréo et s'appuie sur les différences entre canaux pour décider ce qui
/// appartient à quoi. Lui donner la somme des canaux reviendrait à lui retirer une
/// partie de ce sur quoi il travaille.
public protocol StemSeparator {
    /// - Parameter progress: appelé depuis le fil de calcul.
    /// - Returns: les pistes et leur fréquence d'échantillonnage.
    func separate(fileAt url: URL,
                  progress: @escaping (SeparationProgress) -> Void,
                  isCancelled: @escaping () -> Bool) throws -> SeparatedStems
}
