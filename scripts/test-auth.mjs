import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { randomUUID, createHash } from "node:crypto";
import { setTimeout } from "node:timers/promises";
import { parseArgs } from "node:util";

// Local CLI credentials stay in memory; never use a linked/remote project.
const status = spawnSync("supabase", ["status", "-o", "json"], {
  encoding: "utf8",
});
assert.equal(status.status, 0, "Start the local Supabase stack first");
const config = JSON.parse(status.stdout);
const api = new URL(config.API_URL);
const mailbox = new URL(config.MAILPIT_URL ?? config.INBUCKET_URL);
for (const url of [api, mailbox]) {
  assert.equal(url.hostname, "127.0.0.1", "Only local services are allowed");
  assert.equal(url.protocol, "http:");
}
const { values } = parseArgs({ options: { email: { type: "string" } } });
const email = values.email ?? `auth-smoke-${randomUUID()}@example.test`;
const password = "Test123!";
const verifier = randomUUID() + randomUUID();
const challenge = createHash("sha256").update(verifier).digest("base64url");
const headers = {
  apikey: config.PUBLISHABLE_KEY,
  "Content-Type": "application/json",
};
const adminHeaders = {
  apikey: config.SECRET_KEY ?? config.SERVICE_ROLE_KEY,
  Authorization: `Bearer ${config.SERVICE_ROLE_KEY}`,
};
let userId;
let messageId;

async function request(path, body) {
  return fetch(new URL(path, api), {
    method: "POST",
    headers,
    body: JSON.stringify(body),
  });
}
async function signup(value) {
  return request("/auth/v1/signup?redirect_to=dailytracker%3A%2F%2Fcallback", {
    email,
    password: value,
    code_challenge: challenge,
    code_challenge_method: "s256",
  });
}
try {
  // A requested test address must never overwrite or delete an existing account.
  for (let page = 1; ; page++) {
    const response = await fetch(
      new URL(`/auth/v1/admin/users?page=${page}&per_page=1000`, api),
      { headers: adminHeaders },
    );
    assert.equal(
      response.status,
      200,
      "Local cleanup credentials must be available",
    );
    const { users } = await response.json();
    assert.ok(
      !users.some((user) => user.email?.toLowerCase() === email.toLowerCase()),
      "Test address already exists; its account was preserved. Choose an unused test address.",
    );
    if (users.length < 1000) break;
  }
  const rejected = await signup("Short1!");
  assert.equal(rejected.status, 422, "Seven-character passwords must fail");
  assert.equal((await rejected.json()).error_code, "weak_password");
  const registered = await signup(password);
  const registration = await registered.json();
  userId = registration.id ?? registration.user?.id;
  assert.equal(
    registered.status,
    200,
    `Eight-character signup failed: ${registered.status} ${registration.error_code ?? ""}`,
  );
  assert.ok(userId, "Signup must create an Auth user");
  assert.ok(
    !registration.access_token,
    "Email confirmation must remain required",
  );
  console.log(
    "PASS: password policy (7 rejected / 8 accepted), signup and confirmation required",
  );

  for (let attempt = 0; attempt < 30; attempt++) {
    const response = await fetch(
      new URL(
        `/api/v1/search?query=${encodeURIComponent(`to:${email}`)}`,
        mailbox,
      ),
    );
    assert.equal(response.status, 200, "Mailpit must be available");
    const messages = await response.json();
    messageId = messages.messages?.[0]?.ID;
    if (messageId) break;
    await setTimeout(200);
  }
  assert.ok(messageId, "Confirmation email must arrive in the local mailbox");
  const message = await (
    await fetch(new URL(`/api/v1/message/${messageId}`, mailbox))
  ).json();
  const link = (message.HTML ?? message.Text)
    .match(/https?:\/\/[^\s"<>]+\/auth\/v1\/verify\?[^\s"<>]+/)?.[0]
    ?.replaceAll("&amp;", "&");
  assert.ok(link, "Email must contain a verification link");
  assert.equal(
    new URL(link).origin,
    api.origin,
    "Verification must stay local",
  );
  const verified = await fetch(link, { redirect: "manual" });
  assert.equal(verified.status, 303, "Verification must redirect to the app");
  const callback = new URL(verified.headers.get("location"));
  assert.equal(callback.protocol, "dailytracker:");
  assert.equal(callback.hostname, "callback");
  const code = callback.searchParams.get("code");
  assert.ok(code, "PKCE callback must include an authorization code");
  const exchanged = await request("/auth/v1/token?grant_type=pkce", {
    auth_code: code,
    code_verifier: verifier,
  });
  assert.equal(exchanged.status, 200, "S256 PKCE exchange must succeed");
  const session = await exchanged.json();
  const profileResponse = await fetch(
    new URL(`/rest/v1/profiles?id=eq.${userId}&select=id`, api),
    {
      headers: { ...headers, Authorization: `Bearer ${session.access_token}` },
    },
  );
  assert.equal(
    profileResponse.status,
    200,
    "Owner must be able to read their profile",
  );
  assert.deepEqual(
    await profileResponse.json(),
    [{ id: userId }],
    "Auth must create the profile atomically",
  );
  console.log(
    "PASS: confirmation email, callback, S256 exchange and profile through authenticated RLS",
  );
} finally {
  if (userId) {
    const deleted = await fetch(
      new URL(`/auth/v1/admin/users/${userId}`, api),
      { method: "DELETE", headers: adminHeaders },
    );
    assert.ok(deleted.ok, "Synthetic Auth user cleanup must succeed");
    console.log("PASS: synthetic user and profile removed");
  }
  if (messageId) {
    const deleted = await fetch(new URL(`/api/v1/messages`, mailbox), {
      method: "DELETE",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ IDs: [messageId] }),
    });
    assert.ok(deleted.ok, "Synthetic email cleanup must succeed");
  }
}
