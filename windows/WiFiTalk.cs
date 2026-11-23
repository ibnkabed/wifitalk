// WiFiTalk companion for Windows.
//
// A deliberately small program: an icon beside the clock that listens on the local Wi-Fi network and does
// exactly what the paired iPhone tells it, nothing more. It makes no decisions and holds no AI and no keys:
// the phone understands the user (on-device Apple model or Gemini through Firebase AI Logic) and sends plain
// actions such as "type this text", "press ctrl+t", "move the mouse", "open chrome".
//
// Built with the C# compiler that ships with Windows (.NET Framework 4, C# 5): see build.ps1.
//
// Protocol: one TCP connection per phone. Each frame is [1 byte type][4 bytes big-endian length][payload].
//   type 1 = JSON (both ways), type 2 = phone microphone audio (float32 mono 48 kHz),
//   type 3 = computer sound for the phone (float32 stereo interleaved, 48 kHz),
//   type 4 = a file being sent (either way; see Files).
// The first JSON frame must be {"hello":{"pin":"123456"}} or {"hello":{"token":"..."}}.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using Microsoft.Win32;

[assembly: AssemblyTitle("WiFiTalk")]
[assembly: AssemblyProduct("WiFiTalk")]
[assembly: AssemblyCompany("IbnKabed")]
[assembly: AssemblyCopyright("Copyright (c) 2026 IbnKabed")]
[assembly: AssemblyVersion("1.0.0.0")]
[assembly: AssemblyFileVersion("1.0.0.0")]

namespace WiFiTalk
{
    static class Program
    {
        public const int Port = 47821;

        [STAThread]
        static int Main(string[] args)
        {
            bool first;
            using (var mutex = new Mutex(true, "IbnKabed.WiFiTalk.Companion", out first))
            {
                if (!first) { return 0; }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.Run(new TrayApp());
            }
            return 0;
        }
    }


    // ---------------------------------------------------------------- settings: the PIN and the paired phones

    class Store
    {
        readonly string dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "WiFiTalk");
        readonly object gate = new object();
        public string Pin;
        readonly HashSet<string> tokens = new HashSet<string>();

        public Store()
        {
            try
            {
                foreach (var line in File.ReadAllLines(Path.Combine(dir, "settings.txt")))
                {
                    if (line.StartsWith("pin=")) Pin = line.Substring(4).Trim();
                    else if (line.StartsWith("token=")) tokens.Add(line.Substring(6).Trim());
                }
            }
            catch { }
            if (string.IsNullOrEmpty(Pin) || Pin.Length != 6) { Pin = NewPin(); Save(); }
        }

        static string NewPin()
        {
            var b = new byte[4];
            using (var r = RandomNumberGenerator.Create()) r.GetBytes(b);
            return (BitConverter.ToUInt32(b, 0) % 1000000).ToString("D6");
        }

        public static string NewToken()
        {
            var b = new byte[24];
            using (var r = RandomNumberGenerator.Create()) r.GetBytes(b);
            return Convert.ToBase64String(b).Replace('+', '-').Replace('/', '_').TrimEnd('=');
        }

        public bool HasToken(string t) { lock (gate) return !string.IsNullOrEmpty(t) && tokens.Contains(t); }
        public void AddToken(string t) { lock (gate) { tokens.Add(t); Save(); } }
        public int PhoneCount { get { lock (gate) return tokens.Count; } }

        /// A new PIN and no paired phones: every phone has to pair again.
        public void Reset() { lock (gate) { tokens.Clear(); Pin = NewPin(); Save(); } }

        void Save()
        {
            Directory.CreateDirectory(dir);
            var sb = new StringBuilder("pin=" + Pin + "\r\n");
            foreach (var t in tokens) sb.Append("token=" + t + "\r\n");
            File.WriteAllText(Path.Combine(dir, "settings.txt"), sb.ToString());
        }
    }

    // ---------------------------------------------------------------- the icon beside the clock

    class TrayApp : ApplicationContext
    {
        readonly NotifyIcon icon = new NotifyIcon();
        readonly Store store = new Store();
        readonly Server server;
        readonly SynchronizationContext ui;
        InfoForm info;
        int phones;

        public TrayApp()
        {
            var host = new Control();
            host.CreateControl();
            ui = SynchronizationContext.Current ?? new WindowsFormsSynchronizationContext();
            server = new Server(store, ui);
            server.PhonesChanged += n => ui.Post(_ => { phones = n; Refresh(); }, null);
            icon.MouseClick += (s, e) => { if (e.Button == MouseButtons.Left) ShowInfo(); };
            icon.ContextMenuStrip = new ContextMenuStrip();
            icon.ContextMenuStrip.Opening += (s, e) => BuildMenu();
            Refresh();
            icon.Visible = true;
            try { server.Start(); }
            catch (Exception ex)
            {
                MessageBox.Show("WiFiTalk could not listen on port " + Program.Port + ":\n" + ex.Message,
                    "WiFiTalk", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            if (store.PhoneCount == 0) ShowInfo();
        }

        void Refresh()
        {
            var old = icon.Icon;
            icon.Icon = Art.TrayIcon(phones > 0);
            if (old != null) old.Dispose();
            string text = phones > 0 ? "WiFiTalk: iPhone connected"
                                     : "WiFiTalk: waiting for the iPhone";
            icon.Text = text.Length > 63 ? text.Substring(0, 63) : text;
            if (info != null && !info.IsDisposed) info.Fill(store, phones);
        }

        void BuildMenu()
        {
            var m = icon.ContextMenuStrip;
            m.Items.Clear();
            m.Items.Add("Address and PIN…", null, (s, e) => ShowInfo());
            var start = new ToolStripMenuItem("Start with Windows") { Checked = StartsWithWindows() };
            start.Click += (s, e) => SetStartWithWindows(!start.Checked);
            m.Items.Add(start);
            m.Items.Add("Unpair all phones (new PIN)", null, (s, e) =>
            {
                if (Ask("Unpair every phone and make a new PIN?"))
                { store.Reset(); server.DropAll(); Refresh(); ShowInfo(); }
            });
            m.Items.Add(new ToolStripSeparator());
            m.Items.Add("Close WiFiTalk", null, (s, e) =>
            {
                if (Ask("Close WiFiTalk?")) Quit();
            });
        }

        static bool Ask(string text)
        {
            return MessageBox.Show(text, "WiFiTalk", MessageBoxButtons.YesNo, MessageBoxIcon.Question,
                MessageBoxDefaultButton.Button2, MessageBoxOptions.DefaultDesktopOnly) == DialogResult.Yes;
        }

        void ShowInfo()
        {
            if (info == null || info.IsDisposed) info = new InfoForm();
            info.Fill(store, phones);
            info.Show();
            info.Activate();
        }

        const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

        static bool StartsWithWindows()
        {
            using (var k = Registry.CurrentUser.OpenSubKey(RunKey)) return k != null && k.GetValue("WiFiTalk") != null;
        }

        static void SetStartWithWindows(bool on)
        {
            using (var k = Registry.CurrentUser.CreateSubKey(RunKey))
            {
                if (on) k.SetValue("WiFiTalk", "\"" + Application.ExecutablePath + "\"");
                else k.DeleteValue("WiFiTalk", false);
            }
        }

        void Quit()
        {
            server.Stop();
            icon.Visible = false;
            icon.Dispose();
            ExitThread();
        }
    }

    /// The only window: the computer's address and the PIN to type on the phone.
    class InfoForm : Form
    {
        readonly Label body = new Label();

        public InfoForm()
        {
            Text = "WiFiTalk";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false; MinimizeBox = false;
            StartPosition = FormStartPosition.CenterScreen;
            AutoScaleMode = AutoScaleMode.Dpi;
            Font = new Font("Segoe UI", 11f);
            Padding = new Padding(16);
            AutoSize = true; AutoSizeMode = AutoSizeMode.GrowAndShrink;
            body.AutoSize = true;
            body.MaximumSize = new Size(520, 0);
            Controls.Add(body);
            Icon = Art.TrayIcon(false);
            FormClosing += (s, e) => { if (e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); } };
        }

        public void Fill(Store store, int phones)
        {
            var sb = new StringBuilder();
            sb.AppendLine("Open WiFiTalk on your iPhone (same Wi-Fi) and enter:");
            sb.AppendLine();
            sb.AppendLine("Address:  " + string.Join("   or   ", Net.Addresses()));
            sb.AppendLine("PIN:  " + store.Pin);
            sb.AppendLine();
            sb.AppendLine(phones > 0 ? "● iPhone connected"
                                     : "○ Waiting for the iPhone");
            sb.AppendLine("Paired phones: " + store.PhoneCount);
            body.Text = sb.ToString();
        }
    }

    static class Net
    {
        /// The computer's IPv4 addresses on networks that have a gateway (the Wi-Fi or Ethernet the phone shares).
        public static List<string> Addresses()
        {
            var list = new List<string>();
            foreach (var ni in NetworkInterface.GetAllNetworkInterfaces())
            {
                if (ni.OperationalStatus != OperationalStatus.Up || ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
                var props = ni.GetIPProperties();
                if (props.GatewayAddresses.Count == 0) continue;
                foreach (var a in props.UnicastAddresses)
                    if (a.Address.AddressFamily == AddressFamily.InterNetwork) list.Add(a.Address.ToString());
            }
            if (list.Count == 0) list.Add("127.0.0.1");
            return list;
        }

        /// Only phones on the local network may connect.
        public static bool IsLocal(IPAddress a)
        {
            if (IPAddress.IsLoopback(a)) return true;
            if (a.IsIPv4MappedToIPv6) a = a.MapToIPv4();
            var b = a.GetAddressBytes();
            if (b.Length != 4) return a.IsIPv6LinkLocal;
            return b[0] == 10 || (b[0] == 172 && b[1] >= 16 && b[1] <= 31) || (b[0] == 192 && b[1] == 168) || (b[0] == 169 && b[1] == 254);
        }
    }

    // ---------------------------------------------------------------- the server

    class Server
    {
        readonly Store store;
        readonly SynchronizationContext ui;
        TcpListener listener;
        readonly List<Session> sessions = new List<Session>();
        int failures;
        DateTime lockedUntil = DateTime.MinValue;
        public event Action<int> PhonesChanged;

        public Server(Store store, SynchronizationContext ui) { this.store = store; this.ui = ui; }

        public void Start()
        {
            listener = new TcpListener(IPAddress.Any, Program.Port);
            listener.Start();
            var t = new Thread(AcceptLoop) { IsBackground = true, Name = "accept" };
            t.Start();
        }

        public void Stop()
        {
            try { listener.Stop(); } catch { }
            DropAll();
        }

        public void DropAll()
        {
            Session[] all;
            lock (sessions) all = sessions.ToArray();
            foreach (var s in all) s.Close();
        }

        void AcceptLoop()
        {
            while (true)
            {
                TcpClient c;
                try { c = listener.AcceptTcpClient(); } catch { return; }
                var ep = (IPEndPoint)c.Client.RemoteEndPoint;
                if (!Net.IsLocal(ep.Address)) { c.Close(); continue; }
                var s = new Session(c, this);
                var t = new Thread(s.Run) { IsBackground = true, Name = "phone" };
                t.Start();
            }
        }

        /// Checks a hello; returns the token to keep, or null. Five wrong PINs lock pairing for a minute.
        public string Authorize(string pin, string token, out string error)
        {
            error = null;
            if (!string.IsNullOrEmpty(token))
            {
                if (store.HasToken(token)) return token;
                error = "unpaired";
                return null;
            }
            lock (this)
            {
                if (DateTime.UtcNow < lockedUntil) { error = "locked"; return null; }
                if (pin == store.Pin)
                {
                    failures = 0;
                    var t = Store.NewToken();
                    store.AddToken(t);
                    return t;
                }
                if (++failures >= 5) { failures = 0; lockedUntil = DateTime.UtcNow.AddMinutes(1); }
                error = "wrong_pin";
                return null;
            }
        }

        public void Joined(Session s) { int n; lock (sessions) { sessions.Add(s); n = sessions.Count; } Fire(n); }
        public void Left(Session s) { int n; lock (sessions) { sessions.Remove(s); n = sessions.Count; } Fire(n); }
        void Fire(int n) { var h = PhonesChanged; if (h != null) h(n); }

        /// Runs `f` on the window thread (the clipboard needs it) and returns its result.
        public object OnUI(Func<object> f)
        {
            object result = null; Exception err = null;
            ui.Send(_ => { try { result = f(); } catch (Exception e) { err = e; } }, null);
            if (err != null) throw err;
            return result;
        }
    }

    class Session
    {
        readonly TcpClient client;
        readonly NetworkStream stream;
        readonly Server server;
        readonly object writeGate = new object();
        readonly JavaScriptSerializer json = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
        bool authed;
        FileStream upload;
        string uploadPath;
        Loopback speaker;
        MicOut mic;

        public Session(TcpClient c, Server s)
        {
            client = c; server = s;
            client.NoDelay = true;
            stream = c.GetStream();
        }

        public void Close() { try { client.Close(); } catch { } }

        public void Run()
        {
            try
            {
                stream.ReadTimeout = 15000;   // the hello must come quickly
                while (true)
                {
                    int type; byte[] payload;
                    if (!ReadFrame(out type, out payload)) break;
                    if (type == 1) HandleJson(Encoding.UTF8.GetString(payload));
                    else if (type == 2 && authed && mic != null) mic.Write(payload);
                    else if (type == 4 && authed && upload != null) upload.Write(payload, 0, payload.Length);
                    if (authed) stream.ReadTimeout = Timeout.Infinite;
                }
            }
            catch { }
            finally
            {
                if (speaker != null) speaker.Stop();
                if (mic != null) mic.Dispose();
                if (upload != null) upload.Dispose();
                if (authed) server.Left(this);
                Close();
            }
        }

        bool ReadFrame(out int type, out byte[] payload)
        {
            type = 0; payload = null;
            var head = new byte[5];
            if (!ReadAll(head)) return false;
            type = head[0];
            int len = (head[1] << 24) | (head[2] << 16) | (head[3] << 8) | head[4];
            if (len < 0 || len > 16 * 1024 * 1024) return false;
            if (!authed && (type != 1 || len > 4096)) return false;
            payload = new byte[len];
            return ReadAll(payload);
        }

        bool ReadAll(byte[] buf)
        {
            int off = 0;
            while (off < buf.Length)
            {
                int n = stream.Read(buf, off, buf.Length - off);
                if (n <= 0) return false;
                off += n;
            }
            return true;
        }

        public void Send(int type, byte[] payload, int count)
        {
            var head = new byte[] { (byte)type, (byte)(count >> 24), (byte)(count >> 16), (byte)(count >> 8), (byte)count };
            lock (writeGate)
            {
                stream.Write(head, 0, 5);
                stream.Write(payload, 0, count);
            }
        }

        void SendJson(object o)
        {
            var b = Encoding.UTF8.GetBytes(json.Serialize(o));
            Send(1, b, b.Length);
        }

        void HandleJson(string text)
        {
            var msg = json.DeserializeObject(text) as Dictionary<string, object>;
            if (msg == null) return;
            if (!authed)
            {
                var hello = Get<Dictionary<string, object>>(msg, "hello");
                if (hello == null) { Close(); return; }
                string error;
                var token = server.Authorize(Str(hello, "pin"), Str(hello, "token"), out error);
                if (token == null)
                {
                    SendJson(new Dictionary<string, object> { { "error", error } });
                    Close();
                    return;
                }
                authed = true;
                server.Joined(this);
                SendJson(new Dictionary<string, object> {
                    { "welcome", new Dictionary<string, object> {
                        { "token", token }, { "name", Environment.MachineName }, { "mic", MicOut.Available() }, { "version", 1 } } } });
                return;
            }
            var actions = Get<object[]>(msg, "do");
            if (actions == null) return;
            object id = msg.ContainsKey("id") ? msg["id"] : null;
            var reply = new Dictionary<string, object> { { "done", id }, { "ok", true } };
            try
            {
                foreach (var a in actions)
                {
                    var d = a as Dictionary<string, object>;
                    if (d != null) Do(d, reply);
                }
            }
            catch (Exception ex)
            {
                reply["ok"] = false;
                reply["error"] = ex.Message;
            }
            // "q": true (mouse moves, many a second) asks for a reply only when something failed
            object quiet;
            if (msg.TryGetValue("q", out quiet) && quiet is bool && (bool)quiet && (bool)reply["ok"]) return;
            SendJson(reply);
        }

        /// One action. Everything the companion can do is in this switch.
        void Do(Dictionary<string, object> a, Dictionary<string, object> reply)
        {
            switch (Str(a, "t"))
            {
                case "text": Input.TypeText(Str(a, "s")); break;
                case "keys": Input.Combo(Str(a, "k")); break;
                case "move": Input.Move(Dbl(a, "dx"), Dbl(a, "dy")); break;
                case "click": Input.Click(Str(a, "b"), Math.Max(1, Int(a, "n"))); break;
                case "down": Input.Button(Str(a, "b"), true); break;
                case "up": Input.Button(Str(a, "b"), false); break;
                case "scroll": Input.Scroll(Dbl(a, "dx"), Dbl(a, "dy")); break;
                case "wait": Thread.Sleep(Math.Min(5000, Math.Max(0, Int(a, "ms")))); break;
                case "open": Opener.Open(Str(a, "s")); break;
                case "clip":
                    var s = Str(a, "s");
                    server.OnUI(() => { if (string.IsNullOrEmpty(s)) Clipboard.Clear(); else Clipboard.SetText(s); return null; });
                    break;
                case "getclip":
                    reply["clip"] = server.OnUI(() => Clipboard.ContainsText() ? Clipboard.GetText() : "");
                    break;
                case "power": Power(Str(a, "s")); break;
                case "speaker":
                    if (Bool(a, "on")) { if (speaker == null) { speaker = new Loopback(this); speaker.Start(); } }
                    else if (speaker != null) { speaker.Stop(); speaker = null; }
                    break;
                case "mic":
                    if (Bool(a, "on")) { if (mic == null) mic = MicOut.Open(); if (mic == null) throw new Exception("no_virtual_cable"); reply["device"] = mic.Name; }
                    else if (mic != null) { mic.Dispose(); mic = null; }
                    break;
                case "ls": reply["listing"] = Files.List(Str(a, "s")); break;
                case "get": Files.Send(Str(a, "s"), this); break;
                case "put":
                    if (upload != null) upload.Dispose();
                    string savedPath;
                    upload = Files.Create(Str(a, "s"), Str(a, "sub"), out savedPath);
                    uploadPath = savedPath;
                    break;
                case "putend":
                    if (upload == null) throw new Exception("no upload in progress");
                    long size = upload.Length;
                    upload.Dispose(); upload = null;
                    reply["file"] = new Dictionary<string, object> { { "name", Path.GetFileName(uploadPath) }, { "path", Files.Relative(uploadPath) }, { "size", size } };
                    break;
                case "ping": break;
                default: throw new Exception("unknown action: " + Str(a, "t"));
            }
        }

        static void Power(string what)
        {
            switch (what)
            {
                case "lock": Native.LockWorkStation(); break;
                case "sleep": Application.SetSuspendState(PowerState.Suspend, false, false); break;
                case "shutdown": Process.Start(new ProcessStartInfo("shutdown.exe", "/s /t 0") { CreateNoWindow = true, UseShellExecute = false }); break;
                case "restart": Process.Start(new ProcessStartInfo("shutdown.exe", "/r /t 0") { CreateNoWindow = true, UseShellExecute = false }); break;
                default: throw new Exception("unknown power action");
            }
        }

        static TV Get<TV>(Dictionary<string, object> d, string k) where TV : class
        {
            object v; return d.TryGetValue(k, out v) ? v as TV : null;
        }
        static string Str(Dictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v != null ? Convert.ToString(v, System.Globalization.CultureInfo.InvariantCulture) : "";
        }
        static int Int(Dictionary<string, object> d, string k)
        {
            object v; if (!d.TryGetValue(k, out v) || v == null) return 0;
            try { return (int)Math.Round(Convert.ToDouble(v, System.Globalization.CultureInfo.InvariantCulture)); } catch { return 0; }
        }
        static double Dbl(Dictionary<string, object> d, string k)
        {
            object v; if (!d.TryGetValue(k, out v) || v == null) return 0;
            try { return Convert.ToDouble(v, System.Globalization.CultureInfo.InvariantCulture); } catch { return 0; }
        }
        static bool Bool(Dictionary<string, object> d, string k)
        {
            object v; return d.TryGetValue(k, out v) && v is bool && (bool)v;
        }

        public void AnnounceSpeaker(int rate)
        {
            SendJson(new Dictionary<string, object> { { "speaker", new Dictionary<string, object> { { "rate", rate }, { "channels", 2 } } } });
        }
    }

    // ---------------------------------------------------------------- keyboard and mouse

    static class Input
    {
        const uint KEYEVENTF_KEYUP = 0x2, KEYEVENTF_UNICODE = 0x4, KEYEVENTF_EXTENDEDKEY = 0x1;
        const uint MOVE = 0x1, LDOWN = 0x2, LUP = 0x4, RDOWN = 0x8, RUP = 0x10, MDOWN = 0x20, MUP = 0x40, WHEEL = 0x800, HWHEEL = 0x1000;

        static readonly Dictionary<string, ushort> Keys = new Dictionary<string, ushort>(StringComparer.OrdinalIgnoreCase)
        {
            {"ctrl",0x11},{"control",0x11},{"shift",0x10},{"alt",0x12},{"win",0x5B},{"windows",0x5B},{"cmd",0x5B},
            {"enter",0x0D},{"return",0x0D},{"tab",0x09},{"esc",0x1B},{"escape",0x1B},{"space",0x20},
            {"backspace",0x08},{"delete",0x2E},{"del",0x2E},{"insert",0x2D},
            {"up",0x26},{"down",0x28},{"left",0x25},{"right",0x27},{"home",0x24},{"end",0x23},{"pageup",0x21},{"pagedown",0x22},
            {"printscreen",0x2C},{"capslock",0x14},{"menu",0x5D},
            {"volumeup",0xAF},{"volumedown",0xAE},{"mute",0xAD},{"playpause",0xB3},{"next",0xB0},{"previous",0xB1},{"prev",0xB1},{"stop",0xB2},
            {"plus",0xBB},{"minus",0xBD},{"comma",0xBC},{"period",0xBE}
        };

        static readonly HashSet<ushort> Extended = new HashSet<ushort> { 0x26, 0x28, 0x25, 0x27, 0x24, 0x23, 0x21, 0x22, 0x2E, 0x2D, 0x5B, 0x5D, 0x2C };

        static ushort Vk(string name)
        {
            ushort vk;
            if (Keys.TryGetValue(name, out vk)) return vk;
            if (name.Length >= 2 && (name[0] == 'f' || name[0] == 'F'))
            {
                int n; if (int.TryParse(name.Substring(1), out n) && n >= 1 && n <= 24) return (ushort)(0x70 + n - 1);
            }
            if (name.Length == 1)
            {
                char c = char.ToUpperInvariant(name[0]);
                if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) return c;
                short s = Native.VkKeyScan(name[0]);
                if (s != -1) return (ushort)(s & 0xFF);
            }
            throw new Exception("unknown key: " + name);
        }

        /// "ctrl+shift+t", "enter", "volumeup": holds the modifiers, taps the last key, releases in reverse.
        public static void Combo(string combo)
        {
            var parts = combo.Replace(" ", "").Split('+');
            var vks = new List<ushort>();
            foreach (var p in parts) if (p.Length > 0) vks.Add(Vk(p));
            if (combo.EndsWith("++")) vks.Add(Vk("plus"));
            var list = new List<Native.INPUT>();
            foreach (var vk in vks) list.Add(Key(vk, false));
            for (int i = vks.Count - 1; i >= 0; i--) list.Add(Key(vks[i], true));
            Send(list);
        }

        static Native.INPUT Key(ushort vk, bool up)
        {
            var i = new Native.INPUT { type = 1 };
            i.u.ki.wVk = vk;
            i.u.ki.dwFlags = (up ? KEYEVENTF_KEYUP : 0) | (Extended.Contains(vk) ? KEYEVENTF_EXTENDEDKEY : 0);
            return i;
        }

        /// Types any text, Arabic included, as Unicode characters; a new line is the Enter key.
        public static void TypeText(string text)
        {
            var list = new List<Native.INPUT>();
            foreach (char c in text.Replace("\r\n", "\n"))
            {
                if (c == '\n') { list.Add(Key(0x0D, false)); list.Add(Key(0x0D, true)); continue; }
                if (c == '\t') { list.Add(Key(0x09, false)); list.Add(Key(0x09, true)); continue; }
                foreach (var up in new[] { false, true })
                {
                    var i = new Native.INPUT { type = 1 };
                    i.u.ki.wScan = c;
                    i.u.ki.dwFlags = KEYEVENTF_UNICODE | (up ? KEYEVENTF_KEYUP : 0);
                    list.Add(i);
                }
                if (list.Count >= 200) { Send(list); list.Clear(); Thread.Sleep(2); }
            }
            Send(list);
        }

        static double restX, restY, restWheel, restHWheel;

        /// Moves by a fractional amount; what is under a pixel is carried to the next move.
        public static void Move(double dx, double dy)
        {
            restX += dx; restY += dy;
            int x = (int)Math.Truncate(restX), y = (int)Math.Truncate(restY);
            restX -= x; restY -= y;
            if (x != 0 || y != 0) Send(new List<Native.INPUT> { Mouse(MOVE, x, y, 0) });
        }

        public static void Click(string button, int times)
        {
            uint down, up; Flags(button, out down, out up);
            var list = new List<Native.INPUT>();
            for (int i = 0; i < Math.Min(times, 3); i++) { list.Add(Mouse(down, 0, 0, 0)); list.Add(Mouse(up, 0, 0, 0)); }
            Send(list);
        }

        public static void Button(string button, bool press)
        {
            uint down, up; Flags(button, out down, out up);
            Send(new List<Native.INPUT> { Mouse(press ? down : up, 0, 0, 0) });
        }

        /// Scrolls by wheel notches (fractions add up): positive dy scrolls up, positive dx right.
        public static void Scroll(double dx, double dy)
        {
            restWheel += dy; restHWheel += dx;
            int v = (int)Math.Truncate(restWheel), h = (int)Math.Truncate(restHWheel);
            restWheel -= v; restHWheel -= h;
            var list = new List<Native.INPUT>();
            if (v != 0) list.Add(Mouse(WHEEL, 0, 0, v * 120));
            if (h != 0) list.Add(Mouse(HWHEEL, 0, 0, h * 120));
            Send(list);
        }

        static void Flags(string button, out uint down, out uint up)
        {
            if (button == "right") { down = RDOWN; up = RUP; }
            else if (button == "middle") { down = MDOWN; up = MUP; }
            else { down = LDOWN; up = LUP; }
        }

        static Native.INPUT Mouse(uint flags, int dx, int dy, int data)
        {
            var i = new Native.INPUT { type = 0 };
            i.u.mi.dx = dx; i.u.mi.dy = dy; i.u.mi.dwFlags = flags; i.u.mi.mouseData = unchecked((uint)data);
            return i;
        }

        static void Send(List<Native.INPUT> list)
        {
            if (list.Count == 0) return;
            Native.SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf(typeof(Native.INPUT)));
        }
    }

    // ---------------------------------------------------------------- opening apps, files and links

    static class Opener
    {
        /// A link, a settings page, a known program name ("chrome", "notepad"), or the name of a Start menu entry.
        public static void Open(string what)
        {
            what = (what ?? "").Trim();
            if (what.Length == 0) throw new Exception("nothing to open");
            if (what.Contains("://") || what.StartsWith("ms-settings:") || what.StartsWith("mailto:"))
            {
                Shell(what);
                return;
            }
            if (what.StartsWith("www.")) { Shell("https://" + what); return; }
            var lnk = FindShortcut(what);
            if (lnk != null) { Shell(lnk); return; }
            Shell(what);   // App Paths: chrome, msedge, notepad, calc, winword, excel...
        }

        static void Shell(string target)
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true });
        }

        /// The Start menu entry whose name matches best: exact name first, then a name that starts with it.
        static string FindShortcut(string name)
        {
            string starts = null;
            foreach (var root in new[] {
                Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
                Environment.GetFolderPath(Environment.SpecialFolder.StartMenu) })
            {
                string[] files;
                try { files = Directory.GetFiles(root, "*.lnk", SearchOption.AllDirectories); } catch { continue; }
                foreach (var f in files)
                {
                    var n = Path.GetFileNameWithoutExtension(f);
                    if (n.Equals(name, StringComparison.OrdinalIgnoreCase)) return f;
                    if (starts == null && n.StartsWith(name, StringComparison.OrdinalIgnoreCase)
                        && n.IndexOf("uninstall", StringComparison.OrdinalIgnoreCase) < 0) starts = f;
                }
            }
            return starts;
        }
    }

    // ---------------------------------------------------------------- the shared folder

    /// One folder the phone can browse, fetch from and send to: Downloads\WiFiTalk. Every path from the phone
    /// is relative to it, and anything that would climb out of it is refused.
    static class Files
    {
        public static readonly string Root = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "WiFiTalk");

        static string Resolve(string relative)
        {
            Directory.CreateDirectory(Root);
            var full = Path.GetFullPath(Path.Combine(Root, (relative ?? "").Replace('/', '\\').TrimStart('\\')));
            var root = Path.GetFullPath(Root).TrimEnd('\\');
            if (!full.Equals(root, StringComparison.OrdinalIgnoreCase) && !full.StartsWith(root + "\\", StringComparison.OrdinalIgnoreCase))
                throw new Exception("outside the shared folder");
            return full;
        }

        public static string Relative(string full)
        {
            var root = Path.GetFullPath(Root).TrimEnd('\\');
            return full.Length <= root.Length ? "" : full.Substring(root.Length + 1).Replace('\\', '/');
        }

        static double Epoch(DateTime t) { return (t.ToUniversalTime() - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds; }

        public static Dictionary<string, object> List(string relative)
        {
            var dir = Resolve(relative);
            if (!Directory.Exists(dir)) throw new Exception("folder not found");
            var entries = new List<object>();
            foreach (var d in Directory.GetDirectories(dir))
                entries.Add(new Dictionary<string, object> { { "name", Path.GetFileName(d) }, { "path", Relative(d) }, { "is_dir", true }, { "size", 0 }, { "modified", Epoch(Directory.GetLastWriteTime(d)) } });
            foreach (var f in Directory.GetFiles(dir))
            {
                var info = new FileInfo(f);
                if ((info.Attributes & FileAttributes.Hidden) != 0) continue;
                entries.Add(new Dictionary<string, object> { { "name", info.Name }, { "path", Relative(f) }, { "is_dir", false }, { "size", info.Length }, { "modified", Epoch(info.LastWriteTime) } });
            }
            var rel = Relative(dir);
            object parent = null;
            if (rel.Length > 0) { int cut = rel.LastIndexOf('/'); parent = cut < 0 ? "" : rel.Substring(0, cut); }
            return new Dictionary<string, object> { { "root", "Downloads\\WiFiTalk" }, { "path", rel }, { "parent", parent }, { "entries", entries } };
        }

        /// Streams a file to the phone as type-4 frames; the action's reply follows the last one.
        public static void Send(string relative, Session session)
        {
            var path = Resolve(relative);
            using (var f = File.OpenRead(path))
            {
                var buf = new byte[256 * 1024];
                int n;
                while ((n = f.Read(buf, 0, buf.Length)) > 0) session.Send(4, buf, n);
            }
        }

        /// A new file for an upload, never overwriting: "name (2).ext" when the name is taken.
        public static FileStream Create(string name, string sub, out string path)
        {
            name = Path.GetFileName(name ?? "");
            if (name.Length == 0) name = "file";
            var dir = Resolve(sub);
            Directory.CreateDirectory(dir);
            path = Path.Combine(dir, name);
            var stem = Path.GetFileNameWithoutExtension(name);
            var ext = Path.GetExtension(name);
            for (int i = 2; File.Exists(path); i++) path = Path.Combine(dir, stem + " (" + i + ")" + ext);
            return new FileStream(path, FileMode.CreateNew, FileAccess.Write);
        }
    }

    // ---------------------------------------------------------------- computer sound to the phone (WASAPI loopback)

    class Loopback
    {
        readonly Session session;
        volatile bool running;
        Thread thread;

        public Loopback(Session s) { session = s; }

        public void Start()
        {
            running = true;
            thread = new Thread(Run) { IsBackground = true, Name = "speaker" };
            thread.Start();
        }

        public void Stop() { running = false; }

        void Run()
        {
            Wasapi.IAudioClient client = null;
            try
            {
                var enumerator = (Wasapi.IMMDeviceEnumerator)new Wasapi.MMDeviceEnumerator();
                Wasapi.IMMDevice device;
                Marshal.ThrowExceptionForHR(enumerator.GetDefaultAudioEndpoint(0 /*render*/, 1 /*multimedia*/, out device));
                object o;
                var iid = typeof(Wasapi.IAudioClient).GUID;
                Marshal.ThrowExceptionForHR(device.Activate(ref iid, 23, IntPtr.Zero, out o));
                client = (Wasapi.IAudioClient)o;
                IntPtr fmtPtr;
                Marshal.ThrowExceptionForHR(client.GetMixFormat(out fmtPtr));
                int channels = Marshal.ReadInt16(fmtPtr, 2);
                int rate = Marshal.ReadInt32(fmtPtr, 4);
                int bits = Marshal.ReadInt16(fmtPtr, 14);
                int tag = Marshal.ReadInt16(fmtPtr, 0) & 0xFFFF;
                bool isFloat = tag == 3 || (tag == 0xFFFE && bits == 32 && Marshal.ReadInt32(fmtPtr, 24) == 3);
                Marshal.ThrowExceptionForHR(client.Initialize(0, 0x00020000 /*loopback*/, 2000000, 0, fmtPtr, IntPtr.Zero));
                Marshal.FreeCoTaskMem(fmtPtr);
                object cap;
                var capIid = typeof(Wasapi.IAudioCaptureClient).GUID;
                Marshal.ThrowExceptionForHR(client.GetService(ref capIid, out cap));
                var capture = (Wasapi.IAudioCaptureClient)cap;
                // The phone always gets float32 stereo at 48 kHz; another mixer rate is resampled linearly.
                session.AnnounceSpeaker(48000);
                Marshal.ThrowExceptionForHR(client.Start());
                var outBuf = new byte[48000 / 10 * 8];
                int outLen = 0;
                int frameBytes = channels * bits / 8;
                double step = rate / 48000.0, pos = 0;
                float prevL = 0, prevR = 0;
                while (running)
                {
                    Thread.Sleep(10);
                    uint packet;
                    while (running && capture.GetNextPacketSize(out packet) == 0 && packet > 0)
                    {
                        IntPtr data; uint frames, flags; ulong p1, p2;
                        if (capture.GetBuffer(out data, out frames, out flags, out p1, out p2) != 0) break;
                        bool silent = (flags & 2) != 0;
                        // pos runs over [-1, frames): -1 is the last frame of the previous packet
                        while (pos < frames - 1 || (step == 1.0 && pos < frames))
                        {
                            int i0 = (int)Math.Floor(pos);
                            double t = pos - i0;
                            float l0, r0, l1, r1;
                            if (i0 < 0) { l0 = prevL; r0 = prevR; } else { Sample(data, i0, frameBytes, bits, channels, isFloat, silent, out l0, out r0); }
                            if (t > 0 && i0 + 1 < frames) Sample(data, i0 + 1, frameBytes, bits, channels, isFloat, silent, out l1, out r1);
                            else { l1 = l0; r1 = r0; }
                            float l = (float)(l0 + (l1 - l0) * t), r = (float)(r0 + (r1 - r0) * t);
                            if (outLen + 8 > outBuf.Length) { session.Send(3, outBuf, outLen); outLen = 0; }
                            Buffer.BlockCopy(BitConverter.GetBytes(l), 0, outBuf, outLen, 4);
                            Buffer.BlockCopy(BitConverter.GetBytes(r), 0, outBuf, outLen + 4, 4);
                            outLen += 8;
                            pos += step;
                        }
                        if (frames > 0) Sample(data, (int)frames - 1, frameBytes, bits, channels, isFloat, silent, out prevL, out prevR);
                        pos -= frames;
                        capture.ReleaseBuffer(frames);
                        if (outLen >= 48000 / 50 * 8) { session.Send(3, outBuf, outLen); outLen = 0; }   // every ~20 ms
                    }
                }
                client.Stop();
            }
            catch { running = false; }
            finally { if (client != null) Marshal.ReleaseComObject(client); }
        }

        /// One frame of the mixer as two floats (left, right); a mono mixer feeds both.
        static void Sample(IntPtr data, int frame, int frameBytes, int bits, int channels, bool isFloat, bool silent, out float l, out float r)
        {
            l = r = 0;
            if (silent) return;
            l = Read(data, frame * frameBytes, bits, isFloat);
            r = channels > 1 ? Read(data, frame * frameBytes + bits / 8, bits, isFloat) : l;
        }

        static float Read(IntPtr data, int off, int bits, bool isFloat)
        {
            if (isFloat) return BitConverter.ToSingle(BitConverter.GetBytes(Marshal.ReadInt32(data, off)), 0);
            if (bits == 16) return Marshal.ReadInt16(data, off) / 32768f;
            if (bits == 32) return Marshal.ReadInt32(data, off) / 2147483648f;
            return 0;
        }
    }

    static class Wasapi
    {
        [ComImport, Guid("BCDE0395-E52F-467C-8E3D-C4579291692E")]
        public class MMDeviceEnumerator { }

        [ComImport, Guid("A95664D2-9614-4F35-A746-DE8DB63617E6"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IMMDeviceEnumerator
        {
            [PreserveSig] int EnumAudioEndpoints(int dataFlow, int stateMask, out IntPtr devices);
            [PreserveSig] int GetDefaultAudioEndpoint(int dataFlow, int role, out IMMDevice device);
        }

        [ComImport, Guid("D666063F-1587-4E43-81F1-B948E807363F"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IMMDevice
        {
            [PreserveSig] int Activate(ref Guid iid, int clsCtx, IntPtr activationParams, [MarshalAs(UnmanagedType.IUnknown)] out object iface);
        }

        [ComImport, Guid("1CB9AD4C-DBFA-4c32-B178-C2F568A703B2"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IAudioClient
        {
            [PreserveSig] int Initialize(int shareMode, int streamFlags, long bufferDuration, long periodicity, IntPtr format, IntPtr sessionGuid);
            [PreserveSig] int GetBufferSize(out uint frames);
            [PreserveSig] int GetStreamLatency(out long latency);
            [PreserveSig] int GetCurrentPadding(out uint padding);
            [PreserveSig] int IsFormatSupported(int shareMode, IntPtr format, out IntPtr closest);
            [PreserveSig] int GetMixFormat(out IntPtr format);
            [PreserveSig] int GetDevicePeriod(out long defaultPeriod, out long minimumPeriod);
            [PreserveSig] int Start();
            [PreserveSig] int Stop();
            [PreserveSig] int Reset();
            [PreserveSig] int SetEventHandle(IntPtr handle);
            [PreserveSig] int GetService(ref Guid iid, [MarshalAs(UnmanagedType.IUnknown)] out object service);
        }

        [ComImport, Guid("C8ADBD64-E71E-48a0-A4DE-185C395CD317"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        public interface IAudioCaptureClient
        {
            [PreserveSig] int GetBuffer(out IntPtr data, out uint frames, out uint flags, out ulong devicePosition, out ulong qpcPosition);
            [PreserveSig] int ReleaseBuffer(uint frames);
            [PreserveSig] int GetNextPacketSize(out uint frames);
        }
    }

    // ---------------------------------------------------------------- the phone as the computer's microphone

    /// Plays the phone's microphone into a virtual audio cable ("CABLE Input", VB-Audio), whose other end
    /// ("CABLE Output") then works as a microphone in every Windows app. Without the cable the feature is off.
    class MicOut : IDisposable
    {
        IntPtr handle;
        public string Name = "";
        readonly List<IntPtr> pending = new List<IntPtr>();
        static readonly int FlagsOffset = (int)Marshal.OffsetOf(typeof(Native.WAVEHDR), "dwFlags");

        static int FindCable()
        {
            int n = Native.waveOutGetNumDevs();
            for (int i = 0; i < n; i++)
            {
                var caps = new Native.WAVEOUTCAPS();
                if (Native.waveOutGetDevCaps(new IntPtr(i), ref caps, Marshal.SizeOf(typeof(Native.WAVEOUTCAPS))) == 0
                    && caps.szPname != null && caps.szPname.IndexOf("CABLE Input", StringComparison.OrdinalIgnoreCase) >= 0) return i;
            }
            return -1;
        }

        public static bool Available() { return FindCable() >= 0; }

        public static MicOut Open()
        {
            int dev = FindCable();
            if (dev < 0) return null;
            var fmt = new Native.WAVEFORMATEX { wFormatTag = 3, nChannels = 1, nSamplesPerSec = 48000, wBitsPerSample = 32, nBlockAlign = 4, nAvgBytesPerSec = 192000 };
            var m = new MicOut();
            if (Native.waveOutOpen(out m.handle, new IntPtr(dev), ref fmt, IntPtr.Zero, IntPtr.Zero, 0) != 0) return null;
            var caps = new Native.WAVEOUTCAPS();
            Native.waveOutGetDevCaps(new IntPtr(dev), ref caps, Marshal.SizeOf(typeof(Native.WAVEOUTCAPS)));
            m.Name = caps.szPname ?? "CABLE Input";
            return m;
        }

        public void Write(byte[] pcm)
        {
            lock (pending)
            {
                Reap(false);
                if (pending.Count > 40) return;   // more than ~half a second behind: drop rather than lag
                var data = Marshal.AllocHGlobal(pcm.Length);
                Marshal.Copy(pcm, 0, data, pcm.Length);
                var hdr = new Native.WAVEHDR { lpData = data, dwBufferLength = (uint)pcm.Length };
                var p = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(Native.WAVEHDR)));
                Marshal.StructureToPtr(hdr, p, false);
                int size = Marshal.SizeOf(typeof(Native.WAVEHDR));
                Native.waveOutPrepareHeader(handle, p, size);
                Native.waveOutWrite(handle, p, size);
                pending.Add(p);
            }
        }

        void Reap(bool all)
        {
            int size = Marshal.SizeOf(typeof(Native.WAVEHDR));
            for (int i = pending.Count - 1; i >= 0; i--)
            {
                var p = pending[i];
                if (!all && (Marshal.ReadInt32(p, FlagsOffset) & 1) == 0) continue;   // WHDR_DONE
                Native.waveOutUnprepareHeader(handle, p, size);
                Marshal.FreeHGlobal(Marshal.ReadIntPtr(p, 0));
                Marshal.FreeHGlobal(p);
                pending.RemoveAt(i);
            }
        }

        public void Dispose()
        {
            lock (pending)
            {
                if (handle == IntPtr.Zero) return;
                Native.waveOutReset(handle);
                Reap(true);
                Native.waveOutClose(handle);
                handle = IntPtr.Zero;
            }
        }
    }

    // ---------------------------------------------------------------- Windows API

    static class Native
    {
        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT { public int dx; public int dy; public uint mouseData; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT { public ushort wVk; public ushort wScan; public uint dwFlags; public uint time; public IntPtr dwExtraInfo; }
        [StructLayout(LayoutKind.Explicit)]
        public struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT { public uint type; public InputUnion u; }

        [DllImport("user32.dll", SetLastError = true)] public static extern uint SendInput(uint n, INPUT[] inputs, int size);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern short VkKeyScan(char c);
        [DllImport("user32.dll")] public static extern bool LockWorkStation();
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr h);

        [StructLayout(LayoutKind.Sequential)]
        public struct WAVEFORMATEX { public ushort wFormatTag; public ushort nChannels; public uint nSamplesPerSec; public uint nAvgBytesPerSec; public ushort nBlockAlign; public ushort wBitsPerSample; public ushort cbSize; }
        [StructLayout(LayoutKind.Sequential)]
        public struct WAVEHDR { public IntPtr lpData; public uint dwBufferLength; public uint dwBytesRecorded; public IntPtr dwUser; public uint dwFlags; public uint dwLoops; public IntPtr lpNext; public IntPtr reserved; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        public struct WAVEOUTCAPS { public ushort wMid; public ushort wPid; public uint vDriverVersion; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szPname; public uint dwFormats; public ushort wChannels; public ushort wReserved1; public uint dwSupport; }

        [DllImport("winmm.dll")] public static extern int waveOutGetNumDevs();
        [DllImport("winmm.dll", CharSet = CharSet.Unicode)] public static extern int waveOutGetDevCaps(IntPtr id, ref WAVEOUTCAPS caps, int size);
        [DllImport("winmm.dll")] public static extern int waveOutOpen(out IntPtr h, IntPtr id, ref WAVEFORMATEX fmt, IntPtr cb, IntPtr inst, int flags);
        [DllImport("winmm.dll")] public static extern int waveOutPrepareHeader(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll")] public static extern int waveOutUnprepareHeader(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll")] public static extern int waveOutWrite(IntPtr h, IntPtr hdr, int size);
        [DllImport("winmm.dll")] public static extern int waveOutReset(IntPtr h);
        [DllImport("winmm.dll")] public static extern int waveOutClose(IntPtr h);
    }

    // ---------------------------------------------------------------- the icon beside the clock

    static class Art
    {
        /// WiFi Talk's white tray icon (embedded), at the size Windows shows (48 px on a 300% screen: the manifest
        /// declares DPI awareness), with a green dot while the iPhone is connected.
        public static Icon TrayIcon(bool connected)
        {
            int size = Math.Max(16, SystemInformation.SmallIconSize.Width);
            using (var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("WiFiTalk.tray.ico"))
            using (var source = new Icon(stream, size, size))
            using (var bmp = new Bitmap(size, size, PixelFormat.Format32bppArgb))
            {
                using (var g = Graphics.FromImage(bmp))
                {
                    g.SmoothingMode = SmoothingMode.AntiAlias;
                    g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                    g.Clear(Color.Transparent);
                    g.DrawIcon(source, new Rectangle(0, 0, size, size));
                    if (connected)
                    {
                        float d = size * 0.34f;
                        using (var ring = new SolidBrush(Color.FromArgb(32, 32, 32))) g.FillEllipse(ring, size - d - size * 0.04f, size - d - size * 0.04f, d + size * 0.08f, d + size * 0.08f);
                        using (var b = new SolidBrush(Color.FromArgb(52, 199, 89))) g.FillEllipse(b, size - d, size - d, d, d);
                    }
                }
                var h = bmp.GetHicon();
                var icon = (Icon)Icon.FromHandle(h).Clone();
                Native.DestroyIcon(h);
                return icon;
            }
        }
    }
}