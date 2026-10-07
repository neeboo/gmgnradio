#!/usr/bin/env python3
"""Source contract checks; no Editor, provider, or application is started."""
from pathlib import Path
import unittest

SOURCE = (Path(__file__).resolve().parents[1] / "apps/unity-player/Assets/GMGN/World/BuiltinWorldDevice.cs").read_text()


class ProjectionReceiptContract(unittest.TestCase):
    def test_projection_tokens_are_validated_and_echoed(self):
        for field in ("projectionSessionID", "projectionID"):
            self.assertIn(f'Guid.TryParse((string)descriptor["{field}"]', SOURCE)
            self.assertIn(f'["{field}"]=(string)descriptor["{field}"]', SOURCE)
        identity = SOURCE.split("var identity =", 1)[1].split(";", 1)[0]
        self.assertIn("projectionSessionID", identity)
        self.assertIn("projectionID", identity)

    def test_render_receipt_follows_frame_completion(self):
        routine = SOURCE.split("IEnumerator AcknowledgeAfterRenderedFrame", 1)[1].split("void LateUpdate", 1)[0]
        self.assertLess(routine.index("yield return null"), routine.index("new WaitForEndOfFrame"))
        self.assertLess(routine.index("new WaitForEndOfFrame"), routine.index("previewRenderedFrame=Time.frameCount"))
        self.assertLess(routine.index("previewRenderedFrame=Time.frameCount"), routine.index("AcknowledgeOutput(true)"))
        for guard in ("epoch!=previewEpoch", "model!=outputPreview", "!isActiveAndEnabled", "!model.activeInHierarchy"):
            self.assertIn(guard, routine)
        self.assertIn("if(rendered && previewRenderedFrame<=0) return", SOURCE)
        self.assertNotIn("AcknowledgeOutput(isActiveAndEnabled)", SOURCE)

    def test_sequence_and_retry_do_not_reload(self):
        self.assertIn("static long previewReceiptSequence", SOURCE)
        self.assertIn("Interlocked.Increment(ref previewReceiptSequence)", SOURCE)
        self.assertNotIn("previewReceiptSequences", SOURCE)
        self.assertIn('ack["receiptSequence"]=sequence', SOURCE)
        self.assertIn('ack["renderedFrame"]=rendered?previewRenderedFrame:0', SOURCE)
        duplicate = SOURCE.split("if (previewIdentity == identity)", 1)[1].split("HideOutputPreview(); previewAck", 1)[0]
        self.assertIn("Time.unscaledTime-previewReceiptTime>=1f", duplicate)
        self.assertIn("AcknowledgeOutput(", duplicate)
        self.assertIn("return;", duplicate)
        self.assertNotIn("resolver.Resolve", duplicate)

    def test_disable_and_unload_cancel_pending_true(self):
        hide = SOURCE.split("public void HideOutputPreview()", 1)[1].split("void AcknowledgeOutput", 1)[0]
        self.assertLess(hide.index("CancelRenderReceipt()"), hide.index("AcknowledgeOutput(false)"))
        self.assertIn("previewEpoch++", hide)
        self.assertIn("Time.unscaledTime-previewReceiptTime>=1f", hide)
        self.assertNotIn("previewAck=null", hide)
        self.assertIn("void OnDisable() { CancelRenderReceipt();", SOURCE)
        self.assertIn("outputPreview.SetActive(true); ScheduleRenderReceipt();", SOURCE)


if __name__ == "__main__":
    unittest.main()
