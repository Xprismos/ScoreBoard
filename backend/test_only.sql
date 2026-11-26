-- Run ONLY in the TEST Supabase project. Never in the live one.
create or replace function test_topup(p_amount bigint) returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  if p_amount < 10000 then raise exception 'minimum is 100 naira'; end if;
  update profiles set balance_kobo = balance_kobo + p_amount where id = auth.uid();
  insert into wallet_ledger(user_id,kind,amount_kobo,ref) values (auth.uid(),'topup',p_amount,'test');
end $$;

create or replace function reset_my_test_data() returns void language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'login required'; end if;
  update market_options o set pool_kobo = greatest(0, o.pool_kobo - s.t)
    from (select option_id, sum(stake_kobo) t from picks where user_id = auth.uid() and status = 'open' group by option_id) s where o.id = s.option_id;
  delete from picks where user_id = auth.uid();
  delete from wallet_ledger where user_id = auth.uid();
  update profiles set balance_kobo = 0 where id = auth.uid();
end $$;

create or replace function reset_all_test_data() returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  delete from picks; delete from wallet_ledger; delete from markets;
  update profiles set balance_kobo = 0;
end $$;

-- Admin sets the money on each option (amounts in kobo, in option order)
create or replace function test_set_pools(p_market bigint, p_amounts bigint[]) returns void language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'admin only'; end if;
  update market_options set pool_kobo = greatest(0, coalesce(p_amounts[position],0)) where market_id = p_market;
end $$;

create or replace function seed_sample_markets() returns void language plpgsql security definer set search_path = public as $$
declare v bigint;
begin
  if not is_admin() then raise exception 'admin only'; end if;
  v := create_market('Sports','Chelsea vs Liverpool: who wins?','Official league result at full time', now()+interval '20 hours', array['Chelsea','Draw','Liverpool']); perform test_set_pools(v, array[4000000,2000000,3800000]);
  v := create_market('Reality TV','Who wins the season finale?','Winner announced on the live show', now()+interval '44 hours', array['Contestant 1','Contestant 2','Contestant 3','Contestant 4','Contestant 5','Contestant 6']); perform test_set_pools(v, array[900000,500000,1200000,300000,700000,400000]);
  v := create_market('Music','Which song is number one this week?','Official chart published on Friday', now()+interval '68 hours', array['Song A','Song B']); perform test_set_pools(v, array[7000000,3000000]);
  v := create_market('Awards','Who takes Artist of the Year?','Winner announced on award night', now()+interval '90 hours', array['Artist A','Artist B','Artist C']); perform test_set_pools(v, array[6200000,3800000,2100000]);
  v := create_market('Sports','Will the national team win their next match?','Official result after 90 minutes', now()+interval '110 hours', array['Yes','No']); perform test_set_pools(v, array[5800000,4200000]);
  v := create_market('Entertainment','Will the film open at number one?','Official opening weekend box office report', now()+interval '130 hours', array['Yes','No']); perform test_set_pools(v, array[4000000,6000000]);
end $$;

revoke all on function test_topup, reset_my_test_data, reset_all_test_data, test_set_pools, seed_sample_markets from public, anon;
grant execute on function test_topup, reset_my_test_data, reset_all_test_data, test_set_pools, seed_sample_markets to authenticated;
