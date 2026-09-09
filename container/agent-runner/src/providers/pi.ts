/**
 * `pi` provider — a thin, general-assistant agent loop built on the Pi agent
 * harness (`@earendil-works/pi-agent-core` + `@earendil-works/pi-ai`).
 *
 * Why this exists: OpenCode is a coding-agent harness — it bootstraps its cwd
 * as a software project, injects a coding system prompt, and exposes a large
 * dev tool surface. A weak local model (e.g. a 14B served over an
 * OpenAI-compatible gateway) drowns in that framing and confabulates instead of
 * acting. Pi's `agent-core` is decoupled from its coding tools, so here we drive
 * it with ONLY:
 *   - the system prompt NanoClaw composed (persona + destinations), nothing else
 *   - a curated tool set bridged from NanoClaw's own MCP tools server
 *   - a direct OpenAI-compatible connection to the configured gateway
 *
 * Pi has no MCP support ("does not and will not"), so we run the MCP stdio
 * client ourselves (`@modelcontextprotocol/sdk`, already a runtime dep) and wrap
 * each MCP tool as a native Pi `AgentTool`.
 *
 * Runtime configuration comes from PI_* env (injected by the host-side
 * container-config in `src/providers/pi.ts`):
 *   PI_BASE_URL            OpenAI-compatible base URL, e.g. https://host/v1
 *   PI_MODEL               model id served by the gateway, e.g. qwen14
 *   PI_CONTEXT_WINDOW      context window in tokens (required for a custom model)
 *   PI_MAX_TOKENS          max output tokens
 *   PI_API_KEY             optional; defaults to "placeholder" for keyless gateways
 *   PI_THINKING_FORMAT     optional pi-ai compat thinkingFormat (e.g. "qwen")
 *
 * Continuation: Pi's message array IS the serializable state. We persist it to
 * `<cwd>/.pi-sessions/<id>.json` and reload on resume; the continuation token is
 * the session id.
 */
import { spawnSync } from 'child_process';
import fs from 'fs';
import path from 'path';

import { registerProvider } from './provider-registry.js';
import type {
  AgentProvider,
  AgentQuery,
  McpServerConfig,
  ProviderEvent,
  ProviderExchange,
  ProviderOptions,
  QueryInput,
} from './types.js';
import type { MemorySessionHookRegistration } from '../memory/session-hook.js';

// Container stderr is lost when the container exits (--rm), so mirror provider
// logs into a file in the (persisted) agent workspace for post-mortem
// diagnosis. Best-effort; never throws.
const PI_LOG_FILE = process.env.PI_LOG_FILE || '/workspace/agent/.pi-provider.log';
function log(msg: string): void {
  const line = `[pi-provider] ${msg}`;
  console.error(line);
  try {
    fs.appendFileSync(PI_LOG_FILE, `${new Date().toISOString()} ${line}\n`);
  } catch {
    /* ignore */
  }
}

const MEMORY_HOOK_TIMEOUT_MS = 10_000;
const SESSIONS_DIR = '.pi-sessions';

/**
 * A tiny push/pull async queue: the Pi agent's callback subscription pushes
 * ProviderEvents in, the poll-loop drains them out via the async iterator.
 */
class EventQueue {
  private items: ProviderEvent[] = [];
  private resolvers: ((r: IteratorResult<ProviderEvent>) => void)[] = [];
  private closed = false;

  push(item: ProviderEvent): void {
    if (this.closed) return;
    const r = this.resolvers.shift();
    if (r) r({ value: item, done: false });
    else this.items.push(item);
  }

  close(): void {
    if (this.closed) return;
    this.closed = true;
    let r: ((res: IteratorResult<ProviderEvent>) => void) | undefined;
    while ((r = this.resolvers.shift())) r({ value: undefined as never, done: true });
  }

  [Symbol.asyncIterator](): AsyncIterator<ProviderEvent> {
    return {
      next: (): Promise<IteratorResult<ProviderEvent>> => {
        if (this.items.length) return Promise.resolve({ value: this.items.shift()!, done: false });
        if (this.closed) return Promise.resolve({ value: undefined as never, done: true });
        return new Promise((resolve) => this.resolvers.push(resolve));
      },
    };
  }
}

/**
 * Bun-native proxy fetch. In the container the gateway is reachable ONLY through
 * the OneCLI HTTPS proxy (the container has no tailnet route); pi-ai's
 * openai-completions path does not consult proxy env on its own, so we inject a
 * fetch that routes through HTTPS_PROXY. Bun's fetch takes a per-request `proxy`
 * option. Requests to localhost (e.g. never, here) would bypass via NO_PROXY,
 * but pi-ai only ever calls the gateway.
 */
function makeProxyFetch(): typeof fetch | undefined {
  const proxy = process.env.HTTPS_PROXY || process.env.https_proxy;
  if (!proxy) return undefined;
  return ((input: Parameters<typeof fetch>[0], init?: Parameters<typeof fetch>[1]) =>
    fetch(input, { ...(init ?? {}), proxy } as RequestInit)) as typeof fetch;
}

interface PiModelEnv {
  baseUrl: string;
  model: string;
  contextWindow: number;
  maxTokens: number;
  apiKey: string;
  thinkingFormat?: string;
}

function readModelEnv(): PiModelEnv {
  const baseUrl = process.env.PI_BASE_URL?.trim();
  const model = process.env.PI_MODEL?.trim();
  if (!baseUrl) throw new Error('PI_BASE_URL is not set — the pi provider needs an OpenAI-compatible base URL');
  if (!model) throw new Error('PI_MODEL is not set — the pi provider needs a model id');
  const contextWindow = Number.parseInt(process.env.PI_CONTEXT_WINDOW ?? '', 10);
  const maxTokens = Number.parseInt(process.env.PI_MAX_TOKENS ?? '', 10);
  return {
    baseUrl,
    model,
    contextWindow: Number.isFinite(contextWindow) && contextWindow > 0 ? contextWindow : 16384,
    maxTokens: Number.isFinite(maxTokens) && maxTokens > 0 ? maxTokens : 4096,
    apiKey: process.env.PI_API_KEY?.trim() || 'placeholder',
    thinkingFormat: process.env.PI_THINKING_FORMAT?.trim() || undefined,
  };
}

/**
 * Build the pi-ai model registry + streamFn for the configured gateway. Cached
 * for the process — the model config comes from env and never changes mid-run.
 */
let cachedRuntime: Promise<{ model: unknown; streamFn: (m: unknown, c: unknown, o?: unknown) => unknown }> | null = null;
function getModelRuntime(): Promise<{ model: unknown; streamFn: (m: unknown, c: unknown, o?: unknown) => unknown }> {
  if (cachedRuntime) return cachedRuntime;
  cachedRuntime = buildModelRuntime();
  return cachedRuntime;
}

async function buildModelRuntime(): Promise<{
  model: unknown;
  streamFn: (m: unknown, c: unknown, o?: unknown) => unknown;
}> {
  // Lazy-loaded so the ~100MB pi-ai dep tree is only pulled into containers that
  // actually run the pi provider — the provider barrel imports this module in
  // every container to register the name.
  const { createModels, createProvider } = await import('@earendil-works/pi-ai');
  const { openAICompletionsApi } = await import('@earendil-works/pi-ai/api/openai-completions.lazy');
  const env = readModelEnv();
  const model = {
    id: env.model,
    name: env.model,
    api: 'openai-completions',
    provider: 'gateway',
    baseUrl: env.baseUrl,
    reasoning: false,
    input: ['text'],
    cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
    contextWindow: env.contextWindow,
    maxTokens: env.maxTokens,
    compat: {
      supportsDeveloperRole: false,
      supportsReasoningEffort: false,
      ...(env.thinkingFormat ? { thinkingFormat: env.thinkingFormat } : {}),
    },
  };
  const models = createModels();
  models.setProvider(
    createProvider({
      id: 'gateway',
      name: 'Gateway',
      baseUrl: env.baseUrl,
      auth: { apiKey: { name: 'gateway', resolve: async () => ({ auth: { apiKey: env.apiKey } }) } },
      models: [model as never],
      api: openAICompletionsApi() as never,
    } as never),
  );
  const resolved = (models as { getModel(p: string, id: string): unknown }).getModel('gateway', env.model);
  const proxyFetch = makeProxyFetch();
  const baseStream = (models as { streamSimple: (m: unknown, c: unknown, o?: unknown) => unknown }).streamSimple.bind(
    models,
  );
  const streamFn = (m: unknown, c: unknown, o?: unknown): unknown =>
    baseStream(m, c, proxyFetch ? { ...(o as object), fetch: proxyFetch } : o);
  return { model: resolved, streamFn };
}

/**
 * pi-ai re-exports TypeBox's `Type`. Pi only serializes real TypeBox schemas
 * into the request `tools` array — a hand-written JSON-Schema object is dropped,
 * so the model never sees the tool. Everything we expose must be built with (or
 * converted to) `Type`. Cached; lazily imported like the rest of pi-ai.
 */
let cachedType: Promise<{ Type: TypeBuilder }> | null = null;
type TypeBuilder = {
  Object: (props: Record<string, unknown>, opts?: unknown) => unknown;
  String: (opts?: unknown) => unknown;
  Number: (opts?: unknown) => unknown;
  Integer: (opts?: unknown) => unknown;
  Boolean: (opts?: unknown) => unknown;
  Array: (items: unknown, opts?: unknown) => unknown;
  Optional: (schema: unknown) => unknown;
  Union: (schemas: unknown[]) => unknown;
  Literal: (value: unknown) => unknown;
  Any: () => unknown;
};
async function getType(): Promise<TypeBuilder> {
  if (!cachedType) cachedType = import('@earendil-works/pi-ai').then((m) => ({ Type: m.Type as unknown as TypeBuilder }));
  return (await cachedType).Type;
}

/** Convert a JSON-Schema object (e.g. an MCP tool's inputSchema) into a TypeBox schema. */
function jsonSchemaToTypebox(schema: unknown, Type: TypeBuilder): unknown {
  const s = (schema ?? {}) as {
    type?: string;
    properties?: Record<string, unknown>;
    required?: string[];
    items?: unknown;
    enum?: unknown[];
    description?: string;
  };
  const opts = s.description ? { description: s.description } : undefined;
  if (Array.isArray(s.enum) && s.enum.length) return Type.Union(s.enum.map((v) => Type.Literal(v)));
  switch (s.type) {
    case 'string':
      return Type.String(opts);
    case 'number':
      return Type.Number(opts);
    case 'integer':
      return Type.Integer(opts);
    case 'boolean':
      return Type.Boolean(opts);
    case 'array':
      return Type.Array(s.items ? jsonSchemaToTypebox(s.items, Type) : Type.Any(), opts);
    case 'object':
    default: {
      const props: Record<string, unknown> = {};
      const required = new Set(s.required ?? []);
      for (const [k, v] of Object.entries(s.properties ?? {})) {
        const child = jsonSchemaToTypebox(v, Type);
        props[k] = required.has(k) ? child : Type.Optional(child);
      }
      return Type.Object(props, opts);
    }
  }
}

/**
 * An MCP stdio server we've connected to, and the Pi tools it contributed.
 * Cached per (serialized) mcpServers config for the process lifetime so we
 * don't respawn the servers on every turn.
 */
interface McpBridge {
  clients: unknown[];
  tools: unknown[];
}
let cachedBridge: { key: string; bridge: Promise<McpBridge> } | null = null;

function stringEnv(extra?: Record<string, string>): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(process.env)) if (typeof v === 'string') out[k] = v;
  if (extra) for (const [k, v] of Object.entries(extra)) out[k] = v;
  return out;
}

/** Convert an MCP tool result's content array into Pi tool-result content. */
function toPiContent(result: unknown): { type: 'text'; text: string }[] {
  const content = (result as { content?: unknown[] })?.content;
  if (!Array.isArray(content)) {
    return [{ type: 'text', text: typeof result === 'string' ? result : JSON.stringify(result ?? '') }];
  }
  const parts: { type: 'text'; text: string }[] = [];
  for (const item of content) {
    const it = item as { type?: string; text?: string };
    if (it.type === 'text' && typeof it.text === 'string') parts.push({ type: 'text', text: it.text });
    else parts.push({ type: 'text', text: JSON.stringify(item) });
  }
  return parts.length ? parts : [{ type: 'text', text: '' }];
}

/**
 * Which MCP servers to bridge. A weak local model degrades fast as the tool
 * surface grows (a full chrome-devtools server alone adds ~29 large schemas
 * that blow a 16k context and overwhelm tool selection), so default to the core
 * `nanoclaw` server ONLY. Opt in to more with PI_MCP_SERVERS (comma-separated
 * names, or `all`).
 */
function allowedMcpServers(): { all: boolean; names: Set<string> } {
  const raw = process.env.PI_MCP_SERVERS?.trim();
  if (!raw) return { all: false, names: new Set(['nanoclaw']) };
  if (raw.toLowerCase() === 'all') return { all: true, names: new Set() };
  return { all: false, names: new Set(raw.split(',').map((s) => s.trim()).filter(Boolean)) };
}

async function connectMcpServers(mcpServers: Record<string, McpServerConfig>): Promise<McpBridge> {
  const { Client } = await import('@modelcontextprotocol/sdk/client/index.js');
  const { StdioClientTransport } = await import('@modelcontextprotocol/sdk/client/stdio.js');
  const Type = await getType();
  const allow = allowedMcpServers();
  const clients: unknown[] = [];
  const tools: unknown[] = [];
  for (const [name, cfg] of Object.entries(mcpServers)) {
    if (!allow.all && !allow.names.has(name)) {
      log(`Skipping MCP server "${name}" — not in the pi tool allowlist (set PI_MCP_SERVERS to include it)`);
      continue;
    }
    if ('type' in cfg && cfg.type === 'http') {
      log(`Skipping HTTP MCP server "${name}" — the pi bridge supports stdio servers only for now`);
      continue;
    }
    const stdio = cfg as Extract<McpServerConfig, { command: string }>;
    try {
      const transport = new StdioClientTransport({
        command: stdio.command,
        args: stdio.args ?? [],
        env: stringEnv(stdio.env),
        cwd: stdio.cwd,
      });
      const client = new Client({ name: `nanoclaw-pi-${name}`, version: '1.0.0' }, { capabilities: {} });
      await client.connect(transport);
      const listed = await client.listTools();
      for (const t of listed.tools) {
        const toolName = t.name;
        tools.push({
          name: toolName,
          label: toolName,
          description: t.description ?? toolName,
          parameters: jsonSchemaToTypebox(t.inputSchema ?? { type: 'object', properties: {} }, Type),
          execute: async (_id: string, params: unknown) => {
            const res = await client.callTool({ name: toolName, arguments: (params ?? {}) as Record<string, unknown> });
            return { content: toPiContent(res), details: res };
          },
        });
      }
      clients.push(client);
      log(`Bridged ${listed.tools.length} tool(s) from MCP server "${name}"`);
    } catch (err) {
      log(`Failed to connect MCP server "${name}": ${err instanceof Error ? err.message : String(err)}`);
    }
  }
  return { clients, tools };
}

/**
 * A small set of native local-action tools, so the assistant can actually DO
 * things (run a command, read a file) rather than confabulate. Deliberately
 * tiny — the whole point of this provider is a minimal surface a weak local
 * model can drive reliably. Set PI_DISABLE_LOCAL_TOOLS=1 to omit them (pure
 * chat + messaging only).
 */
function builtinTools(cwd: string, Type: TypeBuilder): unknown[] {
  if (process.env.PI_DISABLE_LOCAL_TOOLS === '1') return [];
  return [
    {
      name: 'bash',
      label: 'Bash',
      description:
        'Run a shell command in your workspace and return its combined stdout/stderr. Use this for local actions like listing files (ls), inspecting the workspace, or running scripts.',
      parameters: Type.Object({
        command: Type.String({ description: 'The shell command to run.' }),
      }),
      execute: async (_id: string, params: { command?: string }) => {
        const command = String(params?.command ?? '').trim();
        if (!command) return { content: [{ type: 'text', text: 'No command provided.' }], details: {} };
        const res = spawnSync('bash', ['-lc', command], {
          cwd,
          encoding: 'utf-8',
          timeout: 60_000,
          maxBuffer: 1024 * 1024,
        });
        const parts = [res.stdout, res.stderr].filter((s) => s && s.length).join('\n');
        const text = (parts || `(no output; exit code ${res.status ?? 'unknown'})`).slice(0, 8000);
        return { content: [{ type: 'text', text }], details: { exit: res.status } };
      },
    },
    {
      name: 'read_file',
      label: 'Read File',
      description: 'Read a UTF-8 text file from your workspace and return its contents.',
      parameters: Type.Object({
        path: Type.String({ description: 'Path to the file (relative to your workspace or absolute).' }),
      }),
      execute: async (_id: string, params: { path?: string }) => {
        const rel = String(params?.path ?? '').trim();
        if (!rel) return { content: [{ type: 'text', text: 'No path provided.' }], details: {} };
        const abs = path.isAbsolute(rel) ? rel : path.join(cwd, rel);
        try {
          const text = fs.readFileSync(abs, 'utf-8').slice(0, 16000);
          return { content: [{ type: 'text', text }], details: { path: abs } };
        } catch (err) {
          return {
            content: [{ type: 'text', text: `Error reading ${abs}: ${err instanceof Error ? err.message : String(err)}` }],
            details: {},
          };
        }
      },
    },
  ];
}

function getMcpBridge(mcpServers: Record<string, McpServerConfig>): Promise<McpBridge> {
  const key = JSON.stringify(mcpServers ?? {});
  if (cachedBridge && cachedBridge.key === key) return cachedBridge.bridge;
  const bridge = connectMcpServers(mcpServers ?? {});
  cachedBridge = { key, bridge };
  return bridge;
}

function sessionFile(cwd: string, id: string): string {
  return path.join(cwd, SESSIONS_DIR, `${id.replace(/[^a-zA-Z0-9_-]/g, '_')}.json`);
}

function loadMessages(cwd: string, id: string): unknown[] {
  try {
    const raw = fs.readFileSync(sessionFile(cwd, id), 'utf-8');
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed : [];
  } catch {
    return [];
  }
}

function saveMessages(cwd: string, id: string, messages: unknown[]): void {
  try {
    const file = sessionFile(cwd, id);
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.writeFileSync(file, JSON.stringify(messages));
  } catch (err) {
    log(`Failed to persist session ${id}: ${err instanceof Error ? err.message : String(err)}`);
  }
}

/** Extract the final assistant text from Pi's message array. */
function lastAssistantText(messages: unknown[]): string | null {
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i] as { role?: string; content?: unknown };
    if (m?.role !== 'assistant') continue;
    if (typeof m.content === 'string') return m.content;
    if (Array.isArray(m.content)) {
      const text = m.content
        .filter((p): p is { type: string; text: string } => {
          const pp = p as { type?: string; text?: unknown };
          return pp.type === 'text' && typeof pp.text === 'string';
        })
        .map((p) => p.text)
        .join('');
      return text || null;
    }
    return null;
  }
  return null;
}

export class PiProvider implements AgentProvider {
  private readonly options: ProviderOptions;
  private memoryHook: MemorySessionHookRegistration | undefined;

  constructor(options: ProviderOptions = {}) {
    this.options = options;
  }

  registerMemorySessionHook(hook: MemorySessionHookRegistration): void {
    this.memoryHook = hook;
  }

  isSessionInvalid(_err: unknown): boolean {
    // We own the continuation (a local session file); a missing/corrupt file is
    // handled by loadMessages returning [] rather than surfacing as an error.
    return false;
  }

  /** Run the registered memory hook (best-effort) and return its rendered text. */
  private runMemoryHook(source: 'startup'): string | undefined {
    const hook = this.memoryHook;
    if (!hook || !hook.sources.includes(source)) return undefined;
    try {
      const res = spawnSync(hook.command, {
        shell: true,
        input: JSON.stringify({ hook_event_name: 'SessionStart', source }),
        encoding: 'utf-8',
        timeout: MEMORY_HOOK_TIMEOUT_MS,
      });
      if (res.error || res.status !== 0) return undefined;
      const out = (res.stdout ?? '').trim();
      return out || undefined;
    } catch {
      return undefined;
    }
  }

  onExchangeComplete(exchange: ProviderExchange): void {
    if (!exchange.result) return;
    try {
      const cwd = this.currentCwd ?? process.cwd();
      const dir = path.join(cwd, 'conversations');
      fs.mkdirSync(dir, { recursive: true });
      const name = this.options.assistantName ?? 'agent';
      const day = new Date().toISOString().slice(0, 10);
      const file = path.join(dir, `${day}-${name.replace(/[^a-zA-Z0-9_-]/g, '_')}.md`);
      const stamp = new Date().toISOString();
      const block = `\n## ${stamp}\n\n**User:** ${exchange.prompt}\n\n**${name}:** ${exchange.result}\n`;
      fs.appendFileSync(file, block);
    } catch (err) {
      log(`Failed to archive exchange: ${err instanceof Error ? err.message : String(err)}`);
    }
  }

  private currentCwd: string | undefined;

  query(input: QueryInput): AgentQuery {
    const queue = new EventQueue();
    const options = this.options;
    this.currentCwd = input.cwd;
    const isResume = Boolean(input.continuation);
    const sessionId = input.continuation ?? `pi-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;

    // Follow-up plumbing (mirrors mock.ts): push() queues, end() stops.
    const pending: string[] = [];
    let ended = false;
    let aborted = false;
    let wake: (() => void) | null = null;
    const nextInput = (): Promise<string | null> =>
      new Promise((resolve) => {
        const check = (): boolean => {
          if (pending.length) {
            resolve(pending.shift()!);
            return true;
          }
          if (ended || aborted) {
            resolve(null);
            return true;
          }
          return false;
        };
        if (check()) return;
        wake = () => {
          if (check()) wake = null;
        };
      });

    let agentRef: { abort(): void } | null = null;

    const drive = async (): Promise<void> => {
      try {
        log(`drive start session=${sessionId} resume=${isResume}`);
        const { Agent } = await import('@earendil-works/pi-agent-core');
        const { model, streamFn } = await getModelRuntime();
        const bridge = await getMcpBridge(options.mcpServers ?? {});
        const Type = await getType();
        const tools = [...builtinTools(input.cwd, Type), ...bridge.tools];
        log(`tools ready: ${tools.length} total (${bridge.tools.length} bridged)`);

        let systemPrompt = input.systemContext?.instructions ?? `You are ${options.assistantName ?? 'an assistant'}.`;
        const baseLen = systemPrompt.length;
        let memLen = 0;
        if (!isResume) {
          const memory = this.runMemoryHook('startup');
          if (memory) {
            memLen = memory.length;
            systemPrompt = `${systemPrompt}\n\n${memory}`;
          }
        }
        log(`systemPrompt ${systemPrompt.length} chars (base ${baseLen} + memory ${memLen}); prompt ${input.prompt.length} chars`);
        const messages = isResume ? loadMessages(input.cwd, sessionId) : [];

        const agent = new Agent({
          initialState: {
            systemPrompt,
            model: model as never,
            tools: tools as never,
            ...(messages.length ? { messages: messages as never } : {}),
          },
          streamFn: streamFn as never,
        });
        agentRef = agent as unknown as { abort(): void };

        agent.subscribe((e: unknown) => {
          const ev = e as { type: string; toolName?: string };
          queue.push({ type: 'activity' });
          if (ev.type === 'tool_execution_start' && ev.toolName) {
            queue.push({ type: 'progress', message: `Running ${ev.toolName}…` });
          }
        });

        queue.push({ type: 'activity' });
        queue.push({ type: 'init', continuation: sessionId });

        const runTurn = async (text: string): Promise<void> => {
          log(`runTurn: prompting (${text.length} chars)`);
          await agent.prompt(text);
          await agent.waitForIdle();
          const state = (agent as { state: { messages: unknown[]; errorMessage?: string } }).state;
          log(`runTurn done: ${state.messages.length} msgs, error=${state.errorMessage ?? 'none'}`);
          saveMessages(input.cwd, sessionId, state.messages);
          if (state.errorMessage) {
            queue.push({ type: 'result', text: lastAssistantText(state.messages), isError: true });
          } else {
            queue.push({ type: 'result', text: lastAssistantText(state.messages) });
          }
        };

        await runTurn(input.prompt);
        while (!ended && !aborted) {
          const next = await nextInput();
          if (next === null) break;
          await runTurn(next);
        }
      } catch (err) {
        const message = err instanceof Error ? (err.stack ?? err.message) : String(err);
        log(`drive() failed: ${message}`);
        queue.push({ type: 'error', message: err instanceof Error ? err.message : String(err), retryable: false });
      } finally {
        queue.close();
      }
    };

    void drive();

    return {
      push(message: string) {
        pending.push(message);
        wake?.();
      },
      end() {
        ended = true;
        wake?.();
      },
      events: queue,
      abort() {
        aborted = true;
        try {
          agentRef?.abort();
        } catch {
          /* ignore */
        }
        wake?.();
        queue.close();
      },
    };
  }
}

registerProvider('pi', (opts) => new PiProvider(opts));
