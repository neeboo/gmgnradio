import fs from 'node:fs';
import zlib from 'node:zlib';

// Run from the repository root after PrepareCabin. This checks all input splats,
// independently of Unity's importer or renderer and without editing data.
const spz = zlib.gunzipSync(fs.readFileSync('apps/macos/Resources/Worlds/marble-living-cabin/scene-500k.spz'));
const ply = fs.readFileSync('apps/unity-player/Library/GMGNGaussian/scene-500k.ply');
const count = spz.readUInt32LE(8);
if (spz.readUInt32LE(4) !== 2 || spz[12] !== 0 || count !== 500000) throw new Error('Unexpected cabin format');
const factor = 2 ** (-spz[13]);
const header = ply.indexOf(Buffer.from('end_header\n'));
if (header < 0) throw new Error('Missing PLY header');
const start = header + 11;
if (ply.length !== start + count * 248) throw new Error('Incomplete PLY payload');
const alphaOffset = 16 + count * 9;
const colorOffset = alphaOffset + count;
const scaleOffset = colorOffset + count * 3;
const rotationOffset = scaleOffset + count * 3;
const errors = { position: 0, logScale: 0, dcColor: 0, opacity: 0, quaternion: 0, quaternionNorm: 0, sh: 0 };
const signed24 = (index) => {
  const value = spz[index] | spz[index + 1] << 8 | spz[index + 2] << 16;
  return value & 0x800000 ? value - 0x1000000 : value;
};
for (let i = 0; i < count; i++) {
  const base = start + i * 248;
  const read = (index) => ply.readFloatLE(base + index * 4);
  for (let c = 0; c < 3; c++) {
    errors.position = Math.max(errors.position, Math.abs(read(c) - signed24(16 + i * 9 + c * 3) * factor));
    errors.dcColor = Math.max(errors.dcColor, Math.abs(read(6 + c) - (spz[colorOffset + i * 3 + c] / 255 - .5) / .15));
    errors.logScale = Math.max(errors.logScale, Math.abs(read(55 + c) - (spz[scaleOffset + i * 3 + c] / 16 - 10)));
  }
  for (let j = 9; j < 54; j++) errors.sh = Math.max(errors.sh, Math.abs(read(j)));
  const alpha = Math.max(1e-6, Math.min(1 - 1e-6, spz[alphaOffset + i] / 255));
  errors.opacity = Math.max(errors.opacity, Math.abs(1 / (1 + Math.exp(-read(54))) - alpha));
  const q = [0, 1, 2].map(c => spz[rotationOffset + i * 3 + c] / 127.5 - 1);
  q.unshift(Math.sqrt(Math.max(0, 1 - q.reduce((a, v) => a + v * v, 0))));
  const norm = Math.sqrt(q.reduce((a, v) => a + v * v, 0));
  for (let c = 0; c < 4; c++) errors.quaternion = Math.max(errors.quaternion, Math.abs(read(58 + c) - q[c] / norm));
  errors.quaternionNorm = Math.max(errors.quaternionNorm, Math.abs(Math.sqrt([0, 1, 2, 3].reduce((a, c) => a + read(58 + c) ** 2, 0)) - 1));
}
console.log(JSON.stringify({ count, maxAbsoluteErrors: errors }));
if (Object.values(errors).some(v => !Number.isFinite(v)) || errors.position !== 0 || errors.logScale !== 0 || errors.sh !== 0 || errors.dcColor > 2e-6 || errors.opacity > 2e-6 || errors.quaternion > 1e-5 || errors.quaternionNorm > 1e-5) process.exit(1);
