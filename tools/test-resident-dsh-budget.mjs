// Offline integration against the installed harness. No stream, credentials,
// user settings file, host or network is used; the settings provider is memory-only.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';

const [modulePath, entryPoint, llmPackage] = process.argv.slice(2);
const resolvers = [createRequire(pathToFileURL(entryPoint)), createRequire(pathToFileURL(`${llmPackage}/package.json`))];
const load = name => {
  for (const resolveFrom of resolvers) {
    let path;
    try { path = resolveFrom.resolve(name); } catch { continue; }
    resolvers.push(createRequire(pathToFileURL(path)));
    return import(pathToFileURL(path).href);
  }
  throw new Error(`installed DSH dependency unavailable: ${name}`);
};
const { Context } = await load('@deepseek-ai/cordis');
const { agentEvents, installModelSelection, assembleContextFor } = await load('@deepseek-ai/dsh-agent');
const { default: LlmRuntime } = await load('@deepseek-ai/dsh-llm');
const { default: SystemPrompt } = await load('@deepseek-ai/dsh-system-prompt');
const { SettingsProvider } = await load('@deepseek-ai/dsh-settings');
const { createScope } = await load('@deepseek-ai/dsh-scope');
const DeepSeek = await load('@deepseek-ai/dsh-llm-deepseek');
const budgetPlugin = await import(pathToFileURL(modulePath).href);

class MemorySettings extends SettingsProvider {
  constructor(ctx, { document }) { super(ctx); this.documentFixture = document; }
  get writable() { return false; }
  async load() { return this.documentFixture; }
  async persist() { throw new Error('unexpected settings write'); }
}

const cases = [
  { name: 'unspecified effort defaults to low', expected: 'low' },
  { name: 'explicit thinking disabled remains off', settings: { thinking: 'disabled' }, expected: 'off' },
  { name: 'composition thinking disabled remains off', base: { thinking: 'disabled' }, expected: 'off' },
  { name: 'explicit thinking enabled still gets low default', settings: { thinking: 'enabled' }, expected: 'low' },
  ...['off', 'low', 'high', 'max'].flatMap(effort => [
    { name: `selected ${effort} is preserved`, selection: { reasoningEffort: effort }, expected: effort },
    { name: `provider setting ${effort} is preserved`, settings: { reasoningEffort: effort }, expected: effort },
    { name: `provider composition ${effort} is preserved`, base: { reasoningEffort: effort }, expected: effort },
  ]),
  { name: 'explicit selection wins provider default', settings: { reasoningEffort: 'high' }, selection: { reasoningEffort: 'off' }, expected: 'off' },
  { name: 'disabled setting wins an enabled composition', base: { thinking: 'enabled' }, settings: { thinking: 'disabled' }, expected: 'off' },
  { name: 'smaller explicit token budget is retained', settings: { maxTokens: 1024 }, expected: 'low', tokens: 1024 },
  { name: 'other providers remain untouched', selection: { provider: 'other-provider' }, otherProvider: true },
  // A negative control: reversing registration lets selection erase the low
  // default. This proves the fixture exercises the actual waterfall ordering.
  { name: 'negative control catches reversed hook order', reverse: true, expected: 'high' },
];

for (const fixture of cases) {
  const ctx = new Context();
  try {
    await ctx.plugin(MemorySettings, { document: {
      'llm-deepseek': fixture.settings ?? {},
    } });
    await ctx.plugin(LlmRuntime);
    await ctx.plugin(SystemPrompt);
    await ctx.plugin(DeepSeek, { maxTokens: 8192, ...fixture.base });
    if (!fixture.reverse) await ctx.plugin(budgetPlugin);
    const agent = {};
    const scoped = createScope(ctx, agent);
    agent.ctx = scoped.ctx;
    const selection = { current: { provider: 'deepseek-official', model: 'deepseek-v4-flash', ...fixture.selection }, assembled: undefined };
    installModelSelection(scoped.ctx, selection);
    if (fixture.reverse) await ctx.plugin(budgetPlugin);
    const signal = new AbortController().signal;
    await ctx.systemPrompt.assemble(assembleContextFor(agent, signal));
    const request = await agentEvents(ctx, agent).waterfall(
      'agent/request', { turn: 1, step: 0, signal },
      async () => Object.freeze({ provider: 'seed', model: 'seed', temperature: 0.2 }),
    );
    assert.equal(request.model, 'deepseek-v4-flash', fixture.name);
    assert.equal(request.temperature, 0.2, fixture.name);
    if (fixture.otherProvider) {
      assert.deepEqual(request, { provider: 'other-provider', model: 'deepseek-v4-flash', temperature: 0.2 }, fixture.name);
    } else {
      // prepareCall resolves the request header without invoking its stream.
      const prepared = await ctx.llm.prepareCall(request, signal);
      assert.equal(prepared.config.reasoningEffort, fixture.expected, fixture.name);
      assert.equal(prepared.config.maxTokens, fixture.tokens ?? 8192, fixture.name);
    }
  } finally {
    await ctx.fiber.dispose();
  }
}
console.log(`PASS: ${cases.length} offline DSH reasoning priority cases`);
