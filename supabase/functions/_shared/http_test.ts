// deno test --allow-env supabase/functions/_shared/http_test.ts
import { clientIp, readJson } from "./http.ts";

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const post = (body: BodyInit, headers: Record<string, string> = {}) =>
  new Request("http://x/", { method: "POST", body, headers });

Deno.test("small JSON object is read", async () => {
  const v = await readJson(post(JSON.stringify({ a: 1 })));
  assert(v?.a === 1, "not parsed");
});

Deno.test("body over the limit is rejected without reading it all", async () => {
  let pulled = 0;
  const stream = new ReadableStream<Uint8Array>({
    pull(c) {
      pulled++;
      c.enqueue(new Uint8Array(1024).fill(32));
      if (pulled > 1000) c.close();
    },
  });
  assert((await readJson(post(stream), 4096)) === null, "oversized body accepted");
  assert(pulled < 20, `read ${pulled} chunks of an oversized body`);
});

Deno.test("limit counts bytes, not characters", async () => {
  const body = JSON.stringify({ s: "€".repeat(2000) }); // ~2000 chars, ~6000 bytes
  assert((await readJson(post(body), 4096)) === null, "multibyte body slipped under the limit");
});

Deno.test("arrays, junk and empty bodies are rejected", async () => {
  for (const b of ["[1,2]", "not json", ""]) assert((await readJson(post(b))) === null, `accepted ${b}`);
});

Deno.test("client IP prefers the Cloudflare header over client-supplied forwarding headers", () => {
  const req = new Request("http://x/", { headers: { "x-forwarded-for": "6.6.6.6, 10.0.0.1", "cf-connecting-ip": "1.2.3.4" } });
  assert(clientIp(req) === "1.2.3.4", clientIp(req));
});
