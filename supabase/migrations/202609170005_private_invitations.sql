create or replace function public.invite_user_to_event(
  requested_event_id uuid,
  invitee_email text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_invitee_id uuid;
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

  select id
  into requested_invitee_id
  from auth.users
  where lower(email) = lower(btrim(invitee_email))
  limit 1;

  -- The result deliberately does not reveal whether an email is registered.
  if requested_invitee_id is null
    or requested_invitee_id = (select auth.uid()) then
    return;
  end if;

  insert into public.event_invitations (
    event_id,
    inviter_id,
    invitee_id,
    status,
    responded_at
  )
  values (
    requested_event_id,
    (select auth.uid()),
    requested_invitee_id,
    'pending',
    null
  )
  on conflict (event_id, invitee_id) do update
  set inviter_id = excluded.inviter_id,
      status = 'pending',
      responded_at = null,
      created_at = now();
end;
$$;

revoke execute on function public.invite_user_to_event(uuid, text) from public;
grant execute on function public.invite_user_to_event(uuid, text) to authenticated;
