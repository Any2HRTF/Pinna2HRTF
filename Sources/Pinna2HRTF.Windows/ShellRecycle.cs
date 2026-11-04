using System.Runtime.InteropServices;
namespace Pinna2HRTF.Windows;

// FOFX_RECYCLEONDELETE requests recycling, and the sink vetoes any operation
// lacking recycle semantics. Completion requires an actual Recycle Bin item.
public static class ShellRecycle
{
    [ComImport, Guid("947AAB5F-0A5C-4C13-B4D6-4BF7836FC9F8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IOperation
    {
        void Advise(ISink sink, out uint cookie); void Unadvise(uint cookie); void SetOperationFlags(uint flags);
        void SetProgressMessage([MarshalAs(UnmanagedType.LPWStr)] string message); void SetProgressDialog(IntPtr dialog);
        void SetProperties(IntPtr properties); void SetOwnerWindow(IntPtr window);
        void ApplyPropertiesToItem(IntPtr item); void ApplyPropertiesToItems(IntPtr items);
        void RenameItem(IntPtr item, [MarshalAs(UnmanagedType.LPWStr)] string name, ISink sink); void RenameItems(IntPtr items, [MarshalAs(UnmanagedType.LPWStr)] string name);
        void MoveItem(IntPtr item, IntPtr destination, [MarshalAs(UnmanagedType.LPWStr)] string name, ISink sink); void MoveItems(IntPtr items, IntPtr destination);
        void CopyItem(IntPtr item, IntPtr destination, [MarshalAs(UnmanagedType.LPWStr)] string name, ISink sink); void CopyItems(IntPtr items, IntPtr destination);
        void DeleteItem(IntPtr item, ISink sink); void DeleteItems(IntPtr items);
        void NewItem(IntPtr destination, uint attributes, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string template, ISink sink);
        void PerformOperations(); void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
    }
    [ComVisible(true), Guid("04B0F1A7-9490-44BC-96E1-4296A31252E2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface ISink
    {
        [PreserveSig] int StartOperations(); [PreserveSig] int FinishOperations(int result);
        [PreserveSig] int PreRenameItem(uint flags, IntPtr item, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostRenameItem(uint flags, IntPtr item, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IntPtr created);
        [PreserveSig] int PreMoveItem(uint flags, IntPtr item, IntPtr destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostMoveItem(uint flags, IntPtr item, IntPtr destination, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IntPtr created);
        [PreserveSig] int PreCopyItem(uint flags, IntPtr item, IntPtr destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostCopyItem(uint flags, IntPtr item, IntPtr destination, [MarshalAs(UnmanagedType.LPWStr)] string name, int result, IntPtr created);
        [PreserveSig] int PreDeleteItem(uint flags, IntPtr item);
        [PreserveSig] int PostDeleteItem(uint flags, IntPtr item, int result, IntPtr recycled);
        [PreserveSig] int PreNewItem(uint flags, IntPtr destination, [MarshalAs(UnmanagedType.LPWStr)] string name);
        [PreserveSig] int PostNewItem(uint flags, IntPtr destination, [MarshalAs(UnmanagedType.LPWStr)] string name, [MarshalAs(UnmanagedType.LPWStr)] string template, uint attributes, int result, IntPtr created);
        [PreserveSig] int UpdateProgress(uint total, uint done); [PreserveSig] int ResetTimer(); [PreserveSig] int PauseTimer(); [PreserveSig] int ResumeTimer();
    }
    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    sealed class Sink(Func<bool> revalidate) : ISink
    {
        const int Abort = unchecked((int)0x80004004);
        public bool Recycled; public int Failure;
        public int StartOperations() => 0;
        public int FinishOperations(int result) { if (result < 0) Failure = result; return 0; }
        public int PreDeleteItem(uint flags, IntPtr item) { try { return (flags & 0x80) != 0 && revalidate() ? 0 : Abort; } catch { return Abort; } }
        public int PostDeleteItem(uint flags, IntPtr item, int result, IntPtr recycled)
        { if (result < 0 || recycled == IntPtr.Zero) Failure = result < 0 ? result : Abort; else Recycled = true; return Failure < 0 ? Failure : 0; }
        public int PreRenameItem(uint f, IntPtr i, string n) => Abort;
        public int PostRenameItem(uint f, IntPtr i, string n, int r, IntPtr c) => Abort;
        public int PreMoveItem(uint f, IntPtr i, IntPtr d, string n) => Abort;
        public int PostMoveItem(uint f, IntPtr i, IntPtr d, string n, int r, IntPtr c) => Abort;
        public int PreCopyItem(uint f, IntPtr i, IntPtr d, string n) => Abort;
        public int PostCopyItem(uint f, IntPtr i, IntPtr d, string n, int r, IntPtr c) => Abort;
        public int PreNewItem(uint f, IntPtr d, string n) => Abort;
        public int PostNewItem(uint f, IntPtr d, string n, string t, uint a, int r, IntPtr c) => Abort;
        public int UpdateProgress(uint t, uint d) => 0; public int ResetTimer() => 0; public int PauseTimer() => 0; public int ResumeTimer() => 0;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    static extern void SHCreateItemFromParsingName(string path, IntPtr context, ref Guid iid, out IntPtr item);
    public static Task RecycleAsync(string path, Func<bool> revalidate, IntPtr owner)
    {
        var completed = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            object? com = null; IntPtr item = IntPtr.Zero;
            try
            {
                if (!revalidate()) throw new IOException("The folder changed after confirmation. Nothing was recycled.");
                com = Activator.CreateInstance(Type.GetTypeFromCLSID(new Guid("3AD05575-8857-4850-9277-11B85BDB8E09"))!)!;
                var operation = (IOperation)com;
                operation.SetOwnerWindow(owner);
                operation.SetOperationFlags(0x00080000 | 0x20000000 | 0x00100000 | 0x0400 | 0x0010 | 0x0004);
                var iid = new Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE");
                SHCreateItemFromParsingName(path, IntPtr.Zero, ref iid, out item);
                var sink = new Sink(revalidate); operation.DeleteItem(item, sink); operation.PerformOperations();
                operation.GetAnyOperationsAborted(out var aborted);
                if (aborted || sink.Failure < 0 || !sink.Recycled) throw new IOException("Windows did not confirm recycling. The project remains in the list.");
                completed.SetResult();
            }
            catch (Exception error) { completed.SetException(error); }
            finally { if (item != IntPtr.Zero) Marshal.Release(item); if (com != null) Marshal.FinalReleaseComObject(com); }
        }) { IsBackground = true, Name = "Pinna2HRTF recycle" };
        thread.SetApartmentState(ApartmentState.STA); thread.Start(); return completed.Task;
    }
}
