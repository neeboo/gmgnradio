"""Compile the operator-owned Comfy editor template; never accept a client graph.

Schema is supplied from the target Comfy /object_info endpoint. The adapter only
supports the named widgets and plain links represented in the template. Unknown
serialization, bypass modes, or missing required inputs fail before submission.
"""
import copy
import re


class WorkflowError(ValueError):
    pass


_COST_OVERRIDES = {
    316: ("PrimitiveBoolean", {"value": True}),
    186: ("DecimateMesh", {"target_face_count": 20000}),
    147: ("BakeTextureFromVoxel", {"texture_size": 1024}),
    288: ("PrimitiveInt", {"value": 1024}),
    224: ("BakeNormalMapFromMesh", {"resolution": 1024}),
    233: ("BakeAmbientOcclusion", {"resolution": 512, "samples": 16}),
    94: ("Trellis2UpsampleStage", {"target_resolution": 1024}),
    241: ("RemeshMesh", {"resolution": 256, "smooth_iters": 2, "precluster_max_verts": 1000000}),
}
_UI_ONLY = {"Note", "MarkdownNote", "PreviewImage", "Preview3DAdvanced", "MaskPreview"}
_SCALARS = {"INT", "FLOAT", "BOOLEAN", "STRING", "COMBO"}


def _widget_values(node, schema):
    declared = schema.get("input", {})
    specs = {**declared.get("required", {}), **declared.get("optional", {})}
    widgets = [i["widget"]["name"] for i in node.get("inputs", []) if i.get("widget")]
    if not widgets:
        order = schema.get("input_order", {})
        for group in ("required", "optional"):
            for name in order.get(group, []):
                spec = specs.get(name, [])
                if spec and (isinstance(spec[0], list) or spec[0] in _SCALARS):
                    widgets.append(name)
    values = node.get("widgets_values") or []
    result, cursor = {}, 0
    for name in widgets:
        if cursor >= len(values):
            raise WorkflowError(f"node {node['id']} {node['type']}: missing widget {name}")
        value = values[cursor]
        cursor += 1
        # Browser upload buttons are serialized by LoadImage, not backend inputs.
        if not (node["type"] == "LoadImage" and name == "upload" and name not in specs):
            result[name] = copy.deepcopy(value)
        # Comfy control_after_generate is a frontend-only widget immediately after
        # seed/PrimitiveInt value. Its enum is explicit, not an arbitrary skip.
        control = ((node["type"] == "KSampler" and name == "seed") or
                   (node["type"] == "PrimitiveInt" and name == "value"))
        if control and cursor < len(values) and values[cursor] in ("fixed", "increment", "decrement", "randomize"):
            cursor += 1
    if cursor != len(values):
        raise WorkflowError(f"node {node['id']} {node['type']}: unsupported widget serialization ({len(values)-cursor} trailing values)")
    return result


def build_prompt(workflow, object_info, *, image_name, seed, output_prefix):
    """Return Comfy API prompt for Save3DAdvanced 322, with Trellis-only branches.

    Callers must load an immutable trusted template. Only basename image uploads,
    a bounded seed, and service-owned `props/<job-id>` output prefixes are variable.
    """
    if not isinstance(image_name, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,159}\.(?:png|jpg|jpeg|webp)", image_name, re.IGNORECASE) or ".." in image_name:
        raise WorkflowError("image_name must be an uploaded image basename")
    if type(seed) is not int or not 0 <= seed < 2**64:
        raise WorkflowError("seed must be an unsigned 64-bit integer")
    if not isinstance(output_prefix, str) or not re.fullmatch(r"props/[A-Za-z0-9][A-Za-z0-9_-]{0,79}", output_prefix):
        raise WorkflowError("output_prefix must be service-owned props/<job-id>")
    nodes = {node["id"]: node for node in workflow.get("nodes", [])}
    if len(nodes) != len(workflow.get("nodes", [])):
        raise WorkflowError("duplicate node IDs")
    if nodes.get(322, {}).get("type") != "Save3DAdvanced":
        raise WorkflowError("missing trusted output Save3DAdvanced node 322")
    links = {link[0]: link for link in workflow.get("links", [])}
    if len(links) != len(workflow.get("links", [])):
        raise WorkflowError("duplicate link IDs")
    result, visiting = {}, set()

    def node_for(node_id):
        node = nodes.get(node_id)
        if node is None:
            raise WorkflowError(f"missing node {node_id}")
        if node.get("mode", 0) != 0:
            raise WorkflowError(f"node {node_id}: unsupported mode {node['mode']}")
        return node

    def link_source(node, item):
        link = links.get(item["link"])
        if not link or len(link) < 6 or link[3] != node["id"]:
            raise WorkflowError(f"node {node['id']} input {item['name']}: invalid link")
        inputs = node.get("inputs", [])
        if type(link[4]) is not int or not 0 <= link[4] < len(inputs) or inputs[link[4]]["name"] != item["name"]:
            raise WorkflowError(f"node {node['id']} input {item['name']}: link target slot mismatch")
        if type(link[2]) is not int or link[2] < 0:
            raise WorkflowError("invalid source link slot")
        return link[1], link[2]

    def switch_value(node):
        item = next((i for i in node.get("inputs", []) if i["name"] == "switch"), None)
        if not item:
            raise WorkflowError(f"node {node['id']}: missing switch")
        if item.get("link") is not None:
            source_id, slot = link_source(node, item)
            source = node_for(source_id)
            if source["type"] != "PrimitiveBoolean" or slot != 0:
                raise WorkflowError(f"node {node['id']}: dynamic switch unsupported")
            if source_id == 316:
                return True
            values = source.get("widgets_values") or []
            value = values[0] if len(values) == 1 else None
        else:
            value = _widget_values(node, object_info.get("ComfySwitchNode", {})).get("switch")
        if type(value) is not bool:
            raise WorkflowError(f"node {node['id']}: non-boolean switch")
        return value

    def resolve(node_id, slot=0):
        node = node_for(node_id)
        if node["type"] in ("PreviewImage", "MaskPreview"):
            kind = node["type"]
            input_name, data_type = ("images", "IMAGE") if kind == "PreviewImage" else ("mask", "MASK")
            if object_info.get(kind, {}).get("output") != [data_type] or slot != 0:
                raise WorkflowError(f"node {node_id}: unverified preview passthrough")
            if node_id in visiting:
                raise WorkflowError(f"cycle at preview node {node_id}")
            item = next((i for i in node.get("inputs",[]) if i["name"] == input_name), None)
            if not item or item.get("link") is None:
                raise WorkflowError(f"node {node_id}: missing preview input")
            visiting.add(node_id)
            source = resolve(*link_source(node,item))
            visiting.remove(node_id)
            return source
        if node["type"] != "ComfySwitchNode":
            visit(node_id)
            outputs = object_info[node["type"]].get("output")
            if outputs is not None and slot >= len(outputs):
                raise WorkflowError(f"node {node_id}: source link output slot {slot} missing")
            return [str(node_id), slot]
        if node_id in visiting:
            raise WorkflowError(f"cycle at switch node {node_id}")
        if slot != 0:
            raise WorkflowError(f"node {node_id}: unsupported switch output {slot}")
        visiting.add(node_id)
        name = "on_true" if switch_value(node) else "on_false"
        item = next((i for i in node.get("inputs", []) if i["name"] == name), None)
        if not item or item.get("link") is None:
            raise WorkflowError(f"node {node_id}: missing {name} branch")
        source = resolve(*link_source(node, item))
        visiting.remove(node_id)
        return source

    def visit(node_id):
        if str(node_id) in result:
            return
        if node_id in visiting:
            raise WorkflowError(f"cycle at node {node_id}")
        node = node_for(node_id)
        kind = node["type"]
        if kind in _UI_ONLY:
            raise WorkflowError(f"output depends on unsupported UI node {node_id} {kind}")
        schema = object_info.get(kind)
        if schema is None:
            raise WorkflowError(f"missing node schema {kind} (node {node_id})")
        visiting.add(node_id)
        inputs = _widget_values(node, schema)
        overrides = {}
        if node_id in _COST_OVERRIDES:
            expected, overrides = _COST_OVERRIDES[node_id]
            if kind != expected:
                raise WorkflowError(f"trusted override node {node_id}: expected {expected}, got {kind}")
        if kind == "LoadImage":
            if node_id != 122:
                raise WorkflowError(f"unexpected LoadImage node {node_id}")
            overrides = {**overrides, "image": image_name}
        if kind == "KSampler":
            overrides = {**overrides, "seed": seed}
        if node_id == 322:
            overrides = {**overrides, "filename_prefix": output_prefix}
        for item in node.get("inputs", []):
            if item.get("link") is not None and item["name"] not in overrides:
                inputs[item["name"]] = resolve(*link_source(node, item))
        inputs.update(overrides)
        groups = schema.get("input", {})
        required = dict(groups.get("required", {}))
        specs = {**required, **groups.get("optional", {})}
        # V3 dynamic combos serialize flat prefixed inputs. Only the selected
        # schema branch is valid (see pinned Comfy _io.DynamicCombo expansion).
        for name, spec in list(specs.items()):
            if spec[0] == "COMFY_DYNAMICCOMBO_V3":
                option = next((o for o in spec[1]["options"] if o["key"] == inputs.get(name)), None)
                if option is None:
                    raise WorkflowError(f"node {node_id}: unsupported dynamic choice {name}")
                for group in ("required", "optional"):
                    for child, child_spec in option["inputs"].get(group, {}).items():
                        full_name = f"{name}.{child}"
                        specs[full_name] = child_spec
                        if group == "required":
                            required[full_name] = child_spec
        for name in inputs:
            if name not in specs:
                raise WorkflowError(f"node {node_id} {kind}: unsupported input {name}")
        for name, spec in required.items():
            if name not in inputs:
                options = spec[1] if len(spec) > 1 and isinstance(spec[1], dict) else {}
                if "default" not in options:
                    raise WorkflowError(f"node {node_id} {kind}: missing required input {name}")
                inputs[name] = copy.deepcopy(options["default"])
        result[str(node_id)] = {"class_type": kind, "inputs": inputs}
        visiting.remove(node_id)

    visit(322)
    return result
