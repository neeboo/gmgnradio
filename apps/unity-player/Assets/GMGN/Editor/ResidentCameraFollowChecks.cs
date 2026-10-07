using System;
using UnityEngine;

namespace GMGN.UnityPlayer.Editor
{
    public static class ResidentCameraFollowChecks
    {
        public static void Validate()
        {
            var host = new GameObject("resident-camera-follow-fixture");
            var role = new GameObject("resident-follow-role");
            var cameraObject = new GameObject("resident-follow-camera");
            try {
                var camera = cameraObject.AddComponent<Camera>();
                var controller = host.AddComponent<WorldCameraController>();
                controller.Configure(camera, null);
                bool allowed = true;
                controller.BindResident(role.transform, "world-a", () => allowed);
                controller.SetActive(true);
                role.transform.position = new Vector3(0, 0, 4);
                controller.ObserveResident(2);
                role.transform.position = new Vector3(1, 0, 4);
                controller.ObserveResident(2.03f);
                controller.AdvanceFollow(.01f);
                float first = Mathf.DeltaAngle(0, camera.transform.eulerAngles.y);
                float target = Mathf.Atan2(1, 4) * Mathf.Rad2Deg;
                if (first <= 0 || first >= target) throw new Exception("Rightward mirrored-world displacement was not smoothly followed.");
                for (int i=0;i<60;i++) controller.AdvanceFollow(.016f);
                if (Mathf.Abs(Mathf.DeltaAngle(camera.transform.eulerAngles.y, target)) > .001f)
                    throw new Exception("Follow yaw lost queued motion.");
                role.transform.position = new Vector3(-1, 0, 4);
                controller.ObserveResident(3);
                for (int i=0;i<60;i++) controller.AdvanceFollow(.016f);
                if (Mathf.Abs(Mathf.DeltaAngle(camera.transform.eulerAngles.y, -target)) > .001f)
                    throw new Exception("Leftward displacement followed the wrong handedness.");
                if (camera.transform.position != Vector3.zero || camera.fieldOfView != 60)
                    throw new Exception("Follow moved the camera or changed FOV.");
                float stationary = camera.transform.eulerAngles.y;
                for (int i=0;i<60;i++) { controller.ObserveResident(4); controller.AdvanceFollow(.016f); }
                if (Mathf.Abs(Mathf.DeltaAngle(stationary, camera.transform.eulerAngles.y)) > .001f)
                    throw new Exception("Idle resident caused repeated pursuit.");
                controller.RecordUserInteraction(5);
                role.transform.position = new Vector3(0, 0, 4); controller.ObserveResident(5.5f);
                controller.AdvanceFollow(.1f);
                if (Mathf.Abs(Mathf.DeltaAngle(stationary, camera.transform.eulerAngles.y)) > .001f)
                    throw new Exception("Follow fought user input during the one-second suppression.");
                role.transform.position = new Vector3(1, 0, 4); controller.ObserveResident(6.1f);
                controller.BindResident(role.transform, "world-b", () => allowed);
                controller.AdvanceFollow(.1f);
                if (Mathf.Abs(Mathf.DeltaAngle(stationary, camera.transform.eulerAngles.y)) > .001f)
                    throw new Exception("World switch replayed old queued yaw.");
                controller.ObserveResident(7);
                role.transform.position = new Vector3(2, 0, 4); controller.ObserveResident(7.1f);
                allowed = false; controller.ObserveResident(7.2f); controller.AdvanceFollow(.1f);
                role.transform.position = new Vector3(-2, 0, 4);
                allowed = true; controller.ObserveResident(8); controller.AdvanceFollow(.1f);
                if (Mathf.Abs(Mathf.DeltaAngle(stationary, camera.transform.eulerAngles.y)) > .001f)
                    throw new Exception("Compact/editing suspension replayed hidden movement on return.");
                role.transform.position = new Vector3(-1, 0, 4); controller.ObserveResident(9);
                controller.AdvanceFollow(.5f);
                if (Mathf.Abs(Mathf.DeltaAngle(stationary, camera.transform.eulerAngles.y)) > .001f)
                    throw new Exception("Paused render gap replayed backlog.");
                Debug.Log("PASS resident camera follow: mirrored left/right, smooth convergence, no translation/FOV change, idle, user suppression, world switch, compact/editing return, paused gap.");
            } finally {
                UnityEngine.Object.DestroyImmediate(host);
                UnityEngine.Object.DestroyImmediate(role);
                UnityEngine.Object.DestroyImmediate(cameraObject);
            }
        }
    }
}
