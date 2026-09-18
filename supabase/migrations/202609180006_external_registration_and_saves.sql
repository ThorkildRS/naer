alter table public.events
  add column registration_type text not null default 'internal'
  check (registration_type in ('internal', 'external', 'none')),
  add column external_registration_url text;

alter table public.events
  add constraint events_registration_configuration_check check (
    (registration_type = 'external'
      and visibility = 'public'
      and external_registration_url is not null
      and external_registration_url ~* '^https://[^[:space:]]+$'
      and char_length(external_registration_url) <= 2048
      and capacity is null)
    or
    (registration_type in ('internal', 'none')
      and external_registration_url is null
      and (registration_type = 'internal' or capacity is null))
  );

create table public.event_saves (
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create index event_saves_user_created_idx
  on public.event_saves (user_id, created_at desc);

alter table public.event_saves enable row level security;

create policy "Users read their own saved events"
on public.event_saves for select
to authenticated
using ((select auth.uid()) = user_id);

create policy "Users save visible events"
on public.event_saves for insert
to authenticated
with check (
  (select auth.uid()) = user_id
  and private.can_view_event(event_id)
);

create policy "Users remove their own saved events"
on public.event_saves for delete
to authenticated
using ((select auth.uid()) = user_id);

grant select, insert, delete on public.event_saves to authenticated;

create function private.validate_event_registration_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if old.registration_type = 'internal'
    and new.registration_type <> 'internal'
    and exists (
      select 1
      from public.event_attendees a
      where a.event_id = new.id
    ) then
    raise exception 'Remove attendees before changing the registration type'
      using errcode = '22023';
  end if;

  return new;
end;
$$;

create trigger validate_event_registration_before_change
before update of registration_type on public.events
for each row execute function private.validate_event_registration_change();

revoke all on function private.validate_event_registration_change() from public;

create or replace function public.toggle_event_attendance(requested_event_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  event_capacity integer;
  attending_count integer;
  existing_status text;
  next_status text;
  promoted_user_id uuid;
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required'
      using errcode = '42501';
  end if;

  select e.capacity
  into event_capacity
  from public.events e
  where e.id = requested_event_id
    and e.visibility = 'public'
    and e.status = 'published'
    and e.registration_type = 'internal'
  for update;

  if not found then
    raise exception 'Attendance is only available for public events with internal registration'
      using errcode = '22023';
  end if;

  select a.status
  into existing_status
  from public.event_attendees a
  where a.event_id = requested_event_id
    and a.user_id = (select auth.uid());

  if found then
    delete from public.event_attendees
    where event_id = requested_event_id
      and user_id = (select auth.uid());

    if existing_status = 'attending' and event_capacity is not null then
      update public.event_attendees a
      set status = 'attending'
      where (a.event_id, a.user_id) = (
        select queued.event_id, queued.user_id
        from public.event_attendees queued
        where queued.event_id = requested_event_id
          and queued.status = 'waitlisted'
        order by queued.created_at, queued.user_id
        limit 1
      )
      returning a.user_id into promoted_user_id;
    end if;

    return jsonb_build_object(
      'status', 'removed',
      'previous_status', existing_status,
      'promoted_user_id', promoted_user_id
    );
  end if;

  select count(*)
  into attending_count
  from public.event_attendees a
  where a.event_id = requested_event_id
    and a.status = 'attending';

  next_status := case
    when event_capacity is not null and attending_count >= event_capacity
      then 'waitlisted'
    else 'attending'
  end;

  insert into public.event_attendees (event_id, user_id, status)
  values (requested_event_id, (select auth.uid()), next_status);

  return jsonb_build_object('status', next_status);
end;
$$;

revoke execute on function public.toggle_event_attendance(uuid) from public;
grant execute on function public.toggle_event_attendance(uuid) to authenticated;
