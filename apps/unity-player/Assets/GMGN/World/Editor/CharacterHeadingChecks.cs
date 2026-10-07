using System;
using GMGN.UnityPlayer.Characters;
using Newtonsoft.Json.Linq;
using UnityEngine;

namespace GMGN.UnityPlayer.World.Editor
{
    public static class CharacterHeadingChecks
    {
        public static void Run()
        {
            foreach (var displacement in new[] {
                new Vector3(0, 0, 1), new Vector3(0, 0, -1),
                new Vector3(1, 0, 0), new Vector3(-1, 0, 0),
                new Vector3(3, 0, 4), new Vector3(-3, 0, 4),
                new Vector3(3, 0, -4), new Vector3(-3, 0, -4) }) {
                var yaw = Mathf.Atan2(displacement.x, displacement.z);
                var pose = new JObject { ["x"] = 0, ["y"] = Mathf.Sin(yaw / 2),
                    ["z"] = 0, ["w"] = Mathf.Cos(yaw / 2) };
                var reflectedDisplacement = new Vector3(displacement.x, 0, -displacement.z).normalized;
                var oldForward = WorldCoordinates.Rotation(pose) * Vector3.forward;
                Require(Vector3.Dot(oldForward, reflectedDisplacement) < -.9999f,
                    "regression fixture must reproduce the old backward heading");
                var projected = CharacterActivityHeading.Resolve(pose, true);
                Require(Vector3.Dot(projected * Vector3.forward, reflectedDisplacement) > .9999f,
                    "walking forward must align with reflected authority displacement");
                Require(Quaternion.Angle(CharacterActivityHeading.Resolve(pose, false),
                    WorldCoordinates.Rotation(pose)) < .001f, "stationary placement must remain unchanged");
            }
            Debug.Log("[CharacterHeadingChecks] PASS: eight path directions align; idle placement unchanged");
        }

        static void Require(bool value, string description)
        {
            if (!value) throw new InvalidOperationException(description);
        }
    }
}
