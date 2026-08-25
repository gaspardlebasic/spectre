import Foundation
#if os(Windows)
import WinSDK
#endif

/// Où va ce qui ne peut pas s'afficher dans la fenêtre.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// LE SEUL `#if` DE TOUTE LA COUCHE PARTAGÉE, ET POURQUOI IL EST LÉGITIME
///
/// `SpectreToile`, `SpectreSon` et `SpectreDessin` n'en portent aucun : ce qui
/// change d'un système à l'autre est un étage plus bas, dans `Sources/CPont`, où
/// deux fichiers C exportent les mêmes fonctions. Ce fichier-ci fait exception, et
/// la raison est réelle plutôt que commode.
///
/// Sous Windows, l'application est bâtie en sous-système « fenêtre », donc **sans
/// console à elle** : écrire sur la sortie d'erreur n'irait nulle part, et le
/// premier message qu'on cherche est justement celui qui explique pourquoi la
/// fenêtre ne s'est pas ouverte. `rattacherLaConsole()` reprend celle du terminal
/// quand il y en avait une ; lancée par un double-clic, il n'y en a pas. On écrit
/// donc aussi par `OutputDebugString`, que le débogueur et DebugView lisent.
///
/// Sous Linux et sur le Mac, une application graphique garde la sortie d'erreur du
/// terminal qui l'a lancée, et le bureau la range dans le journal du système quand
/// personne ne l'a lancée à la main. Il n'y a rien à ajouter.
/// ─────────────────────────────────────────────────────────────────────────────
public enum Journal {
    public static func erreur(_ message: String) {
        ecrire("Spectre : \(message)", surLErreur: true)
    }

    /// Une note va sur la **sortie ordinaire**, et pas sur celle d'erreur.
    ///
    /// La distinction n'est pas cosmétique : PowerShell tient pour une erreur tout
    /// ce qu'un exécutable écrit sur la sortie d'erreur, et l'annonce comme telle au
    /// milieu d'une épreuve qui se passe bien. Un nom de carte graphique n'est pas
    /// une erreur.
    public static func note(_ message: String) {
        ecrire("Spectre : \(message)", surLErreur: false)
    }

    private static func ecrire(_ ligne: String, surLErreur: Bool) {
        let flux = surLErreur ? FileHandle.standardError : FileHandle.standardOutput
        flux.write(Data((ligne + "\n").utf8))
        #if os(Windows)
        ligne.withCString(encodedAs: UTF16.self) { OutputDebugStringW($0) }
        #endif
    }
}
