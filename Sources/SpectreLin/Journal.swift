import Foundation

/// Où va ce qui ne peut pas s'afficher dans la fenêtre.
///
/// Le pendant du `Journal` de `SpectreWin`, et il est plus court d'autant que
/// Windows a de raisons d'être compliqué : là-bas l'application est bâtie en
/// sous-système « fenêtre », donc sans console à elle, et il faut écrire à deux
/// endroits pour espérer être lu. Sous Linux une application graphique garde la
/// sortie d'erreur du terminal qui l'a lancée, et le bureau la range dans le
/// journal du système quand personne ne l'a lancée à la main.
public enum Journal {
    public static func erreur(_ message: String) {
        FileHandle.standardError.write(Data("Spectre : \(message)\n".utf8))
    }

    /// Une note va sur la **sortie ordinaire**, et pas sur celle d'erreur : un nom
    /// de carte graphique n'est pas une erreur, et les harnais lisent les deux flux
    /// séparément.
    public static func note(_ message: String) {
        FileHandle.standardOutput.write(Data("Spectre : \(message)\n".utf8))
    }
}
