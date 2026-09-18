create table public.event_attendees (
  event_id uuid not null references public.events (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (event_id, user_id)
);

create index event_attendees_user_idx
  on public.event_attendees (user_id, created_at desc);

alter table public.event_attendees enable row level security;
revoke all on public.event_attendees from anon, authenticated;

create or replace function public.get_event_attendance(requested_event_ids uuid[])
returns table (
  event_id uuid,
  attendee_count bigint,
  is_attending boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    e.id,
    count(a.user_id),
    coalesce(bool_or(a.user_id = (select auth.uid())), false)
  from public.events e
  left join public.event_attendees a on a.event_id = e.id
  where e.id = any(coalesce(requested_event_ids, array[]::uuid[]))
    and e.status = 'published'
    and private.can_view_event(e.id)
  group by e.id;
$$;

create or replace function public.toggle_event_attendance(requested_event_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'Authentication required'
      using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.events e
    where e.id = requested_event_id
      and e.visibility = 'public'
      and e.status = 'published'
  ) then
    raise exception 'Attendance is only available for public events'
      using errcode = '22023';
  end if;

  delete from public.event_attendees
  where event_id = requested_event_id
    and user_id = (select auth.uid());

  if found then
    return false;
  end if;

  insert into public.event_attendees (event_id, user_id)
  values (requested_event_id, (select auth.uid()));

  return true;
end;
$$;

create or replace function public.get_event_attendees(requested_event_id uuid)
returns table (
  user_id uuid,
  first_name text,
  avatar_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.can_view_event(requested_event_id) then
    raise exception 'Event is not visible'
      using errcode = '42501';
  end if;

  return query
  select a.user_id, p.first_name, p.avatar_path
  from public.event_attendees a
  join public.profiles p on p.id = a.user_id
  where a.event_id = requested_event_id
  order by a.created_at
  limit 100;
end;
$$;

revoke execute on function public.get_event_attendance(uuid[]) from public;
revoke execute on function public.toggle_event_attendance(uuid) from public;
revoke execute on function public.get_event_attendees(uuid) from public;

grant execute on function public.get_event_attendance(uuid[]) to anon, authenticated;
grant execute on function public.toggle_event_attendance(uuid) to authenticated;
grant execute on function public.get_event_attendees(uuid) to anon, authenticated;
