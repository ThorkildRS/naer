import { createClient } from 'npm:@supabase/supabase-js@2';

const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
const SUPABASE_ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const APP_URL = (Deno.env.get('APP_URL') ?? 'https://appventure.thorkildstray.no').replace(/\/$/, '');
const ALLOWED_ORIGINS = new Set(
  (Deno.env.get('APP_ORIGINS') ?? `${APP_URL},http://localhost:5173`)
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean),
);

function headers(request: Request) {
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
  return new Response(JSON.stringify(body), { status, headers: headers(request) });
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: headers(request) });
  if (request.method !== 'POST') return json(request, { error: 'Method not allowed' }, 405);
  if (!SUPABASE_URL || !SUPABASE_ANON_KEY || !SUPABASE_SERVICE_ROLE_KEY) {
    return json(request, { error: 'Server configuration is incomplete' }, 500);
  }

  const authorization = request.headers.get('Authorization');
  if (!authorization) return json(request, { error: 'Authentication required' }, 401);

  const userClient = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: authData, error: authError } = await userClient.auth.getUser();
  const user = authData.user;
  if (authError || !user) return json(request, { error: 'Authentication required' }, 401);

  let payload: { confirmation?: string };
  try {
    payload = await request.json();
  } catch {
    return json(request, { error: 'Invalid request body' }, 400);
  }
  if (payload.confirmation !== 'SLETT') return json(request, { error: 'Confirmation required' }, 400);

  const admin = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const [profileResult, eventsResult] = await Promise.all([
    admin.from('profiles').select('avatar_path').eq('id', user.id).maybeSingle(),
    admin.from('events').select('image_path').eq('creator_id', user.id),
  ]);
  if (profileResult.error || eventsResult.error) {
    console.error('Could not collect account assets', profileResult.error, eventsResult.error);
    return json(request, { error: 'Could not prepare account deletion' }, 500);
  }

  const avatarPath = profileResult.data?.avatar_path;
  const eventImagePaths = (eventsResult.data ?? [])
    .map((event) => event.image_path)
    .filter((path): path is string => Boolean(path));
  if (avatarPath) {
    const { error } = await admin.storage.from('avatars').remove([avatarPath]);
    if (error) {
      console.error('Avatar cleanup failed', error);
      return json(request, { error: 'Could not remove account files' }, 500);
    }
  }
  if (eventImagePaths.length) {
    const { error } = await admin.storage.from('event-images').remove(eventImagePaths);
    if (error) {
      console.error('Event image cleanup failed', error);
      return json(request, { error: 'Could not remove account files' }, 500);
    }
  }

  const { error: deleteError } = await admin.auth.admin.deleteUser(user.id);
  if (deleteError) {
    console.error('Account deletion failed', deleteError);
    return json(request, { error: 'Account deletion failed' }, 500);
  }

  return json(request, { deleted: true });
});
