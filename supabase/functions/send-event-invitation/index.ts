import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY') ?? '';
const INVITATION_FROM_EMAIL = Deno.env.get('INVITATION_FROM_EMAIL') ?? '';
const APP_URL = (Deno.env.get('APP_URL') ?? 'https://appventure.thorkildstray.no').replace(/\/$/, '');
const DEFAULT_ORIGINS = `${APP_URL},http://localhost:5173`;
const ALLOWED_ORIGINS = new Set(
  (Deno.env.get('APP_ORIGINS') ?? DEFAULT_ORIGINS)
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean),
);

const HTML_ENTITIES: Record<string, string> = {
  '&': '&amp;',
  '<': '&lt;',
  '>': '&gt;',
  '"': '&quot;',
  "'": '&#39;',
};
const htmlEscape = (value: unknown) =>
  String(value).replace(/[&<>"']/g, (character) => HTML_ENTITIES[character] ?? character);

function responseHeaders(request: Request) {
  const origin = request.headers.get('Origin') ?? APP_URL;
  return {
    'Access-Control-Allow-Origin': ALLOWED_ORIGINS.has(origin) ? origin : APP_URL,
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Content-Type': 'application/json',
    Vary: 'Origin',
  };
}

function json(request: Request, body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: responseHeaders(request),
  });
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') {
    return new Response('ok', { headers: responseHeaders(request) });
  }
  if (request.method !== 'POST') return json(request, { error: 'Method not allowed' }, 405);
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY) return json(request, { error: 'Server configuration is incomplete' }, 500);

  const authorization = request.headers.get('Authorization');
  if (!authorization) return json(request, { error: 'Authentication required' }, 401);

  const client = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await client.auth.getUser();
  const user = authData.user;
  if (authError || !user) return json(request, { error: 'Authentication required' }, 401);

  let payload: { eventId?: string; email?: string; token?: string };
  try {
    payload = await request.json();
  } catch {
    return json(request, { error: 'Invalid request body' }, 400);
  }

  const eventId = payload.eventId?.trim() ?? '';
  const email = payload.email?.trim().toLowerCase() ?? '';
  const token = payload.token?.trim() ?? '';
  if (!/^[0-9a-f-]{36}$/i.test(eventId) || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !/^[0-9a-f]{64}$/i.test(token)) {
    return json(request, { error: 'Invalid invitation data' }, 400);
  }

  const { data: event, error: eventError } = await client
    .from('events')
    .select('id, title, starts_at, venue, creator_id, visibility')
    .eq('id', eventId)
    .eq('creator_id', user.id)
    .eq('visibility', 'private')
    .maybeSingle();
  if (eventError) return json(request, { error: 'Could not verify event ownership' }, 500);
  if (!event) return json(request, { error: 'Only the owner of a private event can send invitations' }, 403);

  if (!RESEND_API_KEY || !INVITATION_FROM_EMAIL) {
    return json(request, { error: 'Email delivery is not configured' }, 503);
  }

  const { data: profile } = await client
    .from('profiles')
    .select('first_name, last_name')
    .eq('id', user.id)
    .maybeSingle();
  const inviterName = [profile?.first_name, profile?.last_name].filter(Boolean).join(' ') || 'En Appventure-bruker';
  const invitationUrl = `${APP_URL}/?invite=${encodeURIComponent(token)}`;
  const date = new Intl.DateTimeFormat('nb-NO', {
    timeZone: 'Europe/Oslo',
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    hour: '2-digit',
    minute: '2-digit',
  }).format(new Date(event.starts_at));
  const safeTitle = htmlEscape(event.title);
  const safeInviter = htmlEscape(inviterName);
  const safeDate = htmlEscape(date);
  const safeVenue = htmlEscape(event.venue);
  const safeUrl = htmlEscape(invitationUrl);

  const emailResponse = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${RESEND_API_KEY}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      from: INVITATION_FROM_EMAIL,
      to: [email],
      subject: `${inviterName} inviterer deg til ${event.title}`,
      text: `${inviterName} inviterer deg til ${event.title}.\n${date} · ${event.venue}\n\nÅpne invitasjonen: ${invitationUrl}\n\nLenken er personlig og utløper etter 14 dager.`,
      html: `<div style="font-family:Arial,sans-serif;max-width:560px;margin:auto;color:#222324;line-height:1.6"><p style="font-size:12px;letter-spacing:.12em;text-transform:uppercase;color:#6b7068">Appventure</p><h1 style="font-size:24px;line-height:1.25">${safeInviter} inviterer deg</h1><h2 style="font-size:18px;font-weight:600">${safeTitle}</h2><p>${safeDate}<br>${safeVenue}</p><p style="margin:28px 0"><a href="${safeUrl}" style="background:#ffaa1e;color:#222324;text-decoration:none;padding:12px 18px;border-radius:6px;font-weight:600">Se invitasjonen</a></p><p style="font-size:12px;color:#6b7068">Lenken er personlig og utløper etter 14 dager. Du må bruke denne e-postadressen når du logger inn eller oppretter konto.</p></div>`,
    }),
  });

  if (!emailResponse.ok) {
    console.error('Resend invitation failed', emailResponse.status, await emailResponse.text());
    return json(request, { error: 'Email delivery failed' }, 502);
  }

  return json(request, { sent: true });
});
