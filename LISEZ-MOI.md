# Floxly – paquet final (front + Supabase + Fluxus)

## Contenu
- index.html : l'application (c'est CE nom qui doit rester, sinon le site affiche « introuvable »)
- config.js : URL + clé « anon public » de Supabase (à remplir)
- manifest.webmanifest, icons/ : installation sur l'écran d'accueil
- sw.js : hors-ligne + notifications
- vercel.json : réglages Vercel
- supabase/01, 02, 03 : base de données (dans CET ordre)
- supabase/functions/fluxus/index.ts : assistant Fluxus
- supabase/functions/push/index.ts : notifications (facultatif)

## Étapes (depuis un téléphone, sans rien installer)
1. Supabase > SQL Editor : exécuter 01, puis 02, puis 03 (un à la fois, « Run »).
2. Supabase > Project Settings > API : copier « Project URL » et la clé « anon public ».
   JAMAIS la clé service_role.
3. Ouvrir config.js sur GitHub (crayon ✏️), coller url et anonKey entre guillemets, « Commit changes ».
4. GitHub : le dépôt doit contenir à la RACINE index.html, config.js, sw.js, manifest.webmanifest,
   vercel.json, le dossier icons/. Vercel redéploie tout seul.
5. Supabase > Authentication > URL Configuration : mettre l'adresse du site dans « Site URL ».
6. Fluxus : Supabase > Edge Functions > Deploy a new function > Via Editor, nom EXACT « fluxus »,
   coller index.ts, Deploy. Puis Edge Functions > Secrets : ajouter ANTHROPIC_API_KEY (ta clé IA).
   Facultatif : FLUXUS_DAILY_LIMIT (30 par défaut, 0 = illimité), FLUXUS_MODEL.
7. Vercel > Settings > Deployment Protection : mettre « Vercel Authentication » sur Disabled
   pour le domaine de production (sinon les visiteurs voient une page de connexion Vercel).

## Installer sur le téléphone
- iPhone : ouvrir le lien dans SAFARI (pas dans Instagram/WhatsApp), Partager > « Sur l'écran d'accueil ».
- Android : Chrome > menu ⋮ > « Installer l'application ».

## Non testé
Vrai Supabase, temps réel, notifications, Fluxus avec un vrai modèle, iPhone réel.
