// Pings Bubble when pi has finished and is waiting on you. Copy this to ~/.pi/agent/extensions/bubble.ts
// agent_settled only fires once pi won't carry on by itself, so a retry or a queued follow-up doesn't ping early.
// @ts-nocheck
import { execFile } from "node:child_process";
import { existsSync } from "node:fs";
import { homedir } from "node:os";

const bubble = ["/Applications", `${homedir()}/Applications`]
  .map((dir) => `${dir}/Bubble.app/Contents/MacOS/Bubble`)
  .find(existsSync);

export default function (pi) {
  if (!bubble) return;
  pi.on("agent_settled", () => {
    execFile(bubble, ["notify", "pi finished"], () => {});
  });
}
