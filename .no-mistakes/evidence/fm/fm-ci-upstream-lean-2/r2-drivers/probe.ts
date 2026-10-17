// Lab probe extension: records Pi's real before_agent_start event and, when
// PROBE_OFFER=1, plays fm-primary-pi-watch's role by offering one eligible wake
// to the branch at agent_start (before Pi persists the captain's prompt), then
// waits for the branch's model request to reach the stand-in server.
import { appendFileSync, existsSync, readFileSync } from "node:fs";
export default function (pi: any) {
  const log = process.env.PROBE_LOG as string;
  const requests = process.env.PROBE_REQUESTS as string;
  const record = (o: unknown) => appendFileSync(log, `${JSON.stringify(o)}\n`);
  pi.on("before_agent_start", (event: any) => {
    record({
      hook: "before_agent_start",
      keys: Object.keys(event).sort(),
      messageType: "messageType" in event ? event.messageType : "(absent)",
      prompt: event.prompt,
      updatedGuardAdmits: "prompt" in event,
      round1GuardDrops: event.messageType !== "user",
    });
  });
  let offered = false;
  pi.on("agent_start", async (_event: any, ctx: any) => {
    if (process.env.PROBE_OFFER !== "1" || offered) return;
    offered = true;
    const persisted = (ctx?.sessionManager?.getEntries?.() ?? [])
      .filter((e: any) => e.type === "message" && e.message?.role === "user").length;
    const offer: any = {
      message: "heartbeat: lab review for the branch", projects: [], heartbeat: true, eligible: true, awayOnly: false,
      accepted: false, settlement: Promise.resolve(),
      accept(s = Promise.resolve()) { offer.accepted = true; offer.settlement = s; },
    };
    pi.events.emit("fm-branch-supervision:dispatch", offer);
    record({ hook: "agent_start", persistedUserMessagesAtOffer: persisted, offerAccepted: offer.accepted });
    const before = existsSync(requests) ? readFileSync(requests, "utf8").split("\n").filter(Boolean).length : 0;
    let branchBody = "";
    for (let i = 0; i < 300 && !branchBody; i += 1) {
      await new Promise((r) => setTimeout(r, 100));
      const rows = existsSync(requests) ? readFileSync(requests, "utf8").split("\n").filter(Boolean) : [];
      branchBody = rows.slice(before).find((row) => row.includes("fm_branch_report")) ?? "";
    }
    const settled = await Promise.race([offer.settlement.then(() => "resolved", (e: any) => `rejected: ${e?.message ?? e}`), new Promise((r) => setTimeout(() => r("pending after 5s"), 5000))]);
    record({
      hook: "branch-request",
      branchReachedModel: Boolean(branchBody),
      mirrorCarriesCaptainPrompt: branchBody.includes("[captain] captain: please check the fleet"),
      mirrorExcerpt: (branchBody.match(/\[captain\][^"\\]{0,80}/g) ?? []).slice(0, 3),
      settlement: settled,
    });
  });
}
