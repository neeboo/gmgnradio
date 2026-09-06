import copy
import json
from pathlib import Path
import unittest

try:
    from workflow_adapter import build_prompt, WorkflowError
except ImportError:
    build_prompt = None
    WorkflowError = ValueError


def fixture():
    # A small editor graph with explicit widget names and linked widgets.
    graph = {"nodes": [
        {"id": 122, "type": "LoadImage", "inputs": [
            {"name": "image", "widget": {"name": "image"}},
            {"name": "upload", "widget": {"name": "upload"}}], "widgets_values": ["old.png", "image"]},
        {"id": 316, "type": "PrimitiveBoolean", "inputs": [
            {"name": "value", "widget": {"name": "value"}}], "widgets_values": [False]},
        {"id": 12, "type": "KSampler", "inputs": [
            {"name": "image", "link": 1},
            {"name": "seed", "widget": {"name": "seed"}},
            {"name": "steps", "widget": {"name": "steps"}},
            {"name": "cfg", "widget": {"name": "cfg"}}], "widgets_values": [43, "fixed", 12, 1]},
        {"id": 314, "type": "ComfySwitchNode", "inputs": [
            {"name": "on_false", "link": 2}, {"name": "on_true", "link": 3},
            {"name": "switch", "link": 4, "widget": {"name": "switch"}}], "widgets_values": [False]},
        {"id": 319, "type": "MissingPixal", "inputs": [], "widgets_values": []},
        {"id": 322, "type": "Save3DAdvanced", "inputs": [
            {"name": "model_3d", "link": 5},
            {"name": "filename_prefix", "widget": {"name": "filename_prefix"}}], "widgets_values": ["3d/ComfyUI"]},
        {"id": 999, "type": "Preview3DAdvanced", "inputs": [{"name": "model_3d", "link": 6}]},
        {"id": 313, "type": "MarkdownNote", "widgets_values": ["not executable"]}
    ], "links": [[1,122,0,12,0,"IMAGE"], [2,319,0,314,0,"*"],
                 [3,12,0,314,1,"*"], [4,316,0,314,2,"BOOLEAN"],
                 [5,314,0,322,0,"*"], [6,314,0,999,0,"*"]]}
    schemas = {
        "LoadImage": {"input": {"required": {"image": [[], {}]}}},
        "PrimitiveBoolean": {"input": {"required": {"value": ["BOOLEAN", {"default":False}]}}},
        "KSampler": {"input": {"required": {"image": ["IMAGE"], "seed": ["INT"], "steps": ["INT"], "cfg": ["FLOAT"], "denoise": ["FLOAT", {"default":1.0}]}}},
        "Save3DAdvanced": {"input": {"required": {"model_3d": ["FILE_3D"], "filename_prefix": ["STRING"]}}},
    }
    return graph, schemas


class AdapterTests(unittest.TestCase):
    def setUp(self):
        self.assertIsNotNone(build_prompt, "workflow adapter is not implemented")
        self.graph, self.schemas = fixture()

    def build(self, **changes):
        args = {"image_name": "source.png", "seed": 7, "output_prefix": "props/job-123"}
        args.update(changes)
        return build_prompt(self.graph, self.schemas, **args)

    def test_fold_trellis_prune_notes_previews_and_unused_missing_classes(self):
        result = self.build()
        self.assertEqual(set(result), {"122", "12", "322"})
        self.assertEqual(result["322"]["inputs"]["model_3d"], ["12", 0])
        self.assertEqual(result["12"]["inputs"], {"image":["122",0], "seed":7, "steps":12, "cfg":1, "denoise":1.0})
        self.assertEqual(result["122"]["inputs"], {"image":"source.png"})

    def test_no_mutation_and_repeatable(self):
        before = copy.deepcopy(self.graph)
        self.assertEqual(self.build(), self.build())
        self.assertEqual(before, self.graph)

    def test_missing_node_and_required_input_are_specific(self):
        del self.schemas["KSampler"]
        with self.assertRaisesRegex(WorkflowError, "KSampler.*12|12.*KSampler"):
            self.build()
        self.graph, self.schemas = fixture()
        self.schemas["KSampler"]["input"]["required"]["new_required"] = ["IMAGE"]
        with self.assertRaisesRegex(WorkflowError, "new_required"):
            self.build()

    def test_paths_and_seed_are_restricted(self):
        for name in ("../x.png", "/tmp/x.png", "x/y.png", "http://x", "x\\y.png"):
            with self.subTest(name=name), self.assertRaises(WorkflowError):
                self.build(image_name=name)
        for prefix in ("../x", "/tmp/x", "props/../../x", "http://x", "a\\b"):
            with self.subTest(prefix=prefix), self.assertRaises(WorkflowError):
                self.build(output_prefix=prefix)
        for seed in (-1, True, 1.5, 2**64):
            with self.subTest(seed=seed), self.assertRaises(WorkflowError):
                self.build(seed=seed)

    def test_unhandled_modes_and_bad_widgets_fail(self):
        self.graph["nodes"][2]["mode"] = 4
        with self.assertRaisesRegex(WorkflowError, "mode"):
            self.build()
        self.graph["nodes"][2]["mode"] = 0
        self.graph["nodes"][2]["widgets_values"].append("mystery")
        with self.assertRaisesRegex(WorkflowError, "widget"):
            self.build()

    def test_broken_link_rejected(self):
        self.graph["links"][0][3] = 999
        with self.assertRaisesRegex(WorkflowError, "link"):
            self.build()

    def test_input_order_used_when_editor_has_no_widget_markers(self):
        self.graph["nodes"][2]["inputs"] = [{"name":"image", "link":1}]
        self.schemas["KSampler"]["input_order"] = {"required":["image", "seed", "steps", "cfg"]}
        self.assertEqual(self.build()["12"]["inputs"]["steps"], 12)

    def test_fixed_cost_overrides(self):
        self.graph["nodes"][2]["id"] = 186
        self.graph["nodes"][2]["type"] = "DecimateMesh"
        self.graph["nodes"][2]["inputs"] = [{"name":"image", "link":1}, {"name":"target_face_count", "widget":{"name":"target_face_count"}}]
        self.graph["nodes"][2]["widgets_values"] = [700000]
        self.schemas["DecimateMesh"] = {"input":{"required":{"image":["IMAGE"], "target_face_count":["INT"]}}}
        self.graph["links"][0][3] = 186
        self.graph["links"][2][1] = 186
        self.assertEqual(self.build()["186"]["inputs"]["target_face_count"], 20000)

    def test_preview_image_passthrough_is_removed(self):
        self.graph["nodes"].append({"id":302,"type":"PreviewImage","inputs":[{"name":"images","link":7}]})
        self.graph["links"].append([7,122,0,302,0,"IMAGE"])
        self.graph["links"][0][1] = 302
        self.schemas["PreviewImage"] = {"input":{"required":{"images":["IMAGE"]}},"output":["IMAGE"]}
        self.assertEqual(self.build()["12"]["inputs"]["image"], ["122",0])
        self.assertNotIn("302", self.build())

    def test_dynamic_combo_selected_branch_and_default(self):
        node = self.graph["nodes"][2]
        node["inputs"].extend([{"name":"sign_mode","widget":{"name":"sign_mode"}},
                               {"name":"sign_mode.qef","widget":{"name":"sign_mode.qef"}}])
        node["widgets_values"].extend(["udf", False])
        self.schemas["KSampler"]["input"]["required"]["sign_mode"] = ["COMFY_DYNAMICCOMBO_V3",{"options":[
            {"key":"udf","inputs":{"required":{"qef":["BOOLEAN"], "extra":["BOOLEAN",{"default":False}]}}},
            {"key":"sdf","inputs":{"required":{"manifold":["BOOLEAN"]}}}]}]
        self.assertFalse(self.build()["12"]["inputs"]["sign_mode.extra"])
        node["widgets_values"][-2] = "unknown"
        with self.assertRaisesRegex(WorkflowError, "sign_mode"):
            self.build()

    def test_real_template_with_recorded_live_schema(self):
        root = Path(__file__).parent
        workflow_path, schema_path = root/'workflow.source.json', root/'fixtures/comfy-object-info.json'
        result = build_prompt(json.loads(workflow_path.read_text()), json.loads(schema_path.read_text()),
                              image_name='source.png',seed=42,output_prefix='props/probe')
        self.assertEqual(len(result),38)
        self.assertNotIn('319',result)
        self.assertNotIn('55',result)
        self.assertTrue(all(n['class_type'] not in ('PreviewImage','ComfySwitchNode','MarkdownNote') for n in result.values()))
        self.assertEqual(result['94']['inputs']['target_resolution'],1024)
        self.assertEqual(result['241']['inputs']['resolution'],256)
        self.assertEqual(result['241']['inputs']['smooth_iters'],2)
        self.assertEqual(result['241']['inputs']['precluster_max_verts'],1000000)
        self.assertEqual(result['233']['inputs']['samples'],16)
        for node in result.values():
            if node['class_type']=='KSampler':
                self.assertEqual(node['inputs']['seed'],42)


if __name__ == "__main__":
    unittest.main()
