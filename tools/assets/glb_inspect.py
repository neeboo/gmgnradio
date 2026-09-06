"""Bounded, dependency-free GLB inspection; does not certify physical scale.

Bounds are recomputed from embedded POSITION bytes in mesh-local coordinates.
Node/scene transforms are deliberately not flattened into a purported meter size.
"""
import hashlib
import json
import math
from pathlib import Path
import struct


class GLBError(ValueError):
    pass


_COMPONENTS = {5120:("b",1),5121:("B",1),5122:("h",2),5123:("H",2),5125:("I",4),5126:("f",4)}
_WIDTHS = {"SCALAR":1,"VEC2":2,"VEC3":3,"VEC4":4,"MAT2":4,"MAT3":9,"MAT4":16}


def inspect_glb(path, *, max_bytes=128*1024*1024, max_triangles=100000):
    """Inspect a service-owned local GLB. Raises GLBError on unsupported/unsafe data."""
    try:
        return _inspect_glb(path, max_bytes=max_bytes, max_triangles=max_triangles)
    except (KeyError, IndexError, TypeError, AttributeError, struct.error, RecursionError) as error:
        raise GLBError("malformed GLB structure") from error


def _inspect_glb(path, *, max_bytes, max_triangles):
    path = Path(path)
    if path.stat().st_size > max_bytes:
        raise GLBError("GLB file size limit exceeded")
    with path.open("rb") as stream:
        data = stream.read(max_bytes+1)
    if len(data) > max_bytes:
        raise GLBError("GLB file size limit exceeded")
    if len(data) < 20:
        raise GLBError("truncated GLB header")
    magic, version, length = struct.unpack_from("<4sII", data)
    if magic != b"glTF" or version != 2 or length != len(data):
        raise GLBError("invalid GLB header/version/length")
    chunks, offset = [], 12
    while offset < len(data):
        if offset+8 > len(data):
            raise GLBError("truncated chunk header")
        size, kind = struct.unpack_from("<I4s", data, offset)
        offset += 8
        if size % 4 or offset+size > len(data):
            raise GLBError("invalid chunk length")
        chunks.append((kind,data[offset:offset+size]))
        offset += size
    if not chunks or chunks[0][0] != b"JSON" or len(chunks)>2 or (len(chunks)==2 and chunks[1][0]!=b"BIN\0"):
        raise GLBError("expected JSON then optional BIN chunk")
    try:
        doc = json.loads(chunks[0][1], parse_constant=lambda value: (_ for _ in ()).throw(GLBError("non-finite JSON")))
    except (ValueError, UnicodeError, RecursionError) as error:
        raise GLBError("invalid GLB JSON") from error
    if not isinstance(doc, dict) or doc.get("asset",{}).get("version") != "2.0":
        raise GLBError("expected glTF 2.0 document")
    binary = chunks[1][1] if len(chunks)==2 else b""
    for collection in ("buffers", "images"):
        for entry in doc.get(collection, []):
            if "uri" in entry:
                raise GLBError(f"external/URI {collection} are not allowed; embed in GLB")
    if doc.get("extensionsRequired"):
        raise GLBError("required GLB extensions unsupported by inspector")
    buffers = doc.get("buffers", [])
    if len(buffers) != 1 or type(buffers[0].get("byteLength")) is not int:
        raise GLBError("expected one embedded buffer")
    buffer_length = buffers[0]["byteLength"]
    if buffer_length < 0 or not buffer_length <= len(binary) <= buffer_length+3:
        raise GLBError("embedded buffer byteLength mismatch")
    views = doc.get("bufferViews", [])
    for view in views:
        start, size = view.get("byteOffset",0), view.get("byteLength")
        if view.get("buffer") != 0 or type(start) is not int or type(size) is not int or start<0 or size<0 or start+size>buffer_length:
            raise GLBError("invalid bufferView range")
    accessors = doc.get("accessors", [])
    layouts = []
    for accessor in accessors:
        if "sparse" in accessor:
            raise GLBError("sparse accessors unsupported")
        view_index = accessor.get("bufferView")
        if type(view_index) is not int or not 0 <= view_index < len(views):
            raise GLBError("accessor bufferView missing/invalid")
        component, width = _COMPONENTS.get(accessor.get("componentType")), _WIDTHS.get(accessor.get("type"))
        count, byte_offset = accessor.get("count"), accessor.get("byteOffset",0)
        if component is None or width is None or type(count) is not int or count<0 or type(byte_offset) is not int or byte_offset<0:
            raise GLBError("invalid accessor layout")
        view = views[view_index]
        item_size = component[1]*width
        stride = view.get("byteStride", item_size)
        if type(stride) is not int or stride<item_size or stride%component[1] or byte_offset%component[1]:
            raise GLBError("invalid accessor stride/alignment")
        end = byte_offset + ((count-1)*stride+item_size if count else 0)
        if end > view["byteLength"]:
            raise GLBError("accessor exceeds bufferView")
        layouts.append((view.get("byteOffset",0)+byte_offset, stride, count, "<"+component[0]*width))

    def rows(index):
        if type(index) is not int or not 0 <= index < len(layouts):
            raise GLBError("invalid accessor reference")
        start, stride, count, fmt = layouts[index]
        return (struct.unpack_from(fmt,binary,start+i*stride) for i in range(count))

    triangles, primitives, bounds_by_accessor = 0, 0, {}
    materials = doc.get("materials", [])
    for mesh in doc.get("meshes", []):
        for primitive in mesh.get("primitives", []):
            primitives += 1
            position = primitive.get("attributes",{}).get("POSITION")
            position_rows = rows(position)
            accessor = accessors[position]
            if accessor.get("type")!="VEC3" or accessor.get("componentType")!=5126 or accessor.get("normalized",False):
                raise GLBError("POSITION must be unnormalized float VEC3")
            vertex_count = accessor["count"]
            if vertex_count == 0:
                raise GLBError("empty POSITION accessor")
            # Reject over-budget meshes before decoding potentially large arrays.
            preliminary_count = vertex_count
            if "indices" in primitive:
                index = primitive["indices"]
                rows(index)  # validate reference without materializing values
                preliminary_count = accessors[index]["count"]
            mode = primitive.get("mode",4)
            preliminary_triangles = preliminary_count//3 if mode==4 else max(0,preliminary_count-2)
            if triangles+preliminary_triangles > max_triangles or vertex_count > max(3,max_triangles*3):
                raise GLBError("triangle/vertex limit exceeded")
            if str(position) not in bounds_by_accessor:
                lower, upper = [math.inf]*3, [-math.inf]*3
                for xyz in position_rows:
                    if not all(math.isfinite(x) for x in xyz):
                        raise GLBError("non-finite POSITION")
                    lower = [min(a,b) for a,b in zip(lower,xyz)]
                    upper = [max(a,b) for a,b in zip(upper,xyz)]
                bounds_by_accessor[str(position)] = {"min":lower,"max":upper}
            count = vertex_count
            if "indices" in primitive:
                index = primitive["indices"]
                index_rows = rows(index)
                if accessors[index]["type"]!="SCALAR" or accessors[index]["componentType"] not in (5121,5123,5125):
                    raise GLBError("invalid indices type")
                count = accessors[index]["count"]
                if any(row[0]>=vertex_count for row in index_rows):
                    raise GLBError("index outside POSITION range")
            mode = primitive.get("mode",4)
            if mode == 4:
                if count % 3:
                    raise GLBError("triangle index count not divisible by 3")
                triangles += count//3
            elif mode in (5,6):
                triangles += max(0,count-2)
            else:
                raise GLBError("only triangle primitives supported")
            if triangles > max_triangles:
                raise GLBError("triangle limit exceeded")
            if "material" in primitive and (type(primitive["material"]) is not int or not 0 <= primitive["material"] < len(materials)):
                raise GLBError("invalid material reference")
    if not bounds_by_accessor:
        raise GLBError("no inspectable mesh geometry")
    lower = [min(bound["min"][axis] for bound in bounds_by_accessor.values()) for axis in range(3)]
    upper = [max(bound["max"][axis] for bound in bounds_by_accessor.values()) for axis in range(3)]
    return {"sha256":hashlib.sha256(data).hexdigest(), "bytes":len(data), "triangles":triangles,
            "primitives":primitives, "materials":len(materials), "accessors":len(accessors),
            "accessor_bounds":bounds_by_accessor,
            "bounds":{"min":lower,"max":upper,"dimensions":[b-a for a,b in zip(lower,upper)],
                      "units":"model_units", "space":"mesh_local"},
            "scale_calibrated":False, "meters_per_model_unit":None,
            "scene_transform_count":sum("matrix" in n or "scale" in n or "rotation" in n or "translation" in n for n in doc.get("nodes",[]))}
