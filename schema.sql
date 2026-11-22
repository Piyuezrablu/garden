-- Love Garden MVP schema. Run once in Supabase SQL Editor.
create extension if not exists pgcrypto;

create table if not exists public.love_gardens (
  id uuid primary key default gen_random_uuid(),
  name text not null default 'Our little patch' check (char_length(name) between 1 and 32),
  owner_id uuid not null references auth.users(id) on delete cascade,
  partner_id uuid references auth.users(id) on delete set null,
  invite_code text not null unique default upper('LOVE-' || substr(encode(gen_random_bytes(4),'hex'),1,6)),
  anniversary_date date,
  xp integer not null default 0 check (xp >= 0),
  level integer not null default 1 check (level >= 1),
  seeds integer not null default 8 check (seeds >= 0),
  last_together_bonus date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (partner_id is null or partner_id <> owner_id)
);
create unique index if not exists love_gardens_owner_unique on public.love_gardens(owner_id);
create unique index if not exists love_gardens_partner_unique on public.love_gardens(partner_id) where partner_id is not null;

create table if not exists public.love_flowers (
  id uuid primary key default gen_random_uuid(),
  garden_id uuid not null references public.love_gardens(id) on delete cascade,
  planted_by uuid not null references auth.users(id) on delete cascade,
  plot integer not null check (plot between 0 and 11),
  flower_type text not null check (flower_type in ('daisy','tulip','rose','lavender','sunflower','cherry')),
  planted_at timestamptz not null default now(),
  growth_hours integer not null check (growth_hours between 1 and 720),
  last_cared_at timestamptz,
  unique(garden_id, plot)
);

create table if not exists public.love_checkins (
  id uuid primary key default gen_random_uuid(),
  garden_id uuid not null references public.love_gardens(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  checkin_date date not null,
  partner_bonus_claimed boolean not null default false,
  created_at timestamptz not null default now(),
  unique(garden_id, user_id, checkin_date)
);

alter table public.love_gardens enable row level security;
alter table public.love_flowers enable row level security;
alter table public.love_checkins enable row level security;

drop policy if exists "garden members read garden" on public.love_gardens;
create policy "garden members read garden" on public.love_gardens for select to authenticated
using (auth.uid() = owner_id or auth.uid() = partner_id);
drop policy if exists "garden members update garden" on public.love_gardens;
-- All garden writes go through narrowly scoped RPCs. Clients cannot edit XP, seeds,
-- membership, or invite codes directly through the table API.
drop policy if exists "members read flowers" on public.love_flowers;
create policy "members read flowers" on public.love_flowers for select to authenticated
using (exists (select 1 from public.love_gardens g where g.id=garden_id and (g.owner_id=auth.uid() or g.partner_id=auth.uid())));
drop policy if exists "members read checkins" on public.love_checkins;
create policy "members read checkins" on public.love_checkins for select to authenticated
using (exists (select 1 from public.love_gardens g where g.id=garden_id and (g.owner_id=auth.uid() or g.partner_id=auth.uid())));

create or replace function public.lg_add_xp(p_garden_id uuid, p_amount integer)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare current_xp integer; current_level integer; need integer;
begin
 if p_amount < 0 or p_amount > 1000 then raise exception 'Invalid XP amount'; end if;
 select xp,level into current_xp,current_level from public.love_gardens
 where id=p_garden_id and (owner_id=auth.uid() or partner_id=auth.uid()) for update;
 if not found then raise exception 'Garden not found or access denied'; end if;
 current_xp := current_xp + p_amount;
 need := current_level * 100;
 while current_xp >= need loop current_xp := current_xp - need; current_level := current_level + 1; need := current_level * 100; end loop;
 update public.love_gardens set xp=current_xp,level=current_level,updated_at=now() where id=p_garden_id;
end; $$;


create or replace function public.update_love_garden_settings(p_garden_id uuid,p_name text,p_anniversary date)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 update public.love_gardens set name=coalesce(nullif(trim(p_name),''),'Our little patch'),anniversary_date=p_anniversary,updated_at=now()
 where id=p_garden_id and (owner_id=auth.uid() or partner_id=auth.uid());
 if not found then raise exception 'Garden not found or access denied'; end if;
end; $$;

create or replace function public.create_love_garden(p_name text, p_anniversary date default null)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare new_id uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if exists(select 1 from public.love_gardens where owner_id=auth.uid() or partner_id=auth.uid()) then raise exception 'You already belong to a garden'; end if;
 insert into public.love_gardens(name,owner_id,anniversary_date) values (coalesce(nullif(trim(p_name),''),'Our little patch'),auth.uid(),p_anniversary) returning id into new_id;
 return new_id;
end; $$;

create or replace function public.join_love_garden(p_invite_code text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare target uuid;
begin
 if auth.uid() is null then raise exception 'Sign in required'; end if;
 if exists(select 1 from public.love_gardens where owner_id=auth.uid() or partner_id=auth.uid()) then raise exception 'You already belong to a garden'; end if;
 update public.love_gardens set partner_id=auth.uid(),updated_at=now()
 where invite_code=upper(trim(p_invite_code)) and partner_id is null and owner_id<>auth.uid() returning id into target;
 if target is null then raise exception 'Invite code is invalid or already used'; end if;
 return target;
end; $$;

create or replace function public.plant_love_flower(p_garden_id uuid,p_plot integer,p_flower_type text)
returns uuid language plpgsql security definer set search_path=public,pg_temp as $$
declare cost integer; hours integer; flower_id uuid; current_seeds integer; current_level integer; required_level integer;
begin
 if p_plot not between 0 and 11 then raise exception 'Invalid plot'; end if;
 select case p_flower_type when 'daisy' then 1 when 'tulip' then 1 when 'rose' then 2 when 'lavender' then 2 when 'sunflower' then 3 when 'cherry' then 4 else null end,
 case p_flower_type when 'daisy' then 24 when 'tulip' then 36 when 'rose' then 48 when 'lavender' then 60 when 'sunflower' then 72 when 'cherry' then 96 else null end
 into cost,hours;
 if cost is null then raise exception 'Unknown flower'; end if;
 required_level := case p_flower_type when 'daisy' then 1 when 'tulip' then 2 when 'rose' then 3 when 'lavender' then 4 when 'sunflower' then 5 when 'cherry' then 6 end;
 select level into current_level from public.love_gardens where id=p_garden_id and (owner_id=auth.uid() or partner_id=auth.uid());
 if current_level is null then raise exception 'Garden not found or access denied'; end if;
 if current_level < required_level then raise exception 'Flower is locked until level %',required_level; end if;
 update public.love_gardens set seeds=seeds-cost where id=p_garden_id and (owner_id=auth.uid() or partner_id=auth.uid()) and seeds>=cost returning seeds into current_seeds;
 if not found then raise exception 'Not enough seeds or access denied'; end if;
 insert into public.love_flowers(garden_id,planted_by,plot,flower_type,growth_hours) values(p_garden_id,auth.uid(),p_plot,p_flower_type,hours) returning id into flower_id;
 perform public.lg_add_xp(p_garden_id,5);
 return flower_id;
exception when unique_violation then raise exception 'That plot is already planted';
end; $$;

create or replace function public.care_love_flower(p_garden_id uuid,p_flower_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
begin
 update public.love_flowers f set last_cared_at=now() from public.love_gardens g where f.id=p_flower_id and f.garden_id=p_garden_id and g.id=f.garden_id and (g.owner_id=auth.uid() or g.partner_id=auth.uid()) and (f.last_cared_at is null or f.last_cared_at < now()-interval '24 hours');
 if not found then raise exception 'Flower not found, access denied, or already cared for today'; end if;
 perform public.lg_add_xp(p_garden_id,5);
end; $$;

create or replace function public.remove_love_flower(p_garden_id uuid,p_flower_id uuid)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare deleted integer;
begin
 delete from public.love_flowers f where f.id=p_flower_id and f.garden_id=p_garden_id and exists(select 1 from public.love_gardens g where g.id=p_garden_id and (g.owner_id=auth.uid() or g.partner_id=auth.uid()));
 get diagnostics deleted=row_count;
 if deleted=0 then raise exception 'Flower not found or access denied'; end if;
 -- Removed flowers do not refund seeds, preventing a plant/remove XP farming loop.
end; $$;

create or replace function public.claim_love_checkin(p_garden_id uuid,p_date date)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare count_today integer; bonus_done date;
begin
 if p_date <> (now() at time zone 'Asia/Jakarta')::date then raise exception 'Check-in date must be today'; end if;
 insert into public.love_checkins(garden_id,user_id,checkin_date) values(p_garden_id,auth.uid(),p_date);
 update public.love_gardens set seeds=seeds+1 where id=p_garden_id;
 perform public.lg_add_xp(p_garden_id,10);
 select count(*) into count_today from public.love_checkins where garden_id=p_garden_id and checkin_date=p_date;
 select last_together_bonus into bonus_done from public.love_gardens where id=p_garden_id;
 if count_today=2 and bonus_done is distinct from p_date then
   update public.love_gardens set last_together_bonus=p_date where id=p_garden_id;
   update public.love_checkins set partner_bonus_claimed=true where garden_id=p_garden_id and checkin_date=p_date;
   perform public.lg_add_xp(p_garden_id,20);
 end if;
exception when unique_violation then raise exception 'You already checked in today';
end; $$;

create or replace function public.claim_love_anniversary(p_garden_id uuid,p_year integer)
returns void language plpgsql security definer set search_path=public,pg_temp as $$
declare ann date; today date; already boolean;
begin
 select anniversary_date into ann from public.love_gardens where id=p_garden_id and (owner_id=auth.uid() or partner_id=auth.uid()) for update;
 if not found or ann is null then raise exception 'Anniversary date is not set'; end if;
 today := (now() at time zone 'Asia/Jakarta')::date;
 if extract(month from ann)<>extract(month from today) or (extract(day from ann)<>extract(day from today) and not (extract(month from ann)=2 and extract(day from ann)=29 and extract(day from today)=28 and not ((extract(year from today)::integer%4=0) and (extract(year from today)::integer%100<>0 or extract(year from today)::integer%400=0)))) or p_year<>extract(year from today) then raise exception 'Not your anniversary today'; end if;
 if exists(select 1 from public.love_anniversary_claims where garden_id=p_garden_id and claim_year=p_year) then raise exception 'Anniversary already claimed'; end if;
 insert into public.love_anniversary_claims(garden_id,claim_year,claimed_by) values(p_garden_id,p_year,auth.uid());
 perform public.lg_add_xp(p_garden_id,100);
end; $$;

create table if not exists public.love_anniversary_claims (
 garden_id uuid not null references public.love_gardens(id) on delete cascade,
 claim_year integer not null,
 claimed_by uuid not null references auth.users(id),
 claimed_at timestamptz not null default now(),
 primary key(garden_id,claim_year)
);
alter table public.love_anniversary_claims enable row level security;

grant select on public.love_gardens, public.love_flowers, public.love_checkins, public.love_anniversary_claims to authenticated;
drop policy if exists "members read anniversary claims" on public.love_anniversary_claims;
create policy "members read anniversary claims" on public.love_anniversary_claims for select to authenticated
using (exists(select 1 from public.love_gardens g where g.id=garden_id and (g.owner_id=auth.uid() or g.partner_id=auth.uid())));

-- Expose only intended RPCs to authenticated users.
revoke all on function public.lg_add_xp(uuid,integer) from public, anon, authenticated;
revoke all on function public.update_love_garden_settings(uuid,text,date) from public, anon;
revoke all on function public.create_love_garden(text,date) from public, anon;
revoke all on function public.join_love_garden(text) from public, anon;
revoke all on function public.plant_love_flower(uuid,integer,text) from public, anon;
revoke all on function public.care_love_flower(uuid,uuid) from public, anon;
revoke all on function public.remove_love_flower(uuid,uuid) from public, anon;
revoke all on function public.claim_love_checkin(uuid,date) from public, anon;
revoke all on function public.claim_love_anniversary(uuid,integer) from public, anon;
grant execute on function public.update_love_garden_settings(uuid,text,date) to authenticated;
grant execute on function public.create_love_garden(text,date) to authenticated;
grant execute on function public.join_love_garden(text) to authenticated;
grant execute on function public.plant_love_flower(uuid,integer,text) to authenticated;
grant execute on function public.care_love_flower(uuid,uuid) to authenticated;
grant execute on function public.remove_love_flower(uuid,uuid) to authenticated;
grant execute on function public.claim_love_checkin(uuid,date) to authenticated;
grant execute on function public.claim_love_anniversary(uuid,integer) to authenticated;

-- Enable Realtime for the tables used by the app (ignore if already added).
do $$ begin alter publication supabase_realtime add table public.love_gardens; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.love_flowers; exception when duplicate_object then null; end $$;
do $$ begin alter publication supabase_realtime add table public.love_checkins; exception when duplicate_object then null; end $$;
