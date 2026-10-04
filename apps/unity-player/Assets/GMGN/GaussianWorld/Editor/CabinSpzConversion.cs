using System;
using System.IO;
using System.IO.Compression;
using System.Text;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    // The pinned upstream importer reads SH entries even for SH0 SPZ, causing
    // job exceptions and zero-position output. Convert this known cabin input
    // once at build preparation, preserving true Gaussian attributes.
    public static class CabinSpzConversion
    {
        public static string ConvertSh0(string source)
        {
            using var file = File.OpenRead(source);
            using var gzip = new GZipStream(file, CompressionMode.Decompress);
            using var reader = new BinaryReader(gzip);
            if (reader.ReadUInt32() != 0x5053474e || reader.ReadUInt32() != 2)
                throw new InvalidDataException("Cabin converter requires SPZ v2");
            var count = checked((int)reader.ReadUInt32());
            var degree = reader.ReadByte(); var bits = reader.ReadByte();
            reader.ReadByte(); reader.ReadByte();
            if (count <= 0 || count > 1000000 || bits > 24 || degree != 0)
                throw new InvalidDataException("Cabin converter supports bounded SH0 SPZ only");
            var positions = Read(reader, checked(count * 9));
            var opacity = Read(reader, count);
            var colors = Read(reader, checked(count * 3));
            var scales = Read(reader, checked(count * 3));
            var rotations = Read(reader, checked(count * 3));
            var output = "Library/GMGNGaussian/scene-500k.ply";
            Directory.CreateDirectory(Path.GetDirectoryName(output));
            using var stream = File.Create(output);
            var header = new StringBuilder("ply\nformat binary_little_endian 1.0\nelement vertex " + count + "\n");
            foreach (var name in new[] {"x","y","z","nx","ny","nz","f_dc_0","f_dc_1","f_dc_2"}) header.Append("property float " + name + "\n");
            for (var i = 0; i < 45; i++) header.Append("property float f_rest_" + i + "\n");
            foreach (var name in new[] {"opacity","scale_0","scale_1","scale_2","rot_0","rot_1","rot_2","rot_3"}) header.Append("property float " + name + "\n");
            header.Append("end_header\n");
            var bytes = Encoding.ASCII.GetBytes(header.ToString()); stream.Write(bytes, 0, bytes.Length);
            using var writer = new BinaryWriter(stream);
            var factor = 1f / (1 << bits);
            var min = Vector3.one * float.PositiveInfinity;
            var max = Vector3.one * float.NegativeInfinity;
            for (var i = 0; i < count; i++) {
                var p = new Vector3(Signed24(positions, i*9)*factor, Signed24(positions, i*9+3)*factor, Signed24(positions, i*9+6)*factor);
                min = Vector3.Min(min, p); max = Vector3.Max(max, p);
                writer.Write(p.x); writer.Write(p.y); writer.Write(p.z);
                writer.Write(0f); writer.Write(0f); writer.Write(0f);
                for (var c = 0; c < 3; c++) writer.Write((colors[i*3+c]/255f-.5f)/.15f);
                for (var c = 0; c < 45; c++) writer.Write(0f);
                var alpha = Mathf.Clamp(opacity[i]/255f, 1e-6f, 1-1e-6f);
                writer.Write(Mathf.Log(alpha/(1-alpha)));
                for (var c = 0; c < 3; c++) writer.Write(scales[i*3+c]/16f-10);
                var q = new Quaternion(rotations[i*3]/127.5f-1, rotations[i*3+1]/127.5f-1, rotations[i*3+2]/127.5f-1, 0);
                q.w = Mathf.Sqrt(Mathf.Max(0, 1-q.x*q.x-q.y*q.y-q.z*q.z)); q = q.normalized;
                writer.Write(q.w); writer.Write(q.x); writer.Write(q.y); writer.Write(q.z);
            }
            Debug.Log("SPZ SH0 conversion preserved " + count + " Gaussian ellipsoids, raw bounds " + min + " / " + max);
            return output;
        }
        static byte[] Read(BinaryReader reader, int count)
        {
            var bytes = reader.ReadBytes(count);
            if (bytes.Length != count) throw new EndOfStreamException("Incomplete cabin SPZ");
            return bytes;
        }
        static int Signed24(byte[] bytes, int index)
        {
            var value = bytes[index] | bytes[index+1]<<8 | bytes[index+2]<<16;
            return (value & 0x800000) != 0 ? value | unchecked((int)0xff000000) : value;
        }
    }
}
