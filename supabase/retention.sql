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

create or replace function public.hive_prune_expired_data()
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cutoff timestamptz := now() - interval '7 days';
begin
  if not public.hive_is_active() then
    raise exception 'Active workspace profile required';
  end if;

  delete from public.hive_audit_log where created_at < v_cutoff;

  update public.hive_workspace
  set events = public.hive_prune_messages_from_events(events, v_cutoff),
      updated_at = now(),
      updated_by = auth.uid()
  where id = 'main'
    and events is distinct from public.hive_prune_messages_from_events(events, v_cutoff);
end;
$$;

grant execute on function public.hive_prune_messages_from_events(jsonb,timestamptz) to authenticated;
grant execute on function public.hive_prune_expired_data() to authenticated;
