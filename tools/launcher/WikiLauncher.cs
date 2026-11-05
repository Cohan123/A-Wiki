using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Windows.Forms;

namespace FirmenWiki
{
    internal sealed class WikiOptions
    {
        public int Port = 8765;
        public string Bind = "127.0.0.1";
        public bool NoBrowser = false;
        public bool Minimized = false;
        public string RootOverride = null;

        public static void PrintHelp()
        {
            MessageBox.Show(
                "Firmen-Wiki Launcher\n\n" +
                "Optionen:\n" +
                "  --port N      Start-Port (Standard 8765, bei Belegung automatisch 8766...8785)\n" +
                "  --bind ADDR   Bind-Adresse (Standard 127.0.0.1)\n" +
                "  --network     Kurzform fuer --bind 0.0.0.0 (LAN-Zugriff, ggf. Firewall-Rueckfrage)\n" +
                "  --root PFAD   Wiki-Ordner explizit angeben\n" +
                "  --no-browser  Browser nicht automatisch oeffnen\n" +
                "  --autostart   Minimiert starten (fuer Autostart, ohne Browser)\n" +
                "  --help        Diese Hilfe anzeigen",
                "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        public static WikiOptions Parse(string[] args)
        {
            WikiOptions o = new WikiOptions();
            for (int i = 0; i < args.Length; i++)
            {
                string a = args[i].ToLowerInvariant();
                if (a == "--help" || a == "-h" || a == "/?")
                {
                    PrintHelp();
                    Environment.Exit(0);
                }
                else if (a == "--port" && i + 1 < args.Length)
                {
                    int p;
                    if (int.TryParse(args[++i], out p) && p >= 1024 && p <= 65535) o.Port = p;
                }
                else if (a == "--bind" && i + 1 < args.Length)
                {
                    o.Bind = args[++i].Trim();
                }
                else if (a == "--network")
                {
                    o.Bind = "0.0.0.0";
                }
                else if (a == "--root" && i + 1 < args.Length)
                {
                    o.RootOverride = args[++i];
                }
                else if (a == "--no-browser")
                {
                    o.NoBrowser = true;
                }
                else if (a == "--autostart")
                {
                    o.Minimized = true;
                    o.NoBrowser = true;
                }
            }
            return o;
        }
    }

    internal static class WikiPaths
    {
        public static string FindRoot(string rootOverride)
        {
            if (!string.IsNullOrEmpty(rootOverride))
            {
                string full = Path.GetFullPath(rootOverride);
                if (Directory.Exists(full)) return full;
                throw new Exception("Wiki-Ordner nicht gefunden: " + rootOverride);
            }
            string exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
            string[] candidates = new string[]
            {
                exeDir,
                Directory.Exists(exeDir) ? Path.GetDirectoryName(exeDir) : null,
                Directory.GetCurrentDirectory()
            };
            foreach (string c in candidates)
            {
                if (string.IsNullOrEmpty(c)) continue;
                try
                {
                    if (File.Exists(Path.Combine(c, "tools", "editor-server.ps1"))
                        && File.Exists(Path.Combine(c, "index.html")))
                        return Path.GetFullPath(c);
                }
                catch { }
            }
            // Fallback: EXE-Verzeichnis, Fehler kommt spaeter mit klarer Meldung
            return Path.GetFullPath(exeDir);
        }

        public static string MutexName(string root)
        {
            string key = root.Trim().ToLowerInvariant();
            using (SHA1 sha = SHA1.Create())
            {
                byte[] hash = sha.ComputeHash(Encoding.UTF8.GetBytes(key));
                StringBuilder sb = new StringBuilder();
                for (int i = 0; i < 8; i++) sb.Append(hash[i].ToString("x2"));
                return "Local\\FirmenWikiLauncher-" + sb.ToString();
            }
        }

        public static string StartupShortcut
        {
            get
            {
                return Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.Startup),
                    "Firmen-Wiki.lnk");
            }
        }
    }

    internal static class WikiHealth
    {
        public static string GetStatusRoot(string url, int timeoutMs)
        {
            try
            {
                HttpWebRequest req = (HttpWebRequest)WebRequest.Create(url);
                req.Method = "GET";
                req.Timeout = timeoutMs;
                req.ReadWriteTimeout = timeoutMs;
                req.CachePolicy = new System.Net.Cache.RequestCachePolicy(System.Net.Cache.RequestCacheLevel.BypassCache);
                using (HttpWebResponse res = (HttpWebResponse)req.GetResponse())
                {
                    if (res.StatusCode != HttpStatusCode.OK) return null;
                    using (StreamReader sr = new StreamReader(res.GetResponseStream(), Encoding.UTF8))
                    {
                        string body = sr.ReadToEnd();
                        // Minimal-Parsing ohne JSON-Dependency: "root": "..." suchen
                        int idx = body.IndexOf("\"root\"");
                        if (idx < 0) return "";
                        int colon = body.IndexOf(':', idx);
                        if (colon < 0) return "";
                        int q1 = body.IndexOf('"', colon + 1);
                        if (q1 < 0) return "";
                        StringBuilder sb = new StringBuilder();
                        for (int i = q1 + 1; i < body.Length; i++)
                        {
                            char c = body[i];
                            if (c == '\\' && i + 1 < body.Length)
                            {
                                char n = body[i + 1];
                                if (n == '\\') { sb.Append('\\'); i++; }
                                else if (n == '"') { sb.Append('"'); i++; }
                                else if (n == 'n') { sb.Append('\n'); i++; }
                                else if (n == 'r') { sb.Append('\r'); i++; }
                                else if (n == 't') { sb.Append('\t'); i++; }
                                else { sb.Append(n); i++; }
                            }
                            else if (c == '"') break;
                            else sb.Append(c);
                        }
                        return sb.ToString();
                    }
                }
            }
            catch
            {
                return null;
            }
        }

        public static bool IsSameRoot(string statusRoot, string root)
        {
            if (statusRoot == null) return false;
            try
            {
                string a = Path.GetFullPath(statusRoot).Trim().TrimEnd('\\').ToLowerInvariant();
                string b = Path.GetFullPath(root).Trim().TrimEnd('\\').ToLowerInvariant();
                return a == b;
            }
            catch { return false; }
        }

        public static bool IsPortListening(int port)
        {
            try
            {
                using (System.Net.Sockets.TcpClient c = new System.Net.Sockets.TcpClient())
                {
                    IAsyncResult ar = c.BeginConnect("127.0.0.1", port, null, null);
                    bool ok = ar.AsyncWaitHandle.WaitOne(400);
                    if (!ok) return false;
                    c.EndConnect(ar);
                    return true;
                }
            }
            catch { return false; }
        }
    }

    internal sealed class WikiContext : ApplicationContext
    {
        private readonly string _root;
        private readonly WikiOptions _opt;
        private readonly int _port;
        private Process _server;
        private readonly NotifyIcon _tray;
        private readonly string _url;
        private readonly string _logFile;
        private bool _exiting;

        public WikiContext(string root, WikiOptions opt, int port)
        {
            _root = root;
            _opt = opt;
            _port = port;
            _url = "http://127.0.0.1:" + port + "/";
            _logFile = Path.Combine(root, "runtime", "wiki-server-" + port + ".log");

            _tray = new NotifyIcon();
            _tray.Icon = SystemIcons.Application;
            _tray.Text = "Firmen-Wiki (Port " + port + ")";
            _tray.Visible = true;
            _tray.DoubleClick += delegate { OpenBrowser(); };
            _tray.ContextMenuStrip = BuildMenu();
            _tray.BalloonTipTitle = "Firmen-Wiki";
        }

        private ContextMenuStrip BuildMenu()
        {
            ContextMenuStrip m = new ContextMenuStrip();
            ToolStripItem open = m.Items.Add("Wiki im Browser oeffnen", null, delegate { OpenBrowser(); });
            open.Font = new Font(open.Font, FontStyle.Bold);
            m.Items.Add("Status pruefen", null, delegate { CheckStatus(); });
            m.Items.Add("Server neu starten", null, delegate { RestartServer(); });
            m.Items.Add("Server-Log oeffnen", null, delegate { OpenLog(); });
            m.Items.Add(new ToolStripSeparator());
            ToolStripMenuItem auto = new ToolStripMenuItem("Autostart bei Anmeldung");
            auto.Checked = File.Exists(WikiPaths.StartupShortcut);
            auto.Click += delegate
            {
                try
                {
                    if (File.Exists(WikiPaths.StartupShortcut))
                    {
                        File.Delete(WikiPaths.StartupShortcut);
                        auto.Checked = false;
                        _tray.ShowBalloonTip(3000, "Firmen-Wiki", "Autostart deaktiviert.", ToolTipIcon.Info);
                    }
                    else
                    {
                        LauncherProgram.CreateStartupShortcut();
                        auto.Checked = true;
                        _tray.ShowBalloonTip(3000, "Firmen-Wiki", "Autostart aktiviert (nur dieses Benutzerkonto).", ToolTipIcon.Info);
                    }
                }
                catch (Exception ex) { MessageBox.Show("Autostart konnte nicht geaendert werden:\n" + ex.Message, "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Warning); }
            };
            m.Items.Add(auto);
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add("Beenden", null, delegate { ExitClean(); });
            return m;
        }

        public void Run()
        {
            StartServer();
            if (!_opt.NoBrowser)
            {
                // Kleiner Delay damit der erste Request nicht ins Leere laeuft;
                // der Server wird parallel bereits per Poll abgewartet.
                Thread t = new Thread(delegate ()
                {
                    Thread.Sleep(1200);
                    OpenBrowser();
                });
                t.IsBackground = true;
                t.Start();
            }
            else
            {
                _tray.ShowBalloonTip(3000, "Firmen-Wiki",
                    "Wiki laeuft im Hintergrund:\n" + _url, ToolTipIcon.Info);
            }
        }

        private void StartServer()
        {
            string ps1 = Path.Combine(_root, "tools", "editor-server.ps1");
            if (!File.Exists(ps1))
                throw new Exception("Server-Skript nicht gefunden:\n" + ps1);

            try { Directory.CreateDirectory(Path.Combine(_root, "runtime")); }
            catch { }

            string args = "-NoProfile -ExecutionPolicy Bypass -File \""
                + ps1 + "\" -Port " + _port + " -BindAddress \"" + _opt.Bind
                + "\" -Root \"" + _root + "\"";

            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.System),
                "WindowsPowerShell\\v1.0\\powershell.exe");
            if (!File.Exists(psi.FileName)) psi.FileName = "powershell.exe";
            psi.Arguments = args;
            psi.WorkingDirectory = _root;
            psi.CreateNoWindow = true;
            psi.WindowStyle = ProcessWindowStyle.Hidden;
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;

            _server = new Process();
            _server.StartInfo = psi;
            _server.EnableRaisingEvents = true;
            _server.Exited += delegate
            {
                if (_exiting) return;
                // Unerwartetes Ende -> Hinweis im Tray
                try
                {
                    string tail = ReadTail(_logFile, 2000);
                    _tray.ShowBalloonTip(5000, "Firmen-Wiki",
                        "Server wurde unerwartet beendet (Port " + _port + ").\nLog: runtime\\wiki-server-" + _port + ".log",
                        ToolTipIcon.Error);
                }
                catch { }
            };

            if (!_server.Start())
                throw new Exception("PowerShell-Prozess konnte nicht gestartet werden.");

            // Logs mitschreiben (konfliktfrei: append, pro Port eigene Datei)
            try
            {
                StreamWriter log = new StreamWriter(_logFile, true, new UTF8Encoding(false));
                log.AutoFlush = true;
                log.WriteLine("==== Start " + DateTime.Now.ToString("s") + " Port=" + _port + " Bind=" + _opt.Bind + " ====");
                _server.OutputDataReceived += delegate (object s, DataReceivedEventArgs e)
                {
                    try { if (e.Data != null) log.WriteLine(e.Data); }
                    catch { }
                };
                _server.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e)
                {
                    try { if (e.Data != null) log.WriteLine("[ERR] " + e.Data); }
                    catch { }
                };
                _server.BeginOutputReadLine();
                _server.BeginErrorReadLine();
            }
            catch { }

            // Auf Bereitschaft warten (max ~25 s)
            bool ready = false;
            for (int i = 0; i < 50; i++)
            {
                Thread.Sleep(500);
                if (_server.HasExited) break;
                string probe = WikiHealth.GetStatusRoot("http://127.0.0.1:" + _port + "/api/status", 1500);
                if (probe != null) { ready = true; break; }
            }
            if (!ready)
            {
                if (_server.HasExited)
                    throw new Exception("Server-Prozess wurde sofort beendet. Details in:\nruntime\\wiki-server-" + _port + ".log");
                // Laeuft evtl. trotzdem (langsamer Erst-Build) -> weiterlaufen lassen
                AppendLog("Hinweis: Status nach 25s noch nicht erreichbar, laeuft evtl. noch der Erst-Build.");
            }
        }

        private void AppendLog(string line)
        {
            try { File.AppendAllText(_logFile, DateTime.Now.ToString("s") + " " + line + "\r\n", new UTF8Encoding(false)); }
            catch { }
        }

        private static string ReadTail(string file, int maxChars)
        {
            try
            {
                if (!File.Exists(file)) return "";
                string t = File.ReadAllText(file, Encoding.UTF8);
                if (t.Length <= maxChars) return t;
                return t.Substring(t.Length - maxChars);
            }
            catch { return ""; }
        }

        private void OpenBrowser()
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = _url;
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Browser konnte nicht geoeffnet werden:\n" + _url + "\n\n" + ex.Message,
                    "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void CheckStatus()
        {
            string probe = WikiHealth.GetStatusRoot("http://127.0.0.1:" + _port + "/api/status", 3000);
            if (probe != null)
                MessageBox.Show("Server laeuft.\n\nURL: " + _url + "\nOrdner: " + _root,
                    "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Information);
            else
                MessageBox.Show("Server antwortet gerade nicht (Port " + _port + ").\nLog: runtime\\wiki-server-" + _port + ".log",
                    "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        private void RestartServer()
        {
            try
            {
                KillServer();
                StartServer();
                _tray.ShowBalloonTip(3000, "Firmen-Wiki", "Server wurde neu gestartet.", ToolTipIcon.Info);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Neustart fehlgeschlagen:\n" + ex.Message,
                    "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
        }

        private void OpenLog()
        {
            try
            {
                if (!File.Exists(_logFile))
                {
                    MessageBox.Show("Noch keine Log-Datei vorhanden:\n" + _logFile,
                        "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Information);
                    return;
                }
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = _logFile;
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Log konnte nicht geoeffnet werden:\n" + ex.Message,
                    "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }

        private void KillServer()
        {
            try
            {
                if (_server != null && !_server.HasExited)
                {
                    _server.CancelOutputRead();
                    _server.CancelErrorRead();
                    _server.Kill();
                    _server.WaitForExit(5000);
                }
            }
            catch { }
            try { if (_server != null) _server.Dispose(); }
            catch { }
            _server = null;
        }

        public void ExitClean()
        {
            _exiting = true;
            try { KillServer(); }
            finally
            {
                try { _tray.Visible = false; }
                catch { }
                Application.Exit();
            }
        }
    }

    internal static class LauncherProgram
    {
        public static void CreateStartupShortcut()
        {
            string exe = Assembly.GetExecutingAssembly().Location;
            string lnk = WikiPaths.StartupShortcut;
            try
            {
                Type shellType = Type.GetTypeFromProgID("WScript.Shell");
                object shell = Activator.CreateInstance(shellType);
                object shortcut = shellType.InvokeMember("CreateShortcut",
                    BindingFlags.InvokeMethod, null, shell, new object[] { lnk });
                Type scType = shortcut.GetType();
                scType.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { exe });
                scType.InvokeMember("Arguments", BindingFlags.SetProperty, null, shortcut, new object[] { "--autostart" });
                scType.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut,
                    new object[] { Path.GetDirectoryName(exe) });
                scType.InvokeMember("WindowStyle", BindingFlags.SetProperty, null, shortcut, new object[] { 7 });
                scType.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut,
                    new object[] { "Firmen-Wiki automatisch starten (nur dieses Benutzerkonto)." });
                scType.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
            }
            catch (Exception ex)
            {
                throw new Exception("Autostart-Verknuepfung konnte nicht erstellt werden (" + lnk + "): " + ex.Message);
            }
        }

        [STAThread]
        public static void Main(string[] args)
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            WikiOptions opt;
            try { opt = WikiOptions.Parse(args); }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            string root;
            try { root = WikiPaths.FindRoot(opt.RootOverride); }
            catch (Exception ex)
            {
                MessageBox.Show(ex.Message, "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // Konflikt-Schutz 1: nur eine Launcher-Instanz pro Wiki-Ordner.
            // Andere Ordner (andere Pfade) bekommen bewusst einen eigenen Mutex.
            Mutex mutex = null;
            bool first = false;
            try
            {
                mutex = new Mutex(false, WikiPaths.MutexName(root));
                first = mutex.WaitOne(0);
            }
            catch { first = true; }

            // Port-Auswahl: 8765 bevorzugt, bei Fremdbelegung automatisch weiter.
            int port = opt.Port;
            bool portFixed = false;
            for (int i = 0; i < args.Length; i++)
            {
                if (args[i].ToLowerInvariant() == "--port") { portFixed = true; break; }
            }

            int chosen = -1;
            if (portFixed)
            {
                string probe = WikiHealth.GetStatusRoot("http://127.0.0.1:" + port + "/api/status", 1500);
                if (probe != null && WikiHealth.IsSameRoot(probe, root))
                {
                    // Gleiche Instanz laeuft bereits -> nur Browser oeffnen
                    if (!opt.NoBrowser) OpenUrl("http://127.0.0.1:" + port + "/");
                    return;
                }
                if (probe != null || WikiHealth.IsPortListening(port))
                {
                    MessageBox.Show("Port " + port + " ist bereits belegt (fremder Prozess).\n" +
                        "Entweder den anderen Prozess beenden oder ohne --port starten (automatische Wahl).",
                        "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                    return;
                }
                chosen = port;
            }
            else
            {
                for (int p = port; p <= port + 20; p++)
                {
                    string probe = WikiHealth.GetStatusRoot("http://127.0.0.1:" + p + "/api/status", 900);
                    if (probe != null)
                    {
                        if (WikiHealth.IsSameRoot(probe, root))
                        {
                            if (!opt.NoBrowser) OpenUrl("http://127.0.0.1:" + p + "/");
                            else
                            {
                                // Autostart: still und kommentarlos beenden
                            }
                            return;
                        }
                        continue; // fremder Server -> naechsten Port versuchen
                    }
                    if (WikiHealth.IsPortListening(p)) continue;
                    chosen = p;
                    break;
                }
                if (chosen < 0)
                {
                    MessageBox.Show("Kein freier Port im Bereich " + port + "..." + (port + 20) + " gefunden.",
                        "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return;
                }
                if (chosen != port)
                {
                    // Hinweis nur im interaktiven Modus, nicht beim Autostart
                    if (!opt.Minimized)
                    {
                        // kein Popup-Zwang: Tray zeigt es spaeter; hier bewusst still
                    }
                }
            }

            if (!first)
            {
                // Zweiter Launcher-Doppelklick auf denselben Ordner:
                // keinen zweiten Server starten, stattdessen Browser oeffnen.
                if (!opt.NoBrowser) OpenUrl("http://127.0.0.1:" + chosen + "/");
                else
                {
                    string probe2 = WikiHealth.GetStatusRoot("http://127.0.0.1:" + chosen + "/api/status", 1500);
                    if (probe2 == null && !opt.NoBrowser) OpenUrl("http://127.0.0.1:" + chosen + "/");
                }
                // Falls auf dem gewaehlten Port noch nichts laeuft, waere das
                // ein verwaister Mutex -> trotzdem normal weiterstarten.
                // Pruefung: nur abbrechen, wenn der Port wirklich antwortet.
                string verify = WikiHealth.GetStatusRoot("http://127.0.0.1:" + chosen + "/api/status", 1200);
                if (verify != null) return;
                // sonst: Mutex verwaist, weiterlaufen und Server starten
            }

            WikiContext ctx = null;
            try
            {
                ctx = new WikiContext(root, opt, chosen);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Start fehlgeschlagen:\n" + ex.Message,
                    "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return;
            }

            // Sauberes Aufraeumen bei Abmeldung/Herunterfahren
            Microsoft.Win32.SystemEvents.SessionEnding += delegate
            {
                try { if (ctx != null) ctx.ExitClean(); }
                catch { }
            };

            try
            {
                ctx.Run();
                Application.Run(ctx);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Start fehlgeschlagen:\n" + ex.Message,
                    "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Error);
                try { ctx.ExitClean(); }
                catch { }
            }
            finally
            {
                try { if (mutex != null) { try { mutex.ReleaseMutex(); } catch { } mutex.Dispose(); } }
                catch { }
            }
        }

        private static void OpenUrl(string url)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = url;
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch (Exception ex)
            {
                MessageBox.Show("Browser konnte nicht geoeffnet werden:\n" + url + "\n\n" + ex.Message,
                    "Firmen-Wiki", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        }
    }
}
