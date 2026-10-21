// Exercise the real coordinator and SessionManager inside the installed Pi.
// Only adapt the command's TUI check: the test drives this parent over RPC.
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { installParley } from "../../pi/parley.ts";

export default function (pi: ExtensionAPI): void {
  const host = Object.create(pi) as ExtensionAPI;
  host.registerCommand = (name, command) => pi.registerCommand(name, {
    ...command,
    handler: (args, ctx) => command.handler(args, { ...ctx, mode: "tui" }),
  });
  const coordinator = installParley(host, { busy: () => false, release: async () => {}, captureCommit: async () => "a".repeat(40) });
  pi.on("session_shutdown", () => coordinator.close());
}
