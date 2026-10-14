// No tokenizer dependency: UTF-8 bytes conservatively upper-bound text tokens.
// Include framing headroom; this deliberately underfills typical code contexts.
export function inputTokenBound(system: string, prompt: string): number {
  return Buffer.byteLength(system, "utf8") + Buffer.byteLength(prompt, "utf8") + 2048;
}
export function inputFits(contextWindow: number, system: string, prompt: string, ratio = 0.5): boolean {
  return Number.isFinite(contextWindow) && inputTokenBound(system, prompt) <= Math.floor(contextWindow * ratio);
}
export function checkInputBudget(contextWindow: number, system: string, prompt: string, recovery: string): void {
  if (!inputFits(contextWindow, system, prompt)) {
    throw new Error(`Review input exceeds the 50% context budget (${inputTokenBound(system, prompt)} conservative token bound; limit ${Math.floor(contextWindow / 2)}). ${recovery}`);
  }
}
