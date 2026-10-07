namespace GMGN.UnityPlayer
{
    public sealed class CameraKeyboardGate
    {
        bool suspended;
        public void Suspend() => suspended = true;
        public int Read(int pressed)
        {
            // A key held across an input owner change must be released before
            // camera movement resumes, including when its key-up was not delivered.
            if (!suspended) return pressed;
            if (pressed == 0) suspended = false;
            return 0;
        }
    }
}
