// Pings Notchy when pi has finished and is waiting on you. Copy this to ~/.pi/agent/extensions/notchy.ts
// agent_settled only fires once pi won't carry on by itself, so a retry or a queued follow-up doesn't ping early.
// @ts-nocheck
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";

const notchy = ["/Applications", `${homedir()}/Applications`]
  .map((dir) => `${dir}/Notchy.app/Contents/MacOS/Notchy`)
  .find(existsSync);

export default function (pi) {
  if (!notchy) return;
  pi.on("agent_settled", () => {
    execFile(notchy, ["notify", "pi finished"], () => {});
  });
}
