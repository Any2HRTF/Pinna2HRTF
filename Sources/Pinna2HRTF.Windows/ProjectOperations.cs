namespace Pinna2HRTF.Windows;

internal sealed class ProjectOperations
{
    readonly object gate = new();
    sealed class Entry { public int References = 1; }
    readonly Dictionary<Guid, Entry> owners = [];
    public bool Contains(Guid project) { lock (gate) return owners.ContainsKey(project); }
    public IDisposable? TryReserve(Guid project, IDisposable? parent = null)
    {
        lock (gate)
        {
            if (owners.TryGetValue(project, out var current))
            {
                if (parent is not Lease inherited || inherited.Owner != this || inherited.Project != project || inherited.Entry != current || inherited.Released) return null;
                current.References++;
            }
            else { current = new Entry(); owners.Add(project, current); }
            return new Lease(this, project, current, () => { lock (gate) { if (--current.References == 0 && owners.GetValueOrDefault(project) == current) owners.Remove(project); } });
        }
    }
    sealed class Lease(ProjectOperations owner, Guid project, Entry entry, Action release) : IDisposable
    {
        Action? action = release;
        public ProjectOperations Owner => owner;
        public Guid Project => project;
        public Entry Entry => entry;
        public bool Released => action == null;
        public void Dispose() => Interlocked.Exchange(ref action, null)?.Invoke();
    }
}

internal sealed class ActivityCounter
{
    readonly Dictionary<Guid, int> counts = [];
    public bool Contains(Guid id) => counts.ContainsKey(id);
    public bool Add(Guid id) { counts[id] = counts.GetValueOrDefault(id) + 1; return true; }
    public bool TryAdd(Guid id) { if (Contains(id)) return false; return Add(id); }
    public bool Remove(Guid id)
    {
        if (!counts.TryGetValue(id, out var count)) return false;
        if (count == 1) counts.Remove(id); else counts[id] = count - 1;
        return true;
    }
}
