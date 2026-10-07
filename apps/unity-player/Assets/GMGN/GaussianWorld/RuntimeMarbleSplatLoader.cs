// SPDX-License-Identifier: MIT
// SPZ v2 decoding and GPU layouts follow the pinned UnityGaussianSplatting
// SPZFileReader / GaussianSplatAssetCreator. No point subsampling is performed.
using System;
using System.IO;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Threading;
using System.Threading.Tasks;
using GaussianSplatting.Runtime;
using Unity.Mathematics;
using UnityEngine;

namespace GMGN.UnityPlayer
{
    public static class RuntimeMarbleSplatLoader
    {
        public sealed class Decoded
        {
            public int Count, SHDegree;
            public Vector3 Minimum, Maximum;
            public byte[] Positions, Other, Colors, SH;
            public string SourceHash;
        }
        public sealed class RuntimeAsset : IDisposable
        {
            public GaussianSplatAsset Asset { get; }
            readonly TextAsset[] files;
            public RuntimeAsset(Decoded decoded)
            {
                Asset = ScriptableObject.CreateInstance<GaussianSplatAsset>();
                Asset.name = "Runtime Marble " + decoded.SourceHash;
                Asset.Initialize(decoded.Count, GaussianSplatAsset.VectorFormat.Float32, GaussianSplatAsset.VectorFormat.Float32,
                    GaussianSplatAsset.ColorFormat.Float16x4, GaussianSplatAsset.SHFormat.Float16,
                    decoded.Minimum, decoded.Maximum, Array.Empty<GaussianSplatAsset.CameraInfo>());
                Asset.SetDataHash(Hash128.Compute(decoded.SourceHash));
                files = new[] { Bytes(decoded.Positions), Bytes(decoded.Other), Bytes(decoded.Colors), Bytes(decoded.SH) };
                Asset.SetAssetFiles(null, files[0], files[1], files[2], files[3]);
            }
            static TextAsset Bytes(byte[] data) => new TextAsset(new ReadOnlySpan<byte>(data));
            public void Dispose()
            {
                foreach (var file in files) if (file != null) UnityEngine.Object.Destroy(file);
                if (Asset != null) UnityEngine.Object.Destroy(Asset);
            }
        }
        public static Task<Decoded> DecodeAsync(string path, CancellationToken cancellation)
            => Task.Run(() => Decode(path, cancellation), cancellation);

        public static Decoded Decode(string path, CancellationToken cancellation)
        {
            using var file = File.OpenRead(path);
            using var gzip = new GZipStream(file, CompressionMode.Decompress);
            using var reader = new BinaryReader(gzip);
            if (reader.ReadUInt32() != 0x5053474e || reader.ReadUInt32() != 2)
                throw new InvalidDataException("Marble 运行时支持 SPZ v2，请导入受支持的正式空间包。");
            var count = checked((int)reader.ReadUInt32());
            var degree = reader.ReadByte(); var bits = reader.ReadByte();
            reader.ReadByte(); reader.ReadByte();
            if (count <= 0 || count > GaussianSplatAsset.kMaxSplats || bits > 24 || degree > 3)
                throw new InvalidDataException("Marble SPZ 点数或属性格式不受支持。");
            int coefficients = degree == 0 ? 0 : degree == 1 ? 3 : degree == 2 ? 8 : 15;
            var position = Read(reader, checked(count * 9), cancellation);
            var alpha = Read(reader, count, cancellation);
            var color = Read(reader, checked(count * 3), cancellation);
            var scale = Read(reader, checked(count * 3), cancellation);
            var rotation = Read(reader, checked(count * 3), cancellation);
            var sh = Read(reader, checked(count * coefficients * 3), cancellation);
            if (gzip.ReadByte() != -1) throw new InvalidDataException("Marble SPZ 包含未支持的额外属性。");
            var (width, height) = GaussianSplatAsset.CalcTextureSize(count);
            var result = new Decoded { Count = count, SHDegree = degree,
                Positions = new byte[checked(count * 12)], Other = new byte[checked(count * 16)],
                Colors = new byte[checked(width * height * 8)], SH = new byte[checked(count * 96)],
                Minimum = Vector3.one * float.PositiveInfinity, Maximum = Vector3.one * float.NegativeInfinity };
            using var positions = new BinaryWriter(new MemoryStream(result.Positions, true));
            using var other = new BinaryWriter(new MemoryStream(result.Other, true));
            float factor = 1f / (1 << bits);
            for (int i = 0; i < count; i++) {
                if ((i & 4095) == 0) cancellation.ThrowIfCancellationRequested();
                var point = new Vector3(Signed24(position, i * 9) * factor,
                    Signed24(position, i * 9 + 3) * factor, Signed24(position, i * 9 + 6) * factor);
                result.Minimum = Vector3.Min(result.Minimum, point); result.Maximum = Vector3.Max(result.Maximum, point);
                positions.Write(point.x); positions.Write(point.y); positions.Write(point.z);
                var xyz = new float3(rotation[i * 3] / 127.5f - 1, rotation[i * 3 + 1] / 127.5f - 1, rotation[i * 3 + 2] / 127.5f - 1);
                var quaternion = math.normalize(new float4(xyz, math.sqrt(math.max(0, 1 - math.lengthsq(xyz)))));
                var packed = GaussianUtils.PackSmallest3Rotation(quaternion);
                other.Write((uint)(packed.x * 1023.5f) | ((uint)(packed.y * 1023.5f) << 10) |
                    ((uint)(packed.z * 1023.5f) << 20) | ((uint)(packed.w * 3.5f) << 30));
                for (int c = 0; c < 3; c++) other.Write((float)Math.Exp(scale[i * 3 + c] / 16f - 10));
                int textureIndex = ColorIndex(i) * 8;
                for (int c = 0; c < 3; c++) Half(result.Colors, textureIndex + c * 2,
                    (color[i * 3 + c] / 255f - 0.5f) / 0.15f * 0.2820948f + 0.5f);
                Half(result.Colors, textureIndex + 6, alpha[i] / 255f);
                for (int c = 0; c < coefficients * 3; c++)
                    Half(result.SH, i * 96 + c * 2, (sh[i * coefficients * 3 + c] - 128) / 128f);
            }
            cancellation.ThrowIfCancellationRequested();
            using var sha = SHA256.Create(); using var source = File.OpenRead(path);
            result.SourceHash = BitConverter.ToString(sha.ComputeHash(source)).Replace("-", "").ToLowerInvariant();
            return result;
        }
        static byte[] Read(BinaryReader reader, int count, CancellationToken cancellation)
        {
            cancellation.ThrowIfCancellationRequested(); var data = reader.ReadBytes(count);
            if (data.Length != count) throw new EndOfStreamException("Marble SPZ 属性不完整。");
            return data;
        }
        static int Signed24(byte[] bytes, int index)
        {
            int value = bytes[index] | bytes[index + 1] << 8 | bytes[index + 2] << 16;
            return (value & 0x800000) != 0 ? value | unchecked((int)0xff000000) : value;
        }
        static void Half(byte[] bytes, int index, float value)
        {
            ushort bits = new half(value).value; bytes[index] = (byte)bits; bytes[index + 1] = (byte)(bits >> 8);
        }
        static int ColorIndex(int index)
        {
            int tile = index >> 8, morton = index & 255, x = 0, y = 0;
            for (int bit = 0; bit < 4; bit++) { x |= ((morton >> (bit * 2)) & 1) << bit; y |= ((morton >> (bit * 2 + 1)) & 1) << bit; }
            int tilesPerRow = GaussianSplatAsset.kTextureWidth / 16;
            return ((tile / tilesPerRow) * 16 + y) * GaussianSplatAsset.kTextureWidth + (tile % tilesPerRow) * 16 + x;
        }
    }
}
