create table public.user_legal_acceptances (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  terms_version text not null,
  privacy_version text not null,
  minimum_age_confirmed boolean not null check (minimum_age_confirmed),
  accepted_at timestamptz not null default now()
);

alter table public.user_legal_acceptances enable row level security;

create policy "Users read their own legal acceptance"
on public.user_legal_acceptances for select
to authenticated
using ((select auth.uid()) = user_id);

grant select on public.user_legal_acceptances to authenticated;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(new.raw_user_meta_data ->> 'terms_version', '') <> '2026-09-18'
    or coalesce(new.raw_user_meta_data ->> 'privacy_version', '') <> '2026-09-18'
    or coalesce((new.raw_user_meta_data ->> 'minimum_age_confirmed')::boolean, false) is not true then
    raise exception 'Current terms, privacy information and minimum age must be accepted'
      using errcode = '22023';
  end if;

  insert into public.profiles (id, first_name, last_name, district)
  values (
    new.id,
    nullif(btrim(new.raw_user_meta_data ->> 'first_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'last_name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'district'), '')
  );

  insert into public.user_legal_acceptances (
    user_id,
    terms_version,
    privacy_version,
    minimum_age_confirmed
  ) values (
    new.id,
    new.raw_user_meta_data ->> 'terms_version',
    new.raw_user_meta_data ->> 'privacy_version',
    true
  );

  return new;
end;
$$;
