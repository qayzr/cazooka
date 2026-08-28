create table if not exists public.outside_interaction_templates (
  id uuid primary key default gen_random_uuid(),
  kind text not null,
  icon text not null default '✨',
  body text not null,
  weight integer not null default 1 check (weight > 0),
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create table if not exists public.outside_runs (
  id uuid primary key default gen_random_uuid(),
  player_id uuid not null references auth.users(id) on delete cascade,
  selected_cat_indices integer[] not null default '{}',
  run_data jsonb not null,
  created_at timestamptz not null default now()
);

alter table public.outside_interaction_templates enable row level security;
alter table public.outside_runs enable row level security;
alter table public.outside_runs alter column player_id set not null;

drop policy if exists "outside templates readable" on public.outside_interaction_templates;
-- No public read policy for templates. Logged-in players receive selected
-- copy only through start_outside_run(), so the full interaction pool is not
-- exposed through the browser client.

drop policy if exists "players read own outside runs" on public.outside_runs;
create policy "players read own outside runs"
on public.outside_runs
for select
to authenticated
using (auth.uid() = player_id);

create unique index if not exists outside_interaction_templates_kind_body_key
on public.outside_interaction_templates (kind, body);

insert into public.outside_interaction_templates (kind, icon, body, weight) values
  ('observe', '👀', '%CAT% pauses just outside the door, watching the street settle into patterns.', 3),
  ('observe', '👀', '%CAT% sniffs the air, checks the corners, and chooses a direction.', 3),
  ('observe', '👀', '%CAT% studies the nearby shadows like every leaf might be hiding treasure.', 2),
  ('observe', '👀', '%CAT% takes a quiet moment to map the sounds, smells, and possible nonsense ahead.', 2),
  ('find', '✨', '%CAT% was poking around the rooftops when something caught the light.', 3),
  ('find', '✨', '%CAT% investigated a suspicious pile near the corner shop.', 3),
  ('find', '✨', '%CAT% took the long way home and found something tucked behind the bins.', 2),
  ('friend-win', '🤝', '%CAT% shared a calm blink with a neighbourhood cat. The street felt friendlier after that.', 3),
  ('friend-win', '🤝', '%CAT% found good company in an unexpected corner and left with a small gift.', 2),
  ('friend-lose', '🙂', '%CAT% tried to make friends, but the other cat had appointments with a wall.', 2),
  ('friend-lose', '🙂', '%CAT% offered a polite greeting. The reply was a tail flick and mystery.', 2),
  ('battle', '⚔', '%CAT% ran into trouble, held their ground, and came away with a story.', 2),
  ('battle', '💨', '%CAT% spotted a bad situation early and slipped past before it got loud.', 2)
on conflict (kind, body) do nothing;

create or replace function public.weighted_outside_template(p_kind text)
returns public.outside_interaction_templates
language sql
stable
as $$
  select t
  from public.outside_interaction_templates t
  where t.active and t.kind = p_kind
  order by -ln(greatest(random(), 0.000001)) / t.weight
  limit 1
$$;

create or replace function public.random_outside_loot(p_rarity text default null)
returns jsonb
language sql
stable
as $$
  select to_jsonb(c)
  from public.cards c
  where c.type in ('home_item', 'battle_gear', 'consumable')
    and (p_rarity is null or c.rarity = p_rarity)
  order by random()
  limit 1
$$;

drop function if exists public.start_outside_run(integer[], jsonb);

create or replace function public.start_outside_run(p_selected_cat_indices integer[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  gs jsonb;
  cats jsonb;
  cat jsonb;
  breed jsonb;
  stats jsonb;
  stat_bonuses jsonb;
  ci integer;
  cat_name text;
  stamina numeric;
  speed numeric;
  agility numeric;
  strength numeric;
  intelligence numeric;
  affection numeric;
  amicability numeric;
  dur_min numeric;
  encounter_count integer;
  encounters jsonb;
  kind text;
  tmpl public.outside_interaction_templates;
  body text;
  loot jsonb;
  roll numeric;
  i integer;
  runs jsonb := '[]'::jsonb;
  result jsonb;
begin
  if auth.uid() is null then
    raise exception 'Authentication required';
  end if;

  select game_state into gs
  from public.players
  where id = auth.uid();

  if gs is null then
    raise exception 'No saved game state found';
  end if;

  cats := coalesce(gs->'cats', '[]'::jsonb);

  foreach ci in array p_selected_cat_indices loop
    cat := cats->ci;
    if cat is null then
      continue;
    end if;

    breed := cat->'breed';
    stats := coalesce(breed->'data'->'stats', '{}'::jsonb);
    stat_bonuses := coalesce(cat->'permanent_stat_bonuses', '{}'::jsonb);
    stats := jsonb_set(stats, '{loyalty}', to_jsonb(
      greatest(1, coalesce((stats->>'loyalty')::numeric, 10) + coalesce((stat_bonuses->>'loyalty')::numeric, 0))
    ));
    cat_name := regexp_replace(coalesce(nullif(cat->>'name', ''), breed->>'name', 'Cat'), '[<>&"'']', '', 'g');
    stamina := coalesce((stats->>'stamina')::numeric, 10);
    speed := coalesce((stats->>'speed')::numeric, 10);
    agility := coalesce((stats->>'agility')::numeric, 10);
    strength := coalesce((stats->>'strength')::numeric, 10);
    intelligence := coalesce((stats->>'intelligence')::numeric, 10);
    affection := coalesce((stats->>'affection')::numeric, 10);
    amicability := coalesce((stats->>'amicability')::numeric, 10);
    dur_min := 3 + (stamina / 100) * 12 + (speed / 100) * 5;
    encounter_count := greatest(2, floor(2 + (agility / 100) * 3 + (speed / 100) * 2)::integer);

    tmpl := public.weighted_outside_template('observe');
    encounters := jsonb_build_array(jsonb_build_object(
      'type', 'observe',
      'icon', coalesce(tmpl.icon, '👀'),
      'catName', cat_name,
      'intro', replace(coalesce(tmpl.body, '%CAT% checks the street.'), '%CAT%', cat_name)
    ));

    for i in 1..encounter_count loop
      roll := random() * greatest(1, strength + agility + ((affection + amicability) * 1.8) + (intelligence * 2.2));
      if roll < strength + agility then
        kind := 'battle';
      elsif roll < strength + agility + ((affection + amicability) * 1.8) then
        kind := case when random() < least(0.92, ((affection + amicability) / 2) / 30) then 'friend-win' else 'friend-lose' end;
      else
        kind := 'find';
      end if;

      tmpl := public.weighted_outside_template(kind);
      body := replace(coalesce(tmpl.body, '%CAT% keeps moving.'), '%CAT%', cat_name);
      loot := null;
      if kind in ('find', 'friend-win') and random() < (case when kind = 'find' then 0.9 else 0.45 end) then
        loot := public.random_outside_loot(case
          when intelligence >= 55 and random() < 0.22 then 'rare'
          when intelligence >= 30 and random() < 0.50 then 'uncommon'
          else 'common'
        end);
      end if;

      if kind = 'battle' then
        encounters := encounters || jsonb_build_array(jsonb_build_object(
          'type', 'battle',
          'icon', coalesce(tmpl.icon, '⚔'),
          'enemy', 'street cat',
          'won', random() < least(0.86, 0.35 + ((strength + agility + stamina) / 300)),
          'charmed', false,
          'avoided', tmpl.icon = '💨',
          'battleLog', jsonb_build_array(jsonb_build_object('cls', 'open', 'text', body)),
          'loot', loot,
          'extraLoot', '[]'::jsonb,
          'persistAfter', random() < 0.35,
          'persistText', cat_name || ' keeps watching the route before heading back.'
        ));
      else
        encounters := encounters || jsonb_build_array(jsonb_build_object(
          'type', kind,
          'icon', coalesce(tmpl.icon, '✨'),
          'intro', body,
          'outcome', '',
          'loot', loot,
          'extraLoot', '[]'::jsonb,
          'abilityNotes', '[]'::jsonb
        ));
      end if;
    end loop;

    runs := runs || jsonb_build_array(jsonb_build_object(
      'catIdx', ci,
      'name', cat_name,
      'stats', stats,
      'dur_min', dur_min,
      'duration_ms', round(dur_min * 60 * 1000 / 10),
      'encounters', encounters,
      'energyCost', least(98, round(20 + encounter_count * 7)),
      'energySaveNote', ''
    ));
  end loop;

  result := jsonb_build_object('runs', runs, 'createdAt', now());

  insert into public.outside_runs (player_id, selected_cat_indices, run_data)
  values (auth.uid(), p_selected_cat_indices, result);

  return result;
end;
$$;

grant execute on function public.start_outside_run(integer[]) to authenticated;
