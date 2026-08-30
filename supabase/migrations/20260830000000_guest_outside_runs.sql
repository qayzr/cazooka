create or replace function public.generate_outside_run(
  p_cats jsonb,
  p_selected_cat_indices integer[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  cats jsonb := coalesce(p_cats, '[]'::jsonb);
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
begin
  if jsonb_typeof(cats) <> 'array' then
    raise exception 'Cats must be a JSON array';
  end if;

  foreach ci in array coalesce(p_selected_cat_indices, '{}') loop
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

  return jsonb_build_object('runs', runs, 'createdAt', now());
end;
$$;

grant execute on function public.generate_outside_run(jsonb, integer[]) to anon, authenticated;
