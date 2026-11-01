-- =====================================================================
-- FLOXLY – BACKEND SUPABASE (migration additive et rejouable)
-- À exécuter dans Supabase > SQL Editor, d'abord sur une COPIE / branche.
-- Ne supprime aucune table ni aucune donnée. Les nouvelles colonnes sont ajoutées
-- avec « add column if not exists », les nouvelles tables avec « if not exists ».
-- Aucun quota ni seuil n'est défini ici : ils restent à fixer par le propriétaire.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 0. PRÉ-VÉRIFICATION : colonnes attendues dans les tables déjà existantes
-- ---------------------------------------------------------------------
do $$
declare t text; c text; miss text := '';
begin
  for t, c in
    select * from (values
      ('profiles','id'),('profiles','handle'),('profiles','display_name'),('profiles','bio'),('profiles','avatar_url'),
      ('posts','id'),('posts','author_id'),('posts','kind'),('posts','body'),('posts','image_url'),('posts','created_at'),
      ('follows','follower_id'),('follows','followee_id'),
      ('likes','user_id'),('likes','post_id')
    ) v(t,c)
  loop
    if to_regclass('public.'||t) is not null
       and not exists (select 1 from information_schema.columns where table_schema='public' and table_name=t and column_name=c) then
      miss := miss || t || '.' || c || ' ';
    end if;
  end loop;
  if miss <> '' then
    raise exception 'Colonnes attendues absentes : %. Envoie le résultat de \d profiles / posts / follows / likes pour adapter le script.', miss;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. TABLES DE BASE (créées seulement si elles n'existent pas)
-- ---------------------------------------------------------------------
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  handle text, display_name text, bio text, avatar_url text,
  created_at timestamptz not null default now());
create table if not exists public.posts (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'Publication', body text, image_url text,
  created_at timestamptz not null default now());
create table if not exists public.follows (
  follower_id uuid not null references public.profiles(id) on delete cascade,
  followee_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (follower_id, followee_id));
create table if not exists public.likes (
  user_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id));

-- ---------------------------------------------------------------------
-- 2. COLONNES AJOUTÉES AUX TABLES EXISTANTES
-- ---------------------------------------------------------------------
alter table public.profiles
  add column if not exists status text not null default '',
  add column if not exists settings jsonb not null default '{}'::jsonb,
  add column if not exists goal integer,
  add column if not exists followers_count integer not null default 0,
  add column if not exists following_count integer not null default 0,
  add column if not exists is_verified boolean not null default false,
  add column if not exists updated_at timestamptz not null default now();

alter table public.posts
  add column if not exists title text not null default '',
  add column if not exists media jsonb not null default '[]'::jsonb,
  add column if not exists tags text[] not null default '{}',
  add column if not exists visibility text not null default 'Public',
  add column if not exists community_id uuid,
  add column if not exists like_count integer not null default 0,
  add column if not exists comment_count integer not null default 0,
  add column if not exists repost_count integer not null default 0,
  add column if not exists save_count integer not null default 0;

-- Identifiant unique (insensible à la casse) : échoue s'il existe déjà des doublons à corriger.
create unique index if not exists profiles_handle_lower_idx on public.profiles (lower(handle));
do $$ begin
  alter table public.profiles add constraint profiles_handle_fmt check (handle ~ '^[a-z0-9._]{3,24}$') not valid;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.posts add constraint posts_visibility_check check (visibility in ('Public','Abonnés','Privé')) not valid;
exception when duplicate_object then null; end $$;
do $$ begin
  alter table public.posts add constraint posts_author_profile_fkey foreign key (author_id) references public.profiles(id) on delete cascade not valid;
exception when duplicate_object then null; end $$;

-- Types de publication : Publication, Story, Texte (existants) + Projet, Short.
do $$
declare r record; ut text;
begin
  select udt_name into ut from information_schema.columns where table_schema='public' and table_name='posts' and column_name='kind';
  if ut in ('text','varchar','bpchar') then
    for r in select conname from pg_constraint
             where conrelid='public.posts'::regclass and contype='c' and pg_get_constraintdef(oid) ilike '%kind%' loop
      execute format('alter table public.posts drop constraint %I', r.conname);
    end loop;
    alter table public.posts add constraint posts_kind_check check (kind in ('Publication','Story','Texte','Projet','Short')) not valid;
  else
    execute format('alter type public.%I add value if not exists %L', ut, 'Projet');
    execute format('alter type public.%I add value if not exists %L', ut, 'Short');
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 3. NOUVELLES TABLES
-- ---------------------------------------------------------------------
create table if not exists public.communities (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 40),
  description text not null default '' check (char_length(description) <= 120),
  visual smallint not null default 0 check (visual between 0 and 2),
  is_private boolean not null default false,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  rules text not null default '' check (char_length(rules) <= 140),
  members_count integer not null default 0,
  created_at timestamptz not null default now());
create table if not exists public.community_members (
  community_id uuid not null references public.communities(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role text not null default 'membre' check (role in ('admin','moderateur','membre')),
  status text not null default 'actif' check (status in ('actif','en_attente')),
  joined_at timestamptz not null default now(),
  primary key (community_id, user_id));
create table if not exists public.community_reports (
  id uuid primary key default gen_random_uuid(),
  community_id uuid not null references public.communities(id) on delete cascade,
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_user uuid references public.profiles(id) on delete set null,
  post_id uuid references public.posts(id) on delete set null,
  reason text not null default '',
  status text not null default 'ouvert' check (status in ('ouvert','traite','ignore')),
  created_at timestamptz not null default now());
do $$ begin
  alter table public.posts add constraint posts_community_fkey foreign key (community_id) references public.communities(id) on delete set null not valid;
exception when duplicate_object then null; end $$;

create table if not exists public.stories (
  id uuid primary key default gen_random_uuid(),
  author_id uuid not null references public.profiles(id) on delete cascade,
  text text not null default '', media jsonb not null default '[]'::jsonb,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours'));
create table if not exists public.comments (
  id uuid primary key default gen_random_uuid(),
  post_id uuid not null references public.posts(id) on delete cascade,
  author_id uuid not null references public.profiles(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 500),
  created_at timestamptz not null default now());
create table if not exists public.saves (
  user_id uuid not null references public.profiles(id) on delete cascade,
  post_id uuid not null references public.posts(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, post_id));
-- Smart Repost : le repost reste lié à la publication d'origine, annulable sans la supprimer.
create table if not exists public.reposts (
  repost_id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  original_post_id uuid not null references public.posts(id) on delete cascade,
  status text not null default 'actif' check (status in ('actif','annulé')),
  created_at timestamptz not null default now(),
  unique (user_id, original_post_id));

create table if not exists public.conversations (
  id uuid primary key default gen_random_uuid(),
  is_group boolean not null default false,
  is_self boolean not null default false,
  title text, created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now());
create unique index if not exists conversations_self_idx on public.conversations (created_by) where is_self;
create table if not exists public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  last_read_at timestamptz,
  primary key (conversation_id, user_id));
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'text' check (kind in ('text','voice','sticker')),
  body text not null default '', media_url text, duration_s integer,
  reply_to uuid references public.messages(id) on delete set null,
  edited_at timestamptz, deleted_at timestamptz,
  created_at timestamptz not null default now());
create table if not exists public.message_reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null,
  primary key (message_id, user_id));

create table if not exists public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  type text not null default 'activity' check (type in ('mention','activity','system')),
  actor_id uuid references public.profiles(id) on delete set null,
  text text not null, ref jsonb not null default '{}'::jsonb,
  read boolean not null default false,
  created_at timestamptz not null default now());
create table if not exists public.stat_events (
  id bigint generated always as identity primary key,
  owner_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null check (kind in ('l+','l-','c','f+','f-')),
  post_id uuid, actor_id uuid,
  created_at timestamptz not null default now());
create table if not exists public.sched_posts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  payload jsonb not null, publish_at timestamptz not null,
  status text not null default 'en_attente' check (status in ('en_attente','publie','annule')),
  created_at timestamptz not null default now());
create table if not exists public.drafts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  payload jsonb not null, created_at timestamptz not null default now());
create table if not exists public.sticker_packs (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check (char_length(name) between 1 and 24),
  created_at timestamptz not null default now());
create table if not exists public.stickers (
  id uuid primary key default gen_random_uuid(),
  pack_id uuid not null references public.sticker_packs(id) on delete cascade,
  url text not null, created_at timestamptz not null default now());
create table if not exists public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid not null references public.profiles(id) on delete cascade,
  target_type text not null, target_id text not null, reason text not null default '',
  status text not null default 'ouvert', created_at timestamptz not null default now());
-- Journal d'audit (écrit par le serveur uniquement) et suivi d'usage de Fluxus.
create table if not exists public.audit_log (
  id bigint generated always as identity primary key,
  actor uuid, action text not null, meta jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now());
create table if not exists public.fluxus_usage (
  user_id uuid not null references public.profiles(id) on delete cascade,
  day date not null default current_date, count integer not null default 0,
  primary key (user_id, day));

create index if not exists posts_author_created_idx on public.posts (author_id, created_at desc);
create index if not exists posts_created_idx on public.posts (created_at desc);
create index if not exists posts_community_idx on public.posts (community_id, created_at desc);
create index if not exists comments_post_idx on public.comments (post_id, created_at);
create index if not exists messages_conv_idx on public.messages (conversation_id, created_at);
create index if not exists notifs_user_idx on public.notifications (user_id, created_at desc);
create index if not exists stat_events_idx on public.stat_events (owner_id, kind, created_at);
create index if not exists stories_author_idx on public.stories (author_id, created_at desc);
create index if not exists sched_due_idx on public.sched_posts (status, publish_at);

-- ---------------------------------------------------------------------
-- 4. FONCTIONS D'AIDE (utilisées par la sécurité)
-- ---------------------------------------------------------------------
create or replace function public.is_conv_member(p_conv uuid) returns boolean
language sql stable security definer set search_path=public as $$
  select exists (select 1 from conversation_members where conversation_id=p_conv and user_id=auth.uid()) $$;
create or replace function public.is_community_member(p_comm uuid) returns boolean
language sql stable security definer set search_path=public as $$
  select exists (select 1 from community_members where community_id=p_comm and user_id=auth.uid() and status='actif') $$;
create or replace function public.is_community_admin(p_comm uuid) returns boolean
language sql stable security definer set search_path=public as $$
  select exists (select 1 from community_members where community_id=p_comm and user_id=auth.uid() and status='actif' and role in ('admin','moderateur')) $$;
create or replace function public.can_see_community(p_comm uuid) returns boolean
language sql stable security definer set search_path=public as $$
  select exists (select 1 from communities c where c.id=p_comm and (not c.is_private or public.is_community_member(c.id))) $$;
create or replace function public.can_see_post(p_post uuid) returns boolean
language sql stable security definer set search_path=public as $$
  select exists (
    select 1 from posts p where p.id=p_post and (
      p.author_id=auth.uid()
      or (p.visibility='Public' and (p.community_id is null or public.can_see_community(p.community_id)))
      or (p.visibility='Abonnés' and exists (select 1 from follows f where f.follower_id=auth.uid() and f.followee_id=p.author_id))
    )) $$;

-- ---------------------------------------------------------------------
-- 5. TRIGGERS : compteurs, événements de statistiques, notifications
-- (les compteurs ne sont JAMAIS modifiables par le client)
-- ---------------------------------------------------------------------
create or replace function public._who(p_uid uuid) returns text language sql stable security definer set search_path=public as $$
  select coalesce(display_name, handle, 'Quelqu''un') from profiles where id=p_uid $$;

create or replace function public.trg_likes() returns trigger language plpgsql security definer set search_path=public as $$
declare a uuid; pid uuid;
begin
  pid := coalesce(new.post_id, old.post_id);
  select author_id into a from posts where id=pid;
  if a is null then return coalesce(new, old); end if;
  if tg_op='INSERT' then
    update posts set like_count=like_count+1 where id=pid;
    insert into stat_events(owner_id,kind,post_id,actor_id) values (a,'l+',pid,new.user_id);
    if a<>new.user_id then
      insert into notifications(user_id,type,actor_id,text,ref) values (a,'activity',new.user_id,_who(new.user_id)||' a aimé ta publication',jsonb_build_object('post',pid));
    end if;
    return new;
  else
    update posts set like_count=greatest(0,like_count-1) where id=pid;
    insert into stat_events(owner_id,kind,post_id,actor_id) values (a,'l-',pid,old.user_id);
    return old;
  end if;
end $$;
drop trigger if exists likes_aiud on public.likes;
create trigger likes_aiud after insert or delete on public.likes for each row execute function public.trg_likes();

create or replace function public.trg_comments() returns trigger language plpgsql security definer set search_path=public as $$
declare a uuid; pid uuid;
begin
  pid := coalesce(new.post_id, old.post_id);
  if tg_op='INSERT' then
    update posts set comment_count=comment_count+1 where id=pid returning author_id into a;
    if a is not null then
      insert into stat_events(owner_id,kind,post_id,actor_id) values (a,'c',pid,new.author_id);
      if a<>new.author_id then
        insert into notifications(user_id,type,actor_id,text,ref) values (a,'activity',new.author_id,_who(new.author_id)||' a commenté ta publication',jsonb_build_object('post',pid));
      end if;
    end if;
    return new;
  else
    update posts set comment_count=greatest(0,comment_count-1) where id=pid;
    return old;
  end if;
end $$;
drop trigger if exists comments_aid on public.comments;
create trigger comments_aid after insert or delete on public.comments for each row execute function public.trg_comments();

create or replace function public.trg_saves() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then update posts set save_count=save_count+1 where id=new.post_id; return new;
  else update posts set save_count=greatest(0,save_count-1) where id=old.post_id; return old; end if;
end $$;
drop trigger if exists saves_aid on public.saves;
create trigger saves_aid after insert or delete on public.saves for each row execute function public.trg_saves();

create or replace function public.trg_reposts() returns trigger language plpgsql security definer set search_path=public as $$
declare pid uuid;
begin
  pid := coalesce(new.original_post_id, old.original_post_id);
  update posts set repost_count=(select count(*) from reposts where original_post_id=pid and status='actif') where id=pid;
  return coalesce(new, old);
end $$;
drop trigger if exists reposts_aiud on public.reposts;
create trigger reposts_aiud after insert or update or delete on public.reposts for each row execute function public.trg_reposts();

create or replace function public.trg_follows() returns trigger language plpgsql security definer set search_path=public as $$
begin
  if tg_op='INSERT' then
    update profiles set followers_count=followers_count+1 where id=new.followee_id;
    update profiles set following_count=following_count+1 where id=new.follower_id;
    insert into stat_events(owner_id,kind,actor_id) values (new.followee_id,'f+',new.follower_id);
    insert into notifications(user_id,type,actor_id,text) values (new.followee_id,'activity',new.follower_id,_who(new.follower_id)||' a commencé à te suivre');
    return new;
  else
    update profiles set followers_count=greatest(0,followers_count-1) where id=old.followee_id;
    update profiles set following_count=greatest(0,following_count-1) where id=old.follower_id;
    insert into stat_events(owner_id,kind,actor_id) values (old.followee_id,'f-',old.follower_id);
    return old;
  end if;
end $$;
drop trigger if exists follows_aid on public.follows;
create trigger follows_aid after insert or delete on public.follows for each row execute function public.trg_follows();

create or replace function public.trg_members() returns trigger language plpgsql security definer set search_path=public as $$
declare cid uuid;
begin
  cid := coalesce(new.community_id, old.community_id);
  update communities set members_count=(select count(*) from community_members where community_id=cid and status='actif') where id=cid;
  return coalesce(new, old);
end $$;
drop trigger if exists members_aiud on public.community_members;
create trigger members_aiud after insert or update or delete on public.community_members for each row execute function public.trg_members();

-- Création automatique du profil et de la conversation « Mes notes » à l'inscription.
create or replace function public._ensure_self_conv(p_uid uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare cid uuid;
begin
  select id into cid from conversations where created_by=p_uid and is_self;
  if cid is null then
    insert into conversations(is_self,title,created_by) values (true,'Mes notes',p_uid) returning id into cid;
    insert into conversation_members(conversation_id,user_id) values (cid,p_uid);
  end if;
  return cid;
end $$;
create or replace function public.handle_new_user() returns trigger language plpgsql security definer set search_path=public as $$
declare h text; n text; k int := 0;
begin
  h := lower(regexp_replace(coalesce(new.raw_user_meta_data->>'handle',''),'[^a-z0-9._]','','gi'));
  if char_length(h) < 3 then h := 'user' || substr(replace(new.id::text,'-',''),1,8); end if;
  h := left(h,24); n := left(coalesce(nullif(new.raw_user_meta_data->>'display_name',''), h),40);
  loop
    begin
      insert into profiles(id,handle,display_name) values (new.id, h, n);
      exit;
    exception when unique_violation then
      k := k + 1; h := left(h,20) || substr(replace(gen_random_uuid()::text,'-',''),1,4);
      if k > 5 then raise; end if;
    end;
  end loop;
  perform _ensure_self_conv(new.id);
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- 6. FONCTIONS APPELÉES PAR L'APPLICATION (RPC)
-- ---------------------------------------------------------------------
create or replace function public.ensure_self_conversation() returns uuid language sql security definer set search_path=public as $$
  select public._ensure_self_conv(auth.uid()) $$;

create or replace function public.start_conversation(p_other uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare cid uuid; me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if p_other = me then return _ensure_self_conv(me); end if;
  if not exists (select 1 from profiles where id=p_other) then raise exception 'Profil introuvable'; end if;
  select c.id into cid from conversations c
   where not c.is_group and not c.is_self
     and exists (select 1 from conversation_members m where m.conversation_id=c.id and m.user_id=me)
     and exists (select 1 from conversation_members m where m.conversation_id=c.id and m.user_id=p_other) limit 1;
  if cid is null then
    insert into conversations(created_by) values (me) returning id into cid;
    insert into conversation_members(conversation_id,user_id) values (cid,me),(cid,p_other);
  end if;
  return cid;
end $$;

create or replace function public.my_conversations() returns jsonb language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(x order by (x->'last'->>'at')::bigint desc nulls last), '[]'::jsonb) from (
    select jsonb_strip_nulls(jsonb_build_object(
      'id', c.id,
      'title', case when c.is_self then 'Mes notes' when c.is_group then coalesce(c.title,'Groupe')
                    else coalesce((select p.display_name from conversation_members m2 join profiles p on p.id=m2.user_id
                                    where m2.conversation_id=c.id and m2.user_id<>auth.uid() limit 1),'Conversation') end,
      'self', c.is_self, 'group', c.is_group,
      'unread', (select count(*) from messages m where m.conversation_id=c.id and m.sender_id<>auth.uid() and m.deleted_at is null and m.created_at > coalesce(cm.last_read_at,'epoch')),
      'last', (select jsonb_build_object('id',m.id,'at',(extract(epoch from m.created_at)*1000)::bigint,'t',m.body,
                       'v',case when m.kind='voice' then m.duration_s end,'st',case when m.kind='sticker' then m.media_url end)
               from messages m where m.conversation_id=c.id and m.deleted_at is null order by m.created_at desc limit 1)
    )) as x
    from conversation_members cm join conversations c on c.id=cm.conversation_id
    where cm.user_id=auth.uid()
  ) q $$;

create or replace function public.edit_message(p_id uuid, p_text text) returns void language plpgsql security definer set search_path=public as $$
begin
  if coalesce(trim(p_text),'')='' then raise exception 'Message vide'; end if;
  update messages set body=p_text, edited_at=now()
   where id=p_id and sender_id=auth.uid() and kind='text' and deleted_at is null;
  if not found then raise exception 'Modification impossible'; end if;
end $$;
create or replace function public.delete_message(p_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  update messages set deleted_at=now(), body='', media_url=null where id=p_id and sender_id=auth.uid() and deleted_at is null;
  if not found then raise exception 'Suppression impossible'; end if;
  delete from message_reactions where message_id=p_id;
end $$;
create or replace function public.react_message(p_id uuid, p_emoji text) returns void language plpgsql security definer set search_path=public as $$
declare cur text;
begin
  if not exists (select 1 from messages m where m.id=p_id and m.deleted_at is null and is_conv_member(m.conversation_id)) then
    raise exception 'Message introuvable';
  end if;
  select emoji into cur from message_reactions where message_id=p_id and user_id=auth.uid();
  if cur = p_emoji then delete from message_reactions where message_id=p_id and user_id=auth.uid();
  else insert into message_reactions(message_id,user_id,emoji) values (p_id,auth.uid(),p_emoji)
       on conflict (message_id,user_id) do update set emoji=excluded.emoji; end if;
end $$;
create or replace function public.mark_read(p_conv uuid) returns void language sql security definer set search_path=public as $$
  update conversation_members set last_read_at=now() where conversation_id=p_conv and user_id=auth.uid() $$;

create or replace function public.toggle_repost(p_post uuid) returns boolean language plpgsql security definer set search_path=public as $$
declare cur text; me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if not can_see_post(p_post) then raise exception 'Publication introuvable'; end if;
  select status into cur from reposts where user_id=me and original_post_id=p_post;
  if cur = 'actif' then update reposts set status='annulé' where user_id=me and original_post_id=p_post; return false;
  else insert into reposts(user_id,original_post_id,status) values (me,p_post,'actif')
       on conflict (user_id,original_post_id) do update set status='actif'; return true; end if;
end $$;

create or replace function public.create_community(p_name text, p_desc text, p_visual int, p_private boolean) returns jsonb
language plpgsql security definer set search_path=public as $$
declare cid uuid; me uuid := auth.uid();
begin
  if me is null then raise exception 'Non authentifié'; end if;
  if coalesce(trim(p_name),'')='' then raise exception 'Nom requis'; end if;
  insert into communities(name,description,visual,is_private,owner_id) values (left(trim(p_name),40), left(coalesce(p_desc,''),120), coalesce(p_visual,0), coalesce(p_private,false), me) returning id into cid;
  insert into community_members(community_id,user_id,role,status) values (cid,me,'admin','actif');
  return jsonb_build_object('id',cid);
end $$;
create or replace function public.join_community(p_id uuid) returns text language plpgsql security definer set search_path=public as $$
declare priv boolean; st text;
begin
  select is_private into priv from communities where id=p_id;
  if priv is null then raise exception 'Communauté introuvable'; end if;
  st := case when priv then 'en_attente' else 'actif' end;
  insert into community_members(community_id,user_id,role,status) values (p_id,auth.uid(),'membre',st) on conflict do nothing;
  return st;
end $$;
create or replace function public.community_admin(p_id uuid) returns jsonb language plpgsql stable security definer set search_path=public as $$
begin
  if not is_community_admin(p_id) then raise exception 'Réservé aux administrateurs'; end if;
  return jsonb_build_object(
    'members',(select coalesce(jsonb_agg(jsonb_build_object('id',m.user_id,'name',p.display_name,'role',case when m.status='en_attente' then 'en_attente' else m.role end) order by m.joined_at),'[]'::jsonb)
               from community_members m join profiles p on p.id=m.user_id where m.community_id=p_id and m.user_id<>auth.uid()),
    'reports',(select coalesce(jsonb_agg(jsonb_build_object('id',r.id,'who',coalesce(pt.display_name,'Contenu signalé'),'why',r.reason) order by r.created_at),'[]'::jsonb)
               from community_reports r left join profiles pt on pt.id=r.target_user where r.community_id=p_id and r.status='ouvert'));
end $$;
create or replace function public.set_member_role(p_comm uuid, p_user uuid, p_role text) returns void language plpgsql security definer set search_path=public as $$
begin
  if not exists (select 1 from community_members where community_id=p_comm and user_id=auth.uid() and status='actif' and role='admin') then
    raise exception 'Réservé aux administrateurs'; end if;
  if p_role='refuser' then delete from community_members where community_id=p_comm and user_id=p_user;
  elsif p_role in ('admin','moderateur','membre') then update community_members set role=p_role, status='actif' where community_id=p_comm and user_id=p_user;
  else raise exception 'Rôle invalide'; end if;
end $$;
create or replace function public.report_in_community(p_comm uuid, p_post uuid, p_user uuid, p_reason text) returns void language plpgsql security definer set search_path=public as $$
begin
  if not is_community_member(p_comm) then raise exception 'Réservé aux membres'; end if;
  insert into community_reports(community_id,reporter_id,target_user,post_id,reason) values (p_comm,auth.uid(),p_user,p_post,left(coalesce(p_reason,''),300));
end $$;
create or replace function public.resolve_report(p_id uuid, p_action text) returns void language plpgsql security definer set search_path=public as $$
declare cid uuid; pid uuid;
begin
  select community_id, post_id into cid, pid from community_reports where id=p_id;
  if cid is null or not is_community_admin(cid) then raise exception 'Réservé aux administrateurs'; end if;
  if p_action='retirer' and pid is not null then delete from posts where id=pid and community_id=cid; end if;
  update community_reports set status=case when p_action='retirer' then 'traite' else 'ignore' end where id=p_id;
  insert into audit_log(actor,action,meta) values (auth.uid(),'community_report_'||p_action,jsonb_build_object('report',p_id,'community',cid));
end $$;

-- Publications programmées : publie ce qui est dû (pour l'utilisateur, ou pour tous via une tâche planifiée).
create or replace function public._publish_sched(p_user uuid) returns integer language plpgsql security definer set search_path=public as $$
declare r record; k text; n int := 0; pl jsonb;
begin
  for r in select * from sched_posts where status='en_attente' and publish_at<=now() and (p_user is null or user_id=p_user) order by publish_at for update skip locked loop
    pl := r.payload; k := coalesce(pl->>'kind','Post');
    if k='Story' then
      insert into stories(author_id,text,media) values (r.user_id, coalesce(pl->>'text',''), coalesce(pl->'media','[]'::jsonb));
    else
      insert into posts(author_id,kind,title,body,media,tags,visibility,community_id,image_url)
      values (r.user_id, case k when 'Post' then 'Publication' else k end, coalesce(pl->>'title',''), coalesce(pl->>'text',''), coalesce(pl->'media','[]'::jsonb),
              coalesce((select array_agg(t) from jsonb_array_elements_text(coalesce(pl->'tags','[]'::jsonb)) t), '{}'),
              coalesce(nullif(pl->>'vis',''),'Public'), nullif(pl->>'community','')::uuid,
              (select m->>'url' from jsonb_array_elements(coalesce(pl->'media','[]'::jsonb)) m where m->>'type'='image' limit 1));
    end if;
    update sched_posts set status='publie' where id=r.id; n := n + 1;
  end loop;
  return n;
end $$;
create or replace function public.flush_my_scheduled() returns integer language sql security definer set search_path=public as $$
  select public._publish_sched(auth.uid()) $$;
create or replace function public.publish_due_posts() returns integer language sql security definer set search_path=public as $$
  select public._publish_sched(null) $$;

create or replace function public.stat_series(p_uid uuid, p_kind text, p_t0 timestamptz, p_w double precision, p_n int) returns jsonb
language sql stable security definer set search_path=public as $$
  select coalesce(jsonb_agg(coalesce(s.c,0) order by g.i), '[]'::jsonb)
  from generate_series(0,p_n-1) as g(i)
  left join (select least(p_n-1, floor(extract(epoch from (created_at-p_t0))/p_w))::int as i, count(*) c
             from stat_events where owner_id=p_uid and kind=p_kind and created_at>=p_t0 group by 1) s on s.i=g.i $$;
create or replace function public.get_stats(p_days int) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare uid uuid := auth.uid(); n int; t0 timestamptz; w double precision;
begin
  if uid is null then raise exception 'Non authentifié'; end if;
  if p_days not in (7,30,90) then raise exception 'Période invalide'; end if;
  n := case p_days when 7 then 7 when 30 then 10 else 12 end;
  t0 := now() - make_interval(days => p_days); w := p_days * 86400.0 / n;
  return jsonb_build_object(
    'posts',(select count(*) from posts where author_id=uid and created_at>=t0),
    'likesIn',(select count(*) from stat_events where owner_id=uid and kind='l+' and created_at>=t0),
    'likesOut',(select count(*) from stat_events where owner_id=uid and kind='l-' and created_at>=t0),
    'comments',(select count(*) from stat_events where owner_id=uid and kind='c' and created_at>=t0),
    'folIn',(select count(*) from stat_events where owner_id=uid and kind='f+' and created_at>=t0),
    'folOut',(select count(*) from stat_events where owner_id=uid and kind='f-' and created_at>=t0),
    'followers',(select followers_count from profiles where id=uid),
    'goal',(select goal from profiles where id=uid),
    'series',jsonb_build_object(
      'likes',stat_series(uid,'l+',t0,w,n), 'comments',stat_series(uid,'c',t0,w,n),
      'posts',(select coalesce(jsonb_agg(coalesce(s.c,0) order by g.i),'[]'::jsonb) from generate_series(0,n-1) g(i)
               left join (select least(n-1, floor(extract(epoch from (created_at-t0))/w))::int i, count(*) c from posts where author_id=uid and created_at>=t0 group by 1) s on s.i=g.i)),
    'perPost',(select coalesce(jsonb_agg(jsonb_build_object('id',q.id,'title',coalesce(nullif(q.title,''),nullif(left(q.body,40),''),q.kind),
                 'likes',q.like_count,'comments',q.comment_count,'saves',q.save_count,'reposts',q.repost_count) order by q.created_at desc),'[]'::jsonb)
               from (select * from posts where author_id=uid order by created_at desc limit 5) q),
    'unavailable',jsonb_build_array('Vues','Audience (âge, pays)','Sources de croissance','Rétention des Shorts','Meilleur moment pour publier'));
end $$;

create or replace function public.trending_tags() returns jsonb language sql stable security invoker set search_path=public as $$
  select coalesce(jsonb_agg(t order by c desc), '[]'::jsonb) from (
    select t, count(*) c from posts, unnest(tags) t where created_at > now() - interval '7 days' group by t order by c desc limit 8) q $$;
create or replace function public.suggest_profiles() returns jsonb language sql stable security invoker set search_path=public as $$
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',display_name,'handle',handle,'bio',bio,'avatar',avatar_url)), '[]'::jsonb) from (
    select * from profiles p where p.id<>auth.uid() and not exists (select 1 from follows f where f.follower_id=auth.uid() and f.followee_id=p.id)
    order by followers_count desc, created_at desc limit 10) q $$;
create or replace function public.search_all(p_q text) returns jsonb language plpgsql stable security invoker set search_path=public as $$
declare q text := '%' || replace(replace(replace(trim(coalesce(p_q,'')),'\','\\'),'%','\%'),'_','\_') || '%';
begin
  if trim(coalesce(p_q,''))='' then return jsonb_build_object('profiles','[]'::jsonb,'post_ids','[]'::jsonb,'communities','[]'::jsonb); end if;
  return jsonb_build_object(
    'profiles',(select coalesce(jsonb_agg(jsonb_build_object('id',id,'name',display_name,'handle',handle,'bio',bio,'avatar',avatar_url)),'[]'::jsonb)
                from (select * from profiles where handle ilike q or display_name ilike q order by followers_count desc limit 20) a),
    'post_ids',(select coalesce(jsonb_agg(id),'[]'::jsonb) from (select id from posts where body ilike q or title ilike q or exists (select 1 from unnest(tags) t where t ilike q) order by created_at desc limit 20) b),
    'communities',(select coalesce(jsonb_agg(id),'[]'::jsonb) from (select id from communities where name ilike q limit 20) c));
end $$;

-- ---------------------------------------------------------------------
-- 7. SÉCURITÉ : RLS + privilèges
-- ---------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.posts enable row level security;
alter table public.follows enable row level security;
alter table public.likes enable row level security;
alter table public.communities enable row level security;
alter table public.community_members enable row level security;
alter table public.community_reports enable row level security;
alter table public.stories enable row level security;
alter table public.comments enable row level security;
alter table public.saves enable row level security;
alter table public.reposts enable row level security;
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.message_reactions enable row level security;
alter table public.notifications enable row level security;
alter table public.stat_events enable row level security;
alter table public.sched_posts enable row level security;
alter table public.drafts enable row level security;
alter table public.sticker_packs enable row level security;
alter table public.stickers enable row level security;
alter table public.reports enable row level security;
alter table public.audit_log enable row level security;
alter table public.fluxus_usage enable row level security;

-- Pas d'accès anonyme : l'application exige une connexion.
revoke all on all tables in schema public from anon;
-- Tables sans aucun accès direct client (serveur / fonctions uniquement) :
revoke all on public.stat_events, public.audit_log, public.fluxus_usage, public.community_reports from authenticated;
-- Colonnes protégées : le client ne peut écrire que les colonnes de contenu.
revoke insert, update on public.profiles from authenticated;
grant insert (id, handle, display_name) on public.profiles to authenticated;
grant update (display_name, handle, bio, avatar_url, status, settings, goal) on public.profiles to authenticated;
revoke insert, update on public.posts from authenticated;
grant insert (author_id, kind, title, body, image_url, media, tags, visibility, community_id) on public.posts to authenticated;
grant update (title, body, image_url, media, tags, visibility) on public.posts to authenticated;
revoke insert, update, delete on public.messages from authenticated;
grant insert (conversation_id, sender_id, kind, body, media_url, duration_s, reply_to) on public.messages to authenticated;
revoke insert, update, delete on public.notifications from authenticated;
grant update (read) on public.notifications to authenticated;
revoke insert, update, delete on public.conversations, public.conversation_members, public.message_reactions, public.communities, public.community_members, public.reposts from authenticated;
grant update (description, rules) on public.communities to authenticated;

-- profiles
drop policy if exists p_sel on public.profiles; create policy p_sel on public.profiles for select to authenticated using (true);
drop policy if exists p_ins on public.profiles; create policy p_ins on public.profiles for insert to authenticated with check (id = auth.uid());
drop policy if exists p_upd on public.profiles; create policy p_upd on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());
-- follows / likes
drop policy if exists f_sel on public.follows; create policy f_sel on public.follows for select to authenticated using (true);
drop policy if exists f_ins on public.follows; create policy f_ins on public.follows for insert to authenticated with check (follower_id = auth.uid() and follower_id <> followee_id);
drop policy if exists f_del on public.follows; create policy f_del on public.follows for delete to authenticated using (follower_id = auth.uid());
drop policy if exists l_sel on public.likes; create policy l_sel on public.likes for select to authenticated using (user_id = auth.uid() or can_see_post(post_id));
drop policy if exists l_ins on public.likes; create policy l_ins on public.likes for insert to authenticated with check (user_id = auth.uid() and can_see_post(post_id));
drop policy if exists l_del on public.likes; create policy l_del on public.likes for delete to authenticated using (user_id = auth.uid());
-- posts
drop policy if exists po_sel on public.posts; create policy po_sel on public.posts for select to authenticated using (can_see_post(id));
drop policy if exists po_ins on public.posts; create policy po_ins on public.posts for insert to authenticated with check (author_id = auth.uid() and (community_id is null or is_community_member(community_id)));
drop policy if exists po_upd on public.posts; create policy po_upd on public.posts for update to authenticated using (author_id = auth.uid()) with check (author_id = auth.uid());
drop policy if exists po_del on public.posts; create policy po_del on public.posts for delete to authenticated using (author_id = auth.uid());
-- comments / saves / reposts
drop policy if exists c_sel on public.comments; create policy c_sel on public.comments for select to authenticated using (can_see_post(post_id));
drop policy if exists c_ins on public.comments; create policy c_ins on public.comments for insert to authenticated with check (author_id = auth.uid() and can_see_post(post_id));
drop policy if exists c_del on public.comments; create policy c_del on public.comments for delete to authenticated using (author_id = auth.uid() or exists (select 1 from posts p where p.id=post_id and p.author_id=auth.uid()));
drop policy if exists s_all on public.saves; create policy s_all on public.saves for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid() and can_see_post(post_id));
drop policy if exists r_sel on public.reposts; create policy r_sel on public.reposts for select to authenticated using (user_id = auth.uid());
-- stories : les siennes + celles des comptes suivis, pendant 24 h
drop policy if exists st_sel on public.stories; create policy st_sel on public.stories for select to authenticated using (author_id = auth.uid() or (expires_at > now() and exists (select 1 from follows f where f.follower_id=auth.uid() and f.followee_id=author_id)));
drop policy if exists st_ins on public.stories; create policy st_ins on public.stories for insert to authenticated with check (author_id = auth.uid());
drop policy if exists st_del on public.stories; create policy st_del on public.stories for delete to authenticated using (author_id = auth.uid());
-- messagerie
drop policy if exists cv_sel on public.conversations; create policy cv_sel on public.conversations for select to authenticated using (is_conv_member(id));
drop policy if exists cm_sel on public.conversation_members; create policy cm_sel on public.conversation_members for select to authenticated using (is_conv_member(conversation_id));
drop policy if exists m_sel on public.messages; create policy m_sel on public.messages for select to authenticated using (is_conv_member(conversation_id));
drop policy if exists m_ins on public.messages; create policy m_ins on public.messages for insert to authenticated with check (sender_id = auth.uid() and is_conv_member(conversation_id));
drop policy if exists mr_sel on public.message_reactions; create policy mr_sel on public.message_reactions for select to authenticated using (exists (select 1 from messages m where m.id=message_id and is_conv_member(m.conversation_id)));
-- notifications
drop policy if exists n_sel on public.notifications; create policy n_sel on public.notifications for select to authenticated using (user_id = auth.uid());
drop policy if exists n_upd on public.notifications; create policy n_upd on public.notifications for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
-- communautés
drop policy if exists co_sel on public.communities; create policy co_sel on public.communities for select to authenticated using (not is_private or is_community_member(id) or owner_id = auth.uid());
drop policy if exists co_upd on public.communities; create policy co_upd on public.communities for update to authenticated using (exists (select 1 from community_members m where m.community_id=id and m.user_id=auth.uid() and m.role='admin' and m.status='actif')) with check (true);
drop policy if exists cmm_sel on public.community_members; create policy cmm_sel on public.community_members for select to authenticated using (user_id = auth.uid() or is_community_member(community_id));
-- programmation, brouillons, stickers, signalements
drop policy if exists sp_all on public.sched_posts; create policy sp_all on public.sched_posts for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists dr_all on public.drafts; create policy dr_all on public.drafts for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());
drop policy if exists pk_all on public.sticker_packs; create policy pk_all on public.sticker_packs for all to authenticated using (owner_id = auth.uid()) with check (owner_id = auth.uid());
drop policy if exists sk_all on public.stickers; create policy sk_all on public.stickers for all to authenticated using (exists (select 1 from sticker_packs p where p.id=pack_id and p.owner_id=auth.uid())) with check (exists (select 1 from sticker_packs p where p.id=pack_id and p.owner_id=auth.uid()));
drop policy if exists rp_ins on public.reports; create policy rp_ins on public.reports for insert to authenticated with check (reporter_id = auth.uid());

-- Fonctions réservées au serveur
revoke execute on function public.publish_due_posts() from public, anon, authenticated;
revoke execute on function public._publish_sched(uuid) from public, anon, authenticated;
revoke execute on function public._ensure_self_conv(uuid) from public, anon, authenticated;
revoke execute on function public.handle_new_user() from public, anon, authenticated;
revoke execute on function public.stat_series(uuid,text,timestamptz,double precision,int) from public, anon, authenticated;
-- Fonctions ouvertes aux utilisateurs connectés uniquement
do $$
declare f text;
begin
  foreach f in array array[
    'ensure_self_conversation()','start_conversation(uuid)','my_conversations()','edit_message(uuid,text)','delete_message(uuid)',
    'react_message(uuid,text)','mark_read(uuid)','toggle_repost(uuid)','create_community(text,text,int,boolean)','join_community(uuid)',
    'community_admin(uuid)','set_member_role(uuid,uuid,text)','report_in_community(uuid,uuid,uuid,text)','resolve_report(uuid,text)',
    'flush_my_scheduled()','get_stats(int)','trending_tags()','suggest_profiles()','search_all(text)']
  loop
    execute format('revoke execute on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- 8. STOCKAGE (bucket « media » : publications, stories, vocaux, stickers, avatars)
-- Chemin imposé : <id utilisateur>/<fichier>. Aucune limite de taille n'est fixée ici (quota à définir).
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public) values ('media','media',true) on conflict (id) do nothing;
drop policy if exists media_read on storage.objects;
create policy media_read on storage.objects for select using (bucket_id = 'media');
drop policy if exists media_ins on storage.objects;
create policy media_ins on storage.objects for insert to authenticated with check (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
drop policy if exists media_del on storage.objects;
create policy media_del on storage.objects for delete to authenticated using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------------------------------------------------------------------
-- 9. TEMPS RÉEL (Supabase) et TÂCHE PLANIFIÉE (optionnels)
-- ---------------------------------------------------------------------
do $$ begin
  alter publication supabase_realtime add table public.messages;
  alter publication supabase_realtime add table public.notifications;
exception when others then null; end $$;
-- Publication automatique des programmations (activer l'extension pg_cron dans Supabase puis décommenter) :
-- select cron.schedule('floxly-publish-due', '* * * * *', $$select public.publish_due_posts()$$);
