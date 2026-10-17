import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const APP_ORIGIN = "https://planificador-menus-psi.vercel.app";
const corsHeaders = {
  "Access-Control-Allow-Origin": APP_ORIGIN,
  "Access-Control-Allow-Headers": "authorization, apikey, x-client-info, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Vary": "Origin",
};
const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" };

function respond(status: number, body: unknown) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function isPublicAddress(address: string) {
  if (address.includes(":")) {
    const lower = address.toLowerCase();
    // Accept only global unicast IPv6; reject loopback, mapped, link-local,
    // unique-local, documentation, and transition ranges.
    const first = parseInt(lower.split(":")[0] || "0", 16);
    return first >= 0x2000 && first <= 0x3fff &&
      !lower.startsWith("2001:db8:") && !lower.startsWith("2001:0:") &&
      !lower.startsWith("2002:");
  }
  const octets = address.split(".").map(Number);
  if (octets.length !== 4 || octets.some(n => !Number.isInteger(n) || n < 0 || n > 255)) return false;
  const [a, b] = octets;
  return !(a === 0 || a === 10 || a === 127 || a >= 224 ||
    (a === 100 && b >= 64 && b <= 127) ||
    (a === 169 && b === 254) || (a === 172 && b >= 16 && b <= 31) ||
    (a === 192 && (b === 0 || b === 168)) ||
    (a === 198 && (b === 18 || b === 19)));
}

async function validatePublicHttps(raw: string): Promise<URL> {
  let url: URL;
  try { url = new URL(raw); } catch { throw new Error("Enlace no válido."); }
  if (url.protocol !== "https:" || url.username || url.password || (url.port && url.port !== "443")) {
    throw new Error("Usa un enlace web público que empiece por https://.");
  }
  const host = url.hostname.toLowerCase().replace(/^\[|\]$/g, "");
  if (!host.includes(".") || host.endsWith(".local") || host.endsWith(".internal") ||
    host === "localhost" || /^\d+(\.\d+){3}$/.test(host) || host.includes(":")) {
    throw new Error("Ese enlace no parece una web pública.");
  }
  let records: string[] = [];
  try { records = await Deno.resolveDns(host, "A"); } catch { /* Try IPv6 below. */ }
  try { records.push(...await Deno.resolveDns(host, "AAAA")); } catch { /* No IPv6 records. */ }
  if (!records.length || records.some(address => !isPublicAddress(address))) {
    throw new Error("No se puede acceder de forma segura a ese dominio.");
  }
  return url;
}

function decodeJsonLd(value: string) {
  return value.replace(/^\s*<!--|-->\s*$/g, "")
    .replace(/&quot;/gi, '"').replace(/&#39;|&apos;/gi, "'")
    .replace(/&lt;/gi, "<").replace(/&gt;/gi, ">").replace(/&amp;/gi, "&").trim();
}

function findRecipes(value: unknown, found: Record<string, unknown>[] = []) {
  if (Array.isArray(value)) { for (const item of value) findRecipes(item, found); return found; }
  if (!value || typeof value !== "object") return found;
  const object = value as Record<string, unknown>;
  const rawType = object["@type"];
  const types = Array.isArray(rawType) ? rawType : [rawType];
  if (types.some(type => typeof type === "string" && type.toLowerCase().split("/").pop() === "recipe")) found.push(object);
  if (object["@graph"]) findRecipes(object["@graph"], found);
  return found;
}

function instructionText(value: unknown, output: string[] = []): string[] {
  if (typeof value === "string") { const text = value.trim(); if (text) output.push(text); return output; }
  if (Array.isArray(value)) { for (const item of value) instructionText(item, output); return output; }
  if (value && typeof value === "object") {
    const object = value as Record<string, unknown>;
    if (typeof object.text === "string") instructionText(object.text, output);
    else if (object.itemListElement) instructionText(object.itemListElement, output);
  }
  return output;
}

function displayTime(value: unknown) {
  if (typeof value !== "string") return "";
  const match = value.match(/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/i);
  if (!match) return value.slice(0, 30);
  const parts = [];
  if (match[1]) parts.push(match[1] + " h");
  if (match[2]) parts.push(match[2] + " min");
  if (!parts.length && match[3]) parts.push(match[3] + " s");
  return parts.join(" ") || "";
}

async function readLimited(response: Response, limit: number) {
  const reader = response.body?.getReader();
  if (!reader) return "";
  const chunks: Uint8Array[] = [];
  let total = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    total += value.length;
    if (total > limit) { await reader.cancel(); throw new Error("La página es demasiado grande."); }
    chunks.push(value);
  }
  const joined = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) { joined.set(chunk, offset); offset += chunk.length; }
  return new TextDecoder().decode(joined);
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  const origin = req.headers.get("origin");
  if (origin && origin !== APP_ORIGIN) return respond(403, { error: "Origen no permitido." });
  if (req.method !== "POST") return respond(405, { error: "Método no permitido." });

  try {
    const body = await req.json();
    if (typeof body?.url !== "string" || body.url.length > 2048) return respond(400, { error: "Enlace no válido." });
    let url = await validatePublicHttps(body.url);
    let response: Response | null = null;

    for (let attempt = 0; attempt < 4; attempt++) {
      const controller = new AbortController();
      const timeout = setTimeout(() => controller.abort(), 12000);
      try {
        response = await fetch(url, {
          method: "GET",
          redirect: "manual",
          signal: controller.signal,
          headers: { "Accept": "text/html,application/xhtml+xml", "User-Agent": "LaMesaRecipeImporter/1.0" },
        });
      } finally { clearTimeout(timeout); }
      if ([301, 302, 303, 307, 308].includes(response.status)) {
        const location = response.headers.get("location");
        if (!location) throw new Error("La página redirigió de forma no válida.");
        url = await validatePublicHttps(new URL(location, url).href);
        continue;
      }
      break;
    }
    if (!response || [301, 302, 303, 307, 308].includes(response.status)) throw new Error("Demasiadas redirecciones.");
    if (!response.ok) return respond(422, { error: "No se pudo leer esa página." });
    const contentType = response.headers.get("content-type") || "";
    if (!/text\/html|application\/xhtml\+xml/i.test(contentType)) return respond(422, { error: "El enlace no contiene una página web compatible." });
    const html = await readLimited(response, 1_000_000);
    const scripts = [...html.matchAll(/<script\b[^>]*type\s*=\s*["']application\/ld\+json["'][^>]*>([\s\S]*?)<\/script\s*>/gi)];
    const candidates: Record<string, unknown>[] = [];
    for (const script of scripts) {
      try { findRecipes(JSON.parse(decodeJsonLd(script[1])), candidates); } catch { /* Ignore malformed metadata blocks. */ }
    }
    const recipe = candidates.find(item =>
      typeof item.name === "string" &&
      Array.isArray(item.recipeIngredient) &&
      instructionText(item.recipeInstructions).length > 0
    );
    if (!recipe) return respond(422, { error: "No se encontró una receta estructurada en esa página." });
    const ingredients = (recipe.recipeIngredient as unknown[]).filter(item => typeof item === "string").map(item => item.trim()).filter(Boolean).slice(0, 100);
    const steps = instructionText(recipe.recipeInstructions).slice(0, 100);
    if (!ingredients.length || !steps.length) return respond(422, { error: "La receta no contiene ingredientes y pasos suficientes." });
    return respond(200, { recipe: {
      name: String(recipe.name).trim().slice(0, 100),
      time: displayTime(recipe.totalTime || recipe.cookTime || recipe.prepTime),
      ingredients,
      steps,
      sourceUrl: url.href,
    }});
  } catch (error) {
    const message = error instanceof Error ? error.message : "No se pudo importar la receta.";
    const status = /https|dominio|enlace|web pública/i.test(message) ? 400 : 422;
    return respond(status, { error: message });
  }
});
