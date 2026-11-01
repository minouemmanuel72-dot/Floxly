/* =====================================================================
   FLOXLY – Adaptateur Supabase : remplace l'objet API local du front.
   Même contrat que INTEGRATION.md. Si config.js est vide, ce fichier ne fait
   rien et le front reste en mode local (localStorage).
   ===================================================================== */
(function () {
  const cfg = window.FLOXLY_CONFIG || {};
  if (!cfg.SUPABASE_URL || !cfg.SUPABASE_ANON_KEY || !window.supabase) return;

  const sb = window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY, {
    auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
  });

  /* ---------- erreurs lisibles ---------- */
  function tr(e) {
    const m = String((e && e.message) || e || ''), c = e && e.code;
    if (/Invalid login credentials/i.test(m)) return 'E-mail ou mot de passe incorrect';
    if (/Email not confirmed/i.test(m)) return 'Confirme d’abord ton adresse e-mail (message reçu dans ta boîte)';
    if (/already registered|already been registered/i.test(m)) return 'Un compte existe déjà avec cet e-mail';
    if (/Password should be at least/i.test(m)) return 'Mot de passe trop court';
    if (/rate limit|too many/i.test(m)) return 'Trop de tentatives, réessaie dans un moment';
    if (/Failed to fetch|NetworkError|Load failed/i.test(m)) return 'Connexion impossible. Vérifie ton réseau.';
    if (c === '42501' || /row-level security|permission denied/i.test(m)) return 'Action non autorisée';
    if (c === '23505' || /duplicate key/i.test(m)) return 'Cet élément existe déjà';
    if (/exceeded the maximum allowed size|Payload too large/i.test(m)) return 'Fichier trop lourd';
    return m || 'Une erreur est survenue';
  }
  const ok = ({ data, error }) => { if (error) throw error; return data; };

  /* ---------- session ---------- */
  let USER = null, PROFILE = null;
  sb.auth.onAuthStateChange((_e, s) => { USER = s && s.user ? s.user : null; if (!USER) PROFILE = null; });
  async function uid() {
    if (USER) return USER.id;
    const { data } = await sb.auth.getSession();
    USER = data && data.session ? data.session.user : null;
    if (!USER) throw new Error('Session expirée : reconnecte-toi');
    return USER.id;
  }

  /* ---------- préférences : miroir local + synchro serveur ---------- */
  let SET = {};
  try { SET = JSON.parse(localStorage.getItem('floxly:set') || '{}') || {}; } catch (_) { SET = {}; }
  let setTimer = null;
  function saveSet() {
    try { localStorage.setItem('floxly:set', JSON.stringify(SET)); } catch (_) {}
    clearTimeout(setTimer);
    setTimer = setTimeout(async () => {
      if (!USER) return;
      try { await sb.from('profiles').update({ settings: SET }).eq('id', USER.id); } catch (_) {}
    }, 800);
  }

  /* ---------- conversions ---------- */
  const PROF = 'id,handle,display_name,bio,avatar_url,status,settings,goal,followers_count,following_count,created_at';
  const mapProfile = (p, email) => ({
    id: p.id, name: p.display_name || p.handle, handle: p.handle, email: email || '',
    bio: p.bio || '', status: p.status || '', avatar: p.avatar_url || null, created: Date.parse(p.created_at)
  });
  const KIND_OUT = k => (k === 'Publication' || k === 'Texte') ? 'Post' : k;
  const ts = v => v ? Date.parse(v) : 0;

  async function profilesById(ids) {
    ids = [...new Set(ids.filter(Boolean))];
    if (!ids.length) return {};
    const rows = ok(await sb.from('profiles').select('id,display_name,handle,avatar_url').in('id', ids)) || [];
    const m = {};
    rows.forEach(p => { m[p.id] = { id: p.id, name: p.display_name || p.handle, handle: p.handle, avatar: p.avatar_url || null }; });
    return m;
  }
  const ghost = id => ({ id: id || '?', name: 'Compte supprimé', handle: 'supprime', avatar: null });

  /* Le front lit likes/saves/reposts/comments comme des listes. Pour ne pas charger
     tout le monde, on renvoie des listes de la bonne LONGUEUR (compteurs du serveur),
     où seul « moi » est un vrai identifiant. */
  const fill = (n, me) => {
    const a = Array.from({ length: Math.max(0, n || 0) }, (_, i) => '·' + i);
    if (me) { if (a.length) a[0] = me; else a.push(me); }
    return a;
  };
  async function hydratePosts(rows) {
    if (!rows || !rows.length) return [];
    const me = await uid(), ids = rows.map(r => r.id);
    const [pm, lk, sv, rp] = await Promise.all([
      profilesById(rows.map(r => r.author_id)),
      sb.from('likes').select('post_id').eq('user_id', me).in('post_id', ids),
      sb.from('saves').select('post_id').eq('user_id', me).in('post_id', ids),
      sb.from('reposts').select('original_post_id').eq('user_id', me).eq('status', 'actif').in('original_post_id', ids)
    ]);
    const L = new Set((ok(lk) || []).map(x => x.post_id)), S = new Set((ok(sv) || []).map(x => x.post_id)),
      R = new Set((ok(rp) || []).map(x => x.original_post_id));
    return rows.map(r => ({
      id: r.id, kind: KIND_OUT(r.kind), title: r.title || '', text: r.body || '',
      media: Array.isArray(r.media) && r.media.length ? r.media : (r.image_url ? [{ type: 'image', url: r.image_url }] : []),
      tags: r.tags || [], vis: r.visibility, community: r.community_id || null, at: ts(r.created_at),
      author: pm[r.author_id] || ghost(r.author_id),
      likes: fill(r.like_count, L.has(r.id) && me), saves: fill(r.save_count, S.has(r.id) && me),
      reposts: fill(r.repost_count, R.has(r.id) && me),
      comments: Array.from({ length: r.comment_count || 0 }, () => ({ id: '·', text: '', at: 0, author: { id: '·', name: '?' } }))
    }));
  }
  const POSTC = 'id,author_id,kind,title,body,image_url,media,tags,visibility,community_id,like_count,comment_count,repost_count,save_count,created_at';

  const mapComm = (c, joined, me) => ({
    id: c.id, name: c.name, desc: c.description || '', g: c.visual || 0, priv: !!c.is_private,
    members: c.members_count || 0, joined: !!joined, mine: c.owner_id === me, rules: c.rules || '', at: ts(c.created_at)
  });
  async function myCommIds(me) {
    const rows = ok(await sb.from('community_members').select('community_id').eq('user_id', me).eq('status', 'actif')) || [];
    return rows.map(r => r.community_id);
  }

  const extOf = t => {
    const s = String(t || '').split(';')[0].split('/')[1] || 'bin';
    return ({ mpeg: 'mp3', quicktime: 'mov', 'x-m4a': 'm4a', jpeg: 'jpg', 'svg+xml': 'svg' })[s] || s;
  };
  const MAXB = 50 * 1024 * 1024; // limite du plan gratuit Supabase par fichier

  /* ================= API ================= */
  const A = {
    auth: {
      out: () => false,
      async me() {
        let s;
        try { s = (await sb.auth.getSession()).data.session; } catch (_) { s = null; }
        if (!s) return null;
        USER = s.user;
        let p = ok(await sb.from('profiles').select(PROF).eq('id', USER.id).maybeSingle());
        if (!p) { // compte antérieur au déclencheur : on crée le profil
          const md = USER.user_metadata || {};
          let h = String(md.handle || '').toLowerCase().replace(/[^a-z0-9._]/g, '').slice(0, 24);
          if (h.length < 3) h = 'user' + USER.id.replace(/-/g, '').slice(0, 8);
          ok(await sb.from('profiles').insert({ id: USER.id, handle: h, display_name: md.display_name || h }));
          p = ok(await sb.from('profiles').select(PROF).eq('id', USER.id).maybeSingle());
        }
        PROFILE = p;
        SET = Object.assign({}, SET, p.settings || {});
        try { localStorage.setItem('floxly:set', JSON.stringify(SET)); } catch (_) {}
        sb.rpc('ensure_self_conversation').then(() => {}, () => {});
        return mapProfile(p, USER.email);
      },
      async signUp({ name, handle, email, pw }) {
        handle = String(handle || '').trim().toLowerCase();
        if (!String(name || '').trim()) throw new Error('Nom requis');
        if (!/^[a-z0-9._]{3,24}$/.test(handle)) throw new Error('Identifiant : 3 à 24 caractères (lettres, chiffres, point, tiret bas)');
        const av = await sb.rpc('handle_available', { p_handle: handle });
        if (!av.error && av.data === false) throw new Error('Cet identifiant est déjà pris');
        const { data, error } = await sb.auth.signUp({
          email: String(email || '').trim(), password: pw,
          options: { data: { handle, display_name: String(name).trim() } }
        });
        if (error) throw error;
        if (!data.session) throw new Error('Compte créé. Confirme ton adresse e-mail avec le message reçu, puis connecte-toi.');
        return A.auth.me();
      },
      async signIn({ email, pw }) {
        const { error } = await sb.auth.signInWithPassword({ email: String(email || '').trim(), password: pw });
        if (error) throw error;
        return A.auth.me();
      },
      async signOut() { await sb.auth.signOut(); USER = null; PROFILE = null; }
    },

    profiles: {
      async update(p) {
        const me = await uid(), patch = {};
        if (p.name !== undefined) patch.display_name = p.name;
        if (p.status !== undefined) patch.status = p.status;
        if (p.bio !== undefined) patch.bio = p.bio;
        if (p.avatar !== undefined) patch.avatar_url = p.avatar;
        ok(await sb.from('profiles').update(patch).eq('id', me));
        return A.auth.me();
      },
      async suggest() { return ok(await sb.rpc('suggest_profiles')) || []; },
      async search(q) { const r = ok(await sb.rpc('search_all', { p_q: q })); return (r && r.profiles) || []; },
      async follow(id) {
        const me = await uid();
        const ex = ok(await sb.from('follows').select('followee_id').eq('follower_id', me).eq('followee_id', id).maybeSingle());
        if (ex) ok(await sb.from('follows').delete().eq('follower_id', me).eq('followee_id', id));
        else ok(await sb.from('follows').insert({ follower_id: me, followee_id: id }));
      },
      async counts() {
        const me = await uid();
        const [c, p] = await Promise.all([
          sb.from('posts').select('id', { count: 'exact', head: true }).eq('author_id', me),
          sb.from('profiles').select('followers_count,following_count').eq('id', me).maybeSingle()
        ]);
        if (c.error) throw c.error;
        const pr = ok(p) || {};
        return { posts: c.count || 0, followers: pr.followers_count || 0, following: pr.following_count || 0 };
      }
    },

    posts: {
      async list({ kinds = ['Post', 'Projet'], mine = false, community = null } = {}) {
        const me = await uid();
        const db = kinds.flatMap(k => k === 'Post' ? ['Publication', 'Texte'] : [k]);
        let q = sb.from('posts').select(POSTC).in('kind', db).order('created_at', { ascending: false }).limit(60);
        if (mine) q = q.eq('author_id', me);
        if (community) q = q.eq('community_id', community);
        return hydratePosts(ok(await q));
      },
      async get(id) {
        const r = ok(await sb.from('posts').select(POSTC).eq('id', id).maybeSingle());
        return r ? (await hydratePosts([r]))[0] : undefined;
      },
      async create(x) {
        const me = await uid(), media = x.media || [], img = media.find(m => m.type === 'image');
        // (id généré par le serveur : la colonne id n'est pas ouverte en écriture au client)
        const row = ok(await sb.from('posts').insert({
          author_id: me, kind: (x.kind || 'Post') === 'Post' ? 'Publication' : x.kind, title: x.title || '', body: x.text || '',
          media, tags: x.tags || [], visibility: x.vis || 'Public', community_id: x.community || null,
          image_url: img ? img.url : null
        }).select(POSTC).single());
        return (await hydratePosts([row]))[0];
      },
      async like(id) {
        const me = await uid();
        const ex = ok(await sb.from('likes').select('post_id').eq('user_id', me).eq('post_id', id).maybeSingle());
        if (ex) ok(await sb.from('likes').delete().eq('user_id', me).eq('post_id', id));
        else ok(await sb.from('likes').insert({ user_id: me, post_id: id }));
      },
      async toggle(id, f) {
        if (f === 'reposts') { ok(await sb.rpc('toggle_repost', { p_post: id })); return; }
        const me = await uid();
        const ex = ok(await sb.from('saves').select('post_id').eq('user_id', me).eq('post_id', id).maybeSingle());
        if (ex) ok(await sb.from('saves').delete().eq('user_id', me).eq('post_id', id));
        else ok(await sb.from('saves').insert({ user_id: me, post_id: id }));
      },
      async comments(id) {
        const rows = ok(await sb.from('comments').select('id,body,created_at,author_id').eq('post_id', id).order('created_at', { ascending: true }).limit(200)) || [];
        const pm = await profilesById(rows.map(r => r.author_id));
        return rows.map(r => ({ id: r.id, text: r.body, at: ts(r.created_at), author: pm[r.author_id] || ghost(r.author_id) }));
      },
      async comment(id, text) {
        const me = await uid();
        ok(await sb.from('comments').insert({ post_id: id, author_id: me, body: String(text).slice(0, 500) }));
      },
      async remove(id) { ok(await sb.from('posts').delete().eq('id', id)); },
      link: id => location.href.split('#')[0] + '#post-' + id
    },

    stories: {
      async list() {
        const rows = ok(await sb.from('stories').select('id,author_id,text,media,created_at,expires_at').gt('expires_at', new Date().toISOString()).order('created_at', { ascending: false }).limit(40)) || [];
        const pm = await profilesById(rows.map(r => r.author_id));
        return rows.map(r => ({ id: r.id, text: r.text || '', media: r.media || [], at: ts(r.created_at), author: pm[r.author_id] || ghost(r.author_id) }));
      },
      async get(id) { return (await A.stories.list()).find(s => s.id === id); },
      async create(x) {
        const me = await uid();
        const r = ok(await sb.from('stories').insert({ author_id: me, text: x.text || '', media: x.media || [] }).select('id').single());
        return (await A.stories.list()).find(s => s.id === r.id);
      },
      async remove(id) { ok(await sb.from('stories').delete().eq('id', id)); }
    },

    messages: {
      async conversations() {
        const r = ok(await sb.rpc('my_conversations')) || [];
        return r.map(c => ({ ...c, title: c.title || 'Conversation', unread: c.unread || 0, last: c.last || null }));
      },
      async start(other) { return ok(await sb.rpc('start_conversation', { p_other: other })); },
      async list(c) {
        const me = await uid();
        const rows = ok(await sb.from('messages').select('id,sender_id,kind,body,media_url,duration_s,reply_to,edited_at,deleted_at,created_at').eq('conversation_id', c).order('created_at', { ascending: true }).limit(300)) || [];
        const rx = rows.length ? (ok(await sb.from('message_reactions').select('message_id,emoji').in('message_id', rows.map(r => r.id))) || []) : [];
        const R = {};
        rx.forEach(x => (R[x.message_id] = R[x.message_id] || []).push(x.emoji));
        return rows.map(r => {
          const m = { id: r.id, me: r.sender_id === me, at: ts(r.created_at), rx: R[r.id] || [] };
          if (r.reply_to) m.re = r.reply_to;
          if (r.deleted_at) { m.del = true; m.rx = []; m.t = ''; return m; }
          if (r.edited_at) m.ed = true;
          if (r.kind === 'voice') { m.v = r.duration_s || 1; m.url = r.media_url; }
          else if (r.kind === 'sticker') { m.st = r.media_url; }
          else m.t = r.body;
          return m;
        });
      },
      async send(c, x) {
        const me = await uid(), row = { conversation_id: c, sender_id: me, reply_to: x.re || null };
        if (x.st) Object.assign(row, { kind: 'sticker', body: '', media_url: x.st });
        else if (x.v !== undefined) Object.assign(row, { kind: 'voice', body: '', media_url: x.url, duration_s: x.v });
        else Object.assign(row, { kind: 'text', body: x.t });
        ok(await sb.from('messages').insert(row));
        return { me: true, at: Date.now() };
      },
      async edit(c, id, t) { ok(await sb.rpc('edit_message', { p_id: id, p_text: t })); },
      async remove(c, id) { ok(await sb.rpc('delete_message', { p_id: id })); },
      async react(c, id, e) { ok(await sb.rpc('react_message', { p_id: id, p_emoji: e })); },
      async markRead(c) { ok(await sb.rpc('mark_read', { p_conv: c })); }
    },

    communities: {
      async list() {
        const me = await uid(), ids = await myCommIds(me);
        if (!ids.length) return [];
        const rows = ok(await sb.from('communities').select('*').in('id', ids)) || [];
        return rows.map(c => mapComm(c, true, me));
      },
      async suggest() {
        const me = await uid(), ids = new Set(await myCommIds(me));
        const rows = ok(await sb.from('communities').select('*').order('members_count', { ascending: false }).limit(30)) || [];
        return rows.filter(c => !ids.has(c.id)).map(c => mapComm(c, false, me));
      },
      async get(id) {
        const me = await uid();
        const c = ok(await sb.from('communities').select('*').eq('id', id).maybeSingle());
        if (!c) return undefined;
        return mapComm(c, (await myCommIds(me)).includes(id), me);
      },
      async create(x) {
        const r = ok(await sb.rpc('create_community', { p_name: x.name, p_desc: x.desc || '', p_visual: x.g || 0, p_private: !!x.priv }));
        return A.communities.get(r.id);
      },
      async join(id) {
        const st = ok(await sb.rpc('join_community', { p_id: id }));
        if (st === 'en_attente') throw new Error('Demande envoyée : un administrateur doit l’accepter');
      },
      async update(id, p) {
        const patch = {};
        if (p.rules !== undefined) patch.rules = p.rules;
        if (p.desc !== undefined) patch.description = p.desc;
        ok(await sb.from('communities').update(patch).eq('id', id));
      },
      async admin(id) { return ok(await sb.rpc('community_admin', { p_id: id })) || { members: [], reports: [] }; },
      invite: id => location.href.split('#')[0] + '#c-' + id
    },

    notifications: {
      async list() {
        const rows = ok(await sb.from('notifications').select('id,type,text,read,created_at,actor_id').order('created_at', { ascending: false }).limit(60)) || [];
        const pm = await profilesById(rows.map(r => r.actor_id));
        return rows.map(r => ({ id: r.id, type: r.type, text: r.text, from: (pm[r.actor_id] || {}).name || 'Floxly', at: ts(r.created_at), read: r.read }));
      },
      async markRead() { const me = await uid(); ok(await sb.from('notifications').update({ read: true }).eq('user_id', me).eq('read', false)); }
    },

    async search(q) {
      q = String(q || '').trim();
      if (!q) return { profiles: [], posts: [], communities: [] };
      const me = await uid(), r = ok(await sb.rpc('search_all', { p_q: q })) || {};
      const [pr, cr] = await Promise.all([
        (r.post_ids || []).length ? sb.from('posts').select(POSTC).in('id', r.post_ids).order('created_at', { ascending: false }) : { data: [] },
        (r.communities || []).length ? sb.from('communities').select('*').in('id', r.communities) : { data: [] }
      ]);
      const mine = new Set(await myCommIds(me));
      return {
        profiles: r.profiles || [], posts: await hydratePosts(ok(pr) || []),
        communities: (ok(cr) || []).map(c => mapComm(c, mine.has(c.id), me))
      };
    },
    async trends() { return ok(await sb.rpc('trending_tags')) || []; },

    settings: {
      get: k => SET[k],
      set(k, v) { SET[k] = v; saveSet(); }
    },

    sched: {
      async list() {
        const rows = ok(await sb.from('sched_posts').select('id,payload,publish_at').eq('status', 'en_attente').order('publish_at', { ascending: true })) || [];
        return rows.map(r => ({ id: r.id, at: ts(r.publish_at), payload: r.payload }));
      },
      async add(payload, at) {
        const me = await uid();
        ok(await sb.from('sched_posts').insert({ user_id: me, payload, publish_at: new Date(at).toISOString() }));
      },
      async remove(id) { ok(await sb.from('sched_posts').delete().eq('id', id)); },
      async flush() { return ok(await sb.rpc('flush_my_scheduled')) || 0; }
    },
    drafts: {
      async list() {
        const rows = ok(await sb.from('drafts').select('id,payload,created_at').order('created_at', { ascending: false })) || [];
        return rows.map(r => ({ id: r.id, at: ts(r.created_at), payload: r.payload }));
      },
      async add(p) { const me = await uid(); ok(await sb.from('drafts').insert({ user_id: me, payload: p })); },
      async remove(id) { ok(await sb.from('drafts').delete().eq('id', id)); }
    },
    stickers: {
      async list() {
        const packs = ok(await sb.from('sticker_packs').select('id,name').order('created_at', { ascending: true })) || [];
        if (!packs.length) return [];
        const st = ok(await sb.from('stickers').select('id,pack_id,url').in('pack_id', packs.map(p => p.id)).order('created_at', { ascending: true })) || [];
        return packs.map(p => ({ id: p.id, name: p.name, items: st.filter(s => s.pack_id === p.id).map(s => ({ id: s.id, url: s.url })) }));
      },
      async createPack(name) {
        const me = await uid();
        const r = ok(await sb.from('sticker_packs').insert({ owner_id: me, name }).select('id,name').single());
        return { id: r.id, name: r.name, items: [] };
      },
      async add(pid, url) { ok(await sb.from('stickers').insert({ pack_id: pid, url })); }
    },

    async stats(days) { return ok(await sb.rpc('get_stats', { p_days: days })); },
    async setGoal(n) { const me = await uid(); ok(await sb.from('profiles').update({ goal: n }).eq('id', me)); },
    config: { async certification() { return null; } },

    fluxus: {
      async ask(text) {
        if (!cfg.FLUXUS_URL) return { text: 'Fluxus n’est pas encore connecté au serveur. L’IA, la mémoire et la surveillance seront branchées côté back-end.' };
        const { data } = await sb.auth.getSession();
        const r = await fetch(cfg.FLUXUS_URL, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: 'Bearer ' + (data.session ? data.session.access_token : '') },
          body: JSON.stringify({ text })
        });
        if (!r.ok) throw new Error('Fluxus est indisponible pour le moment');
        return r.json();
      }
    },
    calls: { async start() { return { ok: false, reason: 'Service d’appel non connecté (WebRTC à brancher)' }; } },

    media: {
      async upload(file, o = {}) {
        const me = await uid(), mx = o.maxPx || 1080, ty = file.type || '';
        let blob = file, ctype = ty, kind = ty.startsWith('image/') ? 'image' : ty.startsWith('video/') ? 'video' : ty.startsWith('audio/') ? 'audio' : 'file';
        if (kind === 'image' && ty !== 'image/gif' && ty !== 'image/svg+xml') {
          blob = await new Promise((res, rej) => {
            const im = new Image(), u = URL.createObjectURL(file);
            im.onload = () => {
              const r = Math.min(1, mx / Math.max(im.width, im.height)), c = document.createElement('canvas');
              c.width = Math.round(im.width * r); c.height = Math.round(im.height * r);
              c.getContext('2d').drawImage(im, 0, 0, c.width, c.height);
              URL.revokeObjectURL(u);
              c.toBlob(b => b ? res(b) : rej(new Error('Image illisible')), 'image/jpeg', 0.82);
            };
            im.onerror = () => rej(new Error('Image illisible'));
            im.src = u;
          });
          ctype = 'image/jpeg';
        }
        if (blob.size > MAXB) throw new Error('Fichier trop lourd (50 Mo maximum sur le plan gratuit)');
        const path = me + '/' + Date.now().toString(36) + Math.random().toString(36).slice(2, 7) + '.' + extOf(ctype);
        ok(await sb.storage.from('media').upload(path, blob, { contentType: ctype || 'application/octet-stream', upsert: false }));
        const { data } = sb.storage.from('media').getPublicUrl(path);
        return { type: kind, url: data.publicUrl, persisted: true };
      }
    },

    async report(kind, id, reason) {
      const me = await uid();
      ok(await sb.from('reports').insert({ reporter_id: me, target_type: kind, target_id: String(id), reason: reason || '' }));
    }
  };

  /* Toute erreur renvoyée à l'interface devient un message lisible en français. */
  function wrap(o) {
    Object.keys(o).forEach(k => {
      const v = o[k];
      if (typeof v === 'function') {
        o[k] = (...a) => {
          let r;
          try { r = v(...a); } catch (e) { throw new Error(tr(e)); }
          return r && typeof r.then === 'function' ? r.catch(e => { throw new Error(tr(e)); }) : r;
        };
      } else if (v && typeof v === 'object') wrap(v);
    });
    return o;
  }
  window.FLOXLY_API = wrap(A);
})();
