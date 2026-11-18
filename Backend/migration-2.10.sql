-- MicFlow 2.10: short pairing codes for Universal Clipboard, and synced dictation history.
-- Everything stored here is encrypted on the devices; the server only relays it.

-- 1) Pairing: a 6-character code that carries the clipboard key to a new device for 10 minutes.
--    The key is wrapped (encrypted) with the code, so the row alone is not the key. Only the
--    signed-in owner can read their own rows.
create table if not exists public.clipboard_pairings (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  code text not null check (char_length(code) = 6),
  wrapped_key text not null check (length(wrapped_key) <= 400),
  created_at timestamptz not null default now()
);
create index if not exists clipboard_pairings_user_code on public.clipboard_pairings (user_id, code);
alter table public.clipboard_pairings enable row level security;
drop policy if exists "own pairings" on public.clipboard_pairings;
create policy "own pairings" on public.clipboard_pairings for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 2) Dictation history, one encrypted row per dictation (words, text, device, time).
create table if not exists public.dictation_history (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null default auth.uid() references auth.users on delete cascade,
  device text not null,
  device_name text,
  spoken_at timestamptz not null default now(),
  data text not null check (length(data) <= 40000),
  created_at timestamptz not null default now()
);
create index if not exists dictation_history_user_time on public.dictation_history (user_id, spoken_at desc);
alter table public.dictation_history enable row level security;
drop policy if exists "own history" on public.dictation_history;
create policy "own history" on public.dictation_history for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
alter publication supabase_realtime add table public.dictation_history;

-- 3) Nothing waits on the server: clean out leftovers every few minutes, so the server only ever
--    relays. (Needs the pg_cron extension; skipped quietly when it isn't available.)
do $$
begin
  create extension if not exists pg_cron;
  perform cron.schedule('micflow-clean-relay', '*/5 * * * *', $job$
    delete from public.clipboard_items where created_at < now() - interval '10 minutes';
    delete from public.clipboard_pairings where created_at < now() - interval '15 minutes';
  $job$);
exception when others then
  raise notice 'pg_cron not available; the apps still clean up on their own: %', sqlerrm;
end $$;
