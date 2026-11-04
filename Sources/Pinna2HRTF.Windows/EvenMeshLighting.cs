using HelixToolkit.SharpDX;
using HelixToolkit.WinUI.SharpDX;
using Microsoft.UI;
using System.Numerics;
namespace Pinna2HRTF.Windows;

internal static class EvenMeshLighting
{
    public static IReadOnlyList<Element3D> Install(Viewport3DX view)
    {
        var lights = new List<Element3D>();
        void Add(Element3D light) { lights.Add(light); view.Items.Add(light); }
        Add(new AmbientLight3D { Color = global::Windows.UI.Color.FromArgb(255, 60, 60, 60) });
        foreach (var direction in new[] { Vector3.UnitX, -Vector3.UnitX, Vector3.UnitY, -Vector3.UnitY, Vector3.UnitZ, -Vector3.UnitZ })
            Add(new DirectionalLight3D { Direction = direction, Color = global::Windows.UI.Color.FromArgb(255, 30, 30, 30) });
        var key = new DirectionalLight3D { Color = global::Windows.UI.Color.FromArgb(255, 155, 155, 155) }; Add(key);
        void FollowCamera()
        {
            if (view.Camera is not PerspectiveCamera camera) return;
            var forward = Vector3.Normalize(camera.LookDirection); var right = Vector3.Normalize(Vector3.Cross(forward, Vector3.UnitZ));
            if (!float.IsFinite(right.X)) right = Vector3.UnitX;
            var up = Vector3.Normalize(Vector3.Cross(right, forward));
            key.Direction = Vector3.Normalize(forward + right * .5f - up * .45f);
        }
        ProjectionCamera? observed = null; long directionToken = 0;
        void BindCamera()
        {
            observed?.UnregisterPropertyChangedCallback(ProjectionCamera.LookDirectionProperty, directionToken);
            observed = view.Camera as ProjectionCamera;
            if (observed != null) directionToken = observed.RegisterPropertyChangedCallback(ProjectionCamera.LookDirectionProperty, (_, _) => FollowCamera());
            FollowCamera();
        }
        view.RegisterPropertyChangedCallback(Viewport3DX.CameraProperty, (_, _) => BindCamera());
        view.Loaded += (_, _) => BindCamera();
        view.Unloaded += (_, _) => { observed?.UnregisterPropertyChangedCallback(ProjectionCamera.LookDirectionProperty, directionToken); observed = null; };
        BindCamera();
        return lights;
    }
}
