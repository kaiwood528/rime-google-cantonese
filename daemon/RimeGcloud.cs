// rime-gcloud.exe — background fetcher for the rime-google-cantonese Weasel (Rime) plugin.
//
// The Lua plugin (rime/lua/gcloud.lua) cannot make network calls, so it talks to this
// program through small files under %APPDATA%\Rime\gcloud:
//
//   request.txt   Lua writes "<query>\n<seq>\n<push 0|1>\n<engine>\n" when it wants a lookup.
//                 An empty query is a "user is typing" ping: no text is sent anywhere, we only
//                 keep the HTTPS connection to Google warm.
//   cache\q_<query>.txt (engine "jyutping") or cache\q_<engine>_<query>.txt
//                 "OK\n" + "<matched_len>\t<text>\t<annotation>" lines, or "ERR\t<message>".
//   heartbeat.txt epoch seconds, refreshed every 2 s so Lua knows we are alive.
//
// Written in C# 5 so that install.ps1 can compile it with the csc.exe that ships with
// .NET Framework 4.x on every Windows 10/11: users do not need to install anything.
// request.txt is watched with FileSystemWatcher (no busy polling), so idle CPU is ~0.
//
//   rime-gcloud.exe                          run in the background (single instance)
//   rime-gcloud.exe --once Q [--engine E] [--out FILE]   fetch one query and print it
//   rime-gcloud.exe --verbose                also log each query text (off by default)

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;

// Run with .NET Framework 4.8 behaviour (system default TLS versions etc.).
[assembly: System.Runtime.Versioning.TargetFramework(".NETFramework,Version=v4.8")]
[assembly: System.Reflection.AssemblyTitle("rime-gcloud")]
[assembly: System.Reflection.AssemblyDescription("Google Cantonese candidates for Weasel (Rime)")]
[assembly: System.Reflection.AssemblyProduct("rime-google-cantonese")]
[assembly: System.Reflection.AssemblyVersion("0.2.0.0")]

namespace RimeGcloud
{
    sealed class Job : IEquatable<Job>
    {
        public readonly string Q;
        public readonly string Engine;
        public Job(string q, string engine) { Q = q; Engine = engine; }
        public bool Equals(Job other) { return other != null && other.Q == Q && other.Engine == Engine; }
        public override bool Equals(object obj) { return Equals(obj as Job); }
        public override int GetHashCode() { return Q.GetHashCode() * 31 + Engine.GetHashCode(); }
    }

    sealed class Cand
    {
        public int Len;
        public string Text;
        public string Note;
    }

    static class Program
    {
        static readonly string AppDir = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Rime", "gcloud");
        static readonly string CacheDir = Path.Combine(AppDir, "cache");
        static readonly string RequestFile = Path.Combine(AppDir, "request.txt");
        static readonly string HeartbeatFile = Path.Combine(AppDir, "heartbeat.txt");
        static readonly string LogFile = Path.Combine(AppDir, "daemon.log");
        static readonly string CacheVersionFile = Path.Combine(AppDir, "cache_version.txt");

        const string Endpoint = "https://inputtools.google.com/request";
        // Each Rime schema names its engine set (gcloud/engine):
        //   jyutping  Jyutping first; Yale-based only when Jyutping returns nothing (e.g. "sjfm")
        //   yale      Yale-based only: the Jyutping engine misreads Yale j/ch (jau -> 有, not 走)
        static readonly Dictionary<string, string[]> Engines = new Dictionary<string, string[]>
        {
            { "jyutping", new[] { "yue-hant-t-i0-jyutping", "yue-hant-t-i0-und" } },
            { "yale", new[] { "yue-hant-t-i0-und" } },
        };
        const string DefaultEngine = "jyutping";
        const string CacheVersion = "2-jyutping+und-fallback"; // same as the old Python daemon
        const int NumCandidates = 15;
        const int Workers = 3;
        const int MaxPending = 4;        // stale prefixes beyond this are dropped while typing fast
        const int MaxQueryLen = 60;
        const int MaxCacheFiles = 30000;
        const double ErrRetrySeconds = 5;
        const double PushMaxAgeSeconds = 3;
        const double KeepaliveSeconds = 45;            // refresh the idle connection ...
        const double KeepaliveWhileActiveSeconds = 600; // ... only within 10 min of typing
        const int HeartbeatMs = 2000;
        const int HttpTimeoutSeconds = 6;
        const long MaxLogBytes = 256000;

        static HttpClient http;
        static bool verbose;
        static Mutex instanceMutex;
        static FileSystemWatcher watcher;
        static Timer heartbeatTimer;
        static Timer keepaliveTimer;

        static readonly object logLock = new object();
        static readonly object reqLock = new object();
        static readonly object gate = new object();
        static readonly LinkedList<Job> pending = new LinkedList<Job>();
        static readonly HashSet<Job> inflight = new HashSet<Job>();
        static Job latestJob;
        static bool latestPush;
        static DateTime latestTime;
        static DateTime lastActivity = DateTime.UtcNow;
        static DateTime lastPrune = DateTime.UtcNow;
        static string lastContent;
        static DateTime lastRequestStamp;
        static long lastRequestLength = -1;
        static int warming;
        static readonly int pid = Process.GetCurrentProcess().Id;

        static int Main(string[] args)
        {
            try
            {
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | (SecurityProtocolType)12288; // + TLS 1.3
            }
            catch (NotSupportedException)
            {
                ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12;
            }
            ServicePointManager.DefaultConnectionLimit = Workers + 1;
            http = new HttpClient();
            http.Timeout = TimeSpan.FromSeconds(HttpTimeoutSeconds);
            http.DefaultRequestHeaders.UserAgent.ParseAdd("rime-gcloud/0.2");

            int once = Array.IndexOf(args, "--once");
            if (once >= 0 && once + 1 < args.Length) return RunOnce(args, args[once + 1]);
            verbose = Array.IndexOf(args, "--verbose") >= 0;
            return Run();
        }

        // ------------------------------------------------------------ one-off lookup (testing)

        [DllImport("kernel32.dll")]
        static extern bool AttachConsole(int processId);

        static int RunOnce(string[] args, string q)
        {
            int e = Array.IndexOf(args, "--engine");
            string engine = (e >= 0 && e + 1 < args.Length) ? args[e + 1] : DefaultEngine;
            int o = Array.IndexOf(args, "--out");
            var sb = new StringBuilder();
            try
            {
                var sw = Stopwatch.StartNew();
                var cands = Lookup(q, engine);
                sb.Append(sw.ElapsedMilliseconds).Append(" ms\n");
                foreach (var c in cands) sb.Append(c.Len).Append('\t').Append(c.Text).Append('\t').Append(c.Note).Append('\n');
            }
            catch (Exception ex)
            {
                sb.Append("ERROR ").Append(Describe(ex)).Append('\n');
            }
            if (o >= 0 && o + 1 < args.Length)
            {
                File.WriteAllText(args[o + 1], sb.ToString(), new UTF8Encoding(false));
            }
            else
            {
                AttachConsole(-1); // built as a windowless exe: borrow the parent's console
                Console.OutputEncoding = Encoding.UTF8;
                Console.Write(sb.ToString());
            }
            return 0;
        }

        // ------------------------------------------------------------ background mode

        static int Run()
        {
            Directory.CreateDirectory(CacheDir);
            bool createdNew;
            instanceMutex = new Mutex(false, @"Local\RimeGoogleCantoneseDaemon", out createdNew);
            if (!createdNew)
            {
                Log("INFO", "another daemon is already running; exiting");
                return 0;
            }
            AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs a)
            {
                Log("ERROR", "unhandled: " + a.ExceptionObject);
            };
            var engines = new List<string>();
            foreach (var kv in Engines) engines.Add(kv.Key + "=" + string.Join("+", kv.Value));
            Log("INFO", "daemon started (pid " + pid + ", C# " +
                Environment.Version + ", engines " + string.Join(", ", engines.ToArray()) + ")");
            EnsureCacheVersion();
            PruneCache();

            for (int i = 0; i < Workers; i++)
            {
                var t = new Thread(Worker);
                t.IsBackground = true;
                t.Start();
            }
            ThreadPool.QueueUserWorkItem(delegate { KeepWarm(); }); // first TLS handshake costs ~1 s

            watcher = new FileSystemWatcher(AppDir, "request.txt");
            watcher.NotifyFilter = NotifyFilters.LastWrite | NotifyFilters.Size | NotifyFilters.FileName | NotifyFilters.CreationTime;
            FileSystemEventHandler onChange = delegate { SafeCheckRequest(true); };
            watcher.Changed += onChange;
            watcher.Created += onChange;
            watcher.Renamed += delegate { SafeCheckRequest(true); };
            watcher.Error += delegate(object s, ErrorEventArgs a) { Log("WARNING", "watcher: " + a.GetException().Message); };
            watcher.EnableRaisingEvents = true;

            // Heartbeat, plus a cheap re-read of request.txt in case a change event was missed.
            heartbeatTimer = new Timer(delegate { OnHeartbeat(); }, null, 0, HeartbeatMs);
            keepaliveTimer = new Timer(delegate { OnKeepalive(); }, null,
                TimeSpan.FromSeconds(KeepaliveSeconds), TimeSpan.FromSeconds(KeepaliveSeconds));

            SafeCheckRequest(true);
            Thread.Sleep(Timeout.Infinite);
            GC.KeepAlive(instanceMutex);
            return 0;
        }

        static void OnHeartbeat()
        {
            try
            {
                // A plain overwrite is enough here (a few bytes); Lua only reads the first line.
                long now = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
                byte[] bytes = Encoding.ASCII.GetBytes(now + "\n" + pid + "\n");
                using (var fs = new FileStream(HeartbeatFile, FileMode.Create, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete))
                {
                    fs.Write(bytes, 0, bytes.Length);
                }
            }
            catch (Exception ex)
            {
                Log("WARNING", "heartbeat: " + ex.Message);
            }
            SafeCheckRequest(false);
            if ((DateTime.UtcNow - lastPrune).TotalHours >= 1)
            {
                lastPrune = DateTime.UtcNow;
                PruneCache();
            }
        }

        static void OnKeepalive()
        {
            bool active;
            lock (gate) active = (DateTime.UtcNow - lastActivity).TotalSeconds < KeepaliveWhileActiveSeconds;
            if (active) KeepWarm();
        }

        // ------------------------------------------------------------ requests from Lua

        // fromEvent = false: periodic safety net; only read the file if its size/time changed.
        static void SafeCheckRequest(bool fromEvent)
        {
            try { CheckRequest(fromEvent); }
            catch (Exception ex) { Log("WARNING", "request: " + ex.Message); }
        }

        static void CheckRequest(bool fromEvent)
        {
            lock (reqLock)
            {
                if (!fromEvent)
                {
                    var fi = new FileInfo(RequestFile);
                    if (!fi.Exists) return;
                    if (fi.LastWriteTimeUtc == lastRequestStamp && fi.Length == lastRequestLength) return;
                    lastRequestStamp = fi.LastWriteTimeUtc;
                    lastRequestLength = fi.Length;
                }
                string content = null;
                for (int attempt = 0; attempt < 3 && content == null; attempt++)
                {
                    try
                    {
                        using (var fs = new FileStream(RequestFile, FileMode.Open, FileAccess.Read,
                                                       FileShare.ReadWrite | FileShare.Delete))
                        using (var sr = new StreamReader(fs, Encoding.ASCII))
                        {
                            content = sr.ReadToEnd();
                        }
                    }
                    catch (FileNotFoundException) { return; }
                    catch (DirectoryNotFoundException) { return; }
                    catch (IOException) { Thread.Sleep(5); }
                }
                if (string.IsNullOrEmpty(content) || content == lastContent) return;
                string[] lines = content.Split('\n');
                if (lines.Length < 3) return; // Lua is still writing; the next event re-reads it
                lastContent = content;

                string q = lines[0].Trim();
                bool push = lines[2].Trim() == "1";
                string engine = lines.Length > 3 ? lines[3].Trim() : "";
                if (!Engines.ContainsKey(engine)) engine = DefaultEngine;
                if (q.Length == 0)
                {
                    Touch();
                    return;
                }
                if (!ValidQuery(q)) return;
                var job = new Job(q, engine);
                lock (gate)
                {
                    latestJob = job;
                    latestPush = push;
                    latestTime = DateTime.UtcNow;
                }
                if (NeedsFetch(job)) Submit(job);
                else if (push) MaybePush(job); // the result landed just after Lua looked
            }
        }

        static bool ValidQuery(string q)
        {
            if (q.Length == 0 || q.Length > MaxQueryLen) return false;
            foreach (char c in q) if (c < 'a' || c > 'z') return false;
            return true;
        }

        // The user is typing (ping without text): keep the connection warm.
        static void Touch()
        {
            bool warmNow;
            lock (gate)
            {
                var now = DateTime.UtcNow;
                warmNow = (now - lastActivity).TotalSeconds > KeepaliveSeconds;
                lastActivity = now;
            }
            if (warmNow) ThreadPool.QueueUserWorkItem(delegate { KeepWarm(); });
        }

        // ------------------------------------------------------------ work queue

        static void Submit(Job job)
        {
            lock (gate)
            {
                if (inflight.Contains(job) || pending.Contains(job)) return;
                pending.AddLast(job);
                while (pending.Count > MaxPending) pending.RemoveFirst();
                Monitor.Pulse(gate);
            }
        }

        // Newest-first, so the latest keystroke is answered first.
        static void Worker()
        {
            while (true)
            {
                Job job;
                lock (gate)
                {
                    while (pending.Count == 0) Monitor.Wait(gate);
                    job = pending.Last.Value;
                    pending.RemoveLast();
                    inflight.Add(job);
                    lastActivity = DateTime.UtcNow;
                }
                var sw = Stopwatch.StartNew();
                try
                {
                    var cands = Lookup(job.Q, job.Engine);
                    var sb = new StringBuilder("OK\n");
                    foreach (var c in cands) sb.Append(c.Len).Append('\t').Append(c.Text).Append('\t').Append(c.Note).Append('\n');
                    WriteAtomic(CachePath(job), sb.ToString());
                    MaybePush(job);
                    if (verbose) Log("INFO", job.Q + " [" + job.Engine + "] -> " + cands.Count + " candidates in " + sw.ElapsedMilliseconds + " ms");
                }
                catch (Exception ex) // network down, Google changed format, ...
                {
                    Log("WARNING", "lookup failed (" + job.Q.Length + " chars, " + job.Engine + "): " + Describe(ex));
                    try { WriteAtomic(CachePath(job), "ERR\t" + Clean(Describe(ex)) + "\n"); }
                    catch (Exception) { }
                }
                finally
                {
                    lock (gate) inflight.Remove(job);
                }
            }
        }

        static void KeepWarm()
        {
            if (Interlocked.Exchange(ref warming, 1) == 1) return;
            try { Fetch("nei", Engines[DefaultEngine][0]); }
            catch (Exception ex) { Log("INFO", "warm-up failed: " + Describe(ex)); }
            finally { Interlocked.Exchange(ref warming, 0); }
        }

        // ------------------------------------------------------------ refresh nudge (F24)
        // rime_slot / cloud_first / cloud_only: when Google's answer for the *current* input
        // arrives, press F24. Weasel hands it to Rime; gcloud.lua swallows it while composing
        // and refreshes the menu. Outside a composition F24 reaches the focused app, where it
        // normally does nothing.

        static void MaybePush(Job job)
        {
            lock (gate)
            {
                if (!latestPush || latestJob == null || !latestJob.Equals(job)) return;
                if ((DateTime.UtcNow - latestTime).TotalSeconds > PushMaxAgeSeconds) return;
                latestPush = false; // nudge once per request
            }
            if (!SendRefreshKey()) Log("INFO", "refresh key not sent (SendInput blocked?)");
        }

        [StructLayout(LayoutKind.Sequential)]
        struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

        [StructLayout(LayoutKind.Sequential)]
        struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }

        [StructLayout(LayoutKind.Explicit)]
        struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }

        [StructLayout(LayoutKind.Sequential)]
        struct INPUT { public uint type; public InputUnion u; }

        [DllImport("user32.dll", SetLastError = true)]
        static extern uint SendInput(uint count, INPUT[] inputs, int size);

        const ushort VK_F24 = 0x87;

        static bool SendRefreshKey()
        {
            var inputs = new INPUT[2];
            for (int i = 0; i < 2; i++)
            {
                inputs[i].type = 1; // INPUT_KEYBOARD
                inputs[i].u.ki.wVk = VK_F24;
                inputs[i].u.ki.dwFlags = i == 0 ? 0u : 0x0002u; // key down, KEYEVENTF_KEYUP
            }
            return SendInput(2, inputs, Marshal.SizeOf(typeof(INPUT))) == 2;
        }

        // ------------------------------------------------------------ Google

        static List<Cand> Lookup(string q, string engine)
        {
            string[] itcs;
            if (!Engines.TryGetValue(engine, out itcs)) itcs = Engines[DefaultEngine];
            var cands = new List<Cand>();
            foreach (var itc in itcs)
            {
                cands = Fetch(q, itc);
                if (cands.Count > 0) break;
            }
            return cands;
        }

        static List<Cand> Fetch(string q, string itc)
        {
            string url = Endpoint + "?text=" + Uri.EscapeDataString(q) + "&itc=" + itc + "&num=" + NumCandidates +
                         "&cp=0&cs=1&ie=utf-8&oe=utf-8&app=demopage";
            for (int attempt = 1; ; attempt++)
            {
                try
                {
                    using (var resp = http.GetAsync(url).Result)
                    {
                        int status = (int)resp.StatusCode;
                        if (status != 200) throw new InvalidDataException("HTTP " + status);
                        byte[] body = resp.Content.ReadAsByteArrayAsync().Result;
                        return Parse(Encoding.UTF8.GetString(body), q);
                    }
                }
                catch (AggregateException ex)
                {
                    // A stale keep-alive connection fails once; the retry opens a new one.
                    if (attempt >= 2) throw ex.GetBaseException();
                }
            }
        }

        static List<Cand> Parse(string text, string q)
        {
            var data = new JavaScriptSerializer().DeserializeObject(text) as object[];
            if (data == null || data.Length < 2 || !"SUCCESS".Equals(data[0]))
                throw new InvalidDataException("google status " + (data != null && data.Length > 0 ? data[0] : "?"));
            var item = ((object[])data[1])[0] as object[];
            var texts = item[1] as object[];
            object[] lengths = null, notes = null;
            var meta = item.Length > 3 ? item[3] as Dictionary<string, object> : null;
            if (meta != null)
            {
                object o;
                if (meta.TryGetValue("matched_length", out o)) lengths = o as object[];
                if (meta.TryGetValue("annotation", out o)) notes = o as object[];
            }
            var result = new List<Cand>();
            for (int i = 0; texts != null && i < texts.Length; i++)
            {
                string t = Clean(Convert.ToString(texts[i])).Trim();
                if (t.Length == 0) continue;
                var c = new Cand();
                c.Text = t;
                c.Len = (lengths != null && i < lengths.Length) ? Convert.ToInt32(lengths[i]) : q.Length;
                c.Note = (notes != null && i < notes.Length) ? Clean(Convert.ToString(notes[i])) : "";
                result.Add(c);
            }
            return result;
        }

        // ------------------------------------------------------------ cache files

        static string CachePath(Job job)
        {
            // "q_" prefix avoids Windows reserved names such as con / nul / aux. Queries are
            // letters only, so "q_<engine>_<q>" cannot collide with a Jyutping "q_<q>" entry.
            string name = job.Engine == DefaultEngine ? "q_" + job.Q + ".txt" : "q_" + job.Engine + "_" + job.Q + ".txt";
            return Path.Combine(CacheDir, name);
        }

        static bool NeedsFetch(Job job)
        {
            string path = CachePath(job);
            try
            {
                var fi = new FileInfo(path);
                if (!fi.Exists) return true;
                var head = new byte[2];
                int n;
                using (var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                {
                    n = fs.Read(head, 0, 2);
                }
                if (n == 2 && head[0] == 'O' && head[1] == 'K')
                {
                    try { File.SetLastWriteTimeUtc(path, DateTime.UtcNow); } // keep recently used entries when pruning
                    catch (Exception) { }
                    return false;
                }
                return (DateTime.UtcNow - fi.LastWriteTimeUtc).TotalSeconds > ErrRetrySeconds; // retry old ERR entries
            }
            catch (IOException) { return true; }
            catch (UnauthorizedAccessException) { return true; }
        }

        static void WriteAtomic(string path, string text)
        {
            string tmp = path + "." + Thread.CurrentThread.ManagedThreadId + ".tmp";
            File.WriteAllText(tmp, text, new UTF8Encoding(false));
            for (int attempt = 0; ; attempt++)
            {
                try
                {
                    if (File.Exists(path)) File.Replace(tmp, path, null, true);
                    else File.Move(tmp, path);
                    return;
                }
                catch (Exception ex)
                {
                    if (!(ex is IOException || ex is UnauthorizedAccessException)) throw;
                    if (attempt >= 5)
                    {
                        try { File.Delete(tmp); } catch (Exception) { }
                        throw;
                    }
                    Thread.Sleep(10); // Lua may be reading the file right now
                }
            }
        }

        static void PruneCache()
        {
            try
            {
                var txt = new List<FileInfo>();
                foreach (var f in new DirectoryInfo(CacheDir).GetFiles())
                {
                    if (f.Name.EndsWith(".tmp", StringComparison.Ordinal))
                    {
                        try { f.Delete(); } catch (Exception) { }
                    }
                    else if (f.Name.EndsWith(".txt", StringComparison.Ordinal)) txt.Add(f);
                }
                if (txt.Count <= MaxCacheFiles) return;
                txt.Sort(delegate(FileInfo a, FileInfo b) { return a.LastWriteTimeUtc.CompareTo(b.LastWriteTimeUtc); });
                int remove = txt.Count - (int)(MaxCacheFiles * 0.8);
                for (int i = 0; i < remove; i++)
                {
                    try { txt[i].Delete(); } catch (Exception) { }
                }
                Log("INFO", "pruned " + remove + " cache files");
            }
            catch (Exception ex)
            {
                Log("WARNING", "prune: " + ex.Message);
            }
        }

        // Drop cached results produced by a different engine setup.
        static void EnsureCacheVersion()
        {
            string current = null;
            try { current = File.ReadAllText(CacheVersionFile).Trim(); }
            catch (Exception) { }
            if (current == CacheVersion) return;
            int removed = 0;
            foreach (var f in Directory.GetFiles(CacheDir, "q_*"))
            {
                try { File.Delete(f); removed++; } catch (Exception) { }
            }
            WriteAtomic(CacheVersionFile, CacheVersion + "\n");
            Log("INFO", "cache cleared for engine change " + (current ?? "none") + " -> " + CacheVersion + " (" + removed + " files)");
        }

        // ------------------------------------------------------------ helpers

        static string Clean(string s)
        {
            return (s ?? "").Replace('\t', ' ').Replace('\n', ' ').Replace('\r', ' ');
        }

        static string Describe(Exception ex)
        {
            var inner = ex.GetBaseException();
            return inner.GetType().Name + ": " + Clean(inner.Message);
        }

        static void Log(string level, string message)
        {
            lock (logLock)
            {
                try
                {
                    var fi = new FileInfo(LogFile);
                    if (fi.Exists && fi.Length > MaxLogBytes)
                    {
                        string old = LogFile + ".1";
                        if (File.Exists(old)) File.Delete(old);
                        File.Move(LogFile, old);
                    }
                    File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss,fff") + " " + level + " " + message + "\n",
                                       new UTF8Encoding(false));
                }
                catch (Exception) { }
            }
        }
    }
}
