import Foundation
import WinSDK

/// Où va ce qui ne peut pas s'afficher dans la fenêtre.
///
/// Une application Windows bâtie en mode « fenêtre » n'a pas de console attachée :
/// écrire sur la sortie d'erreur ne va nulle part, et le premier message qu'on
/// cherche est justement celui qui explique pourquoi la fenêtre ne s'est pas
/// ouverte. `OutputDebugString` est lu par le débogueur et par DebugView, mais pas
/// par un terminal.
///
/// On écrit donc aux deux endroits à la fois. Lancée depuis un terminal — ce que
/// font les vérifications — l'application hérite de sa console et le message s'y
/// lit ; lancée par un double-clic, il reste attrapable.
public enum Journal {
    public static func erreur(_ message: String) {
        ecrire("Spectre : \(message)", surLErreur: true)
    }

    /// Une note va sur la **sortie ordinaire**, et pas sur celle d'erreur.
    ///
    /// La distinction n'est pas cosmétique : PowerShell tient pour une erreur tout
    /// ce qu'un exécutable écrit sur la sortie d'erreur, et l'annonce comme telle
    /// au milieu d'une épreuve qui se passe bien. Un nom de carte graphique n'est
    /// pas une erreur.
    public static func note(_ message: String) {
        ecrire("Spectre : \(message)", surLErreur: false)
    }

    private static func ecrire(_ ligne: String, surLErreur: Bool) {
        let flux = surLErreur ? FileHandle.standardError : FileHandle.standardOutput
        flux.write(Data((ligne + "\n").utf8))
        ligne.withCString(encodedAs: UTF16.self) { OutputDebugStringW($0) }
    }
}
