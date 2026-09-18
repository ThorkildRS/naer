create table public.event_comments (
  id uuid primary key default gen_random_uuid(),
  event_id uuid not null references public.events (id) on delete cascade,
  author_id uuid not null references public.profiles (id) on delete cascade,
  body text not null check (char_length(btrim(body)) between 1 and 500),
  created_at timestamptz not null default now()
);

create index event_comments_event_created_idx
  on public.event_comments (event_id, created_at, id);

alter table public.event_comments enable row level security;
revoke all on public.event_comments from anon, authenticated;

create function private.can_read_event_comments(requested_event_id uuid)
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
      and e.status = 'published'
      and (
        e.visibility = 'public'
        or e.creator_id = (select auth.uid())
        or exists (
          select 1
          from public.event_invitations i
          where i.event_id = e.id
            and i.invitee_id = (select auth.uid())
            and i.status = 'accepted'
        )
      )
  );
$$;

create function private.can_write_event_comment(requested_event_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select (select auth.uid()) is not null
    and private.can_read_event_comments(requested_event_id);
$$;

create function public.get_event_comments(requested_event_id uuid)
returns table (
  id uuid,
  author_id uuid,
  first_name text,
  avatar_path text,
  body text,
  created_at timestamptz,
  can_delete boolean
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not private.can_read_event_comments(requested_event_id) then
    raise exception 'Comments are not visible for this event'
      using errcode = '42501';
  end if;

  return query
  select
    c.id,
    c.author_id,
    p.first_name,
    p.avatar_path,
    c.body,
    c.created_at,
    (
      c.author_id = (select auth.uid())
      or e.creator_id = (select auth.uid())
    ) as can_delete
  from public.event_comments c
  join public.events e on e.id = c.event_id
  join public.profiles p on p.id = c.author_id
  where c.event_id = requested_event_id
  order by c.created_at, c.id
  limit 200;
end;
$$;

create function public.create_event_comment(
  requested_event_id uuid,
  comment_body text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_comment_id uuid;
begin
  if not private.can_write_event_comment(requested_event_id) then
    raise exception 'You cannot comment on this event'
      using errcode = '42501';
  end if;

  if char_length(btrim(coalesce(comment_body, ''))) not between 1 and 500 then
    raise exception 'Comment must contain between 1 and 500 characters'
      using errcode = '22023';
  end if;

  insert into public.event_comments (event_id, author_id, body)
  values (requested_event_id, (select auth.uid()), btrim(comment_body))
  returning id into new_comment_id;

  return new_comment_id;
end;
$$;

create function public.delete_event_comment(requested_comment_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  delete from public.event_comments c
  using public.events e
  where c.id = requested_comment_id
    and e.id = c.event_id
    and (
      c.author_id = (select auth.uid())
      or e.creator_id = (select auth.uid())
    );

  if not found then
    raise exception 'Comment not found or deletion is not allowed'
      using errcode = '42501';
  end if;
end;
$$;

revoke execute on function private.can_read_event_comments(uuid) from public;
revoke execute on function private.can_write_event_comment(uuid) from public;
revoke execute on function public.get_event_comments(uuid) from public;
revoke execute on function public.create_event_comment(uuid, text) from public;
revoke execute on function public.delete_event_comment(uuid) from public;

grant execute on function public.get_event_comments(uuid) to anon, authenticated;
grant execute on function public.create_event_comment(uuid, text) to authenticated;
grant execute on function public.delete_event_comment(uuid) to authenticated;
