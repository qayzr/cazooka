drop policy if exists "admins manage outside templates" on public.outside_interaction_templates;
create policy "admins manage outside templates"
on public.outside_interaction_templates
for all
to authenticated
using (
  exists (
    select 1
    from public.players p
    where p.id = auth.uid()
      and p.is_admin = true
  )
)
with check (
  exists (
    select 1
    from public.players p
    where p.id = auth.uid()
      and p.is_admin = true
  )
);

drop policy if exists "admins read outside runs" on public.outside_runs;
create policy "admins read outside runs"
on public.outside_runs
for select
to authenticated
using (
  exists (
    select 1
    from public.players p
    where p.id = auth.uid()
      and p.is_admin = true
  )
);
