# Prism

Un lanceur pour macOS inspiré de [Raycast](https://www.raycast.com/), fonctionnalités Pro comprises : une fenêtre flottante, ouverte au clavier, pour lancer les apps, calculer, retrouver le presse-papiers, développer des snippets, ranger les fenêtres, poser des questions à l'IA, traduire, dicter, prendre des notes, se concentrer…

Natif (Swift, SwiftUI et AppKit), sans dépendance. Tout reste sur le Mac, sauf ce que vous envoyez vous-même à un service (taux de change, fournisseur d'IA en ligne, Store).

Prism est un projet indépendant, sans lien avec Raycast Technologies.

## Installer

**Configuration requise** : macOS 14 ou plus, sur Apple silicon ou Intel. Apple Intelligence sur l'appareil demande macOS 26 et un Mac Apple silicon ; les extensions Raycast demandent Node.js 18 ou plus (`brew install node`).

### Télécharger la release

1. Téléchargez `Prism-<version>.zip` depuis la [dernière release](https://github.com/Guillaume69/prism/releases/latest), ouvrez-le et glissez `Prism.app` dans `/Applications`.
2. Prism n'est pas notarié par Apple : au premier lancement, macOS refuse de l'ouvrir. Allez dans Réglages Système › Confidentialité et sécurité et cliquez sur « Ouvrir quand même » en face de Prism. Ou, dans le Terminal :

   ```bash
   xattr -dr com.apple.quarantine /Applications/Prism.app
   ```

3. Lancez Prism, puis **⌥ Espace**. Pour coller dans les apps, ranger les fenêtres et développer les snippets, ajoutez Prism dans Réglages Système › Confidentialité et sécurité › Accessibilité (voir [Autorisations](#autorisations)).

Pour vérifier le fichier téléchargé : `shasum -a 256 -c Prism-<version>.zip.sha256`, avec l'empreinte publiée à côté.

### Construire depuis les sources

```bash
git clone https://github.com/Guillaume69/prism.git
cd prism
./scripts/install.sh
```

Le script construit `dist/Prism.app`, le copie dans `/Applications` (ou `~/Applications`) et le lance. Il suffit des Command Line Tools (`xcode-select --install`) : si la licence d'Xcode n'est pas acceptée, le script s'en passe. Avec Node.js, il construit aussi l'hôte des extensions Raycast (après un `npm install` dans `RaycastHost/`).

Pour que macOS garde les autorisations de Prism d'un build à l'autre, créez une fois le certificat local de signature avant d'installer : `./scripts/create-signing-certificate.sh` (il l'ajoute à votre trousseau de session).

## Utiliser

**⌥ Espace** ouvre et ferme Prism. Le raccourci s'enregistre dans les réglages (n'importe quelle combinaison, ⌘ Espace compris).

| Touche | Effet |
|---|---|
| ↑ ↓, ⌃N ⌃P | Parcourir les résultats |
| ← → | Parcourir une grille (emojis, captures) |
| ↵ / ⌘ ↵ | Action principale / secondaire |
| ⌘ K | Panneau d'actions (tapez pour filtrer les actions) |
| ⌘ P | Filtre de l'écran (type, étiquette, calendrier…) |
| Tab | Avec une saisie : poser la question à Quick AI |
| ⌘ 1 à ⌘ 9 | Lancer un favori |
| ⌥ ↵ | Action tertiaire |
| ⌘ ↑ ⌘ ↓, ⌥ ↑ ⌥ ↓ | Section précédente ou suivante, page précédente ou suivante |
| ↑ sur une recherche vide | Recherches précédentes |
| ⌘ Échap | Revenir à la recherche principale |
| ⌃J ⌃K | Navigation façon Vim (réglage) |
| Échap | Fermer le panneau, revenir en arrière, vider, fermer |
| ⌘ , | Réglages |

### Recherche principale

- Apps, commandes, liens rapides, scripts, réglages système, jeux Steam, réunion en cours, contacts, fichiers (en option).
- **Favoris** et **suggestions** quand la saisie est vide.
- Chaque commande ou app peut recevoir un **alias** (« cb »), un **raccourci global** (combinaison ou **double appui** sur ⌘, ⌥, ⌃ ou ⇧), aller dans les favoris, être masquée ; « alias texte » passe le texte en argument (`yt lofi`). Tout se règle depuis ⌘K ou l'onglet Commandes.
- **Arguments dans la barre** : une commande à arguments sélectionnée montre ses champs à droite du texte ; Tab pour y aller, ↵ pour lancer.
- **Recherches de repli** (Google, presse-papiers, emojis, fichiers, IA, scripts) : à activer et ordonner dans les réglages.
- Recherche floue sans accents, par initiales (« vsc »), sensibilité réglable.
- **Mode compact** : seulement la barre de recherche tant qu'on n'a rien tapé, avec les favoris en icônes si on le souhaite.
- **Réglages du lanceur** : taille de l'interface, écran d'ouverture (souris, fenêtre active, principal), source de saisie à l'ouverture, fournisseur des icônes de sites, historique des recherches, recherche dans les réglages.
- **Liens profonds** : `prism://commands/<id>?arguments=…` (⌘K › Copier le lien profond), `prism://search?q=…`, et ceux de chaque fonctionnalité.

### Fonctionnalités

| Domaine | Ce qu'on y trouve |
|---|---|
| **Calculatrice** | Arithmétique, unités (longueurs, masses, volumes, températures, données, vitesse, énergie…), devises et cryptos (taux du jour), pourcentages à la Soulver (« 20% off 80 », « 80 + 15% »), fuseaux (« heure à Tokyo », « 5pm ldn in sf », « décalage Paris »), dates (« jours jusqu’à Noël », « lundi dans 3 semaines », « 145 min en durée »), couleurs (#hex, rgb, hsl, lab, oklch → tous les formats), bases (« 255 in hex »), px/rem, historique |
| **Presse-papiers** | Texte, texte riche, images, fichiers, liens, e-mails, couleurs ; tous les formats gardés ; filtre par type ; épingler, renommer, modifier ; coller en texte brut ; texte des images (OCR) et QR codes ; suppression par période ; rétention réglable ; apps ignorées ; « Coller en séquence » |
| **Snippets** | Mots-clés développés dans toutes les apps (immédiatement ou après un délimiteur), placeholders dynamiques (`{cursor}`, `{clipboard}`, `{date format=…}`, `{argument}`, `{selection}`, `{snippet}`, `{uuid}`, modificateurs `| uppercase`…), étiquettes, import et export au format de Raycast |
| **Liens rapides** | Bibliothèque modifiable, arguments, ouvrir avec une app, préférer l'onglet déjà ouvert, favicons, étiquettes, import et export |
| **Emojis et symboles** | 1 915 emojis (drapeaux, tons de peau) en français et en anglais, 360 symboles Unicode, catégories, épinglés, mots-clés personnels, suggestions de l'IA par le sens, colonnes réglables |
| **IA** | Quick AI (Tab, dictée ⌃M), fenêtre AI Chat (historique, épingles, préréglages, branches, export), commandes d'IA (10 intégrées, personnalisées avec placeholders, remplacer la sélection). Fournisseurs : **Apple Intelligence sur l'appareil** (gratuit, par défaut), Ollama, OpenAI ou compatible, Anthropic (clés dans le trousseau) |
| **Agents, projets, skills** | Agents (rôle, instructions, modèle, outils permis ; « Recherche approfondie » intégré), projets (conversations regroupées, instructions communes, dossier de travail avec son `AGENTS.md`), skills (`SKILL.md` lus dans `~/.claude/skills` et les dossiers de Raycast, chargés par le modèle ou mentionnés avec `@nom`), fournisseurs personnalisés compatibles OpenAI (`providers.json`, champs du `providers.yaml` de Raycast) |
| **AI Chat** | Barre latérale (⇧⌘S), ⌘1 à ⌘9, brancher (⇧⌘B), archiver (⌥⌘A) et archivage automatique, joindre un fichier (⇧⌘A), dicter (⌃M), créativité (⇧⌘Y), ↑ pour modifier, notifications en arrière-plan, pas de veille pendant une réponse |
| **Extensions de l'IA** | 16 outils (agenda, presse-papiers, notes, concentration, fichiers, snippets, calculatrice, commandes de Prism, web, page, onglet, écran, mémoire) appelés par Anthropic, OpenAI et Ollama, ou mentionnés avec tous les modèles (`@agenda`, `@presse-papiers`, `@web`, `@écran`…) ; confirmation avant les actions ; **serveurs MCP** (format de Claude Desktop, import en un clic) ; **mémoire** (générée depuis les conversations ou ajoutée à la main) ; **automatisations** (une fois, chaque jour, en semaine, chaque semaine, toutes les heures ; nouvelle conversation ou toujours la même) avec notification ; **lecture de l'écran** (« Envoyer la fenêtre active / la sélection / l'écran / une zone à l'IA ») |
| **Traduction** | Traduction Apple sur l'appareil (repli sur l'IA), détection de la langue, « bonjour en anglais » dans la recherche, lecture à voix haute, commandes à paire fixe |
| **Dictée** | Pilule flottante, reconnaissance sur l'appareil, nettoyage (règles ou IA), styles selon l'app, historique, dicter une note |
| **Notes** | Fenêtre flottante en Markdown vivant (titres, tâches, code, citations, liens), plusieurs notes, épingles, historique ⌘[ ⌘], menu « / », recherche, corbeille |
| **Concentration** | Sessions avec objectif et durée, blocage d'apps et de sites (ou liste autorisée), catégories, pause, report, barre flottante ou barre des menus, historique |
| **Fenêtres** | 38 rangements (moitiés, tiers, quarts, sixièmes, agrandir, centrer, restaurer, écran suivant…), écarts, cycle 1/2 → 2/3 → 1/3, commandes personnalisées, dispositions enregistrées |
| **Navigation** | Rechercher dans les menus de l'app active, changer de fenêtre |
| **Système** | Verrouiller, veille, hibernation, économie d'énergie, son (volume, micro, lecture), apparence, Night Shift, Stage Manager, bureau, corbeille, disques, apps (masquer, quitter toutes), notifications, Wi-Fi et Bluetooth (bascule et appareils), mode avion, volume par application, caméra (aperçu en miroir, photos), HDR des écrans qui le gèrent |
| **Applications** | Nouvelle fenêtre, fichiers récents de l'app, informations, contenu du paquet, forcer à quitter, redémarrer, désinstaller (avec fichiers d'assistance, vers la corbeille), fermeture automatique des apps inactives |
| **Calendrier et contacts** | Mon agenda, rejoindre la visio (Zoom, Meet, Teams…), créer un évènement (avec invitation : message pré-rempli dans le client mail par défaut, ou Gmail si c'est un navigateur, et fichier `.ics` montré dans le Finder), bloquer du temps, disponibilités, prochaine réunion dans la barre des menus, connexion automatique aux réunions ; contacts : appeler, écrire, copier |
| **Fichiers et captures** | Spotlight en deux colonnes (noms ou contenu), aperçu Quick Look, parcourir les dossiers, chemins tapés, Terminal ; captures d'écran en grille avec OCR et filtres `name:` `text:` `date:` |
| **Commandes scripts** | Compatibles avec les script commands de Raycast (`@raycast.*`), modes silent, compact, fullOutput, inline, arguments |
| **Store** | Les ~850 script commands de la communauté Raycast, à lire puis installer d'un geste |
| **Extensions Raycast** | Le **Store d'extensions de Raycast** dans Prism : recherche, installation, mises à jour, désinstallation. Les extensions tournent dans Node.js avec une réimplémentation de `@raycast/api` (listes, grilles, détails, formulaires, panneaux d'actions, navigation, menus déroulants, toasts, HUD, presse-papiers, stockage local, cache, préférences dans le trousseau, arguments, `launchCommand`, IA de Prism, OAuth) ; `BrowserExtension` par AppleScript (onglets et pages de Safari et des navigateurs Chromium), `WindowManagement` par l'accessibilité ; commandes de barre des menus dans la vraie barre des menus, commandes à intervalle en arrière-plan ; **import d'extensions locales** (construites, ou sources construites par leur CLI `ray`) et **mode développement** (reconstruction et rechargement à chaque modification, comme `ray develop`) ; journal par extension |
| **Thèmes** | 14 thèmes (clair et sombre), éditeur, import et export en JSON |
| **Touche Hyper** | Verr. Maj (ou une autre touche) devient ⌃⌥⌘ (+⇧), appui bref configurable |
| **Équipe** | Comme Raycast Teams, par un dossier partagé (iCloud Drive partagé, Dropbox, réseau) : snippets, liens rapides, commandes d'IA et agents publiés par chacun, présents chez tous dans la recherche (étiquette « Équipe », auteur), copiables dans ses propres données ; « Partager avec l'équipe », « Retirer de l'équipe » |
| **Utilisation de l'IA** | À la place des crédits de Raycast : requêtes et jetons par jour et par modèle, coût estimé (tarifs modifiables dans `ai-prices.json`), budget mensuel qui bloque les modèles payants une fois atteint (Apple Intelligence et Ollama restent libres), alerte à 80 % |
| **Synchronisation** | Export et import chiffrés (`.prismconfig`), synchronisation par un dossier (iCloud Drive), sauvegardes programmées |
| **Divers** | Mes statistiques, mode jeu, lanceur de jeux, confettis |

### Ce qui n'a pas d'équivalent (et pourquoi)

- **Comptes Raycast** (connexion, facturation, administration d'organisation, SSO) : Prism n'a pas de serveur. La synchronisation et l'équipe passent par un dossier (iCloud Drive, Dropbox, réseau), l'IA par vos propres modèles et vos clés, sans crédits à acheter.
- **Fonctions d'IA hébergées par Raycast** : génération d'images et modèles réservés à l'offre Pro n'ont pas d'équivalent ; Prism utilise les modèles des fournisseurs que vous configurez.
- **Windows** : Prism est réservé au Mac.
- **App iPhone** : elle n'est pas publiée sur l'App Store ; elle se construit depuis les sources (voir plus bas).

**Extensions Raycast** : Node.js 18 ou plus (`brew install node`), détecté automatiquement (Homebrew, nvm, Volta, shell). `RaycastHost/` contient l'hôte : `npm install && npm run build` le construit (fait par `scripts/build.sh`), `npm test` l'éprouve sur une extension de démonstration.

## Prism sur iPhone

`iOS/PrismMobile.xcodeproj` : l'app compagnon (iOS 18 ou plus), comme l'app iOS de Raycast.

- **IA** : les conversations de Prism (celles du Mac comprises) et de nouvelles, avec Apple Intelligence sur l'appareil (iOS 26), Anthropic ou un service compatible OpenAI (Ollama, LM Studio sur le réseau local) ; raccourci « Demander à Prism » pour Siri et Raccourcis.
- **Notes**, **Snippets** (un toucher pour copier, placeholders usuels) et **Liens rapides** (arguments demandés, puis ouverture).
- **Synchronisation** : l'app lit et réécrit le fichier de synchronisation du Mac (`iCloud Drive/Prism/Prism.prismconfig`, chiffré ou non) ; chaque modification est datée et reprise par le Mac à sa synchronisation suivante. Sans Mac, les données restent sur l'iPhone.

Construire pour le simulateur : `xcodebuild -project iOS/PrismMobile.xcodeproj -scheme PrismMobile -destination 'generic/platform=iOS Simulator' build`. Pour un iPhone, ouvrez le projet dans Xcode et choisissez votre équipe de développement (Signing & Capabilities).

## Autorisations

- **Accessibilité** : coller dans l'app active, ranger les fenêtres, développer les snippets, lire la sélection, chercher dans les menus, touche Hyper. Signé avec le certificat local « Prism Dev » (`scripts/create-signing-certificate.sh`, une fois par Mac), Prism garde ses autorisations d'un build à l'autre ; sans ce certificat, il est signé « ad hoc » et macOS demande de le réactiver après chaque reconstruction.
- **Automatisation** (Finder, System Events, navigateurs) : demandée à la première commande qui en a besoin.
- **Calendrier, Contacts, Caméra** (commande « Caméra »), **Micro, Reconnaissance vocale, Bluetooth, Localisation** (noms des réseaux Wi-Fi), **Enregistrement de l'écran** (lecture de l'écran par l'IA), **Enregistrement audio** (mixeur de volume), **Notifications** (automatisations) : demandés au premier usage de la fonctionnalité.

`./scripts/verify-accessibility.sh` vérifie de bout en bout le collage et le rangement des fenêtres. `./scripts/verify-keyboard.sh` vérifie l'expansion des snippets, la touche Hyper et les doubles frappes par de vraies frappes, en rendant ensuite vos réglages.

## Données

Tout est dans `~/Library/Application Support/Prism/` (un fichier JSON par fonctionnalité, l'historique du presse-papiers dans `Clipboard/`) et dans les préférences `app.prism.launcher`. Les clés d'API sont dans le trousseau.

## Développer

```bash
swift build                                   # build de débogage
.build/debug/Prism --selftest                 # ~720 vérifications, sans autorisation ni écriture
.build/debug/Prism --calc "100 usd en eur"    # interroge la calculatrice
.build/debug/Prism --ai-test "question"       # essai d'Apple Intelligence sur l'appareil
.build/debug/Prism --ai-tools-test serveur.py # essai réel : serveur MCP, recherche web, page, @date
PRISM_PROVIDERS_FILE=providers.json .build/debug/Prism --custom-provider-test custom:id/modele
PRISM_ANTHROPIC_BASE_URL=… PRISM_ANTHROPIC_TEST_KEY=… .build/debug/Prism --provider-test anthropic   # contre un serveur local
PRISM_OLLAMA_URL=… .build/debug/Prism --provider-test ollama
./scripts/build.sh                            # dist/Prism.app
./scripts/package-release.sh                  # dist/Prism-<version>.zip universel et son empreinte, pour une release
```

Rendus de l'interface en PNG, sans autorisation d'enregistrement de l'écran :

```bash
.build/debug/Prism --snapshot sortie.png [--mode <commande>] [--query "texte"] [--light] [--actions] [--down N] [--demo]
.build/debug/Prism --snapshot reglages.png --settings --pane <onglet>
.build/debug/Prism --snapshot-notes notes.png | --snapshot-chat chat.png | --snapshot-focus barre.png | --snapshot-dictation pilule.png
```

Piloter l'app lancée comme au clavier (essais de bout en bout), seulement si elle est lancée avec `PRISM_DEBUG=1` :

```bash
open --env PRISM_DEBUG=1 /Applications/Prism.app
/Applications/Prism.app/Contents/MacOS/Prism --debug show            # ouvre le lanceur
/Applications/Prism.app/Contents/MacOS/Prism --debug type safari     # tape du texte
/Applications/Prism.app/Contents/MacOS/Prism --debug key 40 cmd      # ⌘K (codes de touche macOS)
/Applications/Prism.app/Contents/MacOS/Prism --debug run command:emoji
/Applications/Prism.app/Contents/MacOS/Prism --debug dump etat.json
```

### Organisation

| Dossier | Contenu |
|---|---|
| `Sources/Prism/App` | Entrée, délégué, fenêtre du lanceur et clavier, protocole des fonctionnalités, alias et raccourcis, liens profonds, crochets entre fonctionnalités, outils d'essai |
| `Sources/Prism/Model` | Écrans empilés et formulaires, modèle du lanceur, recherche principale, recherche floue, stockage JSON |
| `Sources/Prism/Services` | Coller, frappes, sélection, placeholders dynamiques, pastille de confirmation |
| `Sources/Prism/Views` | Lanceur, formulaires, composants et thème, réglages |
| `Sources/Prism/Features/<Domaine>` | Une fonctionnalité par dossier : un `enum …Feature: PrismFeature` (commandes, sections de la recherche, recherches de repli, onglet de réglages, liens profonds, autotests) |

Ajouter une fonctionnalité : créer son dossier, conformer un `enum` à `PrismFeature`, l'ajouter à `Features.all` (`App/Feature.swift`).

## Licence

[MIT](LICENSE).

Les données des emojis combinent les noms de macOS et l'ordre, les catégories et les mots-clés anglais d'[emoji-toolkit](https://github.com/joypixels/emoji-toolkit) (licence MIT). L'hôte des extensions embarque [React](https://react.dev) (licence MIT). Les extensions et les script commands installées depuis les Stores de Raycast restent sous leur propre licence.
