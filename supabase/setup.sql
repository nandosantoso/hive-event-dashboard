-- HIVE Event Dashboard shared authentication, workspace data and activity log.
-- Run this once in Supabase Dashboard > SQL Editor.

create table if not exists public.hive_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null unique,
  full_name text not null default '',
  role text not null default 'viewer' check (role in ('admin','editor','viewer')),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.hive_invites (
  email text primary key,
  full_name text not null default '',
  role text not null check (role in ('editor','viewer')),
  invited_by uuid references auth.users(id),
  created_at timestamptz not null default now()
);

create table if not exists public.hive_workspace (
  id text primary key check (id = 'main'),
  events jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id)
);

create table if not exists public.hive_audit_log (
  id bigint generated always as identity primary key,
  event_id text not null default '',
  event_name text not null default '',
  actor_id uuid not null references auth.users(id),
  actor_name text not null default '',
  actor_email text not null default '',
  action text not null,
  detail text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists hive_audit_log_created_idx on public.hive_audit_log (created_at desc);
create index if not exists hive_audit_log_event_idx on public.hive_audit_log (event_id, created_at desc);

create or replace function public.hive_is_active()
returns boolean language sql stable security definer set search_path = public
as $$ select exists(select 1 from public.hive_profiles p where p.id = auth.uid() and p.active) $$;

create or replace function public.hive_is_admin()
returns boolean language sql stable security definer set search_path = public
as $$ select exists(select 1 from public.hive_profiles p where p.id = auth.uid() and p.active and p.role = 'admin') $$;

create or replace function public.hive_can_edit()
returns boolean language sql stable security definer set search_path = public
as $$ select exists(select 1 from public.hive_profiles p where p.id = auth.uid() and p.active and p.role in ('admin','editor')) $$;

create or replace function public.hive_handle_signup()
returns trigger language plpgsql security definer set search_path = public
as $$
declare v_invite public.hive_invites%rowtype;
begin
  select * into v_invite from public.hive_invites where email = lower(new.email) for update;
  if v_invite.email is null then raise exception 'This email is not invited to the HIVE workspace'; end if;
  insert into public.hive_profiles(id,email,full_name,role,active)
  values(new.id, lower(new.email), coalesce(new.raw_user_meta_data->>'full_name', v_invite.full_name, ''), coalesce(v_invite.role, 'viewer'), true)
  on conflict (id) do nothing;
  if found and v_invite.email is not null then delete from public.hive_invites where email = v_invite.email; end if;
  return new;
end;
$$;
drop trigger if exists hive_auth_user_created on auth.users;
create trigger hive_auth_user_created after insert on auth.users for each row execute function public.hive_handle_signup();

create or replace function public.hive_invite_user(p_email text, p_name text, p_role text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_email text := lower(trim(p_email)); v_user_id uuid;
begin
  if not public.hive_is_admin() then raise exception 'Only an active admin can invite users'; end if;
  if p_role not in ('editor','viewer') then raise exception 'Invalid invited role'; end if;
  if v_email = '' or position('@' in v_email) < 2 then raise exception 'Enter a valid email'; end if;
  insert into public.hive_invites(email,full_name,role,invited_by)
  values(v_email, coalesce(trim(p_name),''), p_role, auth.uid())
  on conflict(email) do update set full_name=excluded.full_name, role=excluded.role, invited_by=excluded.invited_by, created_at=now();
  select id into v_user_id from auth.users where lower(email)=v_email limit 1;
  if v_user_id is not null then
    update public.hive_profiles set full_name=coalesce(nullif(trim(p_name),''),full_name), role=p_role, active=true where id=v_user_id;
    delete from public.hive_invites where email=v_email;
  end if;
end;
$$;

create or replace function public.hive_record_audit(p_event_id text, p_event_name text, p_action text, p_detail text)
returns void language plpgsql security definer set search_path = public
as $$
declare v_profile public.hive_profiles%rowtype;
begin
  select * into v_profile from public.hive_profiles where id=auth.uid() and active;
  if v_profile.id is null then raise exception 'Active workspace profile required'; end if;
  insert into public.hive_audit_log(event_id,event_name,actor_id,actor_name,actor_email,action,detail)
  values(coalesce(p_event_id,''),coalesce(p_event_name,''),auth.uid(),v_profile.full_name,v_profile.email,left(coalesce(p_action,'Activity'),120),left(coalesce(p_detail,''),2000));
end;
$$;

alter table public.hive_profiles enable row level security;
alter table public.hive_invites enable row level security;
alter table public.hive_workspace enable row level security;
alter table public.hive_audit_log enable row level security;

drop policy if exists hive_profiles_select_active on public.hive_profiles;
create policy hive_profiles_select_active on public.hive_profiles for select to authenticated using (public.hive_is_active());
drop policy if exists hive_profiles_admin_update on public.hive_profiles;
create policy hive_profiles_admin_update on public.hive_profiles for update to authenticated using (public.hive_is_admin()) with check (public.hive_is_admin());

drop policy if exists hive_invites_admin_access on public.hive_invites;
create policy hive_invites_admin_access on public.hive_invites for all to authenticated using (public.hive_is_admin()) with check (public.hive_is_admin());

drop policy if exists hive_workspace_read_active on public.hive_workspace;
create policy hive_workspace_read_active on public.hive_workspace for select to authenticated using (public.hive_is_active());
drop policy if exists hive_workspace_editors_write on public.hive_workspace;
create policy hive_workspace_editors_write on public.hive_workspace for all to authenticated using (public.hive_can_edit()) with check (public.hive_can_edit());

drop policy if exists hive_audit_read_active on public.hive_audit_log;
create policy hive_audit_read_active on public.hive_audit_log for select to authenticated using (public.hive_is_active());

grant usage on schema public to authenticated;
grant select, update on public.hive_profiles to authenticated;
grant select, insert, update on public.hive_workspace to authenticated;
grant select on public.hive_audit_log to authenticated;
grant execute on function public.hive_is_active() to authenticated;
grant execute on function public.hive_is_admin() to authenticated;
grant execute on function public.hive_can_edit() to authenticated;
grant execute on function public.hive_invite_user(text,text,text) to authenticated;
grant execute on function public.hive_record_audit(text,text,text,text) to authenticated;

-- This allows only explicitly invited people to sign up; public self-signup is blocked.
insert into public.hive_invites(email,full_name,role,invited_by)
values ('owner@example.com','Workspace Owner','editor',null)
on conflict(email) do update set full_name=excluded.full_name, role=excluded.role;

-- After the owner signs up and confirms email, promote them once:
-- update public.hive_profiles set role='admin' where email='owner@example.com';
