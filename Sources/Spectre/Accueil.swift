import AppKit
import SpectreCore
import SpectreModele
import SpectreTextes
import SwiftUI

// Ce que la fenêtre montre avant qu'un morceau soit ouvert : la liste des morceaux
// déjà travaillés, le diaporama du premier lancement, et la mise à jour.
//
// ─────────────────────────────────────────────────────────────────────────────
// LES JUMEAUX DE `SpectreDessin/Accueil.swift`
//
// Les deux dessins sont écrits deux fois — SwiftUI ici, Direct2D et Cairo là-bas —
// mais **les textes sortent du même catalogue et l'état vient du même objet**,
// `AppModel.lancement`. C'est la seule chose qui compte : quand la corbeille d'une
// ligne se met à emporter autre chose, elle l'emporte des trois côtés, parce que
// ce qu'elle emporte est écrit dans `Lancement.swift` et nulle part ici.
// ─────────────────────────────────────────────────────────────────────────────

// MARK: - La page des morceaux

/// La liste des morceaux déjà ouverts, et de quoi en reprendre un.
///
/// Elle remplace le « Déposer un fichier audio » qui tenait cette place, et
/// l'ouverture automatique du dernier morceau qui la recouvrait aussitôt. La
/// première ligne *est* le dernier morceau : ce qui se faisait tout seul se fait
/// maintenant d'un clic, et les neuf autres fois on choisit.
struct PageDesMorceaux: View {
    @Bindable var model: AppModel
    /// La ligne survolée : c'est elle, et elle seule, qui montre sa corbeille. Une
    /// corbeille par ligne en permanence ferait d'une liste de douze morceaux une
    /// liste de douze boutons de suppression.
    @State private var survolee: URL?
    /// Le morceau dont on demande confirmation avant de jeter ses pistes.
    @State private var aJeter: MorceauRecent?

    var body: some View {
        VStack(spacing: 22) {
            // Le titre est aligné sur la liste, et non centré sur la fenêtre : une
            // colonne de noms alignés à gauche sous un titre centré se lit comme
            // deux blocs qui n'ont rien à voir l'un avec l'autre.
            VStack(alignment: .leading, spacing: 12) {
                Text(T(.lancementReprendre))
                    .font(.system(size: 17, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.leading, 12)

                if model.lancement.morceaux.isEmpty {
                    Text(T(.lancementAucunMorceau))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.leading, 12)
                } else {
                    // La hauteur suit le nombre de lignes, et se borne à sept :
                    // douze morceaux dans une fenêtre courte pousseraient sinon le
                    // bouton d'ouverture hors de l'écran — c'est-à-dire la seule
                    // chose à faire quand la liste ne contient pas ce qu'on cherche.
                    // Une hauteur fixe ferait l'inverse et laisserait un trou de deux
                    // cents points sous une liste d'une ligne, ce qui est le cas le
                    // plus fréquent.
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(model.lancement.morceaux) { morceau in
                                ligne(morceau)
                            }
                        }
                    }
                    .frame(height: hauteurDeLaListe)
                }
            }
            .frame(width: 420, alignment: .leading)

            VStack(spacing: 6) {
                Button(T(.lancementOuvrirUnFichier)) { model.openPanel() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                Text(T(.accueilDeposer) + " · " + T(.accueilRaccourci))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .padding(28)
        // Jeter les pistes d'un morceau, c'est jeter des minutes de GPU. Elles se
        // refont, mais pas sur un clic distrait : on demande, exactement comme le
        // panneau ⌘, le fait pour le cache entier.
        .confirmationDialog(T(.reglagesViderTitre),
                            isPresented: Binding(get: { aJeter != nil },
                                                 set: { if !$0 { aJeter = nil } }),
                            titleVisibility: .visible) {
            Button(T(.reglagesViderBouton), role: .destructive) {
                if let aJeter { model.lancement.oublier(aJeter.url) }
                aJeter = nil
            }
            Button(T(.reglagesAnnuler), role: .cancel) { aJeter = nil }
        } message: {
            Text(T(.reglagesViderMessage))
        }
    }

    /// Sept lignes au plus, et la liste défile au-delà.
    private var hauteurDeLaListe: CGFloat {
        CGFloat(min(model.lancement.morceaux.count, 7)) * Self.hauteurDUneLigne
    }

    private static let hauteurDUneLigne: CGFloat = 40

    private func ligne(_ morceau: MorceauRecent) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(morceau.nom)
                    .font(.system(size: 13, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                // Ce qui distingue un morceau qui rouvre en deux secondes d'un
                // morceau qui redemandera des minutes — et ce que la corbeille de
                // cette ligne-là va jeter.
                if morceau.separe {
                    Text(T(.lancementSepare))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            Spacer(minLength: 8)
            // La corbeille n'apparaît qu'au survol, et garde sa place quand elle est
            // invisible : sans cela le nom du morceau sauterait de vingt points à
            // chaque passage de souris.
            Button {
                if morceau.separe { aJeter = morceau } else { model.lancement.oublier(morceau.url) }
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
            .help(T(.lancementRetirer))
            .opacity(survolee == morceau.url ? 1 : 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(survolee == morceau.url ? Color.white.opacity(0.10) : .clear,
                    in: RoundedRectangle(cornerRadius: 7))
        // Le rectangle entier prend le clic, et pas seulement le texte : viser un
        // nom de trois lettres n'est pas ce qu'on demande à quelqu'un qui veut
        // rouvrir son morceau.
        .contentShape(Rectangle())
        .onHover { survolee = $0 ? morceau.url : (survolee == morceau.url ? nil : survolee) }
        .onTapGesture { model.open(morceau.url) }
    }
}

// MARK: - Le diaporama du premier lancement

/// Deux diapositives, montrées une seule fois : ce que l'application sait faire et
/// qu'on ne devinerait pas.
///
/// La seconde porte la phrase sur les rapports de panne, qui remplace la modale
/// qu'on montrait avant — voir `docs/RAPPORTS.md`. On informe, on ne demande pas ;
/// et ce qui **ne part pas** est écrit aussi gros que ce qui part.
struct Diaporama: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.lancement.diaporama {
            ZStack {
                // Tout le reste s'efface derrière : tant que le diaporama est là, il
                // n'y a rien d'autre à lire dans cette fenêtre.
                Color.black.opacity(0.72).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 0) {
                    capture
                    corps
                    pied
                }
                .frame(width: 620)
                .verre(.regulier, in: .rect(cornerRadius: 16))
            }
        }
    }

    /// La capture d'écran de la diapositive, si le paquet la porte.
    ///
    /// `if let` et non un point d'exclamation : une image absente — un paquet
    /// assemblé à la main, une ressource oubliée — doit laisser le texte, qui est ce
    /// qui compte, plutôt que d'arrêter l'application au premier lancement.
    @ViewBuilder
    private var capture: some View {
        if let image = Self.image(model.lancement.diapositive) {
            // Un fond qui remplit la largeur, et l'image posée dedans à son
            // format. Les deux captures n'ont pas la même forme — l'une est une
            // fenêtre entière, l'autre une bande de vingt points de haut — et sans
            // ce fond la seconde flotterait au milieu du verre comme une erreur.
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: 260)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.black.opacity(0.45))
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16,
                                                  topTrailingRadius: 16))
        }
    }

    private var corps: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(titre)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.95))
            Text(texte)
                .font(.system(size: 12.5, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .fixedSize(horizontal: false, vertical: true)
            if model.lancement.diapositive == 0 {
                Text(T(.bienvenueTempoBoucle))
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.lancement.rapportsAAnnoncer {
                // La même taille que ce qui précède, et une teinte qui appelle
                // l'œil : ce qu'on annonce d'un envoi automatique n'est pas une note
                // de bas de page.
                Text(T(.bienvenueRapports))
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundStyle(Color(red: 0.62, green: 0.86, blue: 0.70))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 26)
        .padding(.top, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var pied: some View {
        HStack(spacing: 12) {
            Button(T(.bienvenuePasser)) { model.lancement.fermerLeDiaporama() }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            // Deux points, pour dire qu'il y a une suite et où l'on en est. Un
            // bouton « Suivant » seul ne dit pas combien il en reste.
            HStack(spacing: 6) {
                ForEach(0..<Lancement.diapositives, id: \.self) { rang in
                    Circle()
                        .fill(.white.opacity(rang == model.lancement.diapositive ? 0.85 : 0.25))
                        .frame(width: 6, height: 6)
                }
            }
            Spacer()
            Button(model.lancement.derniereDiapositive ? T(.bienvenueCommencer)
                                                       : T(.bienvenueSuivant)) {
                model.lancement.suivant()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 20)
    }

    private var titre: String {
        model.lancement.diapositive == 0 ? T(.bienvenueTitreBoucle) : T(.bienvenueTitrePistes)
    }

    private var texte: String {
        model.lancement.diapositive == 0 ? T(.bienvenueCorpsBoucle) : T(.bienvenueCorpsPistes)
    }

    /// Les captures voyagent dans le paquet sous des noms sans accent ni espace :
    /// `build.sh` les y copie depuis `Resources/Captures`, en les renommant. Ce sont
    /// les mêmes fichiers que ceux du README, et c'est voulu — une présentation qui
    /// montrerait autre chose que la page du dépôt vieillirait deux fois.
    ///
    /// Les noms sont dans `Ressources`, avec ceux que les deux autres systèmes
    /// cherchent : un nom qui divergerait d'un côté ferait disparaître l'image sur
    /// un seul système, c'est-à-dire là où personne ne la cherche.
    private static func image(_ rang: Int) -> NSImage? {
        Ressources.capture(rang).flatMap(NSImage.init(contentsOf:))
    }
}

// MARK: - La mise à jour

/// « Spectre 0.6 est disponible ». Un numéro, deux boutons, et rien d'autre.
///
/// Elle ne télécharge rien et n'installe rien : `Télécharger` ouvre la page des
/// versions dans le navigateur. Voir `SpectreCore/MiseAJour.swift`, qui dit
/// pourquoi l'application demande, et pourquoi elle ne fait que demander.
struct ModaleDeMiseAJour: View {
    @Bindable var model: AppModel

    var body: some View {
        if model.lancement.miseAJourAMontrer, let livraison = model.lancement.livraison {
            ZStack {
                Color.black.opacity(0.62).ignoresSafeArea()
                VStack(alignment: .leading, spacing: 14) {
                    Text(T(.majTitre, livraison.version))
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.95))
                    Text(T(.majCorps, model.lancement.versionCourante))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                    HStack(spacing: 10) {
                        Spacer()
                        Button(T(.majIgnorer)) { model.lancement.ignorerCetteVersion() }
                            .controlSize(.large)
                        Button(T(.majTelecharger)) { model.lancement.telecharger() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(26)
                .frame(width: 470, alignment: .leading)
                .verre(.regulier, in: .rect(cornerRadius: 16))
            }
        }
    }
}
