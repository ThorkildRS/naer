drop policy if exists "Event owners delete event images" on storage.objects;

create policy "Event owners delete event images"
on storage.objects for delete
to authenticated
using (
  bucket_id = 'event-images'
  and owner_id = (select auth.uid())::text
);
