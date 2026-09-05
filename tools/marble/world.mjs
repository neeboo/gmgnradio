#!/usr/bin/env node
import { readFile, writeFile, mkdir, rename, open } from 'node:fs/promises';
import { createWriteStream } from 'node:fs';
import { basename, dirname, extname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { Readable } from 'node:stream';
import { pipeline } from 'node:stream/promises';

const API = 'https://api.worldlabs.ai/marble/v1';
const KEY_FILE = '/Users/ghostcorn/Library/Application Support/ai.gmgn.radio/secrets/world-labs-api-key';

function required(value, name) {
  if (typeof value !== 'string' || !value.trim()) throw new Error(`Missing ${name}`);
  return value;
}

async function save(path, value) {
  await mkdir(dirname(path), { recursive: true });
  const temporary = `${path}.${process.pid}.tmp`;
  await writeFile(temporary, JSON.stringify(value, null, 2) + '\n', { mode: 0o600 });
  await rename(temporary, path);
}

async function keyFromLocalFile() {
  if (process.env.WLT_API_KEY?.trim()) return process.env.WLT_API_KEY.trim();
  try { return required((await readFile(KEY_FILE, 'utf8')).trim(), 'API key'); }
  catch { throw new Error('World Labs API key unavailable in WLT_API_KEY or local secrets file'); }
}

export async function run(args, context = {}) {
  const [command, ...rest] = args;
  const options = {};
  let image;
  for (let index = 0; index < rest.length; index++) {
    if (rest[index].startsWith('--')) options[rest[index].slice(2)] = rest[++index];
    else if (command === 'upload' && !image) image = rest[index];
    else throw new Error('Unexpected argument');
  }
  if (!['credits', 'upload', 'generate', 'poll', 'download'].includes(command)) {
    throw new Error('Usage: world.mjs credits | upload IMAGE --out FILE | generate --media-id ID --prompt-file FILE --out FILE | poll --operation-id ID --out FILE | download --world-file FILE --out-dir DIR');
  }
  const fetcher = context.fetch ?? globalThis.fetch;
  const key = command === 'download' ? null : context.key ?? await keyFromLocalFile();
  async function request(url, init = {}) {
    // Never print raw fetch errors or response bodies: they may contain signed URLs.
    let response;
    try { response = await fetcher(url, { ...init, signal: AbortSignal.timeout(120_000) }); }
    catch { throw new Error('Network request failed; no automatic retry was attempted'); }
    if (!response.ok) throw new Error(`Request failed with HTTP ${response.status}; no automatic retry was attempted`);
    return response;
  }
  async function api(path, body) {
    const response = await request(`${API}${path}`, {
      method: body === undefined ? 'GET' : 'POST',
      headers: { 'WLT-Api-Key': key, ...(body === undefined ? {} : { 'Content-Type': 'application/json' }) },
      ...(body === undefined ? {} : { body: JSON.stringify(body) })
    });
    try { return await response.json(); }
    catch { throw new Error('API returned invalid JSON; no automatic retry was attempted'); }
  }

  if (command === 'credits') return api('/credits');

  if (command === 'upload') {
    const file = required(image, 'image file'), out = required(options.out, '--out');
    const bytes = await readFile(file);
    const extension = extname(file).slice(1).toLowerCase();
    if (!['png', 'jpg', 'jpeg', 'webp'].includes(extension)) throw new Error('Supported image extensions: png, jpg, jpeg, webp');
    const prepared = await api('/media-assets:prepare_upload', { file_name: basename(file), extension, kind: 'image' });
    const id = required(prepared.media_asset?.media_asset_id, 'media_asset.media_asset_id');
    const upload = prepared.upload_info;
    const url = required(upload?.upload_url, 'upload_info.upload_url');
    const method = required(upload?.upload_method, 'upload_info.upload_method');
    await request(url, { method, headers: upload.required_headers ?? {}, body: bytes });
    const record = { status: 'uploaded', media_asset_id: id, input_file: resolve(file), uploaded_at: new Date().toISOString() };
    await save(out, record);
    return record;
  }

  if (command === 'generate') {
    const out = required(options.out, '--out');
    const mediaID = required(options['media-id'], '--media-id');
    const text = required((await readFile(required(options['prompt-file'], '--prompt-file'), 'utf8')).trim(), 'nonempty prompt');
    const payload = { model: 'marble-1.1', world_prompt: {
      type: 'image', is_pano: false, disable_recaption: true, text_prompt: text,
      image_prompt: { source: 'media_asset', media_asset_id: mediaID }
    }};
    const record = { status: 'submitting', submitted_at: new Date().toISOString(), request: payload };
    await mkdir(dirname(out), { recursive: true });
    let marker;
    try { marker = await open(out, 'wx', 0o600); }
    catch (error) {
      if (error.code === 'EEXIST') throw new Error('Submission record already exists. Resume with poll; do not repeat generation after an uncertain submission.');
      throw error;
    }
    try { await marker.writeFile(JSON.stringify(record, null, 2) + '\n'); await marker.sync(); }
    finally { await marker.close(); }
    const operation = await api('/worlds:generate', payload);
    const operationID = required(operation.operation_id, 'operation_id');
    await save(out, { ...record, status: 'submitted', operation_id: operationID, operation });
    return { status: 'submitted', operation_id: operationID, record: resolve(out) };
  }

  if (command === 'poll') {
    const id = required(options['operation-id'], '--operation-id'), out = required(options.out, '--out');
    let previous = {};
    try { previous = JSON.parse(await readFile(out, 'utf8')); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    if (previous.operation_id && previous.operation_id !== id) throw new Error('Operation ID does not match existing record');
    const operation = await api(`/operations/${encodeURIComponent(id)}`);
    const record = { ...previous, operation_id: id, status: operation.done ? (operation.error ? 'failed' : 'completed') : 'pending', operation, checked_at: new Date().toISOString() };
    // Save operation first so a failed world fetch does not lose completed status.
    await save(out, record);
    if (operation.done && !operation.error) {
      const worldID = required(operation.response?.world_id ?? operation.response?.id ?? operation.metadata?.world_id, 'completed world_id');
      const details = await api(`/worlds/${encodeURIComponent(worldID)}`);
      record.world = details.world ?? details;
      await save(out, record);
    }
    return { status: record.status, operation_id: id, world_id: record.world?.world_id ?? record.world?.id, record: resolve(out) };
  }

  const file = required(options['world-file'], '--world-file'), output = required(options['out-dir'], '--out-dir');
  const document = JSON.parse(await readFile(file, 'utf8'));
  const world = document.world ?? document;
  const assets = world.assets ?? {};
  const urls = assets.splats?.spz_urls ?? {};
  const downloads = [
    ['world-500k.spz', required(urls['500k'], '500k SPZ URL')],
    ['world-100k.spz', required(urls['100k'], '100k SPZ URL')],
    ['collider.glb', required(assets.mesh?.collider_mesh_url, 'collider mesh URL')]
  ];
  for (const [name, url] of [['thumbnail', assets.thumbnail_url], ['pano', assets.imagery?.pano_url]]) {
    if (url) downloads.push([name + (extname(new URL(url).pathname) || '.jpg'), url]);
  }
  await mkdir(output, { recursive: true });
  const files = [];
  for (const [name, url] of downloads) {
    const destination = join(output, name), temporary = `${destination}.partial`;
    const response = await request(url);
    if (!response.body) throw new Error(`Empty asset response for ${name}`);
    try { await pipeline(Readable.fromWeb(response.body), createWriteStream(temporary)); }
    catch { throw new Error(`Asset download incomplete for ${name}; rerun download to recover`); }
    await rename(temporary, destination);
    files.push(resolve(destination));
  }
  const record = { world_id: world.world_id ?? world.id, downloaded_at: new Date().toISOString(), files };
  await save(join(output, 'downloads.json'), record);
  return record;
}

if (process.argv[1] && import.meta.url === pathToFileURL(resolve(process.argv[1])).href) {
  run(process.argv.slice(2)).then(result => console.log(JSON.stringify(result, null, 2))).catch(error => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
