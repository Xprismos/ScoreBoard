-- Score Board backend schema for Supabase (Postgres). Run in the SQL editor, once per project (test and live).
-- All money is stored in kobo (1 naira = 100 kobo) as integers.

create table profiles (
  id uuid primary key references auth.users on delete cascade,
  name text, phone text,
  role text not null default 'player' check (role in ('player','admin')),
  balance_kobo bigint not null default 0 check (balance_kobo >= 0),
  created_at timestamptz default now()
);
create table markets (
  id bigserial primary key,
  category text not null, title text not null, source text not null,
  closes_at timestamptz not null,
  status text not null default 'open' check (status in ('open','resolved')),
  winner_option bigint, created_by uuid references profiles(id), created_at timestamptz default now()
);
create table market_options (
  id bigserial primary key,
  market_id bigint not null references markets(id) on delete cascade,
  label text not null, position int not null default 0,
  pool_kobo bigint not null default 0
);
create table picks (
  id bigserial primary key,
  user_id uuid not null references profiles(id),
  market_id bigint not null references markets(id),
  option_id bigint not null references market_options(id),
  stake_kobo bigint not null check (stake_kobo > 0),
  status text not null default 'open' check (status in ('open','won','lost','refund')),
  payout_kobo bigint not null default 0, created_at timestamptz default now()
);
create table wallet_ledger (
  id bigserial primary key,
  user_id uuid not null references profiles(id),
  kind text not null, amount_kobo bigint not null, ref text, created_at timestamptz default now()
);
create table suggestions (id bigserial primary key, user_id uuid, title text not null, category text, note text, status text default 'new', created_at timestamptz default now());
create table mailing_list (email text primary key, created_at timestamptz default now());
create table pools (
  id bigserial primary key, code text unique not null, host_id uuid not null references profiles(id),
  name text not null, question text not null, kind text not null check (kind in ('fun','money')),
  entry_kobo bigint not null default 0, status text not null default 'open', winner_option int
);
create table pool_options (id bigserial primary key, pool_id bigint not null references pools(id) on delete cascade, label text not null, position int not null);
create table pool_members (pool_id bigint references pools(id) on delete cascade, user_id uuid references profiles(id), option_id bigint references pool_options(id), primary key (pool_id, user_id));

create or replace function is_admin() returns boolean language sql stable security definer set search_path = public as
$$ select exists(select 1 from profiles where id = auth.uid() and role = 'admin') $$;

-- Create a profile row when someone signs up
create or replace function handle_new_user() returns trigger language plpgsql security definer set search_path = public as
$$ begin insert into profiles(id, name) values (new.id, new.raw_user_meta_data->>'name'); return new; end $$;
create trigger on_auth_user_created after insert on auth.users for each row execute function handle_new_user();

-- Row level security: the browser can read, but never write money-related tables directly
alter table profiles enable row level security;       create policy "own profile" on profiles for select using (id = auth.uid() or is_admin());
alter table markets enable row level security;        create policy "read markets" on markets for select using (true);
alter table market_options enable row level security; create policy "read options" on market_options for select using (true);
alter table picks enable row level security;          create policy "own picks" on picks for select using (user_id = auth.uid() or is_admin());
alter table wallet_ledger enable row level security;  create policy "own ledger" on wallet_ledger for select using (user_id = auth.uid() or is_admin());
alter table suggestions enable row level security;    create policy "anyone suggests" on suggestions for insert with check (true); create policy "admin reads" on suggestions for select using (is_admin());
alter table mailing_list enable row level security;   create policy "anyone joins" on mailing_list for insert with check (true); create policy "admin reads list" on mailing_list for select using (is_admin());
alter table pools enable row level security;          create policy "read pools" on pools for select using (true);
alter table pool_options enable row level security;   create policy "read pool options" on pool_options for select using (true);
alter table pool_members enable row level security;   create policy "read members" on pool_members for select using (true);

-- Admin posts a market (options is a text array, 2 to 12 items)
create or replace function create_market(p_category text, p_title text, p_source text, p_closes timestamptz, p_options text[]) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; i int;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  if array_length(p_options,1) not between 2 and 12 then raise exception 'need 2 to 12 options'; end if;
  insert into markets(category,title,source,closes_at,created_by) values (p_category,p_title,p_source,p_closes,auth.uid()) returning id into v_id;
  for i in 1..array_length(p_options,1) loop insert into market_options(market_id,label,position) values (v_id,p_options[i],i); end loop;
  return v_id;
end $$;

-- Player places a pick. Time check, balance check and pool update all happen here, never in the browser.
create or replace function place_pick(p_option bigint, p_stake bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_opt market_options; v_m markets; v_bal bigint;
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  if p_stake < 10000 then raise exception 'minimum stake is 100 naira'; end if;
  select * into v_opt from market_options where id = p_option for update;
  select * into v_m from markets where id = v_opt.market_id;
  if v_m.status <> 'open' or now() >= v_m.closes_at then raise exception 'betting closed'; end if;
  select balance_kobo into v_bal from profiles where id = auth.uid() for update;
  if v_bal < p_stake then raise exception 'not enough balance'; end if;
  update profiles set balance_kobo = balance_kobo - p_stake where id = auth.uid();
  update market_options set pool_kobo = pool_kobo + p_stake where id = p_option;
  insert into picks(user_id,market_id,option_id,stake_kobo) values (auth.uid(), v_m.id, p_option, p_stake);
  insert into wallet_ledger(user_id,kind,amount_kobo,ref) values (auth.uid(),'pick',-p_stake,'market:'||v_m.id);
end $$;

-- Admin declares a winner (or null to refund). Safe to call twice: the second call does nothing.
create or replace function resolve_market(p_market bigint, p_option bigint) returns void
language plpgsql security definer set search_path = public as $$
declare v_m markets; v_total bigint; v_w bigint := 0; v_l bigint; r record; v_out bigint;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  select * into v_m from markets where id = p_market for update;
  if v_m.status = 'resolved' then return; end if;
  select coalesce(sum(pool_kobo),0) into v_total from market_options where market_id = p_market;
  if p_option is not null then select pool_kobo into v_w from market_options where id = p_option and market_id = p_market; end if;
  v_l := v_total - coalesce(v_w,0);
  if p_option is null or coalesce(v_w,0) <= 0 or v_l <= 0 then p_option := null; end if;  -- refund case
  for r in select * from picks where market_id = p_market and status = 'open' loop
    if p_option is null then v_out := r.stake_kobo; update picks set status='refund', payout_kobo=v_out where id=r.id;
    elsif r.option_id = p_option then v_out := r.stake_kobo + floor(r.stake_kobo::numeric * v_l * 0.9 / v_w); update picks set status='won', payout_kobo=v_out where id=r.id;
    else v_out := 0; update picks set status='lost', payout_kobo=0 where id=r.id; end if;
    if v_out > 0 then
      update profiles set balance_kobo = balance_kobo + v_out where id = r.user_id;
      insert into wallet_ledger(user_id,kind,amount_kobo,ref) values (r.user_id,'payout',v_out,'market:'||p_market);
    end if;
  end loop;
  update markets set status='resolved', winner_option=p_option where id=p_market;
end $$;

revoke all on function create_market, place_pick, resolve_market from public, anon;
grant execute on function create_market, place_pick, resolve_market to authenticated;

-- Make yourself admin after you sign up (replace the email):
-- update profiles set role='admin' where id = (select id from auth.users where email='you@example.com');
-- Wallet top-ups in live mode must only ever be credited by a payment webhook (service role), never from the browser.
