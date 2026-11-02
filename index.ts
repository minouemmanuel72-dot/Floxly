// Edge Function « push » : envoie les notifications push (Web Push).
// Déclenchée par deux Database Webhooks Supabase (événement INSERT) :
//   - table public.notifications  (abonnés, likes, commentaires, mentions)
//   - table public.messages       (nouveaux messages)
// Les webhooks doivent envoyer l'en-tête  x-webhook-secret: <PUSH_WEBHOOK_SECRET>.
// Secrets requis : VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY, VAPID_SUBJECT (ex. mailto:contact@exemple.com), PUSH_WEBHOOK_SECRET.
// Le contenu des messages n'est jamais envoyé dans la notification (confidentialité).
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const SETTING_KEY: Record<string, string> = {
  mention: "notif|Mentions",
  activity: "notif|Nouveaux abonnés",
  message: "notif|Messages",
};

Deno.serve(async (req) => {
  if (req.headers.get("x-webhook-secret") !== Deno.env.get("PUSH_WEBHOOK_SECRET")) {
    return new Response("forbidden", { status: 403 });
  }
  try {
    const { table, record: rec } = await req.json();
    const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    webpush.setVapidDetails(
      Deno.env.get("VAPID_SUBJECT")!, Deno.env.get("VAPID_PUBLIC_KEY")!, Deno.env.get("VAPID_PRIVATE_KEY")!,
    );

    // Qui reçoit quoi
    const targets: { user: string; kind: string; title: string; body: string; url: string }[] = [];
    if (table === "notifications") {
      targets.push({ user: rec.user_id, kind: rec.type, title: "Floxly", body: rec.text, url: "/" });
    } else if (table === "messages") {
      const { data: mem } = await admin.from("conversation_members").select("user_id").eq("conversation_id", rec.conversation_id).neq("user_id", rec.sender_id);
      const { data: s } = await admin.from("profiles").select("display_name").eq("id", rec.sender_id).maybeSingle();
      for (const m of mem ?? []) {
        targets.push({ user: m.user_id, kind: "message", title: s?.display_name ?? "Floxly",
          body: rec.kind === "voice" ? "Message vocal" : rec.kind === "sticker" ? "Sticker" : "Nouveau message", url: "/" });
      }
    } else {
      return new Response("ignored");
    }

    let sent = 0;
    for (const t of targets) {
      // Réglage de la personne (activé par défaut ; 0 = désactivé)
      const { data: pp } = await admin.from("profile_private").select("settings").eq("user_id", t.user).maybeSingle();
      const key = SETTING_KEY[t.kind] ?? SETTING_KEY.activity;
      if (pp?.settings?.[key] === 0) continue;
      const { data: subs } = await admin.from("push_subscriptions").select("id,endpoint,p256dh,auth").eq("user_id", t.user);
      for (const sub of subs ?? []) {
        try {
          await webpush.sendNotification(
            { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
            JSON.stringify({ title: t.title, body: t.body, url: t.url, tag: t.kind }),
          );
          sent++;
        } catch (e) {
          const code = (e as { statusCode?: number }).statusCode;
          if (code === 404 || code === 410) await admin.from("push_subscriptions").delete().eq("id", sub.id); // abonnement expiré
        }
      }
    }
    return new Response(JSON.stringify({ sent }), { headers: { "Content-Type": "application/json" } });
  } catch (_e) {
    return new Response("error", { status: 500 });
  }
});
