// SPDX-License-Identifier: MIT
import {installationToken} from './github.mjs';
const recipient = "firecracker.rebirth@gmail.com";
const issueEndpoint = "https://api.github.com/repos/koshikawa-masato/PC98PLAYER-iOS/issues";

// Call from the durable outbox consumer after validation and OAuth verification.
// The verified account comes from the provider API, never from the submitted JSON.
export async function deliverFeedback(env, report, account, receipt, send=fetch) {
  const { provider, title, body, app_version, os_version, screenshot_png } = report;
  if (!["anonymous", "github", "x"].includes(provider) ||
      (provider !== "anonymous" && (account?.provider !== provider || !account.handle))) {
    throw new Error("Missing verified feedback identity");
  }

  const metadata = [
    `受付番号: ${receipt}`,
    `RetroDOS Player: ${app_version}`,
    `OS: ${os_version}`,
  ];
  if (provider === "github") {
    const handle = account.handle;
    if (!/^[A-Za-z0-9-]{1,39}$/.test(handle)) throw new Error("Invalid GitHub handle");
    const token = await installationToken(env, send);
    const response = await send(issueEndpoint, {
      method: "POST",
      redirect: "manual",
      signal: AbortSignal.timeout(15000),
      headers: {
        Authorization: `Bearer ${token}`,
        Accept: "application/vnd.github+json",
        "Content-Type": "application/json",
        "User-Agent": "RetroDOS-Feedback",
      },
      body: JSON.stringify({
        title,
        body: [body, ...metadata, `報告者: [${handle}](https://github.com/${handle})`,
          `<!-- retrodos-receipt:${receipt} -->`].join("\n\n"),
      }),
    });
    if (response.status !== 201) throw new Error(`GitHub returned ${response.status}`);
    const issue = await response.json();
    return { channel: "github", issueNumber: issue.number, url: issue.html_url };
  }

  const message = {
    to: recipient,
    from: env.FEEDBACK_FROM,
    subject: `[RetroDOS] ${title.replace(/[\r\n]+/g, " ")}`,
    text: [body, ...metadata, provider === "x" ? `報告者: X @${account.handle}` : "報告者: 匿名"].join("\n\n"),
  };
  if (screenshot_png) {
    message.attachments = [{
      content: screenshot_png,
      filename: "retrodos-screenshot.png",
      type: "image/png",
      disposition: "attachment",
    }];
  }
  const delivery = await env.EMAIL.send(message);
  return { channel: "email", messageId: delivery.messageId };
}
