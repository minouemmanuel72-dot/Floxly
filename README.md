# Floxly – front + back-end assemblés

Contenu : le front de ton développeur (`index.html`, inchangé dans son interface), l'adaptateur Supabase (`api-supabase.js`), ton réglage de connexion (`config.js`), le SQL du back-end (`supabase/`), et les fichiers d'installation PWA (`manifest.webmanifest`, `sw.js`, `icons/`, `vercel.json`).

Si `config.js` est vide, Floxly marche en **mode local** (démo dans le navigateur). Dès qu'il est rempli, tout passe par Supabase : comptes, publications, Shorts, stories, messages, notifications, statistiques.

## 1. Préparer Supabase (une seule fois)

1. Va sur supabase.com, ouvre ton projet, menu **SQL Editor**.
2. **Commence par une copie ou un projet de test**, pas ta base importante.
3. Colle tout le contenu de `supabase/01_floxly_backend.sql`, clique **Run**. Attendu : « Success ».
4. Nouvelle requête : colle `supabase/02_floxly_assemblage.sql`, **Run**.
5. Menu **Project Settings > API** : copie **Project URL** et la clé **anon / publishable**. (Jamais la clé `service_role`.)
6. Menu **Authentication > Providers > Email** : pour tes tests, désactive **Confirm email** (sinon chaque testeur doit cliquer un lien reçu par e-mail ; le plan gratuit limite fortement le nombre d'e-mails envoyés).

## 2. Remplir config.js

Ouvre `config.js`, colle l'URL et la clé entre les guillemets, enregistre.

## 3. Mettre sur GitHub puis Vercel

1. github.com > **+** > **New repository** > nom `floxly-app` > **Private** > **Create repository**. (Nouveau dépôt : ne mélange pas avec ton ancien `floxly`.)
2. Sur la page vide : **uploading an existing file**. Glisse **le contenu** du dossier dézippé (pas le dossier lui-même) : `index.html`, `config.js`, `api-supabase.js`, `sw.js`, `icons`, `supabase`… Puis **Commit changes**.
3. vercel.com > **Add New… > Project** > importe `floxly-app` > ne change rien (Framework : *Other*) > **Deploy**.
4. Dans Supabase **Authentication > URL Configuration** : mets l'adresse Vercel dans **Site URL**.
5. Envoie l'adresse Vercel à tes testeurs. Chacun crée son compte ; les publications, Shorts et historiques restent enregistrés sur le serveur et réapparaissent à chaque connexion.

Mise à jour : remplace un fichier dans GitHub, Vercel republie. Change aussi `VERSION` dans `sw.js` pour que les téléphones récupèrent la nouvelle version.

## Ce que j'ai modifié

- `index.html` : ajout des balises PWA et des 3 scripts ; `API` choisit Supabase si `config.js` est rempli ; bouton « profil trouvé » pour écrire à quelqu'un ; mise à jour automatique de la messagerie (toutes les 6 s) et des notifications ; thème/palette restaurés depuis le compte ; enregistrement de l'objectif attendu avant l'affichage.
- `supabase/02_floxly_assemblage.sql` : vérification d'identifiant libre avant inscription ; correction de la lecture des publications par leur auteur (sans elle, publier échouait).
- `supabase/01_floxly_backend.sql` : **non modifié**.

## Ce qui a été testé, et ce qui ne l'a pas été

Testé : ton SQL (exécuté 2 fois sans erreur) sur un vrai PostgreSQL 16 avec la sécurité par ligne, et le front complet (inscription, publier, image, Short, story, brouillon, communauté, like, repost, enregistrer, commentaire, abonnement, messages, réaction, réponse, modification, notifications, statistiques, profil, programmation, signalement, déconnexion/connexion), avec un faux client Supabase relié à cette base. Aucune erreur JavaScript.

**Non testé** : le vrai Supabase (Auth, Storage, requêtes PostgREST réelles), la vraie bibliothèque supabase-js, Vercel, l'installation sur téléphone, l'e-mail de confirmation, le micro réel. Premier vrai test = étape 3.5 ci-dessus ; envoie-moi les erreurs affichées.

## Limites connues

- Pas de page de profil des autres (on peut les suivre et leur écrire, pas ouvrir leur profil).
- Aucun algorithme : le fil montre les publications publiques, les plus récentes d'abord (c'est le rôle de Fluxus ensuite). Pas d'âge ni de filtre d'âge pour l'instant.
- Fluxus : message « pas connecté » tant qu'une fonction serveur n'existe pas (`FLUXUS_URL` dans `config.js`).
- Fichiers limités à 50 Mo (plan gratuit Supabase). Appels : non branchés.
- Le bucket `media` est public : toute personne ayant l'adresse d'un fichier peut le voir.
- Les icônes d'installation sont celles de l'ancienne version (identité chrome), à remplacer.
