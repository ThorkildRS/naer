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
        )
      )
  );
$$;

revoke execute on function private.can_view_event(uuid) from public;
grant execute on function private.can_view_event(uuid) to anon, authenticated;
