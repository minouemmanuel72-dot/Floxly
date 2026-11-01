-- =====================================================================
-- FLOXLY – AJOUT D'ASSEMBLAGE (à exécuter APRÈS 01_floxly_backend.sql)
-- Additif et rejouable. Ne modifie ni ne supprime rien.
-- =====================================================================

-- Vérifier qu'un identifiant est libre AVANT de créer le compte
-- (sans cela, le serveur ajouterait des chiffres à l'identifiant sans prévenir).
create or replace function public.handle_available(p_handle text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce(p_handle ~ '^[a-z0-9._]{3,24}$', false)
     and not exists (select 1 from profiles where lower(handle) = lower(p_handle)) $$;

revoke execute on function public.handle_available(text) from public;
grant execute on function public.handle_available(text) to anon, authenticated;

-- Lecture des publications : l'auteur voit toujours les siennes directement.
-- (Sans cela, « insérer puis relire dans la même requête » est refusé, car la fonction
--  can_see_post ne voit pas la ligne en cours d'insertion.)
drop policy if exists po_sel on public.posts;
create policy po_sel on public.posts for select to authenticated
  using (author_id = auth.uid() or can_see_post(id));
