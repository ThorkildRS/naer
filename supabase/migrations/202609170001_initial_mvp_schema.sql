create extension if not exists pgcrypto;

create type public.event_visibility as enum ('public', 'private');
create type public.event_status as enum ('draft', 'published', 'cancelled');
create type public.invitation_status as enum ('pending', 'accepted', 'declined');

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  first_name text check (first_name is null or char_length(first_name) between 1 and 50),
  last_name text check (last_name is null or char_length(last_name) between 1 and 70),
  district text check (district is null or char_length(district) between 1 and 80),
  avatar_path text,
  interests text[] not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.events (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references public.profiles (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 1 and 90),
  description text not null check (char_length(btrim(description)) between 1 and 500),
  category text not null check (
    category in (
      'jazz', 'electronic', 'rock', 'classical', 'art', 'theatre',
      'film', 'comedy', 'food', 'market', 'talk', 'sport', 'outdoor',
      'family', 'books', 'nightlife', 'other'
    )
  ),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  venue text not null check (char_length(btrim(venue)) between 1 and 100),
  latitude double precision not null check (latitude between -90 and 90),
  longitude double precision not null check (longitude between -180 and 180),
  price_text text not null default 'Gratis' check (char_length(price_text) between 1 and 35),
  image_path text,
  visibility public.event_visibility not null default 'public',
  status public.event_status not null default 'published',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint events_valid_time_range check (ends_at > starts_at)
);

create index events_starts_at_idx on public.events (starts_at);
create index events_creator_id_idx on public.events (creator_id);
create index events_discovery_idx on public.events (status, visibility, starts_at);

create table public.event_invitations (
  event_id uuid not null references public.events (id) on delete cascade,
  inviter_id uuid not null references public.profiles (id) on delete cascade,
  invitee_id uuid not null references public.profiles (id) on delete cascade,
  status public.invitation_status not null default 'pending',
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  primary key (event_id, invitee_id),
  constraint event_invitations_not_self check (inviter_id <> invitee_id)
);

create index event_invitations_invitee_idx
  on public.event_invitations (invitee_id, status);

create schema if not exists private;
revoke all on schema private from public;

create or replace function private.is_event_owner(requested_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.events
    where id = requested_event_id
      and creator_id = (select auth.uid())
  );
$$;

create or replace function private.can_view_event(requested_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.events e
    where e.id = requested_event_id
      and (
        (e.status = 'published' and e.visibility = 'public')
        or e.creator_id = (select auth.uid())
        or exists (
          select 1
          from public.event_invitations i
          where i.event_id = e.id
            and i.invitee_id = (select auth.uid())
            and i.status in ('pending', 'accepted')
        )
      )
  );
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

create trigger profiles_set_updated_at
before update on public.profiles
for each row execute function public.set_updated_at();

create trigger events_set_updated_at
before update on public.events
for each row execute function public.set_updated_at();

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, first_name, last_name)
  values (
    new.id,
    nullif(btrim(new.raw_user_meta_data ->> 'first_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'last_name'), '')
  );
  return new;
end;
$$;

create trigger on_auth_user_created
after insert on auth.users
for each row execute function public.handle_new_user();

create or replace function public.protect_invitation_identity()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.event_id <> old.event_id
    or new.inviter_id <> old.inviter_id
    or new.invitee_id <> old.invitee_id then
    raise exception 'Invitation participants cannot be changed';
  end if;

  if new.status <> old.status then
    new.responded_at = case when new.status = 'pending' then null else now() end;
  end if;

  return new;
end;
$$;

create trigger event_invitations_protect_identity
before update on public.event_invitations
for each row execute function public.protect_invitation_identity();

alter table public.profiles enable row level security;
alter table public.events enable row level security;
alter table public.event_invitations enable row level security;

create policy "Profiles are readable"
on public.profiles for select
using (true);

create policy "Users create their own profile"
on public.profiles for insert
to authenticated
with check ((select auth.uid()) = id);

create policy "Users update their own profile"
on public.profiles for update
to authenticated
using ((select auth.uid()) = id)
with check ((select auth.uid()) = id);

create policy "Visible events are readable"
on public.events for select
using (private.can_view_event(id));

create policy "Users create their own events"
on public.events for insert
to authenticated
with check ((select auth.uid()) = creator_id);

create policy "Owners update their events"
on public.events for update
to authenticated
using ((select auth.uid()) = creator_id)
with check ((select auth.uid()) = creator_id);

create policy "Owners delete their events"
on public.events for delete
to authenticated
using ((select auth.uid()) = creator_id);

create policy "Invitation participants can read invitations"
on public.event_invitations for select
to authenticated
using (
  (select auth.uid()) = inviter_id
  or (select auth.uid()) = invitee_id
  or private.is_event_owner(event_id)
);

create policy "Event owners create invitations"
on public.event_invitations for insert
to authenticated
with check (
  (select auth.uid()) = inviter_id
  and private.is_event_owner(event_id)
);

create policy "Invitees respond to invitations"
on public.event_invitations for update
to authenticated
using ((select auth.uid()) = invitee_id)
with check ((select auth.uid()) = invitee_id);

create policy "Event owners delete invitations"
on public.event_invitations for delete
to authenticated
using (private.is_event_owner(event_id));

revoke execute on function private.is_event_owner(uuid) from public;
revoke execute on function private.can_view_event(uuid) from public;
grant usage on schema private to anon, authenticated;
grant execute on function private.is_event_owner(uuid) to authenticated;
grant execute on function private.can_view_event(uuid) to anon, authenticated;

grant select on public.profiles to anon, authenticated;
grant insert, update on public.profiles to authenticated;
grant select on public.events to anon, authenticated;
grant insert, update, delete on public.events to authenticated;
grant select, insert, update, delete on public.event_invitations to authenticated;
