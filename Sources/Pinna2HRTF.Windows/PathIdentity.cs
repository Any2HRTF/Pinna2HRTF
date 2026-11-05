using Microsoft.Win32.SafeHandles;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
namespace Pinna2HRTF.Windows;

internal sealed record PathIdentity(string Path, string Id)
{
    [StructLayout(LayoutKind.Sequential)] struct FileInfo
    {
        public uint Attributes, CreationLow, CreationHigh, AccessLow, AccessHigh, WriteLow, WriteHigh,
            Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
    }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern SafeFileHandle CreateFile(string path, uint access, uint share, IntPtr security, uint creation, uint flags, IntPtr template);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern uint GetFinalPathNameByHandle(SafeFileHandle file, StringBuilder path, uint size, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetFileInformationByHandle(SafeFileHandle file, out FileInfo info);
    [DllImport("shell32.dll")] static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
    public static PathIdentity Read(string path)
    {
        using var handle = CreateFile(System.IO.Path.GetFullPath(path), 0, 7, IntPtr.Zero, 3, 0x02000000, IntPtr.Zero);
        if (handle.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Resolve filesystem identity");
        var text = new StringBuilder(32768);
        var count = GetFinalPathNameByHandle(handle, text, (uint)text.Capacity, 0);
        if (count == 0 || count >= text.Capacity || !GetFileInformationByHandle(handle, out var info))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Read filesystem identity");
        var canonical = text.ToString();
        if (canonical.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase)) canonical = @"\\" + canonical[8..];
        else if (canonical.StartsWith(@"\\?\")) canonical = canonical[4..];
        return new(System.IO.Path.TrimEndingDirectorySeparator(canonical), $"{info.Volume:X8}:{info.IndexHigh:X8}{info.IndexLow:X8}");
    }
    public static string Resolve(string path)
    {
        var full = System.IO.Path.GetFullPath(path);
        if (Directory.Exists(full) || File.Exists(full)) return Read(full).Path;
        var tail = new Stack<string>(); var parent = full;
        while (!Directory.Exists(parent))
        {
            tail.Push(System.IO.Path.GetFileName(parent));
            var next = System.IO.Path.GetDirectoryName(parent);
            // An offline drive has no resolvable ancestor. Keep its absolute
            // spelling for overlap checks; the selected project validates availability.
            if (next == null) return full;
            parent = next;
        }
        return tail.Aggregate(Read(parent).Path, System.IO.Path.Combine);
    }
    public static bool Contains(string root, string path) => string.Equals(root, path, StringComparison.OrdinalIgnoreCase) ||
        path.StartsWith(System.IO.Path.TrimEndingDirectorySeparator(root) + System.IO.Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    public static IEnumerable<string> KnownFolders()
    {
        foreach (var folder in new[] { Environment.SpecialFolder.UserProfile, Environment.SpecialFolder.DesktopDirectory,
            Environment.SpecialFolder.MyDocuments, Environment.SpecialFolder.MyMusic, Environment.SpecialFolder.MyPictures,
            Environment.SpecialFolder.MyVideos, Environment.SpecialFolder.Windows, Environment.SpecialFolder.System,
            Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86,
            Environment.SpecialFolder.CommonProgramFiles, Environment.SpecialFolder.CommonProgramFilesX86,
            Environment.SpecialFolder.CommonApplicationData, Environment.SpecialFolder.LocalApplicationData,
            Environment.SpecialFolder.ApplicationData })
        { var path = Environment.GetFolderPath(folder); if (!string.IsNullOrWhiteSpace(path)) yield return path; }
        var downloads = new Guid("374DE290-123F-4565-9164-39C4925E467B");
        if (SHGetKnownFolderPath(ref downloads, 0, IntPtr.Zero, out var pointer) == 0)
        { string? path; try { path = Marshal.PtrToStringUni(pointer); } finally { Marshal.FreeCoTaskMem(pointer); } if (!string.IsNullOrWhiteSpace(path)) yield return path; }
    }
}
