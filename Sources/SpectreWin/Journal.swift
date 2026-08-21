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
        ecrire("Spectre : \(message)")
    }

    public static func note(_ message: String) {
        ecrire("Spectre : \(message)")
    }

    private static func ecrire(_ ligne: String) {
        FileHandle.standardError.write(Data((ligne + "\n").utf8))
        ligne.withCString(encodedAs: UTF16.self) { OutputDebugStringW($0) }
    }
}
