#!/bin/bash
# Fabrique les quatre réseaux de htdemucs_ft au format ONNX, pour que
# l'application les embarque et n'ait plus besoin ni de Python ni de PyTorch.
#
# À lancer **une fois**. Le résultat va dans Resources/, que .gitignore écarte :
# les poids de Demucs ne sont pas couverts par la licence MIT du code — leur auteur
# les dit « fournis à des fins scientifiques uniquement », parce qu'ils sont
# entraînés sur MUSDB18. Les convertir pour son propre usage ne pose pas de
# question ; les rediffuser, si. D'où le refus de les verser au dépôt.
#
# Tout ce qui est téléchargé ici l'est depuis les serveurs de Meta, à l'adresse que
# le code de Demucs utilise lui-même.
set -euo pipefail
cd "$(dirname "$0")"

WORK=build/modele
VENV="$WORK/venv"
mkdir -p "$WORK"

# Le fork emploie `enum.StrEnum`, qui n'existe qu'à partir de Python 3.11 : on prend
# donc le premier interpréteur assez récent plutôt que le `python3` du système, qui
# peut être plus ancien.
PYTHON=""
for candidate in python3.13 python3.12 python3.11 python3; do
  if command -v "$candidate" >/dev/null 2>&1 &&
     "$candidate" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)'; then
    PYTHON="$candidate"; break
  fi
done
if [ -z "$PYTHON" ]; then
  echo "Échec : il faut Python 3.11 ou plus récent." >&2
  exit 1
fi

if [ ! -d "$VENV" ] || ! "$VENV/bin/python" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
  echo "→ environnement Python jetable dans $VENV ($("$PYTHON" -V))"
  rm -rf "$VENV"
  "$PYTHON" -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
fi

# Demucs tel quel **ne s'exporte pas** : sa STFT et son inverse travaillent sur des
# tenseurs complexes, que ONNX ne sait pas représenter. C'est l'obstacle qui a
# occupé tout un GSoC chez Mixxx ; on reprend leur travail plutôt que de le refaire.
# Leur fork réécrit les deux transformées en paires sinus/cosinus et ajoute un
# drapeau `onnx_exportable` qui bascule le modèle sur ce chemin.
FORK="$WORK/demucs-onnx"
if [ ! -d "$FORK/.git" ]; then
  echo "→ fork Mixxx/GSoC (dhunstack/demucs, branche allchanges)"
  git clone --quiet --branch allchanges --depth 20 \
    https://github.com/dhunstack/demucs.git "$FORK"
else
  git -C "$FORK" fetch --quiet origin allchanges && git -C "$FORK" checkout --quiet allchanges
fi

# Toujours vérifié, pas seulement à la création : l'environnement peut dater d'un
# passage où il manquait une dépendance. Rien de tout cela ne survit à la
# conversion — l'application n'exécute que du Swift et ONNX Runtime.
"$VENV/bin/pip" install --quiet torch onnx onnxscript
# Le fork remplace `demucs` : installé en dernier, et en mode « édition » pour que
# ce soit bien son code qui s'exécute et non celui du paquet publié.
"$VENV/bin/pip" install --quiet -e "$FORK"

echo "→ conversion des quatre réseaux (téléchargement des poids au premier passage)"
"$VENV/bin/python" - <<'PY'
import pathlib
import torch
from torch.nn import functional as F
from demucs.pretrained import get_model

# Les quatre réseaux, dans l'ordre des sources de Demucs. La matrice de pondération
# de htdemucs_ft étant l'identité, le réseau i ne sert qu'à la source i : on les
# nomme donc par la piste dont chacun a la charge, ce qui évite d'avoir à retenir
# un ordre ailleurs dans le code.
# PyTorch 2.9 aiguille `nn.MultiheadAttention` vers un noyau fusionné,
# `_native_multi_head_attention`, qui n'a pas d'équivalent ONNX. Désactivé, le
# module repasse par ses opérations élémentaires — mêmes calculs, mêmes poids,
# simplement écrits d'une façon qui s'exporte. Le fork de Mixxx n'avait pas à s'en
# soucier : ce chemin rapide n'existait pas dans les versions qu'il visait.
torch.backends.mha.set_fastpath_enabled(False)

bag = get_model("htdemucs_ft")
sources = bag.models[0].sources        # ['drums', 'bass', 'other', 'vocals']
assert len(bag.models) == len(sources), "le sac n'a pas quatre réseaux"

out = pathlib.Path("Resources")
out.mkdir(exist_ok=True)

# La **forme est fixe**, et ce n'est pas un pis-aller : Demucs n'applique jamais le
# réseau au morceau entier, il le découpe en tranches de `segment` secondes qu'il
# recolle avec recouvrement. Le graphe doit donc être figé sur cette tranche-là,
# exactement celle que l'application lui donnera. Déclarer la longueur variable
# faisait d'ailleurs échouer l'export : `pad1d` teste la taille qu'il reçoit, ce que
# l'exportateur ne sait pas trancher sur une dimension symbolique.
first = bag.models[0]
length = int(first.segment * first.samplerate)
print(f"   tranche : {length} échantillons ({first.segment} s à {first.samplerate} Hz)")
example = F.pad(torch.randn(1, first.audio_channels, 343980), (0, length - 343980))

for model, source in zip(bag.models, sources):
    model.eval()
    # Le drapeau du fork : il bascule la STFT et son inverse sur la version en
    # tenseurs réels. Sans lui, l'export échoue dans `torch.functional.stft`.
    model.onnx_exportable = True
    target = out / f"htdemucs_ft-{source}.onnx"
    target.unlink(missing_ok=True)          # pas de reste d'un essai précédent
    print(f"   {source} → {target}", flush=True)
    with torch.no_grad():
        # `dynamo=False` : le chemin par traçage, celui qu'ont employé les gens de
        # Mixxx. L'exportateur récent de torch 2.9 bute en amont, sur une taille
        # calculée dans `pad1d` qu'il ne sait pas trancher.
        torch.onnx.export(model, example, str(target),
                          export_params=True, opset_version=17,
                          do_constant_folding=True, dynamo=False,
                          input_names=["mix"], output_names=["stems"])
PY

echo "→ allègement : demi-précision et tables de Fourier partagées"
"$VENV/bin/pip" install --quiet onnxconverter_common onnxruntime
"$VENV/bin/python" Tools/ModelPack/pack.py Resources --verifier

# Les originaux en simple précision ne servent plus qu'à revérifier : ils quittent
# Resources/, où ils doubleraient inutilement l'empreinte sur le disque.
mkdir -p "$WORK/fp32"
mv -f Resources/htdemucs_ft-*-fp32.onnx "$WORK/fp32/" 2>/dev/null || true

echo
# Le sac n'est utilisable qu'entier : sortir en succès avec trois fichiers, ou
# aucun, laisserait croire que le modèle est prêt.
COUNT=$(ls Resources/htdemucs_ft-*.onnx 2>/dev/null | wc -l | tr -d ' ')
if [ "$COUNT" -ne 4 ]; then
  echo "Échec : $COUNT réseau(x) sur 4 produits."
  exit 1
fi
ls -lh Resources/htdemucs_ft-*.onnx
echo "→ relancer ./build.sh pour les embarquer dans l'application"
