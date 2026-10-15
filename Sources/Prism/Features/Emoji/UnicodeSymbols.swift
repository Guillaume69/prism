// Les symboles Unicode du sélecteur, hors emojis : ce qu'on cherche dans la palette de caractères
// pour écrire (guillemets, tirets, flèches, touches du Mac…). Une ligne par symbole :
// « caractère|nom français|mots-clés », le nom anglais vient des propriétés Unicode.

enum UnicodeSymbols {
    struct Group {
        let id: String
        let title: String
        let table: String
    }

    static let groups: [Group] = [
        Group(id: "arrows", title: "Flèches", table: """
        →|flèche vers la droite|droite suivant
        ←|flèche vers la gauche|gauche précédent
        ↑|flèche vers le haut|haut monter
        ↓|flèche vers le bas|bas descendre
        ↔|flèche gauche-droite|double horizontale
        ↕|flèche haut-bas|double verticale
        ↗|flèche vers le haut à droite|nord-est diagonale
        ↘|flèche vers le bas à droite|sud-est diagonale
        ↙|flèche vers le bas à gauche|sud-ouest diagonale
        ↖|flèche vers le haut à gauche|nord-ouest diagonale
        ⇒|double flèche vers la droite|implique donc alors
        ⇐|double flèche vers la gauche|
        ⇔|double flèche gauche-droite|équivalent si et seulement si
        ⇑|double flèche vers le haut|
        ⇓|double flèche vers le bas|
        ⇕|double flèche haut-bas|
        ⟶|longue flèche vers la droite|
        ⟵|longue flèche vers la gauche|
        ⟷|longue flèche gauche-droite|
        ⟹|longue double flèche vers la droite|implique
        ➜|flèche épaisse vers la droite|
        ➔|flèche large vers la droite|
        ➝|flèche fine vers la droite|
        ➞|flèche effilée vers la droite|
        ➤|pointe de flèche vers la droite|
        ↩|flèche de retour vers la gauche|retour annuler
        ↪|flèche de retour vers la droite|rétablir
        ↺|flèche circulaire antihoraire|rotation recharger
        ↻|flèche circulaire horaire|rotation actualiser
        ⇄|flèches droite et gauche|échange
        ⇆|flèches gauche et droite|échange
        ⇅|flèches haut et bas|tri
        ↰|flèche vers le haut puis la gauche|
        ↱|flèche vers le haut puis la droite|
        ↲|flèche vers le bas puis la gauche|entrée
        ↳|flèche vers le bas puis la droite|sous-élément réponse
        ⤴|flèche courbe vers le haut|
        ⤵|flèche courbe vers le bas|
        ↯|éclair vers le bas|zigzag
        """),
        Group(id: "math", title: "Mathématiques", table: """
        ±|plus ou moins|
        ∓|moins ou plus|
        ×|signe de multiplication|fois multiplier
        ÷|signe de division|diviser
        −|signe moins|soustraction
        ≠|différent de|inégal
        ≈|presque égal à|environ
        ≡|identique à|congruent
        ≅|approximativement égal à|congruent
        ∼|opérateur tilde|semblable
        ≤|inférieur ou égal à|plus petit
        ≥|supérieur ou égal à|plus grand
        ≪|très inférieur à|
        ≫|très supérieur à|
        ∞|infini|
        √|racine carrée|
        ∛|racine cubique|
        ∑|somme|sigma
        ∏|produit|pi
        ∫|intégrale|
        ∂|dérivée partielle|
        ∆|incrément|delta
        ∇|nabla|gradient
        ∈|appartient à|élément
        ∉|n’appartient pas à|
        ⊂|sous-ensemble de|inclus
        ⊃|sur-ensemble de|contient
        ⊆|sous-ensemble ou égal à|
        ⊇|sur-ensemble ou égal à|
        ∪|union|
        ∩|intersection|
        ∅|ensemble vide|
        ∀|pour tout|quantificateur universel
        ∃|il existe|quantificateur existentiel
        ∄|il n’existe pas|
        ¬|négation|non logique
        ∧|et logique|conjonction
        ∨|ou logique|disjonction
        ⊕|plus cerclé|ou exclusif xor
        ⊗|fois cerclé|produit tensoriel
        ∝|proportionnel à|
        ∠|angle|
        ⊥|perpendiculaire|
        ∥|parallèle à|
        ∴|par conséquent|donc
        ∵|parce que|car
        ⋅|point de multiplication|produit scalaire
        ∘|rond|composition
        °|degré|température angle
        ′|prime|minute pied
        ″|double prime|seconde pouce
        ‰|pour mille|
        ‱|pour dix mille|
        ½|un demi|fraction moitié
        ⅓|un tiers|fraction
        ⅔|deux tiers|fraction
        ¼|un quart|fraction
        ¾|trois quarts|fraction
        ⅛|un huitième|fraction
        ℕ|entiers naturels|ensemble
        ℤ|entiers relatifs|ensemble
        ℚ|nombres rationnels|ensemble
        ℝ|nombres réels|ensemble
        ℂ|nombres complexes|ensemble
        """),
        Group(id: "currency", title: "Monnaies", table: """
        €|euro|monnaie devise
        $|dollar|monnaie devise
        £|livre sterling|monnaie devise
        ¥|yen|yuan monnaie devise
        ¢|cent|centime monnaie
        ₿|bitcoin|crypto monnaie
        ₹|roupie indienne|monnaie devise
        ₽|rouble|monnaie devise
        ₩|won|corée monnaie devise
        ₺|livre turque|monnaie devise
        ₴|hryvnia|ukraine monnaie
        ₪|shekel|israël monnaie
        ₫|dong|vietnam monnaie
        ₦|naira|nigeria monnaie
        ₱|peso philippin|monnaie
        ₸|tenge|kazakhstan monnaie
        ₼|manat|azerbaïdjan monnaie
        ₾|lari|géorgie monnaie
        ₡|colón|costa rica monnaie
        ₲|guarani|paraguay monnaie
        ฿|baht|thaïlande monnaie
        ₣|franc|ancien franc monnaie
        ¤|symbole monétaire|monnaie générique
        """),
        Group(id: "punctuation", title: "Ponctuation et typographie", table: """
        «|guillemet ouvrant|chevrons français citation
        »|guillemet fermant|chevrons français citation
        ‹|guillemet simple ouvrant|chevron
        ›|guillemet simple fermant|chevron
        “|guillemet anglais ouvrant|citation
        ”|guillemet anglais fermant|citation
        „|guillemet bas|allemand citation
        ‘|apostrophe ouvrante|guillemet simple
        ’|apostrophe typographique|guillemet simple fermant
        ‚|guillemet simple bas|
        —|tiret cadratin|tiret long dialogue
        –|tiret demi-cadratin|tiret moyen intervalle
        …|points de suspension|trois points ellipse
        ·|point médian|interpunct écriture inclusive
        ¶|pied de mouche|paragraphe alinéa
        §|paragraphe|section article
        †|croix|obèle dague décès
        ‡|double croix|double dague
        ©|copyright|droit d’auteur
        ®|marque déposée|
        ™|marque commerciale|trademark
        ℗|droit phonographique|
        №|numéro|
        ¿|point d’interrogation renversé|espagnol
        ¡|point d’exclamation renversé|espagnol
        ‽|point exclarogatif|interrobang
        ⁂|astérisme|
        ※|marque de référence|
        ‖|double barre verticale|
        ¦|barre interrompue|
        ⁄|barre de fraction|
        \u{00A0}|espace insécable|nbsp espace
        \u{202F}|espace fine insécable|espace étroite typographie
        """),
        Group(id: "greek", title: "Lettres grecques", table: """
        α|alpha|grec
        β|bêta|grec
        γ|gamma|grec
        δ|delta|grec
        ε|epsilon|grec
        ζ|zêta|grec
        η|êta|grec
        θ|thêta|grec
        ι|iota|grec
        κ|kappa|grec
        λ|lambda|grec
        μ|mu|micro grec
        ν|nu|grec
        ξ|xi|grec
        π|pi|grec
        ρ|rhô|grec
        σ|sigma|grec
        ς|sigma final|grec
        τ|tau|grec
        υ|upsilon|grec
        φ|phi|grec
        χ|chi|khi grec
        ψ|psi|grec
        ω|oméga|grec
        Γ|gamma majuscule|grec
        Δ|delta majuscule|grec
        Θ|thêta majuscule|grec
        Λ|lambda majuscule|grec
        Ξ|xi majuscule|grec
        Π|pi majuscule|grec
        Σ|sigma majuscule|somme grec
        Φ|phi majuscule|grec
        Ψ|psi majuscule|grec
        Ω|oméga majuscule|ohm grec
        """),
        Group(id: "keys", title: "Touches", table: """
        ⌘|touche Commande|cmd command pomme
        ⌥|touche Option|alt opt
        ⇧|touche Majuscule|shift maj
        ⌃|touche Contrôle|ctrl control
        ⇪|verrouillage des majuscules|caps lock verr maj
        ⏎|touche Retour|entrée return enter
        ↵|retour chariot|entrée return enter
        ⌤|touche Entrée|enter
        ⌫|effacement arrière|supprimer backspace delete
        ⌦|effacement avant|supprimer delete
        ⎋|touche Échap|escape esc
        ⇥|tabulation|tab
        ⇤|tabulation arrière|tab
        ␣|espace visible|espace barre
        ⏏|éjecter|eject
        ⇞|page précédente|page up
        ⇟|page suivante|page down
        ⇱|début|home
        ⇲|fin|end
        |logo Apple|pomme mac
        ⌧|effacer|clear
        ⌨|clavier|keyboard
        """),
        Group(id: "shapes", title: "Formes et boîtes", table: """
        ■|carré noir|plein
        □|carré blanc|vide
        ▪|petit carré noir|
        ▫|petit carré blanc|
        ▲|triangle noir vers le haut|
        △|triangle blanc vers le haut|
        ▼|triangle noir vers le bas|
        ▽|triangle blanc vers le bas|
        ▶|triangle noir vers la droite|lecture
        ▷|triangle blanc vers la droite|
        ◀|triangle noir vers la gauche|
        ◁|triangle blanc vers la gauche|
        ◆|losange noir|
        ◇|losange blanc|
        ●|cercle noir|disque rond
        ○|cercle blanc|rond
        ◎|double cercle|cible
        ◉|œil de poisson|cercle
        ◯|grand cercle|
        ◐|cercle à moitié noir à gauche|
        ◑|cercle à moitié noir à droite|
        ▬|rectangle noir|
        ▭|rectangle blanc|
        ▮|rectangle vertical noir|
        ▯|rectangle vertical blanc|
        ─|trait horizontal|boîte ligne
        │|trait vertical|boîte ligne
        ┌|coin haut gauche|boîte
        ┐|coin haut droit|boîte
        └|coin bas gauche|boîte
        ┘|coin bas droit|boîte
        ├|té à droite|boîte
        ┤|té à gauche|boîte
        ┬|té vers le bas|boîte
        ┴|té vers le haut|boîte
        ┼|croix de boîte|boîte
        ═|double trait horizontal|boîte
        ║|double trait vertical|boîte
        ╔|double coin haut gauche|boîte
        ╗|double coin haut droit|boîte
        ╚|double coin bas gauche|boîte
        ╝|double coin bas droit|boîte
        ╭|coin arrondi haut gauche|boîte
        ╮|coin arrondi haut droit|boîte
        ╰|coin arrondi bas gauche|boîte
        ╯|coin arrondi bas droit|boîte
        ░|ombre légère|trame
        ▒|ombre moyenne|trame
        ▓|ombre foncée|trame
        █|pavé plein|bloc
        ▀|demi-pavé haut|bloc
        ▄|demi-pavé bas|bloc
        ▌|demi-pavé gauche|bloc
        ▐|demi-pavé droit|bloc
        """),
        Group(id: "bullets", title: "Puces", table: """
        •|puce|liste point
        ‣|puce triangulaire|liste
        ◦|puce blanche|liste
        ⁃|puce tiret|liste
        ∙|point de liste|opérateur puce
        ▸|petit triangle vers la droite|puce liste
        ▹|petit triangle blanc vers la droite|puce liste
        ►|pointeur vers la droite|puce liste
        ❖|losange noir moins un losange blanc|puce
        ➢|pointe de flèche en relief|puce
        ⦿|cercle avec point|puce cible
        ⁌|puce noire vers la gauche|
        ⁍|puce noire vers la droite|
        """),
        Group(id: "stars", title: "Étoiles", table: """
        ★|étoile noire|pleine favori note
        ☆|étoile blanche|vide favori note
        ✦|étoile noire à quatre branches|scintillement
        ✧|étoile blanche à quatre branches|scintillement
        ✩|étoile blanche cerclée|
        ✪|étoile cerclée|
        ✫|étoile noire au centre blanc|
        ✬|étoile noire au centre ouvert|
        ✭|étoile noire en relief|
        ✮|étoile noire ombrée|
        ✯|étoile pivotante|
        ✰|étoile blanche ombrée|
        ⭑|petite étoile noire|
        ⭒|petite étoile blanche|
        ✱|astérisque épais|
        ✲|astérisque ouvert|
        ✵|étoile pivotante à huit branches|
        ✶|étoile noire à six branches|
        ✷|étoile noire rectiligne à huit branches|
        ✸|étoile noire épaisse à huit branches|
        ✹|étoile noire à douze branches|
        ✺|astérisque à seize branches|
        ✻|astérisque en goutte|
        ✼|astérisque ouvert en goutte|
        ✽|astérisque épais en goutte|
        ❋|astérisque hélice|
        ❀|fleur blanche|
        ✿|fleur noire|
        ❁|fleur blanche ombrée|
        ⁎|astérisque bas|
        """),
        Group(id: "checkboxes", title: "Cases à cocher", table: """
        ☐|case vide|case à cocher tâche
        ☑|case cochée|case à cocher fait tâche
        ☒|case avec croix|case à cocher annulé
        ✓|coche|valide oui fait
        ✔|coche épaisse|valide oui fait
        ✗|croix|non faux
        ✘|croix épaisse|non faux
        ⊠|carré barré|
        ⊡|carré pointé|
        """),
        Group(id: "scripts", title: "Exposants et indices", table: """
        ⁰|exposant zéro|puissance
        ¹|exposant un|puissance
        ²|exposant deux|carré puissance
        ³|exposant trois|cube puissance
        ⁴|exposant quatre|puissance
        ⁵|exposant cinq|puissance
        ⁶|exposant six|puissance
        ⁷|exposant sept|puissance
        ⁸|exposant huit|puissance
        ⁹|exposant neuf|puissance
        ⁺|exposant plus|
        ⁻|exposant moins|
        ⁼|exposant égal|
        ⁽|exposant parenthèse ouvrante|
        ⁾|exposant parenthèse fermante|
        ⁿ|exposant n|puissance
        ⁱ|exposant i|
        ₀|indice zéro|
        ₁|indice un|
        ₂|indice deux|
        ₃|indice trois|
        ₄|indice quatre|
        ₅|indice cinq|
        ₆|indice six|
        ₇|indice sept|
        ₈|indice huit|
        ₉|indice neuf|
        ₊|indice plus|
        ₋|indice moins|
        ₌|indice égal|
        ₍|indice parenthèse ouvrante|
        ₎|indice parenthèse fermante|
        ₐ|indice a|
        ₑ|indice e|
        ₒ|indice o|
        ₓ|indice x|
        ª|indicateur ordinal féminin|
        º|indicateur ordinal masculin|
        ᵉ|e en exposant|ordinal premier siècle
        ʳ|r en exposant|
        """),
    ]
}
