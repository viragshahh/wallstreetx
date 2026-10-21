-- Wall Street X database schema. Fictional event market only.
-- Do not put Supabase service-role keys in frontend code.
create extension if not exists pgcrypto;

do $$ begin
  create type public.app_role as enum ('admin','recorder');
exception when duplicate_object then null;
end $$;

create table if not exists public.user_roles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  role public.app_role not null default 'recorder',
  created_at timestamptz not null default now()
);

create or replace function public.has_app_role(required_role public.app_role)
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.user_roles where user_id=auth.uid() and role=required_role) $$;

create or replace function public.can_record()
returns boolean language sql stable security definer set search_path=public
as $$ select exists(select 1 from public.user_roles where user_id=auth.uid() and role in ('admin','recorder')) $$;

create table if not exists public.shares (
  symbol text primary key check(symbol ~ '^[A-Z0-9]{2,12}$'),
  name text not null,
  price numeric(14,2) not null check(price>0),
  previous_price numeric(14,2) not null check(previous_price>0),
  volume bigint not null default 0 check(volume>=0),
  updated_at timestamptz not null default now()
);
create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(),
  name text not null unique,
  cash numeric(18,2) not null default 1000000 check(cash>=0),
  holdings jsonb not null default '{}'::jsonb,
  archived boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.round_state (
  id integer primary key default 1 check(id=1),
  round_number integer not null default 1 check(round_number between 1 and 3),
  status text not null default 'waiting' check(status in ('waiting','active','closed')),
  updated_at timestamptz not null default now()
);
insert into public.round_state(id,round_number,status) values(1,1,'waiting') on conflict(id) do nothing;

create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  round_number integer not null check(round_number between 1 and 3),
  share_symbol text not null references public.shares(symbol),
  quantity integer not null check(quantity>0),
  share_price numeric(14,2) not null check(share_price>0),
  total_value numeric(18,2) generated always as (quantity*share_price) stored,
  buyer_team_id uuid not null references public.teams(id),
  seller_team_id uuid not null references public.teams(id),
  buyer_name text not null,
  seller_name text not null,
  recorder_user_id uuid references auth.users(id),
  recorder_email text,
  created_at timestamptz not null default now(),
  check(buyer_team_id<>seller_team_id)
);
create table if not exists public.public_news (
  id uuid primary key default gen_random_uuid(),
  round_number integer not null check(round_number between 1 and 3),
  share_symbol text not null references public.shares(symbol),
  headline text not null,
  body text not null default '',
  published boolean not null default false,
  published_at timestamptz not null default now(),
  resolved boolean not null default false,
  outcome_label text
);
create table if not exists public.news_events (
  id uuid primary key default gen_random_uuid(),
  public_news_id uuid unique references public.public_news(id) on delete set null,
  round_number integer not null check(round_number between 1 and 3),
  share_symbol text not null references public.shares(symbol),
  headline text not null,
  body text not null default '',
  hidden_type text not null check(hidden_type in ('definitely_positive','definitely_negative','somewhat_positive','somewhat_negative')),
  impact_pct numeric(6,2) not null default 0 check(impact_pct between -30 and 30),
  published boolean not null default false,
  resolved boolean not null default false,
  created_at timestamptz not null default now(),
  unique(round_number,hidden_type),
  check((hidden_type='definitely_positive' and impact_pct>0) or (hidden_type='definitely_negative' and impact_pct<0) or (hidden_type in ('somewhat_positive','somewhat_negative') and impact_pct=0))
);

alter table public.user_roles enable row level security;
alter table public.shares enable row level security;
alter table public.teams enable row level security;
alter table public.round_state enable row level security;
alter table public.transactions enable row level security;
alter table public.public_news enable row level security;
alter table public.news_events enable row level security;

drop policy if exists "roles self or admin read" on public.user_roles;
create policy "roles self or admin read" on public.user_roles for select using(user_id=auth.uid() or public.has_app_role('admin'));
drop policy if exists "shares public read" on public.shares;
create policy "shares public read" on public.shares for select using(true);
drop policy if exists "shares admin manage" on public.shares;
create policy "shares admin manage" on public.shares for all using(public.has_app_role('admin')) with check(public.has_app_role('admin'));
drop policy if exists "teams public read" on public.teams;
create policy "teams public read" on public.teams for select using(true);
drop policy if exists "teams admin manage" on public.teams;
create policy "teams admin manage" on public.teams for all using(public.has_app_role('admin')) with check(public.has_app_role('admin'));
drop policy if exists "round public read" on public.round_state;
create policy "round public read" on public.round_state for select using(true);
drop policy if exists "round admin manage" on public.round_state;
create policy "round admin manage" on public.round_state for all using(public.has_app_role('admin')) with check(public.has_app_role('admin'));
drop policy if exists "transactions public read" on public.transactions;
create policy "transactions public read" on public.transactions for select using(true);
drop policy if exists "public news read published" on public.public_news;
create policy "public news read published" on public.public_news for select using(published=true);
drop policy if exists "public news admin manage" on public.public_news;
create policy "public news admin manage" on public.public_news for all using(public.has_app_role('admin')) with check(public.has_app_role('admin'));
drop policy if exists "hidden events admin only" on public.news_events;
create policy "hidden events admin only" on public.news_events for all using(public.has_app_role('admin')) with check(public.has_app_role('admin'));

create or replace function public.execute_trade(
 p_share_symbol text, p_quantity integer, p_share_price numeric,
 p_seller_team_id uuid, p_buyer_team_id uuid
) returns uuid language plpgsql security definer set search_path=public as $$
declare
 v_round public.round_state%rowtype; v_share public.shares%rowtype;
 v_buyer public.teams%rowtype; v_seller public.teams%rowtype;
 v_total numeric(18,2); v_seller_qty numeric; v_id uuid;
begin
 if not public.can_record() then raise exception 'Recorder or admin login required'; end if;
 if p_quantity is null or p_quantity<=0 or p_share_price is null or p_share_price<=0 then raise exception 'Quantity and price must be positive'; end if;
 if p_buyer_team_id=p_seller_team_id then raise exception 'Buyer and seller must be different teams'; end if;
 select * into v_round from public.round_state where id=1 for update;
 if v_round.status<>'active' then raise exception 'Trading is not open'; end if;
 select * into v_share from public.shares where symbol=p_share_symbol for update;
 if not found then raise exception 'Share not found'; end if;
 perform 1 from public.teams where id in (p_buyer_team_id,p_seller_team_id) order by id for update;
 select * into v_buyer from public.teams where id=p_buyer_team_id and archived=false;
 select * into v_seller from public.teams where id=p_seller_team_id and archived=false;
 if v_buyer.id is null or v_seller.id is null then raise exception 'Buyer or seller team not found/archived'; end if;
 v_total:=round(p_quantity*p_share_price,2);
 if v_buyer.cash<v_total then raise exception 'Buyer has insufficient cash'; end if;
 v_seller_qty:=coalesce((v_seller.holdings->>p_share_symbol)::numeric,0);
 if v_seller_qty<p_quantity then raise exception 'Seller has insufficient shares'; end if;
 update public.teams set cash=cash-v_total, holdings=jsonb_set(holdings,array[p_share_symbol],to_jsonb(coalesce((holdings->>p_share_symbol)::integer,0)+p_quantity),true) where id=p_buyer_team_id;
 update public.teams set cash=cash+v_total, holdings=jsonb_set(holdings,array[p_share_symbol],to_jsonb(v_seller_qty-p_quantity),true) where id=p_seller_team_id;
 -- Last executed trade sets the displayed market price, and prior price is retained for movement display.
 update public.shares set previous_price=price,price=round(p_share_price,2),volume=volume+p_quantity,updated_at=now() where symbol=p_share_symbol;
 insert into public.transactions(round_number,share_symbol,quantity,share_price,buyer_team_id,seller_team_id,buyer_name,seller_name,recorder_user_id,recorder_email)
 values(v_round.round_number,p_share_symbol,p_quantity,round(p_share_price,2),p_buyer_team_id,p_seller_team_id,v_buyer.name,v_seller.name,auth.uid(),auth.jwt()->>'email') returning id into v_id;
 return v_id;
end $$;

create or replace function public.publish_news_event(p_event_id uuid) returns uuid
language plpgsql security definer set search_path=public as $$
declare e public.news_events%rowtype; n_id uuid;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 select * into e from public.news_events where id=p_event_id for update;
 if not found or e.published then raise exception 'News event not found or already published'; end if;
 insert into public.public_news(round_number,share_symbol,headline,body,published,published_at)
 values(e.round_number,e.share_symbol,e.headline,e.body,true,now()) returning id into n_id;
 update public.news_events set published=true,public_news_id=n_id where id=p_event_id;
 return n_id;
end $$;

create or replace function public.resolve_news_event(p_event_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare e public.news_events%rowtype; label text;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 select * into e from public.news_events where id=p_event_id for update;
 if not found or not e.published or e.resolved then raise exception 'Publish the news first; unresolved event required'; end if;
 if e.hidden_type='definitely_positive' then label:='Positive outcome';
 elsif e.hidden_type='definitely_negative' then label:='Negative outcome';
 elsif e.hidden_type='somewhat_positive' then label:='Somewhat positive outcome · no price adjustment';
 else label:='Somewhat negative outcome · no price adjustment'; end if;
 if e.impact_pct<>0 then update public.shares set previous_price=price,price=round(price*(1+e.impact_pct/100),2),updated_at=now() where symbol=e.share_symbol; end if;
 update public.news_events set resolved=true where id=p_event_id;
 update public.public_news set resolved=true,outcome_label=label where id=e.public_news_id;
end $$;

grant execute on function public.execute_trade(text,integer,numeric,uuid,uuid) to authenticated;
grant execute on function public.publish_news_event(uuid) to authenticated;
grant execute on function public.resolve_news_event(uuid) to authenticated;
grant execute on function public.has_app_role(public.app_role) to anon,authenticated;
grant execute on function public.can_record() to anon,authenticated;

insert into public.shares(symbol,name,price,previous_price,volume) values
 ('AURA','Aura Mobility',248.50,248.50,0),('NOVA','Nova Energy Systems',516.20,516.20,0),
 ('VYBE','Vybe Consumer Labs',132.75,132.75,0),('ORBT','Orbit Digital',384.40,384.40,0),
 ('KLYR','Klyr Healthcare',692.10,692.10,0) on conflict(symbol) do nothing;
insert into public.teams(name,cash,holdings) values
 ('Team Alpha',1000000,'{}'::jsonb),('Team Beta',1000000,'{}'::jsonb),('Team Gamma',1000000,'{}'::jsonb)
 on conflict(name) do nothing;
insert into public.news_events(round_number,share_symbol,headline,body,hidden_type,impact_pct) values
 (1,'AURA','A supplier timetable is being revisited ahead of the next production window.','Management says contingency planning remains part of normal operations.','definitely_positive',8),
 (1,'NOVA','A scheduled review has shifted attention toward near-term operating flexibility.','The company declined to comment on individual project milestones.','definitely_negative',-8),
 (1,'VYBE','Retail partners are testing a revised display format in selected locations.','The pilot is limited and no rollout date has been announced.','somewhat_positive',0),
 (1,'ORBT','A customer renewal process is taking longer than the usual cycle.','The company says discussions remain ongoing and declined to quantify exposure.','somewhat_negative',0),
 (2,'ORBT','A platform migration has reached a new internal checkpoint.','The next phase depends on partner readiness and routine validation.','definitely_positive',8),
 (2,'KLYR','A planned facility review has introduced a tighter operating timetable.','No change to the published annual guidance was announced.','definitely_negative',-8),
 (2,'AURA','Dealers are reviewing the mix of models displayed for the coming month.','The review is part of the regular channel planning cycle.','somewhat_positive',0),
 (2,'NOVA','One project milestone is now expected to be discussed at a later meeting.','The company did not provide a revised completion estimate.','somewhat_negative',0),
 (3,'KLYR','A quality review has cleared an internal stage, with routine checks continuing.','The company has not changed its public product timetable.','definitely_positive',8),
 (3,'VYBE','A distribution partner has requested additional documentation before sign-off.','Both parties describe the process as part of standard governance.','definitely_negative',-8),
 (3,'NOVA','A regional team is assessing a different sequence for planned site visits.','No investment decision has been announced.','somewhat_positive',0),
 (3,'ORBT','A prospective customer has asked for a longer evaluation period.','The existing trial continues while both sides review requirements.','somewhat_negative',0)
 on conflict(round_number,hidden_type) do nothing;

-- Enable realtime change notifications for the public dashboard.
do $$ begin alter publication supabase_realtime add table public.shares; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.teams; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.transactions; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.public_news; exception when duplicate_object then null; when undefined_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.round_state; exception when duplicate_object then null; when undefined_object then null; end $$;


-- ===== Simplified event setup (also applied to the live project) =====
-- Reset the unstarted demo seed to the real event universe.
delete from public.public_news;
delete from public.news_events;
delete from public.transactions;
delete from public.teams where name <> 'Organizer Inventory';
delete from public.shares;

alter table public.round_state drop constraint if exists round_state_round_number_check;
alter table public.round_state alter column round_number set default 0;
alter table public.round_state add constraint round_state_round_number_check check (round_number between 0 and 3);
alter table public.transactions drop constraint if exists transactions_round_number_check;
alter table public.transactions add constraint transactions_round_number_check check (round_number between 0 and 3);
alter table public.news_events drop constraint if exists news_events_round_number_check;
alter table public.news_events add constraint news_events_round_number_check check (round_number between 1 and 3);
alter table public.news_events drop constraint if exists news_events_round_number_hidden_type_key;
alter table public.news_events drop constraint if exists news_events_hidden_type_impact_pct_check;

insert into public.shares(symbol,name,price,previous_price,volume) values
 ('RELIANCE','Reliance Industries',1400,1400,0),('TATAMOTORS','Tata Motors',700,700,0),
 ('AIRTEL','Bharti Airtel',1200,1200,0),('HDFCBANK','HDFC Bank',1700,1700,0),('ONGC','ONGC',250,250,0);

insert into public.teams(name,cash,holdings,archived) values
 ('Organizer Inventory',0,'{"RELIANCE":1000000,"TATAMOTORS":1000000,"AIRTEL":1000000,"HDFCBANK":1000000,"ONGC":1000000}'::jsonb,false),
 ('Team 1',1000000,'{}'::jsonb,false),('Team 2',1000000,'{}'::jsonb,false),
 ('Team 3',1000000,'{}'::jsonb,false),('Team 4',1000000,'{}'::jsonb,false),
 ('Team 5',1000000,'{}'::jsonb,false),('Team 6',1000000,'{}'::jsonb,false),
 ('Team 7',1000000,'{}'::jsonb,false),('Team 8',1000000,'{}'::jsonb,false),
 ('Team 9',1000000,'{}'::jsonb,false),('Team 10',1000000,'{}'::jsonb,false)
on conflict(name) do update set cash=excluded.cash,holdings=excluded.holdings,archived=false;

insert into public.news_events(round_number,share_symbol,headline,body,hidden_type,impact_pct) values
(1,'RELIANCE','Reliance Industries signals stronger-than-expected retail and digital momentum.','Investor attention turns to the outlook for consumer businesses and digital services.','definitely_positive',8),
(1,'TATAMOTORS','Tata Motors faces fresh questions about near-term demand in a key overseas market.','Dealers are watching order trends and the company’s response to changing demand.','definitely_negative',-8),
(1,'AIRTEL','Bharti Airtel expands its 5G coverage in several high-traffic urban clusters.','The expansion may support customer experience while requiring continued network investment.','somewhat_positive',0),
(1,'HDFCBANK','HDFC Bank reports steady deposit growth as competition for savings intensifies.','The market is assessing the balance between deposit mobilisation and margins.','somewhat_negative',0),
(1,'ONGC','ONGC reviews its near-term capital spending plan amid changing crude-price expectations.','Management has not announced a change to its longer-term production priorities.','somewhat_positive',0),
(2,'RELIANCE','Reliance announces a delay in a major project milestone as costs are reassessed.','The revised schedule could shift the timing of expected project benefits.','definitely_negative',-8),
(2,'TATAMOTORS','Tata Motors receives encouraging bookings for a newly refreshed vehicle range.','Dealers report stronger customer enquiries ahead of the next delivery cycle.','definitely_positive',8),
(2,'AIRTEL','Bharti Airtel sees stable subscriber additions while industry pricing remains competitive.','Analysts are watching average revenue per user and network spending.','somewhat_positive',0),
(2,'HDFCBANK','HDFC Bank increases provisions as it takes a cautious view of selected loan segments.','The move is described as prudent risk management, with no broad stress signal disclosed.','somewhat_negative',0),
(2,'ONGC','ONGC reports an operational interruption at one production facility.','The company is assessing the duration and expected production impact.','definitely_negative',-8),
(3,'RELIANCE','Reliance reports progress on a strategic partnership supporting its new-energy plans.','The next phase depends on execution milestones and commercial ramp-up.','somewhat_positive',0),
(3,'TATAMOTORS','Tata Motors outlines a stronger cost-control plan following a margin review.','Investors are assessing whether the plan can offset input-cost pressures.','somewhat_positive',0),
(3,'AIRTEL','Bharti Airtel announces a broad network investment programme to accelerate coverage.','The spending is intended to improve capacity but may weigh on near-term cash flow.','definitely_negative',-8),
(3,'HDFCBANK','HDFC Bank reports improved operating efficiency and resilient asset quality.','The update supports confidence in execution and the quality of the loan book.','definitely_positive',8),
(3,'ONGC','ONGC benefits from a favourable production update at a key asset.','The update improves the near-term operating outlook, subject to commodity-price volatility.','somewhat_positive',0);

update public.round_state set round_number=0,status='waiting',updated_at=now() where id=1;
insert into public.round_state(id,round_number,status) values(1,0,'waiting') on conflict(id) do nothing;

create or replace function public.execute_trade(
 p_share_symbol text, p_quantity integer, p_share_price numeric,
 p_seller_team_id uuid, p_buyer_team_id uuid
) returns uuid language plpgsql security definer set search_path=public as $$
declare v_round public.round_state%rowtype; v_share public.shares%rowtype;
 v_buyer public.teams%rowtype; v_seller public.teams%rowtype;
 v_total numeric(18,2); v_seller_qty numeric; v_id uuid; v_buyer_count integer; v_seller_count integer;
begin
 if p_quantity is null or p_quantity<=0 or p_share_price is null or p_share_price<=0 then raise exception 'Quantity and price must be positive'; end if;
 if p_buyer_team_id=p_seller_team_id then raise exception 'Buyer and seller must be different teams'; end if;
 select * into v_round from public.round_state where id=1 for update;
 if v_round.status<>'active' then raise exception 'Trading is not open'; end if;
 select * into v_share from public.shares where symbol=p_share_symbol for update;
 if not found then raise exception 'Share not found'; end if;
 perform 1 from public.teams where id in (p_buyer_team_id,p_seller_team_id) order by id for update;
 select * into v_buyer from public.teams where id=p_buyer_team_id and archived=false;
 select * into v_seller from public.teams where id=p_seller_team_id and archived=false;
 if v_buyer.id is null or v_seller.id is null then raise exception 'Buyer or seller team not found/archived'; end if;
 if v_round.round_number=0 and v_seller.name<>'Organizer Inventory' then raise exception 'Round 0 shares must be bought from the organizer'; end if;
 if v_round.round_number>0 and (v_seller.name='Organizer Inventory' or v_buyer.name='Organizer Inventory') then raise exception 'Organizer sales are only allowed in Round 0'; end if;
 if v_buyer.name='Organizer Inventory' then raise exception 'Organizer Inventory cannot buy shares'; end if;
 if v_buyer.name<>'Organizer Inventory' then
  select count(*) into v_buyer_count from public.transactions where round_number=v_round.round_number and (buyer_team_id=v_buyer.id or seller_team_id=v_buyer.id);
  if v_buyer_count>=3 then raise exception '% has already used all 3 transactions this round',v_buyer.name; end if;
 end if;
 if v_seller.name<>'Organizer Inventory' then
  select count(*) into v_seller_count from public.transactions where round_number=v_round.round_number and (buyer_team_id=v_seller.id or seller_team_id=v_seller.id);
  if v_seller_count>=3 then raise exception '% has already used all 3 transactions this round',v_seller.name; end if;
 end if;
 v_total:=round(p_quantity*p_share_price,2);
 if v_buyer.cash<v_total then raise exception 'Buyer has insufficient cash'; end if;
 v_seller_qty:=coalesce((v_seller.holdings->>p_share_symbol)::numeric,0);
 if v_seller_qty<p_quantity then raise exception 'Seller has insufficient shares'; end if;
 update public.teams set cash=cash-v_total,holdings=jsonb_set(holdings,array[p_share_symbol],to_jsonb(coalesce((holdings->>p_share_symbol)::integer,0)+p_quantity),true) where id=p_buyer_team_id;
 update public.teams set cash=cash+v_total,holdings=jsonb_set(holdings,array[p_share_symbol],to_jsonb(v_seller_qty-p_quantity),true) where id=p_seller_team_id;
 update public.shares set previous_price=price,price=round(p_share_price,2),volume=volume+p_quantity,updated_at=now() where symbol=p_share_symbol;
 insert into public.transactions(round_number,share_symbol,quantity,share_price,buyer_team_id,seller_team_id,buyer_name,seller_name,recorder_user_id,recorder_email)
 values(v_round.round_number,p_share_symbol,p_quantity,round(p_share_price,2),p_buyer_team_id,p_seller_team_id,v_buyer.name,v_seller.name,auth.uid(),auth.jwt()->>'email') returning id into v_id;
 return v_id;
end $$;

create or replace function public.start_round() returns integer language plpgsql security definer set search_path=public as $$
declare r public.round_state%rowtype; n integer;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 select * into r from public.round_state where id=1 for update;
 if r.status='active' then raise exception 'Close the current round before starting another'; end if;
 if r.round_number>=3 and r.status='closed' then raise exception 'All rounds are complete'; end if;
 if r.status='closed' then update public.round_state set round_number=round_number+1,status='active',updated_at=now() where id=1 returning round_number into r.round_number;
 else update public.round_state set status='active',updated_at=now() where id=1; end if;
 if r.round_number>0 then
  insert into public.public_news(round_number,share_symbol,headline,body,published,published_at)
  select e.round_number,e.share_symbol,e.headline,e.body,true,now() from public.news_events e
  where e.round_number=r.round_number and not exists(select 1 from public.public_news p where p.round_number=e.round_number and p.share_symbol=e.share_symbol and p.headline=e.headline);
 end if;
 select count(*) into n from public.news_events where round_number=r.round_number;
 return r.round_number;
end $$;

create or replace function public.close_round() returns integer language plpgsql security definer set search_path=public as $$
declare r public.round_state%rowtype;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 select * into r from public.round_state where id=1 for update;
 if r.status<>'active' then raise exception 'No active round to close'; end if;
 update public.round_state set status='closed',updated_at=now() where id=1;
 return r.round_number;
end $$;
grant execute on function public.execute_trade(text,integer,numeric,uuid,uuid) to anon,authenticated;
revoke all on function public.start_round() from public, anon;
revoke all on function public.close_round() from public, anon;
grant execute on function public.start_round() to authenticated;
grant execute on function public.close_round() to authenticated;


-- ===== Five-round extension and capped close-round adjustments =====
alter table public.round_state drop constraint if exists round_state_round_number_check;
alter table public.round_state add constraint round_state_round_number_check check (round_number between 0 and 4);
alter table public.transactions drop constraint if exists transactions_round_number_check;
alter table public.transactions add constraint transactions_round_number_check check (round_number between 0 and 4);
alter table public.news_events drop constraint if exists news_events_round_number_check;
alter table public.news_events add constraint news_events_round_number_check check (round_number between 1 and 4);

create table if not exists public.round_price_snapshots (
  round_number integer not null check (round_number between 0 and 4),
  share_symbol text not null references public.shares(symbol) on update cascade on delete cascade,
  opening_price numeric(18,2) not null check (opening_price > 0),
  created_at timestamptz not null default now(),
  primary key (round_number, share_symbol)
);
alter table public.round_price_snapshots enable row level security;

insert into public.news_events(round_number,share_symbol,headline,body,hidden_type,impact_pct) values
(4,'RELIANCE','Reliance gains a major distribution partnership, though rollout will take time.','Investors must judge the long-term opportunity against near-term execution costs.','definitely_positive',8),
(4,'TATAMOTORS','Tata Motors flags higher launch and warranty costs in its latest operating review.','The cost impact may be temporary, but margins need close monitoring.','definitely_negative',-8),
(4,'AIRTEL','Bharti Airtel sees improving data usage while network investment remains elevated.','The update is constructive but does not guarantee immediate margin expansion.','somewhat_positive',0),
(4,'HDFCBANK','HDFC Bank faces closer scrutiny of deposit pricing and near-term margin trends.','The market is weighing competitive pressure against the bank’s funding franchise.','somewhat_negative',0),
(4,'ONGC','ONGC reports steadier output at a key asset as commodity prices remain volatile.','Operational progress is encouraging, though revenue still depends on market prices.','somewhat_positive',0)
on conflict do nothing;

create or replace function public.start_round() returns integer
language plpgsql security definer set search_path=public as $$
declare r public.round_state%rowtype;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 select * into r from public.round_state where id=1 for update;
 if r.status='active' then raise exception 'Close the current round before starting another'; end if;
 if r.round_number>=4 and r.status='closed' then raise exception 'All rounds are complete'; end if;
 if r.status='closed' then
   update public.round_state set round_number=round_number+1,status='active',updated_at=now()
   where id=1 returning * into r;
 else
   update public.round_state set status='active',updated_at=now() where id=1 returning * into r;
 end if;
 insert into public.round_price_snapshots(round_number,share_symbol,opening_price)
 select r.round_number,s.symbol,s.price from public.shares s
 on conflict(round_number,share_symbol) do update set opening_price=excluded.opening_price,created_at=now();
 if r.round_number>0 then
   insert into public.public_news(round_number,share_symbol,headline,body,published,published_at)
   select e.round_number,e.share_symbol,e.headline,e.body,true,now()
   from public.news_events e
   where e.round_number=r.round_number
     and not exists(select 1 from public.public_news p where p.round_number=e.round_number and p.share_symbol=e.share_symbol and p.headline=e.headline);
   update public.news_events set published=true where round_number=r.round_number;
 end if;
 return r.round_number;
end $$;

create or replace function public.close_round() returns integer
language plpgsql security definer set search_path=public as $$
declare r public.round_state%rowtype; e public.news_events%rowtype;
        v_open numeric(18,2); v_current numeric(18,2); v_target numeric(18,2);
        v_effect numeric; v_label text;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 select * into r from public.round_state where id=1 for update;
 if r.status<>'active' then raise exception 'No active round to close'; end if;
 if r.round_number between 1 and 4 then
   for e in select * from public.news_events where round_number=r.round_number and published=true and resolved=false order by share_symbol for update
   loop
     select opening_price into v_open from public.round_price_snapshots where round_number=r.round_number and share_symbol=e.share_symbol;
     select price into v_current from public.shares where symbol=e.share_symbol for update;
     if v_open is null then v_open:=v_current; end if;
     v_effect:=greatest(-6.0,least(6.0,e.impact_pct*0.75));
     v_target:=round(v_current*(1+v_effect/100.0),2);
     v_target:=greatest(round(v_open*0.92,2),least(round(v_open*1.08,2),v_target));
     update public.shares set previous_price=price,price=v_target,updated_at=now() where symbol=e.share_symbol;
     if e.hidden_type='definitely_positive' then v_label:='Positive outcome · dampened price adjustment';
     elsif e.hidden_type='definitely_negative' then v_label:='Negative outcome · dampened price adjustment';
     elsif e.hidden_type='somewhat_positive' then v_label:='Somewhat positive outcome · no direct news adjustment';
     else v_label:='Somewhat negative outcome · no direct news adjustment'; end if;
     update public.news_events set resolved=true where id=e.id;
     update public.public_news set resolved=true,outcome_label=v_label
       where round_number=e.round_number and share_symbol=e.share_symbol and headline=e.headline;
   end loop;
 end if;
 update public.round_state set status='closed',updated_at=now() where id=1;
 return r.round_number;
end $$;

create or replace function public.resolve_news_event(p_event_id uuid) returns void
language plpgsql security definer set search_path=public as $$
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 raise exception 'News outcomes and capped price adjustments are applied automatically when the round closes.';
end $$;

revoke all on function public.start_round() from public, anon;
revoke all on function public.close_round() from public, anon;
grant execute on function public.start_round() to authenticated;
grant execute on function public.close_round() to authenticated;
grant execute on function public.resolve_news_event(uuid) to authenticated;


-- ===== Admin reset controls and transaction deletion =====
create or replace function public.admin_delete_transaction(p_transaction_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare t public.transactions%rowtype; v_buyer public.teams%rowtype; v_seller public.teams%rowtype;
        v_buyer_qty integer; v_seller_qty integer;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 select * into t from public.transactions where id=p_transaction_id for update;
 if not found then raise exception 'Transaction not found'; end if;
 select * into v_buyer from public.teams where id=t.buyer_team_id for update;
 select * into v_seller from public.teams where id=t.seller_team_id for update;
 if v_buyer.id is null or v_seller.id is null then raise exception 'Cannot reverse: buyer or seller team no longer exists'; end if;
 v_buyer_qty:=coalesce((v_buyer.holdings->>t.share_symbol)::integer,0);
 v_seller_qty:=coalesce((v_seller.holdings->>t.share_symbol)::integer,0);
 if v_buyer_qty<t.quantity then raise exception 'Cannot delete: buyer no longer holds enough of this share to reverse the transaction'; end if;
 update public.teams set cash=cash+t.total_value,
   holdings=jsonb_set(holdings,array[t.share_symbol],to_jsonb(v_buyer_qty-t.quantity),true) where id=t.buyer_team_id;
 update public.teams set cash=cash-t.total_value,
   holdings=jsonb_set(holdings,array[t.share_symbol],to_jsonb(v_seller_qty+t.quantity),true) where id=t.seller_team_id;
 update public.shares set volume=greatest(0,volume-t.quantity),updated_at=now() where symbol=t.share_symbol;
 delete from public.transactions where id=p_transaction_id;
end $$;

create or replace function public.admin_reset_round()
returns integer language plpgsql security definer set search_path=public as $$
declare r public.round_state%rowtype; t public.transactions%rowtype;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 select * into r from public.round_state where id=1 for update;
 for t in select * from public.transactions where round_number=r.round_number order by created_at desc for update
 loop
   update public.teams set cash=cash+t.total_value,
     holdings=jsonb_set(holdings,array[t.share_symbol],to_jsonb(greatest(0,coalesce((holdings->>t.share_symbol)::integer,0)-t.quantity)),true) where id=t.buyer_team_id;
   update public.teams set cash=cash-t.total_value,
     holdings=jsonb_set(holdings,array[t.share_symbol],to_jsonb(coalesce((holdings->>t.share_symbol)::integer,0)+t.quantity),true) where id=t.seller_team_id;
   update public.shares set volume=greatest(0,volume-t.quantity) where symbol=t.share_symbol;
 end loop;
 delete from public.transactions where round_number=r.round_number;
 update public.shares s set price=sn.opening_price,previous_price=sn.opening_price,updated_at=now()
 from public.round_price_snapshots sn where sn.round_number=r.round_number and sn.share_symbol=s.symbol;
 update public.news_events set resolved=false where round_number=r.round_number;
 update public.public_news set resolved=false,outcome_label=null where round_number=r.round_number;
 update public.round_state set status='active',updated_at=now() where id=1;
 return r.round_number;
end $$;

create or replace function public.admin_complete_reset()
returns void language plpgsql security definer set search_path=public as $$
declare t public.transactions%rowtype;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 perform 1 from public.round_state where id=1 for update;
 for t in select * from public.transactions order by created_at desc for update
 loop
   update public.teams set cash=cash+t.total_value,
     holdings=jsonb_set(holdings,array[t.share_symbol],to_jsonb(greatest(0,coalesce((holdings->>t.share_symbol)::integer,0)-t.quantity)),true) where id=t.buyer_team_id;
   update public.teams set cash=cash-t.total_value,
     holdings=jsonb_set(holdings,array[t.share_symbol],to_jsonb(coalesce((holdings->>t.share_symbol)::integer,0)+t.quantity),true) where id=t.seller_team_id;
 end loop;
 delete from public.transactions;
 update public.shares s set
   price=coalesce((select sn.opening_price from public.round_price_snapshots sn where sn.round_number=0 and sn.share_symbol=s.symbol),s.price),
   previous_price=coalesce((select sn.opening_price from public.round_price_snapshots sn where sn.round_number=0 and sn.share_symbol=s.symbol),s.price),
   volume=0,updated_at=now();
 delete from public.round_price_snapshots;
 update public.news_events set published=false,resolved=false,public_news_id=null;
 delete from public.public_news;
 update public.round_state set round_number=0,status='waiting',updated_at=now() where id=1;
end $$;

revoke all on function public.admin_delete_transaction(uuid) from public, anon;
revoke all on function public.admin_reset_round() from public, anon;
revoke all on function public.admin_complete_reset() from public, anon;
grant execute on function public.admin_delete_transaction(uuid) to authenticated;
grant execute on function public.admin_reset_round() to authenticated;
grant execute on function public.admin_complete_reset() to authenticated;

-- Corrected reset implementation: net ledger reversals avoid temporary cash constraint failures.
create or replace function public.admin_complete_reset()
returns void language plpgsql security definer set search_path=public as $$
declare x record; v_base numeric(18,2);
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 perform 1 from public.round_state where id=1 for update;
 update public.teams tm set cash=tm.cash
   + coalesce((select sum(t.total_value) from public.transactions t where t.buyer_team_id=tm.id),0)
   - coalesce((select sum(t.total_value) from public.transactions t where t.seller_team_id=tm.id),0);
 for x in
   select team_id, share_symbol, sum(qty_delta)::integer as qty_delta
   from (
     select buyer_team_id as team_id, share_symbol, -quantity as qty_delta from public.transactions
     union all
     select seller_team_id as team_id, share_symbol, quantity as qty_delta from public.transactions
   ) d group by team_id, share_symbol
 loop
   update public.teams set holdings=jsonb_set(holdings,array[x.share_symbol],
     to_jsonb(greatest(0,coalesce((holdings->>x.share_symbol)::integer,0)+x.qty_delta)),true)
   where id=x.team_id;
 end loop;
 delete from public.transactions;
 for x in select symbol from public.shares loop
   select opening_price into v_base from public.round_price_snapshots where round_number=0 and share_symbol=x.symbol;
   if v_base is not null then
     update public.shares set price=v_base,previous_price=v_base,volume=0,updated_at=now() where symbol=x.symbol;
   else
     update public.shares set previous_price=price,volume=0,updated_at=now() where symbol=x.symbol;
   end if;
 end loop;
 update public.news_events set published=false,resolved=false,public_news_id=null;
 delete from public.public_news;
 delete from public.round_price_snapshots;
 update public.round_state set round_number=0,status='waiting',updated_at=now() where id=1;
end $$;
revoke all on function public.admin_complete_reset() from public, anon;
grant execute on function public.admin_complete_reset() to authenticated;


-- ===== Ledger reconciliation and exact reset baselines (2026-10) =====
alter table public.teams add column if not exists starting_cash numeric(18,2);
alter table public.teams add column if not exists starting_holdings jsonb;
update public.teams set starting_cash=coalesce(starting_cash,cash), starting_holdings=coalesce(starting_holdings,holdings)
where starting_cash is null or starting_holdings is null;
alter table public.teams alter column starting_cash set default 1000000;
alter table public.teams alter column starting_cash set not null;
alter table public.teams alter column starting_holdings set default '{}'::jsonb;
alter table public.teams alter column starting_holdings set not null;

alter table public.shares add column if not exists starting_price numeric(14,2);
update public.shares set starting_price=case symbol
 when 'RELIANCE' then 1400.00 when 'TATAMOTORS' then 700.00
 when 'AIRTEL' then 1200.00 when 'HDFCBANK' then 1700.00 when 'ONGC' then 250.00
 else price end where starting_price is null;
alter table public.shares alter column starting_price set not null;

create or replace function public.capture_team_starting_state()
returns trigger language plpgsql set search_path=public as $$
begin
 new.starting_cash:=new.cash;
 new.starting_holdings:=new.holdings;
 return new;
end $$;
drop trigger if exists teams_capture_starting_state on public.teams;
create trigger teams_capture_starting_state before insert on public.teams
for each row execute function public.capture_team_starting_state();

create or replace function public.capture_share_starting_price()
returns trigger language plpgsql set search_path=public as $$
begin
 if new.starting_price is null then new.starting_price:=new.price; end if;
 return new;
end $$;
drop trigger if exists shares_capture_starting_price on public.shares;
create trigger shares_capture_starting_price before insert on public.shares
for each row execute function public.capture_share_starting_price();

create or replace function public.rebuild_team_ledgers()
returns void language plpgsql security definer set search_path=public as $$
begin
 update public.teams tm
 set cash=tm.starting_cash
   - coalesce((select sum(t.total_value) from public.transactions t where t.buyer_team_id=tm.id),0)
   + coalesce((select sum(t.total_value) from public.transactions t where t.seller_team_id=tm.id),0),
 holdings=coalesce((
   select jsonb_object_agg(vals.sym,vals.qty)
   from (
     select keys.sym,
       greatest(0,coalesce((tm.starting_holdings->>keys.sym)::integer,0)+coalesce(flows.net_qty,0))::integer as qty
     from (
       select jsonb_object_keys(tm.starting_holdings) as sym
       union
       select distinct share_symbol from public.transactions where buyer_team_id=tm.id or seller_team_id=tm.id
     ) keys
     left join (
       select share_symbol,sum(qty_delta)::integer as net_qty
       from (
         select share_symbol,quantity as qty_delta from public.transactions where buyer_team_id=tm.id
         union all
         select share_symbol,-quantity as qty_delta from public.transactions where seller_team_id=tm.id
       ) f group by share_symbol
     ) flows on flows.share_symbol=keys.sym
   ) vals
 ),'{}'::jsonb)
 where true;
end $$;

create or replace function public.admin_delete_transaction(p_transaction_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare t public.transactions%rowtype;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 select * into t from public.transactions where id=p_transaction_id for update;
 if not found then raise exception 'Transaction not found'; end if;
 delete from public.transactions where id=p_transaction_id;
 perform public.rebuild_team_ledgers();
 update public.shares s set
   volume=coalesce((select sum(tx.quantity) from public.transactions tx where tx.share_symbol=s.symbol),0),
   updated_at=now()
 where true;
end $$;

create or replace function public.admin_reset_round()
returns integer language plpgsql security definer set search_path=public as $$
declare r public.round_state%rowtype;
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 select * into r from public.round_state where id=1 for update;
 if r.round_number not between 0 and 4 then raise exception 'Invalid current round'; end if;
 delete from public.transactions where round_number=r.round_number;
 perform public.rebuild_team_ledgers();
 update public.shares s set
   volume=coalesce((select sum(tx.quantity) from public.transactions tx where tx.share_symbol=s.symbol),0),
   updated_at=now()
 where true;
 update public.shares s set price=sn.opening_price,previous_price=sn.opening_price,updated_at=now()
 from public.round_price_snapshots sn where sn.round_number=r.round_number and sn.share_symbol=s.symbol;
 update public.news_events set resolved=false where round_number=r.round_number;
 update public.public_news set resolved=false,outcome_label=null where round_number=r.round_number;
 update public.round_state set status='active',updated_at=now() where id=1;
 return r.round_number;
end $$;

create or replace function public.admin_complete_reset()
returns void language plpgsql security definer set search_path=public as $$
begin
 if not public.has_app_role('admin') then raise exception 'Admin access required'; end if;
 perform 1 from public.round_state where id=1 for update;
 delete from public.transactions where true;
 update public.teams set cash=starting_cash,holdings=starting_holdings where true;
 update public.shares set price=starting_price,previous_price=starting_price,volume=0,updated_at=now() where true;
 update public.news_events set published=false,resolved=false,public_news_id=null where true;
 delete from public.public_news where true;
 delete from public.round_price_snapshots where true;
 update public.round_state set round_number=0,status='waiting',updated_at=now() where id=1;
end $$;

revoke all on function public.rebuild_team_ledgers() from public,anon,authenticated;
revoke all on function public.admin_delete_transaction(uuid) from public,anon;
revoke all on function public.admin_reset_round() from public,anon;
revoke all on function public.admin_complete_reset() from public,anon;
grant execute on function public.admin_delete_transaction(uuid) to authenticated;
grant execute on function public.admin_reset_round() to authenticated;
grant execute on function public.admin_complete_reset() to authenticated;
