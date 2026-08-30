const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type JsonObject = Record<string, unknown>;

const ALLOWED_OUTSIDE_TYPES = new Set([
  "observe",
  "find",
  "friend-win",
  "friend-lose",
  "battle",
  "pvp-battle",
]);

const MAX_RUNS = 5;
const MAX_ENCOUNTERS = 8;
const MAX_LOG_LINES = 8;
const MAX_TEXT = 180;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "POST only" }, 405);

  try {
    const body = await req.json();
    const mode = body?.mode === "dojo" ? "dojo" : "outside";
    const facts = mode === "dojo" ? sanitizeDojoFacts(body?.result) : sanitizeOutsideFacts(body?.runs);
    if (!facts) return json({ error: "Invalid request" }, 400);

    const ai = await callCohere(mode, facts);
    const guarded = mode === "dojo"
      ? guardDojoResponse(ai, facts as JsonObject)
      : guardOutsideResponse(ai, facts as JsonObject[]);

    return json({ ok: true, mode, ...guarded });
  } catch (err) {
    return json({ ok: false, error: "AI director unavailable" }, 200);
  }
});

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function shortText(value: unknown, max = MAX_TEXT) {
  return String(value ?? "")
    .replace(/[<>{}[\]\\]/g, "")
    .replace(/\s+/g, " ")
    .trim()
    .slice(0, max);
}

function finiteNumber(value: unknown, fallback = 0) {
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function sanitizeOutsideFacts(runs: unknown): JsonObject[] | null {
  if (!Array.isArray(runs)) return null;
  return runs.slice(0, MAX_RUNS).map((run: JsonObject) => ({
    name: shortText(run?.name, 80),
    catIdx: finiteNumber(run?.catIdx),
    energyCost: finiteNumber(run?.energyCost),
    statSummary: sanitizeStatSummary(run?.statSummary),
    tactics: sanitizeTextList(run?.tactics, 5, 120),
    encounters: Array.isArray(run?.encounters)
      ? run.encounters.slice(0, MAX_ENCOUNTERS).map((enc: JsonObject) => ({
          type: ALLOWED_OUTSIDE_TYPES.has(String(enc?.type)) ? enc.type : "observe",
          icon: shortText(enc?.icon, 4),
          intro: shortText(enc?.intro || enc?.outcome || ""),
          enemy: shortText(enc?.enemy, 50),
          won: Boolean(enc?.won),
          avoided: Boolean(enc?.avoided),
          charmed: Boolean(enc?.charmed),
          statSummary: sanitizeStatSummary(enc?.statSummary),
          tactics: sanitizeTextList(enc?.tactics, 5, 120),
          lootName: enc?.loot && typeof enc.loot === "object" ? shortText((enc.loot as JsonObject).name, 80) : "",
          log: Array.isArray(enc?.battleLog)
            ? enc.battleLog.slice(0, MAX_LOG_LINES).map((line: JsonObject) => shortText(line?.text))
            : [],
        }))
      : [],
  }));
}

function sanitizeDojoFacts(result: unknown): JsonObject | null {
  if (!result || typeof result !== "object") return null;
  const r = result as JsonObject;
  return {
    catName: shortText(r.catName, 80),
    oppName: shortText(r.oppName, 80),
    difficulty: shortText(r.difficulty, 40),
    won: Boolean(r.won),
    draw: Boolean(r.draw),
    catHp: finiteNumber(r.catHp),
    oppHp: finiteNumber(r.oppHp),
    catStats: sanitizeStatSummary(r.catStats),
    oppStats: sanitizeStatSummary(r.oppStats),
    tactics: sanitizeTextList(r.tactics, 5, 120),
    log: Array.isArray(r.log) ? r.log.slice(0, MAX_LOG_LINES).map((line) => shortText(line)) : [],
  };
}

function sanitizeStatSummary(value: unknown) {
  if (!value || typeof value !== "object") return {};
  const v = value as JsonObject;
  return {
    power: finiteNumber(v.power),
    high: sanitizeTextList(v.high, 3, 40),
    low: sanitizeTextList(v.low, 2, 40),
  };
}

function sanitizeTextList(value: unknown, maxItems: number, maxLength: number) {
  return Array.isArray(value) ? value.slice(0, maxItems).map((item) => shortText(item, maxLength)).filter(Boolean) : [];
}

async function callCohere(mode: string, facts: unknown) {
  const apiKey = Deno.env.get("COHERE_API_KEY");
  if (!apiKey) throw new Error("Missing COHERE_API_KEY");
  const model = Deno.env.get("COHERE_MODEL") || "command-r-08-2024";
  const schema = mode === "dojo"
    ? `{"summary":"short result line","coach_note":"one useful tactical note","log":["3-6 short fight narration lines"]}`
    : `{"runs":[{"summary":"short run summary","encounters":[{"bubble":"short thought bubble","summary":"short encounter summary","log":["4-6 short lines for battle or pvp-battle encounters, [] otherwise"]}]}]}`;
  const prompt = [
    "You are the Cazooka cat-card game AI director.",
    "Rewrite only narration. Do not alter outcomes, rewards, loot, stats, names, encounter counts, or win/loss facts.",
    "Keep text playful, concise, and suitable for a cozy tactical cat game.",
    "Use provided statSummary and tactics to make fights feel specific: low stamina invites pressure, speed advantages create dodges/counters, strength advantages create heavy trades, intelligence reads patterns.",
    "For battle and pvp-battle encounters, write 4 to 6 beat-by-beat fight log lines that reference at least one provided tactic. For non-battle encounters, keep log empty.",
    "For dojo mode, coach_note should mention the most important stat/tactic lesson.",
    "No gore, no real-world brands, no profanity, no new mechanics.",
    "Return ONLY valid JSON matching this schema:",
    schema,
    "Facts:",
    JSON.stringify(facts),
  ].join("\n");

  const res = await fetch("https://api.cohere.com/v2/chat", {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model,
      temperature: 0.65,
      max_tokens: 900,
      messages: [{ role: "user", content: prompt }],
    }),
  });
  if (!res.ok) throw new Error(`Cohere ${res.status}`);
  const data = await res.json();
  const text = data?.message?.content?.map((part: JsonObject) => part?.text || "").join("") || "";
  return JSON.parse(extractJson(text));
}

function extractJson(text: string) {
  const trimmed = text.trim();
  if (trimmed.startsWith("{")) return trimmed;
  const start = trimmed.indexOf("{");
  const end = trimmed.lastIndexOf("}");
  if (start < 0 || end <= start) throw new Error("No JSON object");
  return trimmed.slice(start, end + 1);
}

function guardOutsideResponse(ai: JsonObject, facts: JsonObject[]) {
  const aiRuns = Array.isArray(ai?.runs) ? ai.runs : [];
  return {
    runs: facts.map((run, ri) => {
      const aiRun = (aiRuns[ri] || {}) as JsonObject;
      const aiEnc = Array.isArray(aiRun?.encounters) ? aiRun.encounters : [];
      const encounters = Array.isArray(run.encounters) ? run.encounters : [];
      return {
        summary: shortText(aiRun.summary, 120),
        encounters: encounters.map((factEnc: JsonObject, ei) => {
          const enc = (aiEnc[ei] || {}) as JsonObject;
          const kind = String(factEnc?.type || "");
          const log = Array.isArray(enc.log) ? enc.log.slice(0, 6).map((line) => shortText(line, 150)).filter(Boolean) : [];
          const guardedLog = (kind === "battle" || kind === "pvp-battle") && log.length >= 3 ? log : [];
          return {
            bubble: shortText(enc.bubble, 120),
            summary: shortText(enc.summary, 120),
            log: guardedLog,
          };
        }),
      };
    }),
  };
}

function guardDojoResponse(ai: JsonObject, facts: JsonObject) {
  return {
    result: {
      summary: shortText(ai?.summary, 120),
      coach_note: shortText(ai?.coach_note, 140),
      log: Array.isArray(ai?.log) ? ai.log.slice(0, 6).map((line) => shortText(line, 150)).filter(Boolean) : [],
      catHp: facts.catHp,
      oppHp: facts.oppHp,
      won: facts.won,
      draw: facts.draw,
    },
  };
}
