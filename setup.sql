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
