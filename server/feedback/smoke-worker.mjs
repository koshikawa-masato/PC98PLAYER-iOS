// SPDX-License-Identifier: MIT
import { deliverFeedback } from "./delivery.mjs";

// Staging only. This endpoint cannot accept user reports.
export default {
  async fetch(request, env) {
    const path = new URL(request.url).pathname;
    if (path !== "/__feedback-smoke" || request.method !== "POST" || !env.SMOKE_TOKEN ||
        request.headers.get("Authorization") !== `Bearer ${env.SMOKE_TOKEN}`) {
      return new Response(null, { status: 404 });
    }
    if (!env.EMAIL || !env.FEEDBACK_FROM) return new Response(null, { status: 503 });

    const receipt = crypto.randomUUID();
    try {
      await deliverFeedback(env, {
        provider: "anonymous",
        title: "受付テスト",
        body: "RetroDOS PlayerのCloudflare受付からGmailまでの疎通確認です。",
        app_version: "smoke-test",
        os_version: "smoke-test",
      }, null, receipt);
    } catch {
      return new Response(null, { status: 502 });
    }
    return Response.json({ receipt }, { status: 201 });
  },
};
