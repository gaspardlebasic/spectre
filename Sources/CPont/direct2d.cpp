// La surimpression : Direct2D et DirectWrite, par-dessus le spectrogramme.
//
// ─────────────────────────────────────────────────────────────────────────────
// UN SEUL TAMPON, DEUX FAÇONS D'Y DESSINER
//
// Le spectrogramme est une image entière calculée par le nuanceur ; la réglette,
// la grille, les noms d'accords et les traits de boucle sont du dessin vectoriel
// et du texte. Les mêler au nuanceur serait absurde — il faudrait y porter une
// fonte — et les dessiner dans une seconde fenêtre coûterait une composition de
// plus, donc une image de retard.
//
// Direct2D sait dessiner **directement dans le tampon de la chaîne d'échange** de
// Direct3D : les deux partagent l'appareil, et la surface D2D n'est qu'une vue du
// même tampon. Le nuanceur remplit, Direct2D écrit par-dessus, une seule
// présentation part. C'est l'équivalent exact du `Canvas` SwiftUI posé sur la vue
// Metal dans `Sources/Spectre/TimelineView.swift`.
//
// ─────────────────────────────────────────────────────────────────────────────
// ET C'EST LE SEUL FICHIER EN C++ DU DÉPÔT
//
// Non par goût, mais parce que `dwrite.h` ne porte pas de version C de ses
// interfaces — voir l'avertissement dans `interne.h`. En C++ le vocabulaire COM
// s'écrit tout seul (`objet->Methode()`), ce qui rend d'ailleurs ce fichier plus
// lisible que ses voisins ; mais la frontière avec Swift, elle, reste du C pur.
// ─────────────────────────────────────────────────────────────────────────────

#include <initguid.h>
#include "interne.h"
#include <cstdio>
#include <cstring>

/// Les polices, dans l'ordre où Swift les désigne.
///
/// Segoe UI Variable est la police de Windows 11 ; Segoe UI est celle de Windows
/// 10, et sert de recours. Cascadia Mono porte les chiffres de la réglette, qui
/// doivent avoir la même largeur d'un instant à l'autre — sans quoi le temps
/// affiché tremble en défilant.
static const WCHAR *nomDePolice(int index, bool recours) {
    if (index == 1) { return recours ? L"Consolas" : L"Cascadia Mono"; }
    return recours ? L"Segoe UI" : L"Segoe UI Variable Text";
}

static D2D1_COLOR_F couleur(uint32_t rvba) {
    D2D1_COLOR_F c;
    c.r = float((rvba >> 24) & 0xFF) / 255.0f;
    c.g = float((rvba >> 16) & 0xFF) / 255.0f;
    c.b = float((rvba >> 8) & 0xFF) / 255.0f;
    c.a = float(rvba & 0xFF) / 255.0f;
    return c;
}

// ─────────────────────────────────────────────────────────── La surface

extern "C" void spectre_surimpression_lacher(SpectreRendu *r) {
    if (!r) { return; }
    if (r->contexteD2D) { r->contexteD2D->SetTarget(nullptr); }
    if (r->surfaceD2D) { r->surfaceD2D->Release(); r->surfaceD2D = nullptr; }
    if (r->pinceau) { r->pinceau->Release(); r->pinceau = nullptr; }
    if (r->contexteD2D) { r->contexteD2D->Release(); r->contexteD2D = nullptr; }
}

extern "C" void spectre_surimpression_detruire(SpectreRendu *r) {
    if (!r) { return; }
    spectre_surimpression_lacher(r);
    if (r->pointille) { r->pointille->Release(); r->pointille = nullptr; }
    for (int i = 0; i < SPECTRE_FORMATS; ++i) {
        if (r->formats[i]) { r->formats[i]->Release(); r->formats[i] = nullptr; }
    }
    if (r->fabriqueTexte) { r->fabriqueTexte->Release(); r->fabriqueTexte = nullptr; }
    if (r->appareilD2D) { r->appareilD2D->Release(); r->appareilD2D = nullptr; }
    if (r->fabriqueD2D) { r->fabriqueD2D->Release(); r->fabriqueD2D = nullptr; }
}

extern "C" void spectre_surimpression_reprendre(SpectreRendu *r) {
    if (!r || !r->appareilD2D || !r->chaine) { return; }

    if (FAILED(r->appareilD2D->CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
                                                   &r->contexteD2D))) {
        return;
    }

    IDXGISurface *surface = nullptr;
    if (FAILED(r->chaine->GetBuffer(0, IID_PPV_ARGS(&surface)))) { return; }

    // 96 points par pouce, quoi que l'écran fasse : le modèle raisonne en points,
    // et c'est nous qui posons l'échelle par une transformation. Laisser Direct2D
    // appliquer la sienne ferait une mise à l'échelle **deux fois**, et le texte
    // sortirait deux fois trop gros sur un écran dense.
    D2D1_BITMAP_PROPERTIES1 proprietes = {};
    proprietes.pixelFormat.format = DXGI_FORMAT_B8G8R8A8_UNORM;
    proprietes.pixelFormat.alphaMode = D2D1_ALPHA_MODE_IGNORE;
    proprietes.dpiX = 96;
    proprietes.dpiY = 96;
    proprietes.bitmapOptions = D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW;

    HRESULT hr = r->contexteD2D->CreateBitmapFromDxgiSurface(surface, &proprietes,
                                                             &r->surfaceD2D);
    surface->Release();
    if (FAILED(hr)) { return; }

    r->contexteD2D->SetTarget(r->surfaceD2D);
    r->contexteD2D->SetDpi(96, 96);
    r->contexteD2D->CreateSolidColorBrush(D2D1::ColorF(D2D1::ColorF::White), &r->pinceau);
}

extern "C" int spectre_surimpression_preparer(SpectreRendu *r, char *erreur) {
    if (!r) { return 0; }
    if (r->contexteD2D) { return 1; }

    D2D1_FACTORY_OPTIONS options = {};
    HRESULT hr = D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                   __uuidof(ID2D1Factory1), &options,
                                   reinterpret_cast<void **>(&r->fabriqueD2D));
    if (FAILED(hr)) {
        if (erreur) {
            snprintf(erreur, SPECTRE_ERREUR_MAX, "Direct2D indisponible (0x%08lX).",
                     (unsigned long)hr);
        }
        return 0;
    }

    IDXGIDevice *dxgi = nullptr;
    hr = r->appareil->QueryInterface(IID_PPV_ARGS(&dxgi));
    if (SUCCEEDED(hr)) {
        // L'appareil Direct2D est bâti **sur celui de Direct3D** : c'est ce qui
        // permet aux deux d'écrire dans le même tampon sans recopie.
        hr = r->fabriqueD2D->CreateDevice(dxgi, &r->appareilD2D);
        dxgi->Release();
    }
    if (FAILED(hr)) {
        if (erreur) {
            snprintf(erreur, SPECTRE_ERREUR_MAX,
                     "Appareil Direct2D refusé (0x%08lX) — l'appareil Direct3D doit "
                     "être créé avec BGRA_SUPPORT.", (unsigned long)hr);
        }
        return 0;
    }

    hr = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
                             reinterpret_cast<IUnknown **>(&r->fabriqueTexte));
    if (FAILED(hr)) {
        if (erreur) {
            snprintf(erreur, SPECTRE_ERREUR_MAX, "DirectWrite indisponible (0x%08lX).",
                     (unsigned long)hr);
        }
        return 0;
    }

    // Le style pointillé de l'aimantation. Direct2D veut un objet ; SwiftUI se
    // contente d'un tableau.
    const FLOAT motif[2] = { 2, 3 };
    D2D1_STROKE_STYLE_PROPERTIES style = {};
    style.dashStyle = D2D1_DASH_STYLE_CUSTOM;
    r->fabriqueD2D->CreateStrokeStyle(&style, motif, 2, &r->pointille);

    r->echelle = 1;
    spectre_surimpression_reprendre(r);
    if (!r->contexteD2D) {
        if (erreur) {
            snprintf(erreur, SPECTRE_ERREUR_MAX,
                     "La surface Direct2D n'a pas pu être créée.");
        }
        return 0;
    }
    return 1;
}

// ─────────────────────────────────────────────────────────── Le dessin

extern "C" void spectre_surimpression_echelle(SpectreRendu *r, float echelle) {
    if (r) { r->echelle = echelle > 0 ? echelle : 1; }
}

extern "C" void spectre_surimpression_debuter(SpectreRendu *r) {
    if (!r || !r->contexteD2D || r->dessinEnCours) { return; }
    r->contexteD2D->BeginDraw();
    // Tout ce qui suit est donné en **points**, comme le modèle les compte. Cette
    // transformation est le seul endroit de la surimpression où l'on passe aux
    // pixels.
    r->contexteD2D->SetTransform(D2D1::Matrix3x2F::Scale(r->echelle, r->echelle));
    r->dessinEnCours = 1;
    r->decoupes = 0;
}

extern "C" void spectre_surimpression_finir(SpectreRendu *r) {
    if (!r || !r->contexteD2D || !r->dessinEnCours) { return; }
    // Une découpe oubliée fait échouer `EndDraw` en silence, et l'image entière
    // disparaît — y compris le spectrogramme, que la surimpression n'a pourtant pas
    // touché. On dépile ici ce qui traîne plutôt que de faire dépendre l'image d'un
    // appel apparié quelque part dans le dessin.
    while (r->decoupes > 0) { spectre_surimpression_recoller(r); }
    r->contexteD2D->EndDraw();
    r->dessinEnCours = 0;
}

static ID2D1SolidColorBrush *pinceau(SpectreRendu *r, uint32_t rvba) {
    r->pinceau->SetColor(couleur(rvba));
    return r->pinceau;
}

extern "C" void spectre_surimpression_rectangle(SpectreRendu *r, float x, float y,
                                                float largeur, float hauteur,
                                                uint32_t rvba) {
    if (!r || !r->dessinEnCours || largeur <= 0 || hauteur <= 0) { return; }
    r->contexteD2D->FillRectangle(D2D1::RectF(x, y, x + largeur, y + hauteur),
                                  pinceau(r, rvba));
}

extern "C" void spectre_surimpression_ligne(SpectreRendu *r, float x0, float y0,
                                            float x1, float y1, uint32_t rvba,
                                            float epaisseur, int pointille) {
    if (!r || !r->dessinEnCours) { return; }
    r->contexteD2D->DrawLine(D2D1::Point2F(x0, y0), D2D1::Point2F(x1, y1),
                             pinceau(r, rvba), epaisseur,
                             pointille ? r->pointille : nullptr);
}

extern "C" void spectre_surimpression_cercle(SpectreRendu *r, float x, float y,
                                             float rayon, uint32_t rvba,
                                             float epaisseur) {
    if (!r || !r->dessinEnCours) { return; }
    r->contexteD2D->DrawEllipse(D2D1::Ellipse(D2D1::Point2F(x, y), rayon, rayon),
                                pinceau(r, rvba), epaisseur, nullptr);
}

extern "C" void spectre_surimpression_aire(SpectreRendu *r, const float *points,
                                           int nombre, uint32_t rvba) {
    if (!r || !r->dessinEnCours || !points || nombre < 3) { return; }

    ID2D1PathGeometry *chemin = nullptr;
    if (FAILED(r->fabriqueD2D->CreatePathGeometry(&chemin))) { return; }
    ID2D1GeometrySink *entree = nullptr;
    if (FAILED(chemin->Open(&entree))) { chemin->Release(); return; }

    entree->BeginFigure(D2D1::Point2F(points[0], points[1]), D2D1_FIGURE_BEGIN_FILLED);
    for (int i = 1; i < nombre; ++i) {
        entree->AddLine(D2D1::Point2F(points[2 * i], points[2 * i + 1]));
    }
    entree->EndFigure(D2D1_FIGURE_END_CLOSED);
    entree->Close();
    entree->Release();

    r->contexteD2D->FillGeometry(chemin, pinceau(r, rvba), nullptr);
    chemin->Release();
}

/// Le format d'une police à une taille donnée, gardé d'un appel à l'autre.
///
/// En fabriquer un par texte coûterait une recherche de fonte à chaque trait de
/// réglette, soit des centaines par image. Les couples déjà demandés sont donc
/// retenus — et il en faut **plusieurs par police** : n'en garder qu'un revenait à
/// refaire la recherche à chaque changement de taille, ce que le panneau des
/// réglages fait des dizaines de fois par image en mêlant intitulés, valeurs et
/// explications.
///
/// Quand les douze places sont prises, la plus ancienne cède la sienne. Aucun
/// classement plus fin n'a de sens ici : l'interface emploie moins de tailles que
/// le pont n'en garde, et le remplacement ne se produit donc jamais en régime
/// établi.
static IDWriteTextFormat *format(SpectreRendu *r, int police, float taille) {
    if (police < 0 || police >= SPECTRE_POLICES) { police = 0; }
    for (int i = 0; i < SPECTRE_FORMATS; ++i) {
        if (r->formats[i] && r->policeDesFormats[i] == police
            && r->tailleDesFormats[i] == taille) {
            return r->formats[i];
        }
    }

    int place = -1;
    for (int i = 0; i < SPECTRE_FORMATS && place < 0; ++i) {
        if (!r->formats[i]) { place = i; }
    }
    if (place < 0) {
        place = r->prochainFormat % SPECTRE_FORMATS;
        r->prochainFormat = (r->prochainFormat + 1) % SPECTRE_FORMATS;
        r->formats[place]->Release();
        r->formats[place] = nullptr;
    }

    HRESULT hr = r->fabriqueTexte->CreateTextFormat(
        nomDePolice(police, false), nullptr, DWRITE_FONT_WEIGHT_NORMAL,
        DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, taille, L"fr-FR",
        &r->formats[place]);
    if (FAILED(hr)) {
        // Segoe UI Variable n'existe pas avant Windows 11, et Cascadia Mono n'est
        // pas garanti : on retombe sur les polices que toute installation porte.
        hr = r->fabriqueTexte->CreateTextFormat(
            nomDePolice(police, true), nullptr, DWRITE_FONT_WEIGHT_NORMAL,
            DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, taille, L"fr-FR",
            &r->formats[place]);
    }
    if (FAILED(hr)) { r->formats[place] = nullptr; return nullptr; }
    r->tailleDesFormats[place] = taille;
    r->policeDesFormats[place] = police;
    return r->formats[place];
}

extern "C" void spectre_surimpression_texte(SpectreRendu *r, const uint16_t *texte,
                                            float x, float y, float largeur,
                                            float taille, uint32_t rvba,
                                            int police, int alignement) {
    if (!r || !r->dessinEnCours || !texte) { return; }
    IDWriteTextFormat *f = format(r, police, taille);
    if (!f) { return; }

    f->SetTextAlignment(alignement == 1 ? DWRITE_TEXT_ALIGNMENT_CENTER
                      : alignement == 2 ? DWRITE_TEXT_ALIGNMENT_TRAILING
                                        : DWRITE_TEXT_ALIGNMENT_LEADING);
    // Centré verticalement sur `y`, comme `context.draw(Text, at:)` de SwiftUI :
    // c'est ce qui permet de reprendre les mêmes ordonnées que la vue macOS sans
    // les recalculer une à une.
    f->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);

    const WCHAR *large = reinterpret_cast<const WCHAR *>(texte);
    r->contexteD2D->DrawText(large, (UINT32)wcslen(large), f,
                             D2D1::RectF(x, y - taille * 2, x + largeur, y + taille * 2),
                             pinceau(r, rvba), D2D1_DRAW_TEXT_OPTIONS_CLIP,
                             DWRITE_MEASURING_MODE_NATURAL);
}

extern "C" float spectre_surimpression_largeur_texte(SpectreRendu *r,
                                                     const uint16_t *texte,
                                                     float taille, int police) {
    if (!r || !r->fabriqueTexte || !texte) { return 0; }
    IDWriteTextFormat *f = format(r, police, taille);
    if (!f) { return 0; }
    const WCHAR *large = reinterpret_cast<const WCHAR *>(texte);
    IDWriteTextLayout *mise = nullptr;
    if (FAILED(r->fabriqueTexte->CreateTextLayout(large, (UINT32)wcslen(large), f,
                                                  10000, 100, &mise))) {
        return 0;
    }
    DWRITE_TEXT_METRICS mesures;
    HRESULT hr = mise->GetMetrics(&mesures);
    mise->Release();
    return SUCCEEDED(hr) ? mesures.widthIncludingTrailingWhitespace : 0;
}

extern "C" float spectre_surimpression_paragraphe(SpectreRendu *r,
                                                  const uint16_t *texte, float x,
                                                  float y, float largeur, float taille,
                                                  uint32_t rvba, int police,
                                                  int dessiner) {
    if (!r || !r->fabriqueTexte || !texte || largeur <= 0) { return 0; }
    IDWriteTextFormat *f = format(r, police, taille);
    if (!f) { return 0; }

    const WCHAR *large = reinterpret_cast<const WCHAR *>(texte);
    IDWriteTextLayout *mise = nullptr;
    if (FAILED(r->fabriqueTexte->CreateTextLayout(large, (UINT32)wcslen(large), f,
                                                  largeur, 4096, &mise))) {
        return 0;
    }
    // Sur la mise en page et non sur le format : celui-ci est partagé, et
    // `spectre_surimpression_texte` y pose un centrage vertical dont un paragraphe
    // ne veut pas — il commence à son `y`, quelle que soit sa hauteur.
    mise->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING);
    mise->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
    mise->SetWordWrapping(DWRITE_WORD_WRAPPING_WRAP);

    DWRITE_TEXT_METRICS mesures;
    if (FAILED(mise->GetMetrics(&mesures))) { mise->Release(); return 0; }
    if (dessiner && r->dessinEnCours) {
        r->contexteD2D->DrawTextLayout(D2D1::Point2F(x, y), mise, pinceau(r, rvba),
                                       D2D1_DRAW_TEXT_OPTIONS_NONE);
    }
    float hauteur = mesures.height;
    mise->Release();
    return hauteur;
}

extern "C" void spectre_surimpression_arrondi(SpectreRendu *r, float x, float y,
                                              float largeur, float hauteur,
                                              float rayon, uint32_t rvba,
                                              float epaisseur) {
    if (!r || !r->dessinEnCours || largeur <= 0 || hauteur <= 0) { return; }
    D2D1_ROUNDED_RECT forme = D2D1::RoundedRect(
        D2D1::RectF(x, y, x + largeur, y + hauteur), rayon, rayon);
    if (epaisseur > 0) {
        r->contexteD2D->DrawRoundedRectangle(forme, pinceau(r, rvba), epaisseur, nullptr);
    } else {
        r->contexteD2D->FillRoundedRectangle(forme, pinceau(r, rvba));
    }
}

extern "C" void spectre_surimpression_decouper(SpectreRendu *r, float x, float y,
                                               float largeur, float hauteur) {
    if (!r || !r->dessinEnCours) { return; }
    r->contexteD2D->PushAxisAlignedClip(
        D2D1::RectF(x, y, x + largeur, y + hauteur), D2D1_ANTIALIAS_MODE_ALIASED);
    r->decoupes += 1;
}

extern "C" void spectre_surimpression_recoller(SpectreRendu *r) {
    if (!r || !r->dessinEnCours || r->decoupes <= 0) { return; }
    r->contexteD2D->PopAxisAlignedClip();
    r->decoupes -= 1;
}
