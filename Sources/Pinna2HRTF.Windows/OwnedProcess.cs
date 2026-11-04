using Microsoft.Win32.SafeHandles;
using System.Collections;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace Pinna2HRTF.Windows;

// Each tool belongs to its own kill-on-close job before its first instruction.
// Callers supply argument arrays; this is the only Windows quoting boundary.
internal sealed class OwnedProcess : IDisposable
{
    sealed class Handle : SafeHandleZeroOrMinusOneIsInvalid
    {
        public Handle() : base(true) { }
        public Handle(IntPtr value) : base(true) => SetHandle(value);
        protected override bool ReleaseHandle() => CloseHandle(handle);
    }
    [StructLayout(LayoutKind.Sequential)] struct Security { public int Length; public IntPtr Descriptor; public int Inherit; }
    [StructLayout(LayoutKind.Sequential)] struct Startup
    {
        public int Size; public IntPtr Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XCountChars, YCountChars, FillAttribute, Flags;
        public short ShowWindow, Reserved2; public IntPtr ReservedPointer, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] struct StartupEx { public Startup Startup; public IntPtr Attributes; }
    [StructLayout(LayoutKind.Sequential)] struct ProcessInfo { public IntPtr Process, Thread; public uint ProcessId, ThreadId; }
    [StructLayout(LayoutKind.Sequential)] struct BasicLimit
    {
        public long ProcessTime, JobTime; public uint Flags; public UIntPtr MinWorkingSet, MaxWorkingSet;
        public uint ActiveLimit; public UIntPtr Affinity; public uint PriorityClass, SchedulingClass;
    }
    [StructLayout(LayoutKind.Sequential)] struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)] struct ExtendedLimit
    {
        public BasicLimit Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
    }
    [StructLayout(LayoutKind.Sequential)] struct Accounting
    {
        public long User, Kernel, PeriodUser, PeriodKernel;
        public uint PageFaults, Total, Active, Terminated;
    }
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr CreateJobObject(IntPtr attributes, string? name);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetInformationJobObject(Handle job, int info, ref ExtendedLimit value, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool QueryInformationJobObject(Handle job, int info, out Accounting value, uint size, IntPtr returned);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool TerminateJobObject(Handle job, uint code);
    [DllImport("kernel32.dll", SetLastError = true)] static extern uint WaitForSingleObject(Handle handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool GetExitCodeProcess(Handle handle, out uint exitCode);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool CreatePipe(out SafeFileHandle read, out SafeFileHandle write, ref Security security, uint size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool SetHandleInformation(SafeFileHandle handle, uint mask, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool InitializeProcThreadAttributeList(IntPtr list, int count, uint flags, ref UIntPtr size);
    [DllImport("kernel32.dll", SetLastError = true)] static extern bool UpdateProcThreadAttribute(IntPtr list, uint flags, UIntPtr attribute, IntPtr value, UIntPtr size, IntPtr previous, IntPtr returned);
    [DllImport("kernel32.dll")] static extern void DeleteProcThreadAttributeList(IntPtr list);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool CreateProcess(string application, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity, bool inherit, uint flags,
        IntPtr environment, string directory, ref StartupEx startup, out ProcessInfo info);

    readonly Handle job;
    readonly Handle processHandle;
    public Process Process { get; }
    public StreamReader Output { get; }
    public StreamReader Error { get; }
    public StreamWriter Input { get; }
    int disposed;
    public bool Cancelled { get; private set; }
    public Guid? ProjectId { get; }
    static readonly object registryGate = new();
    static readonly HashSet<OwnedProcess> active = [];

    OwnedProcess(Handle job, Handle processHandle, Process process, SafeFileHandle input, SafeFileHandle output, SafeFileHandle error, Guid? project)
    {
        this.job = job; this.processHandle = processHandle; Process = process; ProjectId = project;
        Input = new StreamWriter(new FileStream(input, FileAccess.Write), new UTF8Encoding(false)) { AutoFlush = true };
        Output = new StreamReader(new FileStream(output, FileAccess.Read), new UTF8Encoding(false));
        Error = new StreamReader(new FileStream(error, FileAccess.Read), new UTF8Encoding(false));
        lock (registryGate) active.Add(this);
    }
    static void Check(bool result, string operation) { if (!result) throw new Win32Exception(Marshal.GetLastWin32Error(), operation); }
    static (SafeFileHandle Read, SafeFileHandle Write) Pipe(bool childReads)
    {
        var security = new Security { Length = Marshal.SizeOf<Security>(), Inherit = 1 };
        Check(CreatePipe(out var read, out var write, ref security, 0), "Create tool pipe");
        try { Check(SetHandleInformation(childReads ? write : read, 1, 0), "Protect parent pipe handle"); return (read, write); }
        catch { read.Dispose(); write.Dispose(); throw; }
    }
    internal static string Quote(string argument)
    {
        var result = new StringBuilder("\""); var slashes = 0;
        foreach (var c in argument)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') result.Append('\\', slashes * 2 + 1).Append('"');
            else result.Append('\\', slashes).Append(c);
            slashes = 0;
        }
        return result.Append('\\', slashes * 2).Append('"').ToString();
    }
    public static OwnedProcess Start(ProcessStartInfo request, Guid? project = null)
    {
        if (request.Arguments.Length != 0) throw new ArgumentException("Owned tools require ArgumentList.");
        if (!Path.IsPathFullyQualified(request.FileName) || !File.Exists(request.FileName)) throw new FileNotFoundException("The tool executable is missing.", request.FileName);
        var job = new Handle(CreateJobObject(IntPtr.Zero, null));
        if (job.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error(), "Create owned tool job");
        var limits = new ExtendedLimit { Basic = new BasicLimit { Flags = 0x2000 } };
        (SafeFileHandle? Read, SafeFileHandle? Write) stdin = default, stdout = default, stderr = default;
        IntPtr attributes = IntPtr.Zero, handles = IntPtr.Zero, jobs = IntPtr.Zero, environment = IntPtr.Zero;
        var initialized = false; var transferred = false;
        try
        {
            stdin = Pipe(true); stdout = Pipe(false); stderr = Pipe(false);
            Check(SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimit>()), "Set tool job limits");
            UIntPtr bytes = UIntPtr.Zero;
            InitializeProcThreadAttributeList(IntPtr.Zero, 2, 0, ref bytes);
            attributes = Marshal.AllocHGlobal(checked((int)bytes.ToUInt64()));
            Check(InitializeProcThreadAttributeList(attributes, 2, 0, ref bytes), "Initialize launch attributes"); initialized = true;
            var childHandles = new[] { stdin.Read!.DangerousGetHandle(), stdout.Write!.DangerousGetHandle(), stderr.Write!.DangerousGetHandle() };
            handles = Marshal.AllocHGlobal(IntPtr.Size * 3); Marshal.Copy(childHandles, 0, handles, 3);
            jobs = Marshal.AllocHGlobal(IntPtr.Size); Marshal.WriteIntPtr(jobs, job.DangerousGetHandle());
            Check(UpdateProcThreadAttribute(attributes, 0, new UIntPtr(0x20002), handles, new UIntPtr((uint)(IntPtr.Size * 3)), IntPtr.Zero, IntPtr.Zero), "Limit inherited pipe handles");
            Check(UpdateProcThreadAttribute(attributes, 0, new UIntPtr(0x2000D), jobs, new UIntPtr((uint)IntPtr.Size), IntPtr.Zero, IntPtr.Zero), "Contain tool at launch");
            var env = new SortedDictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (DictionaryEntry item in Environment.GetEnvironmentVariables()) env[(string)item.Key] = (string)item.Value!;
            foreach (var item in request.Environment) { if (item.Value == null) env.Remove(item.Key); else env[item.Key] = item.Value; }
            environment = Marshal.StringToHGlobalUni(string.Join('\0', env.Select(x => x.Key + "=" + x.Value)) + "\0\0");
            var startup = new StartupEx { Startup = new Startup { Size = Marshal.SizeOf<StartupEx>(), Flags = 0x100, Input = childHandles[0], Output = childHandles[1], Error = childHandles[2] }, Attributes = attributes };
            var command = new StringBuilder(string.Join(' ', new[] { request.FileName }.Concat(request.ArgumentList).Select(Quote)));
            Check(CreateProcess(request.FileName, command, IntPtr.Zero, IntPtr.Zero, true, 0x08000000 | 0x00000400 | 0x00080000,
                environment, string.IsNullOrEmpty(request.WorkingDirectory) ? Path.GetDirectoryName(request.FileName)! : request.WorkingDirectory, ref startup, out var native), "Launch contained tool");
            var launchedHandle = new Handle(native.Process);
            try
            {
                var result = new OwnedProcess(job, launchedHandle, Process.GetProcessById((int)native.ProcessId), stdin.Write!, stdout.Read!, stderr.Read!, project);
                transferred = true; return result;
            }
            finally { CloseHandle(native.Thread); if (!transferred) launchedHandle.Dispose(); }
        }
        finally
        {
            stdin.Read?.Dispose(); stdout.Write?.Dispose(); stderr.Write?.Dispose();
            if (initialized) DeleteProcThreadAttributeList(attributes);
            foreach (var pointer in new[] { attributes, handles, jobs, environment }) if (pointer != IntPtr.Zero) Marshal.FreeHGlobal(pointer);
            if (!transferred) { job.Dispose(); stdin.Write?.Dispose(); stdout.Read?.Dispose(); stderr.Read?.Dispose(); }
        }
    }
    public int ActiveCount
    {
        get { Check(QueryInformationJobObject(job, 1, out var value, (uint)Marshal.SizeOf<Accounting>(), IntPtr.Zero), "Inspect owned process job"); return (int)value.Active; }
    }
    public void Terminate()
    {
        if (Volatile.Read(ref disposed) != 0) return;
        Cancelled = true; Check(TerminateJobObject(job, 1), "Stop owned process job");
    }
    public async Task<bool> WaitForEmptyAsync(TimeSpan timeout)
    {
        var watch = Stopwatch.StartNew();
        while (ActiveCount != 0) { if (watch.Elapsed >= timeout) return false; await Task.Delay(25).ConfigureAwait(false); }
        return true;
    }
    public async Task<int> WaitAsync(CancellationToken token = default)
    {
        using var registration = token.Register(() => { try { Terminate(); } catch { } });
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var state = WaitForSingleObject(processHandle, 0);
            if (state == 0) break;
            if (state != 258) throw new Win32Exception(Marshal.GetLastWin32Error(), "Wait for owned tool");
            await Task.Delay(25, token).ConfigureAwait(false);
        }
        Check(GetExitCodeProcess(processHandle, out var nativeCode), "Read owned tool exit status");
        var code = unchecked((int)nativeCode);
        if (!await WaitForEmptyAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false))
        { Terminate(); await WaitForEmptyAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); throw new IOException("The tool exited with active child processes; its owned job was stopped."); }
        token.ThrowIfCancellationRequested(); return code;
    }
    public static bool HasProjectActivity(Guid id) { lock (registryGate) return active.Any(p => p.ProjectId == id); }
    public static void StopAll()
    {
        OwnedProcess[] snapshot; lock (registryGate) snapshot = active.ToArray();
        foreach (var process in snapshot) try { process.Terminate(); } catch { }
        try { Task.WhenAll(snapshot.Select(p => p.WaitForEmptyAsync(TimeSpan.FromSeconds(5)))).Wait(TimeSpan.FromSeconds(6)); } catch { }
        foreach (var process in snapshot) process.Dispose();
    }
    public void Dispose()
    {
        if (Interlocked.Exchange(ref disposed, 1) != 0) return;
        try { TerminateJobObject(job, 1); try { WaitForEmptyAsync(TimeSpan.FromSeconds(2)).GetAwaiter().GetResult(); } catch { } }
        finally { job.Dispose(); }
        try { Input.Dispose(); } catch { }
        try { Output.Dispose(); } catch { }
        try { Error.Dispose(); } catch { }
        Process.Dispose(); processHandle.Dispose(); lock (registryGate) active.Remove(this);
    }
}

internal static class ToolProcess
{
    public static async Task<(int ExitCode, string Output, string Error)> RunAsync(ProcessStartInfo request, string? input,
        TimeSpan timeout, CancellationToken token = default, Guid? project = null)
    {
        using var lifetime = CancellationTokenSource.CreateLinkedTokenSource(token); lifetime.CancelAfter(timeout);
        using var owned = OwnedProcess.Start(request, project);
        using var registration = lifetime.Token.Register(() => { try { owned.Terminate(); } catch { } });
        async Task<string> ReadAsync(StreamReader reader)
        {
            try
            {
            var text = new StringBuilder(); var buffer = new char[8192];
            while (true)
            {
                var count = await reader.ReadAsync(buffer.AsMemory(), lifetime.Token).ConfigureAwait(false); if (count == 0) return text.ToString();
                if (text.Length + count > 32 * 1024 * 1024) { owned.Terminate(); throw new IOException("Tool output exceeded the supported response size."); }
                text.Append(buffer, 0, count);
            }
            }
            catch { try { owned.Terminate(); } catch { } throw; }
        }
        var stdout = ReadAsync(owned.Output); var stderr = ReadAsync(owned.Error);
        try
        {
            if (input != null) await owned.Input.WriteAsync(input.AsMemory(), lifetime.Token).ConfigureAwait(false);
            owned.Input.Close();
            var exit = await owned.WaitAsync(lifetime.Token).ConfigureAwait(false);
            await Task.WhenAll(stdout, stderr).WaitAsync(TimeSpan.FromSeconds(2), lifetime.Token).ConfigureAwait(false);
            return (exit, await stdout.ConfigureAwait(false), await stderr.ConfigureAwait(false));
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested)
        { throw new TimeoutException($"The tool exceeded its {timeout.TotalSeconds:g}-second time limit."); }
        finally
        {
            // Observe both readers even when cancellation/launch/protocol failed.
            if (!stdout.IsCompleted || !stderr.IsCompleted) { try { owned.Terminate(); } catch { } }
            try { if (owned.ActiveCount != 0) { owned.Terminate(); await owned.WaitForEmptyAsync(TimeSpan.FromSeconds(5)).ConfigureAwait(false); } } catch { }
            _ = stdout.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
            _ = stderr.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted);
        }
    }
}
