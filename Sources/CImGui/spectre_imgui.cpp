// La passerelle vers Dear ImGui. Voir `include/spectre_imgui.h` pour le pourquoi.
//
// Tout ce qui est C++ — objets, références, surcharges, `ImVec2` — s'arrête à ce
// fichier. Ce qui en sort est du C ordinaire.

#include "imgui/imgui.h"
#include "imgui/imgui_impl_sdl3.h"
#include "imgui/imgui_impl_opengl3.h"

#include <SDL3/SDL.h>

#include "include/spectre_imgui.h"

static float hauteurBarre = 0.0f;
static int sommets = 0;

int spectre_ui_demarrer(void *fenetre, void *contexte, float echelle) {
    IMGUI_CHECKVERSION();
    if (ImGui::CreateContext() == nullptr) { return 0; }

    ImGuiIO &io = ImGui::GetIO();
    // Pas de `imgui.ini` : Spectre n'a pas de fenêtres flottantes que
    // l'utilisateur dispose, et un fichier écrit à côté de l'exécutable
    // surprendrait plus qu'il ne servirait.
    io.IniFilename = nullptr;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;

    // Sombre : le spectrogramme est sombre, et une barre claire au-dessus
    // éblouirait au milieu d'une séance.
    ImGui::StyleColorsDark();
    ImGuiStyle &style = ImGui::GetStyle();
    style.WindowRounding = 0.0f;
    style.FrameRounding = 4.0f;
    style.GrabRounding = 4.0f;
    style.WindowBorderSize = 0.0f;
    style.FramePadding = ImVec2(8.0f, 5.0f);
    style.ItemSpacing = ImVec2(8.0f, 6.0f);
    style.Colors[ImGuiCol_WindowBg] = ImVec4(0.09f, 0.09f, 0.11f, 0.94f);
    style.Colors[ImGuiCol_FrameBg] = ImVec4(0.18f, 0.18f, 0.21f, 1.00f);
    style.Colors[ImGuiCol_Button] = ImVec4(0.22f, 0.22f, 0.26f, 1.00f);
    style.Colors[ImGuiCol_SliderGrab] = ImVec4(0.55f, 0.55f, 0.62f, 1.00f);
    if (echelle > 0.0f && echelle != 1.0f) {
        style.ScaleAllSizes(echelle);
        io.FontGlobalScale = echelle;
    }

    if (!ImGui_ImplSDL3_InitForOpenGL((SDL_Window *)fenetre, contexte)) {
        ImGui::DestroyContext();
        return 0;
    }
    // La même version que le nuanceur du spectrogramme : un seul contexte, une
    // seule exigence.
    if (!ImGui_ImplOpenGL3_Init("#version 330 core")) {
        ImGui_ImplSDL3_Shutdown();
        ImGui::DestroyContext();
        return 0;
    }
    return 1;
}

void spectre_ui_arreter(void) {
    ImGui_ImplOpenGL3_Shutdown();
    ImGui_ImplSDL3_Shutdown();
    ImGui::DestroyContext();
}

int spectre_ui_evenement(const void *evenement) {
    ImGui_ImplSDL3_ProcessEvent((const SDL_Event *)evenement);
    const SDL_Event *e = (const SDL_Event *)evenement;
    ImGuiIO &io = ImGui::GetIO();
    switch (e->type) {
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
    case SDL_EVENT_MOUSE_WHEEL:
    case SDL_EVENT_MOUSE_MOTION:
        return io.WantCaptureMouse ? 1 : 0;
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
    case SDL_EVENT_TEXT_INPUT:
        return io.WantCaptureKeyboard ? 1 : 0;
    default:
        return 0;
    }
}

void spectre_ui_nouvelle_image(void) {
    ImGui_ImplOpenGL3_NewFrame();
    ImGui_ImplSDL3_NewFrame();
    ImGui::NewFrame();
}

void spectre_ui_dessiner(void) {
    ImGui::Render();
    ImDrawData *donnees = ImGui::GetDrawData();
    sommets = donnees ? donnees->TotalVtxCount : 0;
    ImGui_ImplOpenGL3_RenderDrawData(donnees);
}

int spectre_ui_veut_souris(void) { return ImGui::GetIO().WantCaptureMouse ? 1 : 0; }
int spectre_ui_veut_clavier(void) { return ImGui::GetIO().WantCaptureKeyboard ? 1 : 0; }

// ═══════════════════════════════════════════════════════════════ les éléments

static const ImGuiWindowFlags drapeauxBarre =
    ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove |
    ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoSavedSettings |
    ImGuiWindowFlags_NoBringToFrontOnFocus | ImGuiWindowFlags_AlwaysAutoResize;

int spectre_ui_barre_debut(const char *titre, float largeur, float hauteur) {
    ImGui::SetNextWindowPos(ImVec2(0.0f, 0.0f));
    ImGui::SetNextWindowSize(ImVec2(largeur, hauteur));
    bool ouvert = ImGui::Begin(titre, nullptr, drapeauxBarre);
    if (ouvert) { hauteurBarre = ImGui::GetWindowSize().y; }
    return ouvert ? 1 : 0;
}

void spectre_ui_barre_fin(void) { ImGui::End(); }

int spectre_ui_panneau_debut(const char *titre, float x, float y, float largeur) {
    ImGui::SetNextWindowPos(ImVec2(x, y), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSize(ImVec2(largeur, 0.0f), ImGuiCond_FirstUseEver);
    return ImGui::Begin(titre, nullptr,
                        ImGuiWindowFlags_NoSavedSettings | ImGuiWindowFlags_AlwaysAutoResize)
           ? 1 : 0;
}

void spectre_ui_panneau_fin(void) { ImGui::End(); }

void spectre_ui_texte(const char *texte) { ImGui::TextUnformatted(texte); }

void spectre_ui_texte_faible(const char *texte) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.62f, 0.62f, 0.66f, 1.0f));
    ImGui::TextUnformatted(texte);
    ImGui::PopStyleColor();
}

void spectre_ui_meme_ligne(void) { ImGui::SameLine(); }

void spectre_ui_separateur(void) {
    ImGui::SameLine();
    ImGui::TextUnformatted("|");
    ImGui::SameLine();
}

void spectre_ui_espace(void) { ImGui::Spacing(); }

int spectre_ui_bouton(const char *titre, float largeur) {
    return ImGui::Button(titre, ImVec2(largeur, 0.0f)) ? 1 : 0;
}

int spectre_ui_bouton_bascule(const char *titre, int actif, float largeur) {
    if (actif) {
        ImGui::PushStyleColor(ImGuiCol_Button, ImVec4(0.30f, 0.42f, 0.62f, 1.0f));
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.36f, 0.48f, 0.68f, 1.0f));
    }
    bool cliqué = ImGui::Button(titre, ImVec2(largeur, 0.0f));
    if (actif) { ImGui::PopStyleColor(2); }
    return cliqué ? 1 : 0;
}

int spectre_ui_case(const char *titre, int *actif) {
    bool v = (*actif != 0);
    bool changé = ImGui::Checkbox(titre, &v);
    *actif = v ? 1 : 0;
    return changé ? 1 : 0;
}

int spectre_ui_reglette(const char *titre, float *valeur, float mini, float maxi,
                        const char *format, float largeur) {
    ImGui::SetNextItemWidth(largeur);
    return ImGui::SliderFloat(titre, valeur, mini, maxi, format) ? 1 : 0;
}

int spectre_ui_liste(const char *titre, int *choix, const char *articles, float largeur) {
    ImGui::SetNextItemWidth(largeur);
    return ImGui::Combo(titre, choix, articles) ? 1 : 0;
}

float spectre_ui_hauteur_barre(void) { return hauteurBarre; }

int spectre_ui_sommets(void) { return sommets; }
