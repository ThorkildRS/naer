create table if not exists public.external_invitations (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  inviter_id uuid not null references public.profiles (id) on delete cascade,
  invited_email text not null check (char_length(btrim(invited_email)) between 3 and 320),
  token_hash bytea not null unique,
  expires_at timestamptz not null default (now() + interval '14 days'),
  claimed_by uuid references public.profiles (id) on delete set null,
  claimed_at timestamptz,
  created_at timestamptz not null default now()
);

create index if not exists external_invitations_event_idx
  on public.external_invitations (event_id, expires_at);

alter table public.external_invitations enable row level security;
revoke all on public.external_invitations from anon, authenticated;

create or replace function public.create_event_invitation_link(
  requested_event_id uuid,
  invitee_email text
)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  normalized_email text := lower(btrim(invitee_email));
  raw_token text := encode(extensions.gen_random_bytes(32), 'hex');
  registered_user_id uuid;
begin
  if not private.is_event_owner(requested_event_id) then
    raise exception 'Only the event owner can invite users'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.events
    where id = requested_event_id
      and visibility = 'private'
  ) then
    raise exception 'Invitations require a private event'
      using errcode = '22023';
  end if;

  if normalized_email !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'Invalid email address'
      using errcode = '22023';
  end if;

  insert into public.external_invitations (
    event_id,
    inviter_id,
    invited_email,
    token_hash
  ) values (
    requested_event_id,
    (select auth.uid()),
    normalized_email,
    extensions.digest(raw_token, 'sha256')
  );

  select id
  into registered_user_id
  from auth.users
  where lower(email) = normalized_email
  limit 1;

  if registered_user_id is not null
    and registered_user_id <> (select auth.uid()) then
    insert into public.event_invitations (
      event_id,
      inviter_id,
      invitee_id,
      status,
      responded_at
    ) values (
      requested_event_id,
      (select auth.uid()),
      registered_user_id,
      'pending',
      null
    )
    on conflict (event_id, invitee_id) do update
    set inviter_id = excluded.inviter_id,
        status = 'pending',
        responded_at = null,
        created_at = now();
  end if;

  return raw_token;
end;
$$;

create or replace function public.preview_event_invitation(
  invitation_token text
)
returns table (
  event_title text,
  starts_at timestamptz,
  venue text,
  inviter_name text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    e.title,
    e.starts_at,
    e.venue,
    btrim(concat_ws(' ', p.first_name, p.last_name))
  from public.external_invitations x
  join public.events e on e.id = x.event_id
  join public.profiles p on p.id = x.inviter_id
  where x.token_hash = extensions.digest(invitation_token, 'sha256')
    and x.expires_at > now()
    and x.claimed_at is null
  limit 1;
$$;

create or replace function public.claim_event_invitation(
  invitation_token text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  invitation_record public.external_invitations%rowtype;
  signed_in_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required'
      using errcode = '42501';
  end if;

  select *
  into invitation_record
  from public.external_invitations
  where token_hash = extensions.digest(invitation_token, 'sha256')
    and expires_at > now()
    and claimed_at is null
  for update;

  if invitation_record.id is null then
    raise exception 'Invitation is invalid or expired'
      using errcode = '22023';
  end if;

  if invitation_record.invited_email <> signed_in_email then
    raise exception 'Use the email address that received the invitation'
      using errcode = '42501';
  end if;

  update public.external_invitations
  set claimed_by = (select auth.uid()),
      claimed_at = now()
  where id = invitation_record.id;

  insert into public.event_invitations (
    event_id,
    inviter_id,
    invitee_id,
    status,
    responded_at
  ) values (
    invitation_record.event_id,
    invitation_record.inviter_id,
    (select auth.uid()),
    'pending',
    null
  )
  on conflict (event_id, invitee_id) do update
  set inviter_id = excluded.inviter_id,
      status = 'pending',
      responded_at = null,
      created_at = now();

  return invitation_record.event_id;
end;
$$;

revoke execute on function public.create_event_invitation_link(uuid, text) from public;
revoke execute on function public.preview_event_invitation(text) from public;
revoke execute on function public.claim_event_invitation(text) from public;

grant execute on function public.create_event_invitation_link(uuid, text) to authenticated;
grant execute on function public.preview_event_invitation(text) to anon, authenticated;
grant execute on function public.claim_event_invitation(text) to authenticated;
