import json
from pathlib import Path
import struct
import tempfile
import unittest

try:
    from glb_inspect import inspect_glb, GLBError
except ImportError:
    inspect_glb = None
    GLBError = ValueError


def glb(document=None, binary=None):
    if binary is None:
        binary = struct.pack("<9f3H", 0,0,0, 2,0,0, 0,3,1, 0,1,2)
    if document is None:
        document = {"asset":{"version":"2.0"}, "buffers":[{"byteLength":len(binary)}],
          "bufferViews":[{"buffer":0,"byteOffset":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":6}],
          "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3", "min":[-99,-99,-99], "max":[99,99,99]},
                       {"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}],
          "meshes":[{"primitives":[{"attributes":{"POSITION":0},"indices":1}]}], "materials":[{}]}
    data = json.dumps(document).encode()
    data += b" " * (-len(data) % 4)
    binary += b"\0" * (-len(binary) % 4)
    chunks = struct.pack("<I4s", len(data), b"JSON") + data + struct.pack("<I4s",len(binary), b"BIN\0") + binary
    return struct.pack("<4sII",b"glTF",2,12+len(chunks)) + chunks


class GLBTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(inspect_glb, "GLB inspector is not implemented")
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name)/"prop.glb"

    def inspect(self, data=None, **kwargs):
        self.path.write_bytes(glb() if data is None else data)
        return inspect_glb(self.path, **kwargs)

    def test_actual_bounds_and_counts_without_claiming_meters(self):
        result = self.inspect()
        self.assertEqual(result["triangles"], 1)
        self.assertEqual(result["primitives"], 1)
        self.assertEqual(result["materials"], 1)
        self.assertEqual(result["accessors"], 2)
        self.assertEqual(result["bounds"]["min"], [0,0,0])
        self.assertEqual(result["bounds"]["max"], [2,3,1])
        self.assertEqual(result["bounds"]["units"], "model_units")
        self.assertEqual(result["bounds"]["space"], "mesh_local")
        self.assertFalse(result["scale_calibrated"])
        self.assertEqual(len(result["sha256"]), 64)

    def test_reject_external_buffers_and_images(self):
        for collection in ("buffers", "images"):
            doc = {"asset":{"version":"2.0"}, collection:[{"uri":"https://example.com/a"}]}
            with self.subTest(collection=collection), self.assertRaisesRegex(GLBError, "URI"):
                self.inspect(glb(doc))

    def test_file_size_and_triangle_caps(self):
        with self.assertRaisesRegex(GLBError, "size"):
            self.inspect(max_bytes=24)
        with self.assertRaisesRegex(GLBError, "triangle"):
            self.inspect(max_triangles=0)

    def test_invalid_header_and_truncation(self):
        for bad in (b"oops", glb()[:-2], b"XXXX"+glb()[4:]):
            with self.subTest(bad=bad[:4]), self.assertRaises(GLBError):
                self.inspect(bad)

    def test_invalid_buffer_range(self):
        doc = {"asset":{"version":"2.0"}, "buffers":[{"byteLength":42}],
               "bufferViews":[{"buffer":0,"byteOffset":40,"byteLength":12}]}
        with self.assertRaisesRegex(GLBError, "buffer"):
            self.inspect(glb(doc))

    def test_bad_index_or_non_finite_position(self):
        for binary in (struct.pack("<9f3H",0,0,0,2,0,0,0,3,1,0,1,9),
                       struct.pack("<9f3H",float("nan"),0,0,2,0,0,0,3,1,0,1,2)):
            with self.subTest(binary=binary[:4]), self.assertRaises(GLBError):
                self.inspect(glb(binary=binary))

    def test_malformed_document_types_raise_glb_error(self):
        for doc in ({'asset':[]}, {'asset':{'version':'2.0'},'buffers':[None]},
                    {'asset':{'version':'2.0'},'images':'x'}):
            with self.subTest(doc=doc), self.assertRaises(GLBError):
                self.inspect(glb(doc))

    def test_mesh_triangle_limit_precedes_geometry_scan(self):
        binary = struct.pack('<9f3H',float('nan'),0,0,2,0,0,0,3,1,0,1,2)
        with self.assertRaisesRegex(GLBError,'triangle'):
            self.inspect(glb(binary=binary),max_triangles=0)


if __name__ == "__main__":
    unittest.main()
