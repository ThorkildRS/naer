alter table public.events
add column image_preset text not null default 'green'
check (image_preset in ('green', 'yellow', 'blue', 'red'));

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'event-images',
  'event-images',
  false,
  3145728,
  array['image/png', 'image/jpeg', 'image/webp', 'image/gif']
)
on conflict (id) do update
set public = excluded.public,
    file_size_limit = excluded.file_size_limit,
    allowed_mime_types = excluded.allowed_mime_types;

create or replace function private.event_id_from_storage_name(object_name text)
returns uuid
language plpgsql
immutable
set search_path = ''
as $$
begin
  return ((storage.foldername(object_name))[1])::uuid;
exception when invalid_text_representation then
  return null;
end;
$$;

revoke execute on function private.event_id_from_storage_name(text) from public;
grant execute on function private.event_id_from_storage_name(text) to anon, authenticated;

create policy "Visible event images are readable"
on storage.objects for select
using (
  bucket_id = 'event-images'
  and private.can_view_event(private.event_id_from_storage_name(name))
);

create policy "Event owners upload event images"
on storage.objects for insert
to authenticated
with check (
  bucket_id = 'event-images'
  and private.is_event_owner(private.event_id_from_storage_name(name))
);

create policy "Event owners replace event images"
on storage.objects for update
to authenticated
using (
  bucket_id = 'event-images'
  and private.is_event_owner(private.event_id_from_storage_name(name))
)
with check (
  bucket_id = 'event-images'
  and private.is_event_owner(private.event_id_from_storage_name(name))
);

create policy "Event owners delete event images"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'event-images'
  and owner_id = (select auth.uid())::text
);
