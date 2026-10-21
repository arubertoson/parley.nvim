// Purpose-built SDK boundary fake, not an SDK compatibility test. The real
// interaction and artifact writer run offline; no credentials or model are used.
import path from "node:path";
import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import type { ReviewModel } from "../../pi/interaction.ts";

export const model: ReviewModel = {
  provider: "offline", id: "review", name: "Offline", api: "openai-completions",
  baseUrl: "https://invalid.example", reasoning: false, input: ["text"],
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 }, contextWindow: 8192, maxTokens: 1024,
};

const zeroUsage = { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, totalTokens: 0,
  cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 } };

type SessionEvent =
  | { readonly type: "agent_start" }
  | { readonly type: "agent_settled"; readonly aborted: boolean }
  | { readonly type: "message_end"; readonly message: { readonly role: "assistant"; readonly stopReason: string; readonly usage: typeof zeroUsage } };

type SessionManagerHandle = {
  getSessionId(): string;
  getSessionFile(): string;
  getLeafId(): null;
};

type SessionOptions = {
  readonly model: ReviewModel;
  readonly thinkingLevel: string;
  readonly tools: string[];
  readonly customTools: ToolDefinition[];
  readonly sessionManager: SessionManagerHandle;
};

type SdkControl = {
  session?: FakeSession;
  creations: number;
  beforeCreate?: () => Promise<void>;
  beforePrompt?: () => Promise<void>;
  onPrompt?: (session: FakeSession, prompt: string) => Promise<void>;
};

export const sdk: SdkControl = { creations: 0 };

export function resetSdk(): void {
  sdk.session = undefined;
  sdk.creations = 0;
  sdk.beforeCreate = undefined;
  sdk.beforePrompt = undefined;
  sdk.onPrompt = undefined;
}

export class FakeSession {
  readonly model: ReviewModel;
  readonly thinkingLevel: string;
  readonly sessionManager: SessionManagerHandle;
  readonly tools: ReadonlyMap<string, ToolDefinition>;
  readonly listeners = new Set<(event: SessionEvent) => void>();
  private activeTools: string[];
  aborted = false;
  disposed = false;
  summary = "Reviewer summary";

  constructor(options: SessionOptions) {
    this.model = options.model;
    this.thinkingLevel = options.thinkingLevel;
    this.sessionManager = options.sessionManager;
    this.tools = new Map(options.customTools.map(tool => [tool.name, tool]));
    this.activeTools = [...options.tools];
  }

  get sessionId(): string { return this.sessionManager.getSessionId(); }
  getActiveToolNames(): string[] { return [...this.activeTools]; }
  getCallableToolNames(): string[] { return [...this.activeTools]; }
  setActiveToolsByName(names: string[]): void { this.activeTools = [...names]; }
  getLastAssistantText(): string { return this.summary; }

  subscribe(listener: (event: SessionEvent) => void): () => void {
    this.listeners.add(listener);
    return () => { this.listeners.delete(listener); };
  }

  private emit(event: SessionEvent): void {
    for (const listener of this.listeners) listener(event);
  }

  async prompt(prompt: string): Promise<void> {
    this.aborted = false;
    await sdk.beforePrompt?.();
    this.emit({ type: "agent_start" });
    await sdk.onPrompt?.(this, prompt);
    this.emit({ type: "message_end", message: { role: "assistant", stopReason: this.aborted ? "aborted" : "stop", usage: zeroUsage } });
    this.emit({ type: "agent_settled", aborted: this.aborted });
  }

  async waitForIdle(): Promise<void> {}
  async abort(): Promise<void> { this.aborted = true; }
  dispose(): void { this.disposed = true; }
}

export async function createAgentSession(options: SessionOptions): Promise<{ session: FakeSession }> {
  sdk.creations++;
  await sdk.beforeCreate?.();
  const session = new FakeSession(options);
  sdk.session = session;
  return { session };
}

export const ModelRuntime = { create: async () => ({ getModel: () => model }) };
export const SessionManager = {
  create: (_root: string, directory: string): SessionManagerHandle => ({
    getSessionId: () => "review-session",
    getSessionFile: () => path.join(directory, "transcript.jsonl"),
    getLeafId: () => null,
  }),
};
export const SettingsManager = { inMemory: () => ({}) };
export function createExtensionRuntime(): object { return {}; }
