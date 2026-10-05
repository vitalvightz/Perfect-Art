// deno test --allow-env supabase/functions/_shared/crypto_test.ts
Deno.env.set("TICKET_SIGNING_SECRET", "test-secret-that-is-at-least-32-characters-long");
const { randomToken, sha256Hex, signTicket, verifyTicket } = await import("./crypto.ts");

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(msg);
}

const id = "3f2b8c1e-6d4a-4f7b-9a0c-1e2d3f4a5b6c";

Deno.test("a signed ticket verifies back to its id", async () => {
  assert((await verifyTicket(await signTicket(id))) === id, "round trip failed");
});

Deno.test("an edited ticket id is rejected", async () => {
  const code = await signTicket(id);
  const other = code.replace(id, "3f2b8c1e-6d4a-4f7b-9a0c-1e2d3f4a5b6d");
  assert((await verifyTicket(other)) === null, "edited id accepted");
});

Deno.test("an edited signature is rejected", async () => {
  const code = await signTicket(id);
  const flipped = code.slice(0, -1) + (code.endsWith("A") ? "B" : "A");
  assert((await verifyTicket(flipped)) === null, "edited signature accepted");
});

Deno.test("garbage codes are rejected", async () => {
  for (const c of ["", "PA1", `PA1.${id}`, `PA1.${id}.short`, "ticket/152", `PA2.${id}.${"a".repeat(43)}`]) {
    assert((await verifyTicket(c)) === null, `accepted ${c}`);
  }
});

Deno.test("random tokens are 256-bit and unique", () => {
  const a = randomToken(), b = randomToken();
  assert(/^[A-Za-z0-9_-]{43}$/.test(a) && a !== b, "bad token");
});

Deno.test("sha256 matches a known vector", async () => {
  assert((await sha256Hex("abc")) === "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "wrong hash");
});
