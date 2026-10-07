import { readFile, writeFile } from 'node:fs/promises';
import assert from 'node:assert/strict';

// Repairs this project's legacy lilToon conversion, not arbitrary authored VRMs.
// The source conversion left shade textures empty when lilToon retained albedo.
const [source, destination] = process.argv.slice(2);
assert(source && destination && source !== destination, 'Use distinct source and candidate paths');
const input = await readFile(source);
assert.equal(input.readUInt32LE(0), 0x46546c67);
assert.equal(input.readUInt32LE(4), 2);
assert.equal(input.readUInt32LE(8), input.length);
const chunks = [];
for (let offset = 12; offset < input.length;) {
  const length = input.readUInt32LE(offset);
  assert(offset + 8 + length <= input.length);
  chunks.push({ type: input.readUInt32LE(offset + 4), data: input.subarray(offset + 8, offset + 8 + length) });
  offset += 8 + length;
}
assert.equal(chunks[0].type, 0x4e4f534a);
const model = JSON.parse(chunks[0].data.toString('utf8'));
assert.equal(model.extensions?.VRMC_vrm?.meta?.name, 'Kipfel (assembled local conversion)', 'Only repair the assembled conversion');
let repaired = 0;
for (const material of model.materials) {
  const toon = material.extensions?.VRMC_materials_mtoon;
  const base = material.pbrMetallicRoughness?.baseColorTexture;
  assert(toon && base && !toon.shadeMultiplyTexture, 'Unexpected material: inspect its source instead');
  toon.shadeMultiplyTexture = structuredClone(base);
  repaired++;
}
assert(repaired > 0);
const json = Buffer.from(JSON.stringify(model));
const padding = (4 - json.length % 4) % 4;
chunks[0].data = Buffer.concat([json, Buffer.alloc(padding, 0x20)]);
const size = 12 + chunks.reduce((sum, chunk) => sum + 8 + chunk.data.length, 0);
const output = Buffer.alloc(size);
input.copy(output, 0, 0, 12); output.writeUInt32LE(size, 8);
let offset = 12;
for (const chunk of chunks) {
  output.writeUInt32LE(chunk.data.length, offset);
  output.writeUInt32LE(chunk.type, offset + 4);
  chunk.data.copy(output, offset + 8);
  assert(output.subarray(offset + 8, offset + 8 + chunk.data.length).equals(chunk.data));
  offset += 8 + chunk.data.length;
}
// Binary geometry, textures, skinning and animations remain byte-identical.
await writeFile(destination, output, { flag: 'wx' });
console.log(`Candidate saved; ${repaired} materials repaired; binary chunks unchanged`);
