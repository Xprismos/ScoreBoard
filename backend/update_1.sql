-- Run once in BOTH Supabase projects, after schema.sql.
create policy "admin manages suggestions" on suggestions for delete using (is_admin());
-- Make sure the website can read and write what the rules allow (harmless if already set)
grant usage on schema public to anon, authenticated;
grant select on all tables in schema public to anon, authenticated;
grant insert on suggestions, mailing_list to anon, authenticated;
grant delete on suggestions to authenticated;
grant usage, select on all sequences in schema public to anon, authenticated;
