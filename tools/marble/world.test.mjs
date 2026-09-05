import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { run } from './world.mjs';

const json = (value, status = 200) => new Response(JSON.stringify(value), { status });
async function workspace(t) {
  const dir = await mkdtemp(join(tmpdir(), 'marble-test-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  return dir;
}
const readJSON = async path => JSON.parse(await readFile(path, 'utf8'));

test('credits uses official authenticated endpoint', async () => {
  const result = await run(['credits'], { key: 'secret', fetch: async (url, options) => {
    assert.equal(url, 'https://api.worldlabs.ai/marble/v1/credits');
    assert.equal(options.headers['WLT-Api-Key'], 'secret');
    return json({ credits_balance: 123 });
  }});
  assert.deepEqual(result, { credits_balance: 123 });
});

test('upload sends prepared method and headers, persists only media identity', async t => {
  const dir = await workspace(t), input = join(dir, 'cabin.png'), out = join(dir, 'upload.json');
  await writeFile(input, 'image bytes');
  const calls = [];
  const result = await run(['upload', input, '--out', out], { key: 'secret', fetch: async (url, options) => {
    calls.push(url);
    if (calls.length === 1) {
      assert.equal(url, 'https://api.worldlabs.ai/marble/v1/media-assets:prepare_upload');
      assert.deepEqual(JSON.parse(options.body), { file_name: 'cabin.png', extension: 'png', kind: 'image' });
      return json({ media_asset: { media_asset_id: 'media-1' }, upload_info: {
        upload_url: 'https://storage.example/upload?signature=hidden', upload_method: 'PUT', required_headers: { 'Content-Type': 'image/png' }
      }});
    }
    assert.equal(options.method, 'PUT');
    assert.deepEqual(options.headers, { 'Content-Type': 'image/png' });
    assert.equal(options.body.toString(), 'image bytes');
    return new Response(null, { status: 200 });
  }});
  assert.equal(result.media_asset_id, 'media-1');
  assert.equal(calls.length, 2);
  assert.doesNotMatch(await readFile(out, 'utf8'), /signature|secret|upload_url/);
});

test('generate writes submitting marker before one POST and saves operation for resume', async t => {
  const dir = await workspace(t), prompt = join(dir, 'prompt.txt'), out = join(dir, 'operation.json');
  await writeFile(prompt, 'A spacious empty living cabin');
  let calls = 0;
  const context = { key: 'secret', fetch: async (url, options) => {
    calls++;
    assert.equal((await readJSON(out)).status, 'submitting');
    assert.equal(url, 'https://api.worldlabs.ai/marble/v1/worlds:generate');
    assert.equal(options.method, 'POST');
    assert.deepEqual(JSON.parse(options.body), { model: 'marble-1.1', world_prompt: {
      type: 'image', is_pano: false, disable_recaption: true, text_prompt: 'A spacious empty living cabin',
      image_prompt: { source: 'media_asset', media_asset_id: 'media-1' }
    }});
    return json({ operation_id: 'op-1', done: false });
  }};
  const args = ['generate', '--media-id', 'media-1', '--prompt-file', prompt, '--out', out];
  assert.equal((await run(args, context)).operation_id, 'op-1');
  assert.equal((await readJSON(out)).operation_id, 'op-1');
  await assert.rejects(run(args, context), /already exists/);
  assert.equal(calls, 1);
});

test('uncertain generation is never retried and cannot expose network secrets', async t => {
  const dir = await workspace(t), prompt = join(dir, 'prompt.txt'), out = join(dir, 'operation.json');
  await writeFile(prompt, 'Empty cabin');
  let calls = 0;
  const context = { key: 'secret', fetch: async () => { calls++; throw new Error('secret https://storage.example?signature=hidden'); }};
  const args = ['generate', '--media-id', 'media-1', '--prompt-file', prompt, '--out', out];
  await assert.rejects(run(args, context), error => !/secret|signature/.test(error.message));
  assert.equal((await readJSON(out)).status, 'submitting');
  await assert.rejects(run(args, context), /already exists/);
  assert.equal(calls, 1);
});

test('HTTP generation refusal keeps submitting record and omits sensitive response body', async t => {
  const dir = await workspace(t), prompt = join(dir, 'prompt.txt'), out = join(dir, 'operation.json');
  await writeFile(prompt, 'Empty cabin');
  const args = ['generate', '--media-id', 'media-1', '--prompt-file', prompt, '--out', out];
  await assert.rejects(run(args, { key: 'secret', fetch: async () => json({ detail: 'secret signed-upload-url' }, 402) }), error => {
    assert.match(error.message, /HTTP 402/);
    assert.doesNotMatch(error.message, /secret|signed-upload/);
    return true;
  });
  assert.equal((await readJSON(out)).status, 'submitting');
});

test('invalid upload preparation does not send bytes or persist signed response', async t => {
  const dir = await workspace(t), input = join(dir, 'cabin.png'), out = join(dir, 'upload.json');
  await writeFile(input, 'image bytes');
  let calls = 0;
  await assert.rejects(run(['upload', input, '--out', out], { key: 'secret', fetch: async () => {
    calls++;
    return json({ media_asset: {}, upload_info: { upload_url: 'https://storage.example?signature=hidden' } });
  }}), /media_asset.media_asset_id/);
  assert.equal(calls, 1);
  await assert.rejects(readFile(out), { code: 'ENOENT' });
});

test('poll requests operation once then retrieves and persists full completed world', async t => {
  const out = join(await workspace(t), 'operation.json');
  const urls = [];
  const world = { world_id: 'world-1', assets: { splats: { semantics_metadata: { ground: 1 } } } };
  const result = await run(['poll', '--operation-id', 'op-1', '--out', out], { key: 'secret', fetch: async url => {
    urls.push(url);
    return json(url.endsWith('/operations/op-1') ? { operation_id: 'op-1', done: true, response: { id: 'world-1' } } : world);
  }});
  assert.deepEqual(urls, ['https://api.worldlabs.ai/marble/v1/operations/op-1', 'https://api.worldlabs.ai/marble/v1/worlds/world-1']);
  assert.deepEqual((await readJSON(out)).world, world);
  assert.equal(result.status, 'completed');
});

test('poll normalizes wrapped world details for the download record', async t => {
  const out = join(await workspace(t), 'operation.json');
  const world = { world_id: 'world-1', assets: { caption: 'Empty cabin' } };
  const result = await run(['poll', '--operation-id', 'op-1', '--out', out], { key: 'secret', fetch: async url => json(
    url.endsWith('/operations/op-1') ? { operation_id: 'op-1', done: true, response: { world_id: 'world-1' } } : { world }
  ) });
  assert.equal(result.world_id, 'world-1');
  assert.deepEqual((await readJSON(out)).world, world);
});

test('pending and failed polls persist without generation or world requests', async t => {
  for (const operation of [{ operation_id: 'op-1', done: false }, { operation_id: 'op-1', done: true, error: { code: 'FAILED' } }]) {
    let calls = 0;
    const out = join(await workspace(t), 'operation.json');
    const result = await run(['poll', '--operation-id', 'op-1', '--out', out], { key: 'secret', fetch: async () => { calls++; return json(operation); }});
    assert.equal(calls, 1);
    assert.equal(result.status, operation.done ? 'failed' : 'pending');
    assert.deepEqual((await readJSON(out)).operation, operation);
  }
});

test('download obtains 500k/100k splats, collider and optional imagery without API key', async t => {
  const dir = await workspace(t), file = join(dir, 'world.json'), output = join(dir, 'assets');
  await writeFile(file, JSON.stringify({ world: { world_id: 'world-1', assets: {
    splats: { spz_urls: { '500k': 'https://cdn.example/500.spz', '100k': 'https://cdn.example/100.spz', full_res: 'https://cdn.example/full.spz' } },
    mesh: { collider_mesh_url: 'https://cdn.example/collider.glb' }, thumbnail_url: 'https://cdn.example/thumb.webp', imagery: { pano_url: 'https://cdn.example/pano.jpg' }
  }}}));
  const urls = [];
  const result = await run(['download', '--world-file', file, '--out-dir', output], { fetch: async (url, options) => {
    urls.push(url);
    assert.equal(options.headers, undefined);
    return new Response('asset bytes');
  }});
  assert.equal(urls.length, 5);
  assert.ok(!urls.some(url => url.endsWith('full.spz')));
  assert.equal(await readFile(join(output, 'world-500k.spz'), 'utf8'), 'asset bytes');
  assert.equal(result.files.length, 5);
});
