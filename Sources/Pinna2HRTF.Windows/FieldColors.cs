using System.Numerics;

namespace Pinna2HRTF.Windows;

internal static class FieldColors
{
    public static double? Value(string quantity, double real, double imaginary) => quantity switch
    {
        "Level" => 20 * Math.Log10(Math.Max(Math.Sqrt(real * real + imaginary * imaginary) / 0.00002, 1e-8)),
        "Magnitude" => Math.Sqrt(real * real + imaginary * imaginary),
        "Phase" => real == 0 && imaginary == 0 ? null : Math.Atan2(imaginary, real),
        "Real" => real, "Imaginary" => imaginary, _ => throw new ArgumentException("Unknown pressure quantity.")
    };
    public static (double Low, double High) Range(string quantity, IEnumerable<double?> values)
    {
        var finite = values.OfType<double>().Where(double.IsFinite).ToArray();
        var low = finite.Length == 0 ? 0 : finite.Min(); var high = finite.Length == 0 ? 1 : finite.Max();
        if (quantity == "Phase") return (-Math.PI, Math.PI);
        if (quantity is "Real" or "Imaginary") { high = Math.Max(Math.Abs(low), Math.Abs(high)); low = -high; }
        return low == high ? (low - 0.5, high + 0.5) : (low, high);
    }
    public static Vector4 Color(string quantity, double? value, double low, double high)
    {
        if (!value.HasValue || !double.IsFinite(value.Value)) return new(0.5f, 0.5f, 0.5f, 1);
        Vector3[] palette = quantity switch
        {
            "Phase" => [new(.85f,.15f,.2f), new(.9f,.8f,.1f), new(.1f,.75f,.75f), new(.3f,.2f,.8f), new(.85f,.15f,.2f)],
            "Real" or "Imaginary" => [new(.15f,.3f,.75f), new(.95f,.95f,.95f), new(.8f,.15f,.15f)],
            _ => [new(.267f,.005f,.329f), new(.23f,.322f,.546f), new(.128f,.567f,.551f), new(.369f,.789f,.383f), new(.993f,.906f,.144f)]
        };
        var t = (float)Math.Clamp((value.Value - low) / (high - low), 0, 1) * (palette.Length - 1);
        var i = Math.Min((int)t, palette.Length - 2);
        return new(Vector3.Lerp(palette[i], palette[i+1], t-i), 1);
    }
    public static Vector4 Distance(float distance)
    {
        (float Stop,Vector3 Color)[] stops = [(0,new(.10f,.32f,.72f)),(.5f,new(.16f,.72f,.76f)),(1,new(.94f,.88f,.25f)),(1.75f,new(.94f,.43f,.12f)),(3,new(.72f,.12f,.16f))];
        var value = Math.Clamp(float.IsFinite(distance)?distance:3,0,3);
        for(var i=1;i<stops.Length;i++) if(value<=stops[i].Stop) return new(Vector3.Lerp(stops[i-1].Color,stops[i].Color,(value-stops[i-1].Stop)/(stops[i].Stop-stops[i-1].Stop)),1);
        return new(stops[^1].Color,1);
    }
}
