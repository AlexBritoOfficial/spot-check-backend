-- Storage for filmer applications: the edited reel and the required raw
-- follow-line clip from FilmerQualify.
--
-- Private, unlike `avatars`: this is unreleased footage somebody is submitting
-- for review, not a public profile picture. Path convention is {user_id}/...,
-- matching the owner-prefix rule already used by spot-photos.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('filmer-portfolio', 'filmer-portfolio', false, 524288000,
        array['video/mp4', 'video/quicktime', 'video/x-m4v'])
on conflict (id) do nothing;

-- Readable by the owner, and by the reviewers who have to watch it (service
-- role, which bypasses RLS). Not world-readable even to signed-in users: a
-- rejected applicant's raw footage is not public.
create policy "filmers read their own portfolio files"
  on storage.objects for select to authenticated
  using (
    bucket_id = 'filmer-portfolio'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "filmers upload under their own prefix"
  on storage.objects for insert to authenticated
  with check (
    bucket_id = 'filmer-portfolio'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "filmers update their own portfolio files"
  on storage.objects for update to authenticated
  using (
    bucket_id = 'filmer-portfolio'
    and (storage.foldername(name))[1] = auth.uid()::text
  );

create policy "filmers delete their own portfolio files"
  on storage.objects for delete to authenticated
  using (
    bucket_id = 'filmer-portfolio'
    and (storage.foldername(name))[1] = auth.uid()::text
  );
