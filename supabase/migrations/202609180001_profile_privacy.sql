create or replace function private.can_view_full_profile(requested_profile_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
    and (
      requested_profile_id = (select auth.uid())
      or exists (
        select 1
        from public.friendships f
        where (f.user_a = (select auth.uid()) and f.user_b = requested_profile_id)
           or (f.user_b = (select auth.uid()) and f.user_a = requested_profile_id)
      )
      or exists (
        select 1
        from public.friend_requests r
        where r.status = 'pending'
          and (
            (r.sender_id = (select auth.uid()) and r.receiver_id = requested_profile_id)
            or (r.receiver_id = (select auth.uid()) and r.sender_id = requested_profile_id)
          )
      )
    );
$$;

revoke execute on function private.can_view_full_profile(uuid) from public;
grant execute on function private.can_view_full_profile(uuid) to authenticated;

drop policy if exists "Profiles are readable" on public.profiles;
drop policy if exists "Relevant profiles are readable" on public.profiles;

create policy "Relevant profiles are readable"
on public.profiles for select
to authenticated
using (private.can_view_full_profile(id));

revoke select on public.profiles from anon;
grant select on public.profiles to authenticated;

create or replace function public.get_public_profiles(requested_ids uuid[])
returns table (
  id uuid,
  first_name text,
  avatar_path text
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if cardinality(requested_ids) > 100 then
    raise exception 'Too many profiles requested'
      using errcode = '22023';
  end if;

  return query
  select p.id, p.first_name, p.avatar_path
  from public.profiles p
  where p.id = any(coalesce(requested_ids, array[]::uuid[]));
end;
$$;

revoke execute on function public.get_public_profiles(uuid[]) from public;
grant execute on function public.get_public_profiles(uuid[]) to anon, authenticated;

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
    coalesce(nullif(btrim(p.first_name), ''), 'En Appventure-bruker')
  from public.external_invitations x
  join public.events e on e.id = x.event_id
  join public.profiles p on p.id = x.inviter_id
  where x.token_hash = extensions.digest(invitation_token, 'sha256')
    and x.expires_at > now()
    and x.claimed_at is null
  limit 1;
$$;

revoke execute on function public.preview_event_invitation(text) from public;
grant execute on function public.preview_event_invitation(text) to anon, authenticated;
