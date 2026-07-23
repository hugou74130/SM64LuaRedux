# Bruteforce — frame-reduction, couplé au Semantic Workflow

> Doc de design écrit pendant la nuit (autonome). À relire au réveil avant de tester.
> **Rien n'est commité ni pushé.** Branche : `feat/bruteforce`.

## État au réveil (ce qui a été fait + validé)

**Fait, propre, non commité.** Nouveaux fichiers :
- `src/core/Bruteforce.lua` — cœur pur (recherche + frame-min).
- `src/views/Bruteforce.lua` — onglet UI + driver machine-à-états.
- `src/processors/Bruteforce.lua` — processor d'override d'input.
- `tests/bruteforce_test.lua` — 31 tests unitaires.
- Modifs minimes : `SM64Lua.lua` (vue + processor + chargement cœur), `Settings.lua`
  (`Settings.bruteforce`), `Locales.lua` + `en_US.lua` + `fr_FR.lua` (chaînes EN/FR).

**Validé hors mupen :**
- ✅ Les 9 fichiers compilent (syntax-check Lua 5.4).
- ✅ `lua tests/bruteforce_test.lua` → **31/31** (toute la logique de recherche pure).
- ✅ Les tables de langue chargent, clés BRUTEFORCE présentes EN+FR.
- ✅ Processor inactif = pass-through pur → **zéro impact** sur le TAS normal.
- ✅ Garde-fou `ensure_settings()` → pas de crash si un vieux preset n'a pas `Settings.bruteforce`.

**PAS pu tester (impossible hors mupen) → à valider à la main (plan de test en bas) :**
- Le rendu réel de l'onglet dans mupen.
- Le driver émulateur (savestate/pause/speed) : il **réutilise à l'identique** les appels prouvés
  du Semantic Workflow, mais la boucle async ne peut être exécutée qu'à la main.
- Un point d'incertitude honnête : le timing exact du callback de `savestate.do_memory('load')`
  (sync vs async). J'ai neutralisé son effet sur la mesure (input neutre pendant les transitions +
  ré-étalonnage de la référence sur la 1ʳᵉ mesure faite dans la même boucle), donc le **gain**
  affiché reste juste quel que soit le timing. Si tu vois un décalage de ±1 frame à l'usage, c'est là.

## But

Un outil de brute-force **intégré à SM64LuaRedux**, qui tourne dans **mupen** (donc marche
sur **n'importe quelle ROM/hack**, pas de desync libsm64), pour **réduire le nombre de frames**
d'une action pendant qu'on TAS : *je fais mon action → je brute → je gagne des frames → je continue.*

Couplé à la couche **sémantique** : le but d'une recherche est défini par le **`end_action`** de
Mario (l'action-cible), exactement comme les `SectionInputs` du Semantic Workflow. « Plus court »
= atteindre le même `end_action` en **moins de frames**.

## Principe (pourquoi émulateur, pas libsm64)

On reste **dans l'émulateur**. La savestate mupen EST l'état exact → **zéro desync** (le mur qui
nous a bloqué avec STROOP/libsm64). Prix : vitesse émulateur (mais UltraFastForward + action courte
= des milliers de variantes en quelques secondes, largement suffisant).

## Boucle de recherche (machine à états pilotée par les callbacks de frame)

mupen n'a pas de boucle synchrone : tout passe par `emu.atinput` (poser les inputs) / `emu.atvi`
(lire l'état). Le driver est donc une **machine à états** modelée sur le pattern **prouvé** de
`run_to_preview_internal` (charge savestate → run fast-forward → détecte le but → pause).

```
STATE MACHINE (par candidat) :
  LOAD    : savestate.do_memory(start_state,'load')  → reset frame_idx=0 → RUN
  RUN     : chaque frame → override Joypad.input = candidate[frame_idx]
            si Memory.current.mario_action == target_action → succès(frame_idx) → NEXT
            sinon si frame_idx >= timeout                    → échec           → NEXT
            sinon frame_idx++
  NEXT    : report_result au coeur pur → génère candidat suivant
            budget épuisé ? → APPLY (garde le meilleur) → STOP
```

L'override d'input passe par un **processor** ajouté à la pipeline (même mécanisme que
`SemanticWorkflow.transform`) : quand la recherche tourne, il remplace `Joypad.input` par
l'input du candidat courant. **On ne mute jamais le sheet de l'utilisateur** (sécurité : un crash
en cours de recherche ne corrompt rien).

## Séparation testable / non-testable

- **`core/Bruteforce.lua`** = **logique pure** (aucun appel émulateur) : représentation des
  candidats (liste d'inputs par frame), génération de perturbations, bookkeeping frame-min
  (meilleur = moins de frames ET but atteint), contrôle de la boucle. **100 % unit-testé** avec
  l'interpréteur Lua (`tests/bruteforce_test.lua`, mocks purs).
- **`views/Bruteforce.lua`** = **driver async + UI** (fin). Réutilise **à l'identique** les
  primitives prouvées (`savestate.do_memory`, `emu.pause`/`set_speed_mode`,
  `Memory.current.mario_action`, override joypad). **Non testable hors mupen** → à valider à la main
  (plan de test plus bas).

## Fichiers

- `src/core/Bruteforce.lua`        — coeur pur (état + recherche + frame-min). Testé.
- `src/views/Bruteforce.lua`       — UI (onglet) + driver machine-à-états.
- `src/processors/Bruteforce.lua`  — processor d'override d'input pendant la recherche.
- `tests/bruteforce_test.lua`      — tests unitaires du coeur pur (lua tests/bruteforce_test.lua).
- Modifs minimes (1-3 lignes chacune) :
  - `src/SM64Lua.lua`      : ajoute la vue à `views` + le processor à `processors`.
  - `src/core/Settings.lua`: `Settings.bruteforce = { ... }` (défauts).
  - `src/core/Locales.lua` + `src/res/lang/en_US.lua` + `fr_FR.lua` : chaînes localisées.

## Couplage sémantique (comment le but est défini)

À l'ouverture de l'onglet Bruteforce :
1. **Savestate de départ** : « Set start » capture l'état courant (`savestate.do_memory save`).
   Si un sheet Semantic Workflow est chargé, on propose sa savestate (`SemanticWorkflowProject.current`).
2. **Action-cible (`target_action`)** : « Set goal from current » lit `Memory.current.mario_action`
   à la frame où l'utilisateur est. Par défaut, si un sheet est actif, on propose le `end_action`
   de sa section active. C'est le **couplage sémantique** : le but = une action, comme le workflow.
3. **Baseline + timeout** : la baseline (inputs de départ) est capturée en jouant une fois du start
   jusqu'à ce que `target_action` soit atteint ; ce nombre de frames = la référence à battre, et sert
   de `timeout` (une variante qui dépasse est rejetée).

La recherche perturbe les inputs **bruts** (stick X/Y ± amplitude, boutons de saut avec petite
proba) autour de la baseline — ça reste proche du mouvement de l'utilisateur (perturbation faible)
tout en cherchant un chemin plus court vers la même action.

## UI (onglet « Bruteforce », zéro conflit visuel)

Nouvelle vue top-level (dans la navbar, comme TAS/Timer/Tools) — pattern `{name, draw}` standard,
ugui + `grid_rect`, UID via `UIDProvider.allocate_once`, thème via `Styles.theme()`. N'ajoute qu'un
onglet ; ne touche à aucune vue existante.

Contrôles : `Set start` · `Set goal from current` · `perturb chance` · `perturb magnitude` ·
`max frames` · `Start` / `Stop` · statut live (meilleur = X frames, référence = Y, gain = Y−X) ·
`Apply best` (écrit le meilleur input list — voir « sorties »).

## Sorties (appliquer le résultat)

`Apply best` propose (au choix, réglé simple pour la v1) :
- **copier** la meilleure séquence d'inputs dans le presse-papier (format lisible), et/ou
- l'**écrire dans un fichier** `bruteforce_result.txt` à côté du script (liste frame→input),
que l'utilisateur ré-injecte dans sa run. (Écrire directement dans le .m64 en cours est plus risqué
et réservé à une v2 après validation.)

## Ce que je NE fais PAS en v1 (YAGNI / risque)

- Pas de mutation du sheet de l'utilisateur (sécurité).
- Pas d'écriture directe dans le .m64 en cours (v2).
- Pas de perturbation au niveau sémantique (angles tas_state) — v1 = inputs bruts, plus simple et
  robuste, reste proche du move via perturbation faible.
- Pas d'algo génétique/scattershot complexe : recherche simple « perturbe la baseline/le meilleur,
  garde si but atteint en moins de frames », avec pulse d'amplitude quand ça stagne. Suffisant pour
  des actions courtes et facile à raisonner/valider.

## Plan de test (au réveil, dans mupen)

1. `lua tests/bruteforce_test.lua` (hors mupen) → tout passe (coeur pur).
2. Charger `src/SM64Lua.lua` dans mupen sur SM64 → l'onglet **Bruteforce** apparaît, l'UI se dessine,
   **aucune régression** sur les autres onglets.
3. Se placer avant une petite action (ex. long jump + rebond), `Set start`, avancer jusqu'à l'action
   finale, `Set goal from current`, `Start`. Vérifier : le statut affiche une référence puis un
   meilleur ≤ référence, la recherche s'arrête proprement, `Apply best` produit la séquence.
4. Vérifier qu'aucun état n'est laissé cassé si on `Stop` en plein milieu (speed mode/pause
   reviennent à la normale).
