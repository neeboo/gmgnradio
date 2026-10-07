namespace GaussianSplatting.Runtime
{
    /// Compiled into the upstream runtime via asmref. This exposes only draw
    /// registration, leaving buffer creation/destruction owned by the renderer.
    public static class GaussianVisibility
    {
        public static void SetDrawing(GaussianSplatRenderer renderer, bool value)
        {
            if (value) GaussianSplatRenderSystem.instance.RegisterSplat(renderer);
            else GaussianSplatRenderSystem.instance.UnregisterSplat(renderer);
        }
    }
}
