using Newtonsoft.Json.Linq;
using UnityEngine;
using GMGN.UnityPlayer.World;

namespace GMGN.UnityPlayer.Characters
{
    public static class CharacterActivityHeading
    {
        public static Quaternion Resolve(JToken sourceRotation, bool locomoting)
        {
            var reflected = WorldCoordinates.Rotation(sourceRotation);
            if (!locomoting) return reflected;
            // WorldRuntime path yaw faces source +Z. Reflecting the position
            // sends that basis to Unity -Z; transforming only the quaternion
            // leaves a Unity +Z humanoid facing opposite its displacement.
            // Correct the activity heading, never imported bones or asset roots.
            return Quaternion.LookRotation(reflected * Vector3.back, reflected * Vector3.up);
        }
        public static Quaternion FaceInteractionContact(Quaternion stationaryHeading,
            Vector3 standingPosition, Vector3 contactPosition)
        {
            var direction = Vector3.ProjectOnPlane(contactPosition-standingPosition,Vector3.up);
            return direction.sqrMagnitude > .000001f
                ? Quaternion.LookRotation(direction,Vector3.up) : stationaryHeading;
        }
    }
}
