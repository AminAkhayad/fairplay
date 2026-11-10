// Supabase Edge Function "notify": sends push notifications to phones.
// Called by Database Webhooks on the tables "matches" and "messages".
//
// Secrets (Edge Functions → Secrets): VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY,
// VAPID_SUBJECT (e.g. mailto:you@example.com) and WEBHOOK_SECRET.
// SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY are provided by Supabase.
import { createClient } from 'npm:@supabase/supabase-js@2.45.4';
import webpush from 'npm:web-push@3.6.7';

/* ---------- who gets which notification ---------- */
export type Row = Record<string, any>;
export type Payload = { type: 'INSERT' | 'UPDATE' | 'DELETE'; table: string; record: Row | null; old_record: Row | null };
export type Note = { team: string; title: string; body: string; tag: string };

const day = (d: string) => {
  const [y, m, dd] = d.split('-').map(Number);
  return new Date(Date.UTC(y, m - 1, dd)).toLocaleDateString('en-GB', { weekday: 'short', day: 'numeric', month: 'short', timeZone: 'UTC' });
};
const at = (r: Row) => (r.kickoff ? ` at ${String(r.kickoff).slice(0, 5)}` : '');

/** names: team id -> team name */
export function describe(p: Payload, names: Record<string, string>): Note[] {
  const r = p.record;
  if (!r) return [];
  const n = (id: string) => names[id] || 'A team';

  if (p.table === 'messages' && p.type === 'INSERT') {
    const body = String(r.body || '');
    return [{ team: r.recipient, title: n(r.sender), body: body.length > 140 ? body.slice(0, 137) + '…' : body, tag: `chat-${r.sender}` }];
  }
  if (p.table !== 'matches') return [];

  const o = p.old_record || {};
  const tag = `match-${r.id}`;
  const c = r.challenger, op = r.opponent;
  const when = `${day(r.day)}${at(r)}`;

  if (p.type === 'INSERT') {
    if (r.suggested) {
      return [c, op].map(team => ({
        team, tag, title: '⚡ Fair Play match',
        body: `The team you wanted to play chose another opponent — but ${n(team === c ? op : c)} is also free on ${when}. Accept to play!`,
      }));
    }
    return [{ team: op, tag, title: r.call_id ? 'Response to your open call' : 'New challenge',
      body: r.call_id ? `${n(c)} wants to play on ${when}.` : `${n(c)} challenged you for ${when}.` }];
  }

  if (p.type !== 'UPDATE' || o.status === undefined) return [];
  const from = o.status, to = r.status;

  if (from === 'pending' && to === 'accepted') {
    return [c, op].map(team => ({ team, tag, title: "IT'S A MATCH! ⚽", body: `You play ${n(team === c ? op : c)} on ${when}.` }));
  }
  if (from === 'pending' && to === 'pending' && r.suggested && r.confirmed_by && !o.confirmed_by) {
    const other = r.confirmed_by === c ? op : c;
    return [{ team: other, tag, title: '⚡ Fair Play match', body: `${n(r.confirmed_by)} accepted the match on ${when} — your turn!` }];
  }
  if (from === 'pending' && to === 'declined' && !r.suggested) {
    return [{ team: c, tag, title: 'Request declined', body: `${n(op)} can't play on ${day(r.day)}. Look for another team on the calendar.` }];
  }
  if (from === 'accepted' && to === 'cancelled' && r.cancelled_by) {
    const other = r.cancelled_by === c ? op : c;
    return [{ team: other, tag, title: 'Friendly cancelled', body: `${n(r.cancelled_by)} cancelled the friendly on ${day(r.day)}.` }];
  }
  if (from === 'accepted' && to === 'result_pending' && r.result_by) {
    const other = r.result_by === c ? op : c;
    return [{ team: other, tag, title: 'Confirm the score', body: `${n(r.result_by)} entered the score of your match on ${day(r.day)}.` }];
  }
  if (to === 'no_show' && from !== 'no_show' && r.no_show) {
    return [{ team: r.no_show, tag, title: 'No-show reported', body: `${n(r.no_show === c ? op : c)} reported that your team did not show up on ${day(r.day)}.` }];
  }
  return [];
}

/* ---------- sending ---------- */
const sb = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
webpush.setVapidDetails(
  Deno.env.get('VAPID_SUBJECT') || 'mailto:admin@example.com',
  Deno.env.get('VAPID_PUBLIC_KEY')!,
  Deno.env.get('VAPID_PRIVATE_KEY')!,
);
const SECRET = Deno.env.get('WEBHOOK_SECRET');

Deno.serve(async (req) => {
  // only our own database webhook may call this function
  if (!SECRET || req.headers.get('x-webhook-secret') !== SECRET) return new Response('forbidden', { status: 403 });

  const payload = (await req.json()) as Payload;
  const r = payload.record || {};
  const ids = [r.challenger, r.opponent, r.sender, r.recipient, r.confirmed_by, r.cancelled_by, r.result_by, r.no_show].filter(Boolean);
  const { data: teams } = await sb.from('teams').select('id, name, owner').in('id', ids.length ? ids : ['00000000-0000-0000-0000-000000000000']);
  const names = Object.fromEntries((teams || []).map(t => [t.id, t.name]));
  const owners = Object.fromEntries((teams || []).map(t => [t.id, t.owner]));

  let sent = 0, removed = 0;
  for (const note of describe(payload, names)) {
    const owner = owners[note.team];
    if (!owner) continue;
    const { data: subs } = await sb.from('push_subscriptions').select('endpoint, p256dh, auth').eq('user_id', owner);
    for (const s of subs || []) {
      try {
        await webpush.sendNotification(
          { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
          JSON.stringify({ title: note.title, body: note.body, tag: note.tag }),
          { TTL: 60 * 60 * 24 },
        );
        sent++;
      } catch (e: any) {
        // the phone unsubscribed or the app was removed: forget this device
        if (e?.statusCode === 404 || e?.statusCode === 410) {
          await sb.from('push_subscriptions').delete().eq('endpoint', s.endpoint);
          removed++;
        } else console.error('push failed', e?.statusCode, e?.body || e?.message);
      }
    }
  }
  return Response.json({ sent, removed });
});
