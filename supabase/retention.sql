-- HIVE seven-day retention for audit entries and workspace messages.
-- Run this once in Supabase Dashboard > SQL Editor.

create or replace function public.hive_prune_messages_from_events(p_events jsonb, p_cutoff timestamptz)
returns jsonb
language sql
immutable
set search_path = public
as $$
  select coalesce(jsonb_agg(
    jsonb_set(
      jsonb_set(
        jsonb_set(
          ev,
          '{directMessages}',
          coalesce((
            select jsonb_agg(msg order by msg_ord)
            from jsonb_array_elements(case when jsonb_typeof(ev->'directMessages')='array' then ev->'directMessages' else '[]'::jsonb end) with ordinality as d(msg,msg_ord)
            where case when msg->>'at' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' then (msg->>'at')::timestamptz else p_cutoff end >= p_cutoff
          ), '[]'::jsonb),
          true
        ),
        '{tasks}',
        coalesce((
          select jsonb_agg(
            case when jsonb_typeof(task)='array' and jsonb_typeof(task->5)='array' then
              jsonb_set(task, '{5}', coalesce((
                select jsonb_agg(comment order by comment_ord)
                from jsonb_array_elements(task->5) with ordinality as c(comment,comment_ord)
                where case when comment->>'at' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' then (comment->>'at')::timestamptz else p_cutoff end >= p_cutoff
              ), '[]'::jsonb), true)
            else task end
            order by task_ord
          )
          from jsonb_array_elements(case when jsonb_typeof(ev->'tasks')='array' then ev->'tasks' else '[]'::jsonb end) with ordinality as t(task,task_ord)
        ), '[]'::jsonb),
        true
      ),
      '{equipment}',
      coalesce((
        select jsonb_agg(
          case when jsonb_typeof(item)='array' and jsonb_typeof(item->6)='array' then
            jsonb_set(item, '{6}', coalesce((
              select jsonb_agg(comment order by comment_ord)
              from jsonb_array_elements(item->6) with ordinality as c(comment,comment_ord)
              where case when comment->>'at' ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}T' then (comment->>'at')::timestamptz else p_cutoff end >= p_cutoff
            ), '[]'::jsonb), true)
          else item end
          order by item_ord
        )
        from jsonb_array_elements(case when jsonb_typeof(ev->'equipment')='array' then ev->'equipment' else '[]'::jsonb end) with ordinality as i(item,item_ord)
      ), '[]'::jsonb),
      true
    )
    order by event_ord
  ), '[]'::jsonb)
  from jsonb_array_elements(case when jsonb_typeof(p_events)='array' then p_events else '[]'::jsonb end) with ordinality as e(ev,event_ord);
$$;

-- Keep old Inbox messages and comments from accumulating on each workspace write.
create or replace function public.hive_workspace_retention_trigger()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.events := public.hive_prune_messages_from_events(new.events, now() - interval '7 days');
  return new;
end;
$$;

drop trigger if exists hive_workspace_retention on public.hive_workspace;
create trigger hive_workspace_retention
before insert or update of events on public.hive_workspace
for each row execute function public.hive_workspace_retention_trigger();

-- Purge expired audit entries whenever a new activity is written.
create or replace function public.hive_audit_retention_trigger()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  delete from public.hive_audit_log where created_at < now() - interval '7 days';
  return new;
end;
$$;

drop trigger if exists hive_audit_retention on public.hive_audit_log;
create trigger hive_audit_retention
after insert on public.hive_audit_log
for each row execute function public.hive_audit_retention_trigger();

-- Internal cleanup is only callable by the scheduled database job and admin wrapper.
create or replace function public.hive_cleanup_expired_data_internal()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare v_cutoff timestamptz := now() - interval '7 days';
begin
  delete from public.hive_audit_log where created_at < v_cutoff;
  update public.hive_workspace
  set events = public.hive_prune_messages_from_events(events, v_cutoff),
      updated_at = now(),
      updated_by = coalesce(auth.uid(), updated_by)
  where id = 'main'
    and events is distinct from public.hive_prune_messages_from_events(events, v_cutoff);
end;
$$;
revoke all on function public.hive_cleanup_expired_data_internal() from public, anon, authenticated;

-- Admins can run cleanup immediately; the hourly job uses the private function above.
create or replace function public.hive_prune_expired_data()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.hive_is_admin() then raise exception 'Workspace admin required'; end if;
  perform public.hive_cleanup_expired_data_internal();
end;
$$;
revoke all on function public.hive_prune_expired_data() from public, anon;
grant execute on function public.hive_prune_expired_data() to authenticated;
grant execute on function public.hive_prune_messages_from_events(jsonb,timestamptz) to authenticated;

-- Enable Supabase Cron if needed, then create the hourly retention job.
create extension if not exists pg_cron with schema pg_catalog;
select cron.unschedule(jobid) from cron.job where jobname='hive-seven-day-retention';
select cron.schedule('hive-seven-day-retention','0 * * * *','select public.hive_cleanup_expired_data_internal()');
