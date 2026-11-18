using System.Text.Json;

namespace Pinna2HRTF.Windows;

internal sealed class GeneratedOutputManifest
{
    internal enum OutputStage { ScanPreparation = -1, Inference = 0, Preprocessing, Numcalc, Postprocessing }
    internal sealed class ResetResult
    {
        public int Deleted { get; set; }
        public int ProtectedInputs { get; set; }
        public int Modified { get; set; }
        public int NonEmpty { get; set; }
        public int Errors { get; set; }
        public bool Success => Errors == 0;
        public string Summary(OutputStage? stage) =>
            $"Outputs reset ({(stage == null ? "all" : stage == OutputStage.Numcalc ? "NumCalc onward" : stage + " onward")}): deleted {Deleted}, kept modified {Modified}, kept non-empty directories {NonEmpty}, errors {Errors}.";
    }

    readonly string root;
    readonly string rootIdentity;
    readonly string[] inputs;
    readonly string outputFolder;
    readonly Func<object, Task<JsonElement>> send;
    readonly Func<CLIWorker> openWorker;
    readonly object gate = new();
    CLIWorker? session;
    public string Token { get; private set; } = "";

    public GeneratedOutputManifest(string root, string[] inputs, string outputFolder,
        Func<object, Task<JsonElement>> send, Func<CLIWorker> openWorker)
    {
        this.root = PathIdentity.Resolve(root);
        rootIdentity = PathIdentity.Read(this.root).Id;
        this.inputs = inputs;
        this.outputFolder = outputFolder;
        this.send = send;
        this.openWorker = openWorker;
    }

    void CheckRoot()
    {
        if (PathIdentity.Read(root).Id != rootIdentity) throw new IOException("The project folder was replaced.");
    }

    object Request(string action, OutputStage? stage = null) =>
        new { action, root, inputs, output_folder = outputFolder, stage = stage?.ToString() };

    public HashSet<OutputStage> Reconcile()
    {
        lock (gate)
        {
            if (session != null || !Directory.Exists(root)) return [];
            CheckRoot();
            var result = send(Request("status")).GetAwaiter().GetResult();
            return result.GetProperty("stages").EnumerateArray()
                .Select(value => Enum.Parse<OutputStage>(value.GetString()!.Replace("-", ""), true)).ToHashSet();
        }
    }

    public void Begin(OutputStage stage)
    {
        lock (gate)
        {
            if (session != null) throw new IOException("Project outputs are busy.");
            CheckRoot();
            var worker = openWorker();
            try
            {
                var reply = worker.RequestAsync(Request("begin", stage), CancellationToken.None).GetAwaiter().GetResult();
                if (!reply.GetProperty("ready").GetBoolean()) throw new IOException("Could not start output tracking.");
                Token = reply.GetProperty("token").GetString()!;
                session = worker;
            }
            catch { worker.Dispose(); throw; }
        }
    }

    public void Complete()
    {
        lock (gate)
        {
            if (session == null) return;
            try
            {
                var reply = session.RequestAsync(new { action = "complete" }, CancellationToken.None).GetAwaiter().GetResult();
                if (!reply.GetProperty("complete").GetBoolean()) throw new IOException("Could not finish output tracking.");
            }
            finally { ReleaseForRecovery(); }
        }
    }

    public void ReleaseForRecovery()
    {
        lock (gate) { session?.Dispose(); session = null; }
    }

    public ResetResult Reset(OutputStage? stage)
    {
        if (!Directory.Exists(root)) return new();
        CheckRoot();
        var result = send(Request("reset", stage)).GetAwaiter().GetResult();
        return new ResetResult {
            Deleted = result.GetProperty("deleted").GetInt32(), Modified = result.GetProperty("modified").GetInt32(),
            ProtectedInputs = result.GetProperty("protectedInputs").GetInt32(), NonEmpty = result.GetProperty("nonEmpty").GetInt32(),
            Errors = result.GetProperty("errors").GetInt32()
        };
    }
}
