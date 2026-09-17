create type public.friend_request_status as enum ('pending', 'accepted', 'declined');

create table public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles (id) on delete cascade,
  receiver_id uuid not null references public.profiles (id) on delete cascade,
  status public.friend_request_status not null default 'pending',
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  constraint friend_requests_not_self check (sender_id <> receiver_id),
  constraint friend_requests_unique_direction unique (sender_id, receiver_id)
);

create index friend_requests_receiver_idx
  on public.friend_requests (receiver_id, status, created_at desc);

create table public.friendships (
  user_a uuid not null references public.profiles (id) on delete cascade,
  user_b uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_a, user_b),
  constraint friendships_canonical_order check (user_a < user_b)
);

create index friendships_user_b_idx on public.friendships (user_b);

alter table public.friend_requests enable row level security;
alter table public.friendships enable row level security;

create policy "Request participants can read friend requests"
on public.friend_requests for select
to authenticated
using (
  (select auth.uid()) = sender_id
  or (select auth.uid()) = receiver_id
);

create policy "Friends can read their friendships"
on public.friendships for select
to authenticated
using (
  (select auth.uid()) = user_a
  or (select auth.uid()) = user_b
);

revoke insert, update, delete on public.friend_requests from anon, authenticated;
revoke insert, update, delete on public.friendships from anon, authenticated;
grant select on public.friend_requests to authenticated;
grant select on public.friendships to authenticated;

create or replace function public.send_friend_request(requested_email text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  requested_receiver_id uuid;
  current_user_id uuid := (select auth.uid());
  lower_id uuid;
  higher_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication required' using errcode = '42501';
  end if;

  select id into requested_receiver_id
  from auth.users
  where lower(email) = lower(btrim(requested_email))
  limit 1;

  -- Do not expose whether an email address is registered.
  if requested_receiver_id is null or requested_receiver_id = current_user_id then
    return;
  end if;

  lower_id := least(current_user_id, requested_receiver_id);
  higher_id := greatest(current_user_id, requested_receiver_id);

  if exists (
    select 1 from public.friendships
    where user_a = lower_id and user_b = higher_id
  ) then
    return;
  end if;

  if exists (
    select 1 from public.friend_requests
    where sender_id = requested_receiver_id
      and receiver_id = current_user_id
      and status = 'pending'
  ) then
    return;
  end if;

  insert into public.friend_requests (sender_id, receiver_id, status, responded_at)
  values (current_user_id, requested_receiver_id, 'pending', null)
  on conflict (sender_id, receiver_id) do update
  set status = 'pending', responded_at = null, created_at = now();
end;
$$;

create or replace function public.respond_to_friend_request(
  requested_request_id uuid,
  requested_status public.friend_request_status
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  request_record public.friend_requests%rowtype;
  lower_id uuid;
  higher_id uuid;
begin
  if requested_status not in ('accepted', 'declined') then
    raise exception 'Invalid response' using errcode = '22023';
  end if;

  select * into request_record
  from public.friend_requests
  where id = requested_request_id
    and receiver_id = (select auth.uid())
    and status = 'pending'
  for update;

  if request_record.id is null then
    raise exception 'Friend request not found' using errcode = '42501';
  end if;

  update public.friend_requests
  set status = requested_status,
      responded_at = now()
  where id = requested_request_id;

  if requested_status = 'accepted' then
    lower_id := least(request_record.sender_id, request_record.receiver_id);
    higher_id := greatest(request_record.sender_id, request_record.receiver_id);
    insert into public.friendships (user_a, user_b)
    values (lower_id, higher_id)
    on conflict (user_a, user_b) do nothing;
  end if;
end;
$$;

create or replace function public.remove_friend(requested_friend_id uuid)
returns void
language sql
security definer
set search_path = ''
as $$
  delete from public.friendships
  where user_a = least((select auth.uid()), requested_friend_id)
    and user_b = greatest((select auth.uid()), requested_friend_id);
$$;

create or replace function public.invite_friend_to_event(
  requested_event_id uuid,
  requested_friend_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := (select auth.uid());
begin
  if not private.is_event_owner(requested_event_id) then
    raise exception 'Only the event owner can invite users' using errcode = '42501';
  end if;

  if not exists (
    select 1 from public.events
    where id = requested_event_id and visibility = 'private'
  ) then
    raise exception 'Invitations require a private event' using errcode = '22023';
  end if;

  if not exists (
    select 1 from public.friendships
    where user_a = least(current_user_id, requested_friend_id)
      and user_b = greatest(current_user_id, requested_friend_id)
  ) then
    raise exception 'Users are not friends' using errcode = '42501';
  end if;

  insert into public.event_invitations (
    event_id, inviter_id, invitee_id, status, responded_at
  ) values (
    requested_event_id, current_user_id, requested_friend_id, 'pending', null
  )
  on conflict (event_id, invitee_id) do update
  set inviter_id = excluded.inviter_id,
      status = 'pending',
      responded_at = null,
      created_at = now();
end;
$$;

revoke execute on function public.send_friend_request(text) from public;
revoke execute on function public.respond_to_friend_request(uuid, public.friend_request_status) from public;
revoke execute on function public.remove_friend(uuid) from public;
revoke execute on function public.invite_friend_to_event(uuid, uuid) from public;

grant execute on function public.send_friend_request(text) to authenticated;
grant execute on function public.respond_to_friend_request(uuid, public.friend_request_status) to authenticated;
grant execute on function public.remove_friend(uuid) to authenticated;
grant execute on function public.invite_friend_to_event(uuid, uuid) to authenticated;
