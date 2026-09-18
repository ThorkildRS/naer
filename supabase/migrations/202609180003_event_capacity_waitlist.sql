alter table public.events
  add column capacity integer
  check (capacity is null or capacity between 1 and 10000);

alter table public.event_attendees
  add column status text not null default 'attending'
  check (status in ('attending', 'waitlisted'));

create index event_attendees_event_status_created_idx
  on public.event_attendees (event_id, status, created_at);

create function private.validate_event_capacity()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  attending_count integer;
begin
  if new.visibility = 'public' and new.capacity is not null then
    select count(*)::integer
    into attending_count
    from public.event_attendees a
    where a.event_id = new.id
      and a.status = 'attending';

    if attending_count > new.capacity then
      raise exception 'Capacity cannot be lower than current attendance'
        using errcode = '22023';
    end if;
  end if;

  return new;
end;
$$;

create trigger validate_event_capacity_before_change
before update of capacity, visibility on public.events
for each row execute function private.validate_event_capacity();

create function private.promote_event_waitlist()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  available_places integer;
begin
  if new.visibility <> 'public' then
    return new;
  end if;

  if new.capacity is null then
    available_places := 2147483647;
  else
    select greatest(
      new.capacity - count(*) filter (where a.status = 'attending'),
      0
    )::integer
    into available_places
    from public.event_attendees a
    where a.event_id = new.id;
  end if;

  if available_places > 0 then
    with next_in_line as (
      select a.event_id, a.user_id
      from public.event_attendees a
      where a.event_id = new.id
        and a.status = 'waitlisted'
      order by a.created_at, a.user_id
      limit available_places
    )
    update public.event_attendees a
    set status = 'attending'
    from next_in_line n
    where a.event_id = n.event_id
      and a.user_id = n.user_id;
  end if;

  return new;
end;
$$;

create trigger promote_event_waitlist_after_capacity_change
after update of capacity, visibility on public.events
for each row execute function private.promote_event_waitlist();

revoke all on function private.validate_event_capacity() from public;
revoke all on function private.promote_event_waitlist() from public;

drop function public.get_event_attendance(uuid[]);
drop function public.toggle_event_attendance(uuid);
drop function public.get_event_attendees(uuid);

create function public.get_event_attendance(requested_event_ids uuid[])
returns table (
  event_id uuid,
  attendee_count bigint,
  waitlist_count bigint,
  capacity integer,
  viewer_status text
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    e.id,
    count(a.user_id) filter (where a.status = 'attending'),
    count(a.user_id) filter (where a.status = 'waitlisted'),
    e.capacity,
    max(a.status) filter (where a.user_id = (select auth.uid()))
  from public.events e
  left join public.event_attendees a on a.event_id = e.id
  where e.id = any(coalesce(requested_event_ids, array[]::uuid[]))
    and e.status = 'published'
    and private.can_view_event(e.id)
  group by e.id, e.capacity;
$$;

create function public.toggle_event_attendance(requested_event_id uuid)
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
  for update;

  if not found then
    raise exception 'Attendance is only available for public events'
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

create function public.get_event_attendees(requested_event_id uuid)
returns table (
  user_id uuid,
  first_name text,
  avatar_path text,
  status text
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
  select a.user_id, p.first_name, p.avatar_path, a.status
  from public.event_attendees a
  join public.profiles p on p.id = a.user_id
  join public.events e on e.id = a.event_id
  where a.event_id = requested_event_id
    and (
      a.status = 'attending'
      or e.creator_id = (select auth.uid())
    )
  order by
    case a.status when 'attending' then 0 else 1 end,
    a.created_at,
    a.user_id
  limit 200;
end;
$$;

revoke execute on function public.get_event_attendance(uuid[]) from public;
revoke execute on function public.toggle_event_attendance(uuid) from public;
revoke execute on function public.get_event_attendees(uuid) from public;

grant execute on function public.get_event_attendance(uuid[]) to anon, authenticated;
grant execute on function public.toggle_event_attendance(uuid) to authenticated;
grant execute on function public.get_event_attendees(uuid) to anon, authenticated;
