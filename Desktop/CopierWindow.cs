using System;
using System.IO;
using System.Text;
using System.Linq;
using System.Collections.Generic;
using System.Globalization;
using System.Drawing;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace LocalCopier
{
    internal static class Wire
    {
        [DllImport("kernel32.dll")] internal static extern ulong GetTickCount64();
        internal static readonly CultureInfo Inv = CultureInfo.InvariantCulture;
        internal static uint Hash(string text)
        {
            uint h = 2166136261;
            unchecked { foreach (char c in text) h = (h ^ c) * 16777619; }
            return h;
        }
        internal static bool Fresh(ulong now, ulong tick)
        { return tick > 0 && now >= tick && now - tick <= 2000; }
        internal static string Packet(string line)
        { return line + "\r\nEND\t" + Hash(line + "\n").ToString(Inv) + "\r\n"; }
        internal static string[] Parse(string text, string kind, int fields)
        {
            if (text.Length > 16384) return null;
            string[] lines = text.Replace("\r\n", "\n").Split('\n');
            if (lines.Length != 3 || lines[2] != "") return null;
            string[] data = lines[0].Split('\t'), end = lines[1].Split('\t');
            uint hash;
            if (data.Length != fields || data[0] != kind || end.Length != 2 || end[0] != "END" ||
                !uint.TryParse(end[1], out hash) || hash != Hash(lines[0] + "\n")) return null;
            return data;
        }
        internal static void Write(string path, string text)
        {
            // Same exclusive open policy as the EA: an incomplete packet is never usable.
            using (FileStream f = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.None))
            using (StreamWriter writer = new StreamWriter(f, new UTF8Encoding(false)))
            { writer.Write(text); writer.Flush(); f.Flush(true); }
        }
        internal static string Read(string path)
        {
            using (FileStream f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None))
            {
                if (f.Length > 16384) throw new IOException("Packet too large");
                using (StreamReader r = new StreamReader(f, Encoding.UTF8, true)) return r.ReadToEnd();
            }
        }
        internal static decimal Lots(decimal source, int mode, int operation, decimal factor,
                                      decimal fixedLots, int rounding, decimal baseline)
        {
            if (source <= 0 || factor <= 0 || fixedLots <= 0 || baseline <= 0) throw new ArgumentException();
            decimal raw = mode == 0 ? source : mode == 2 ? fixedLots * source / baseline :
                          operation == 0 ? source * factor : source / factor;
            return mode == 0 ? raw : rounding == 1 ? Math.Round(raw, 2, MidpointRounding.AwayFromZero) :
                   Math.Floor(raw * 100) / 100;
        }
        internal static bool SamePath(string a, string b)
        {
            try { return string.Equals(Path.GetFullPath(a).TrimEnd('\\'), Path.GetFullPath(b).TrimEnd('\\'), StringComparison.OrdinalIgnoreCase); }
            catch { return false; }
        }
    }
    internal sealed class Peer
    {
        internal ulong Tick;
        internal long Login;
        internal string Server, Path, Code, Message;
        internal bool Enabled, Allowed;
        internal int Pending;
        internal static Peer Read(string file)
        {
            try
            {
                string[] x = Wire.Parse(Wire.Read(file), "LTCSTATUS2", 10);
                if (x == null) return null;
                Peer p = new Peer();
                if (!ulong.TryParse(x[1], out p.Tick) || !Wire.Fresh(Wire.GetTickCount64(), p.Tick) ||
                    !long.TryParse(x[2], out p.Login) || p.Login <= 0 ||
                    !int.TryParse(x[6], out p.Pending) || p.Pending < 0 ||
                    (x[5] != "0" && x[5] != "1") || (x[9] != "0" && x[9] != "1")) return null;
                p.Server = x[3]; p.Path = x[4]; p.Enabled = x[5] == "1"; p.Pending = int.Parse(x[6]);
                p.Code = x[7]; p.Message = x[8]; p.Allowed = x[9] == "1";
                return p;
            }
            catch (IOException) { return null; }
            catch (UnauthorizedAccessException) { return null; }
        }
    }
    internal sealed class TerminalFolder
    {
        internal string Path, Caption;
        public override string ToString() { return Caption; }
    }
    internal static class Installer
    {
        internal static void Install(string root, bool source)
        {
            if (!Directory.Exists(System.IO.Path.Combine(root, "MQL5")))
                throw new IOException("请选择 MT5 的数据目录（里面有 MQL5 文件夹）。");
            string target = System.IO.Path.Combine(root, "MQL5", "Experts", "LocalCopier");
            string[] names = { source ? "CopierSource.ex5" : "CopierReceiver.ex5",
                               source ? "CopierSource.mq5" : "CopierReceiver.mq5", "CopyCore.mqh", "CopyProtocol.mqh", "CopyDesktop.mqh" };
            Assembly assembly = Assembly.GetExecutingAssembly();
            foreach (string name in names)
                using (Stream resource = assembly.GetManifestResourceStream("EA." + name))
                    if (resource == null) throw new IOException("缺少内置文件：" + name);
            if (Directory.Exists(target))
            {
                string backup = target + ".backup." + DateTime.Now.ToString("yyyyMMdd-HHmmss-fff");
                Directory.CreateDirectory(backup);
                foreach (string name in names)
                {
                    string existing = System.IO.Path.Combine(target, name);
                    if (File.Exists(existing)) File.Copy(existing, System.IO.Path.Combine(backup, name));
                }
            }
            Directory.CreateDirectory(target);
            foreach (string name in names)
                using (Stream resource = assembly.GetManifestResourceStream("EA." + name))
                using (FileStream file = File.Create(System.IO.Path.Combine(target, name))) resource.CopyTo(file);
        }
    }
    internal sealed class CopierForm : Form
    {
        readonly string common, settings;
        readonly FileStream ownership;
        readonly ComboBox source = new ComboBox(), receiver = new ComboBox(), operation = new ComboBox();
        readonly Button sourceBrowse = new Button(), receiverBrowse = new Button(), sourceCopy = new Button(), receiverCopy = new Button(), toggle = new Button();
        readonly RadioButton exact = new RadioButton(), convert = new RadioButton(), fixedMode = new RadioButton(), truncate = new RadioButton(), halfUp = new RadioButton();
        readonly NumericUpDown factor = new NumericUpDown(), fixedLots = new NumericUpDown();
        readonly Label sourceInfo = new Label(), receiverInfo = new Label(), example = new Label(), status = new Label();
        readonly ToolTip tips = new ToolTip();
        readonly System.Windows.Forms.Timer timer = new System.Windows.Forms.Timer();
        Peer sourcePeer, receiverPeer, boundSource, boundReceiver;
        bool running, pulseFailed;
        int failures;
        internal CopierForm() : this(null) { }
        // Test harness uses a completely separate filesystem, never live EA files.
        internal CopierForm(string isolatedRoot)
        {
            common = isolatedRoot == null ? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MetaQuotes", "Terminal", "Common", "Files", "LocalCopier") : System.IO.Path.Combine(isolatedRoot, "Files");
            settings = isolatedRoot == null ? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "MT5LocalCopier", "window.settings") : System.IO.Path.Combine(isolatedRoot, "window.settings");
            Directory.CreateDirectory(common);
            try { ownership = new FileStream(System.IO.Path.Combine(common, "pair1.desktop.lock"), FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
            catch (IOException) { throw new IOException("复制器窗口已打开。"); }
            Text = "MT5 交易复制器";
            Font = new Font("Microsoft YaHei UI", 9F);
            AutoScaleMode = AutoScaleMode.Dpi;
            ClientSize = new Size(600, 398);
            FormBorderStyle = FormBorderStyle.FixedSingle;
            MaximizeBox = false; StartPosition = FormStartPosition.CenterScreen;
            BackColor = Color.FromArgb(248, 249, 251);
            AddLabel("源端 MT5", 20, 23, 65, 24);
            AddLabel("接收 MT5", 20, 90, 65, 24);
            SetupPath(source, sourceBrowse, sourceCopy, 20, true);
            SetupPath(receiver, receiverBrowse, receiverCopy, 87, false);
            Place(sourceInfo, 87, 51, 490, 23); Place(receiverInfo, 87, 118, 490, 23);
            sourceInfo.ForeColor = receiverInfo.ForeColor = Color.DimGray;
            Panel modes = new Panel(); Place(modes, 20, 151, 560, 30);
            Radio(modes, exact, "完全同步", 0, 0, 125);
            Radio(modes, convert, "手数换算", 150, 0, 125);
            Radio(modes, fixedMode, "固定手数", 366, 0, 125);
            exact.Checked = true;
            operation.DropDownStyle = ComboBoxStyle.DropDownList;
            operation.Items.AddRange(new object[] { "乘以 ×", "除以 ÷" }); operation.SelectedIndex = 0;
            Place(operation, 170, 188, 82, 28);
            Number(factor, 1, 0.000001M, 1000000, 6, 260, 188, 105);
            Number(fixedLots, 0.01M, 0.01M, 1000000, 2, 386, 188, 105);
            AddLabel("手", 496, 191, 30, 24);
            AddLabel("小数处理", 20, 231, 90, 24);
            Panel rounds = new Panel(); Place(rounds, 122, 227, 440, 30);
            Radio(rounds, halfUp, "四舍五入", 0, 0, 130);
            Radio(rounds, truncate, "直接舍去", 160, 0, 130); truncate.Checked = true;
            Place(example, 20, 265, 560, 24); example.ForeColor = Color.DimGray;
            Place(toggle, 20, 296, 560, 42); toggle.Text = "启动"; toggle.FlatStyle = FlatStyle.Flat;
            toggle.BackColor = Color.FromArgb(36, 103, 209); toggle.ForeColor = Color.White;
            toggle.Font = new Font(Font.FontFamily, 11F, FontStyle.Bold);
            Place(status, 20, 345, 560, 23);
            Label hint = AddLabel("首次使用：两端各挂载一次对应 EA，并开启“算法交易”。", 20, 372, 560, 22);
            hint.ForeColor = Color.DimGray; hint.Font = new Font(Font.FontFamily, 8F);
            tips.SetToolTip(toggle, "停止会撤销复制入场挂单，保留已持仓。关闭窗口也会停止。");
            if (isolatedRoot == null) { Discover(); LoadSettings(); }
            else
            {
                Text += " · 隔离测试";
                SelectPath(source, System.IO.Path.Combine(isolatedRoot, "Source"));
                SelectPath(receiver, System.IO.Path.Combine(isolatedRoot, "Receiver"));
            }
            exact.CheckedChanged += Changed; convert.CheckedChanged += Changed; fixedMode.CheckedChanged += Changed;
            halfUp.CheckedChanged += Changed; truncate.CheckedChanged += Changed;
            factor.ValueChanged += Changed; fixedLots.ValueChanged += Changed; operation.SelectedIndexChanged += Changed;
            toggle.Click += Toggle;
            FormClosing += ClosingWindow;
            UpdateInputs(); RefreshPeers();
            timer.Interval = 350; timer.Tick += Pulse; timer.Start();
        }
        Label AddLabel(string text, int x, int y, int width, int height)
        { Label l = new Label(); l.Text = text; Place(l, x, y, width, height); return l; }
        void Place(Control c, int x, int y, int width, int height)
        { c.SetBounds(x, y, width, height); Controls.Add(c); }
        void Radio(Panel p, RadioButton r, string text, int x, int y, int width)
        { r.Text = text; r.SetBounds(x, y, width, 28); p.Controls.Add(r); }
        void Number(NumericUpDown n, decimal value, decimal min, decimal max, int decimals, int x, int y, int width)
        { n.DecimalPlaces = decimals; n.Minimum = min; n.Maximum = max; n.Value = value; n.Increment = decimals == 2 ? 0.01M : 0.1M; Place(n, x, y, width, 28); }
        void SetupPath(ComboBox box, Button browse, Button copy, int y, bool isSource)
        {
            box.DropDownStyle = ComboBoxStyle.DropDownList; Place(box, 87, y, 280, 28);
            browse.Text = "选择…"; Place(browse, 375, y - 1, 66, 30);
            copy.Text = isSource ? "复制到源端" : "复制到接收端"; Place(copy, 449, y - 1, 131, 30);
            browse.Click += delegate { Browse(box); };
            copy.Click += delegate { Copy(box, isSource); };
            box.SelectedIndexChanged += delegate { SaveSettings(); RefreshPeers(); };
        }
        string Selected(ComboBox box)
        { TerminalFolder item = box.SelectedItem as TerminalFolder; return item == null ? "" : item.Path; }
        void Discover()
        {
            string root = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "MetaQuotes", "Terminal");
            if (!Directory.Exists(root)) return;
            foreach (string dir in Directory.GetDirectories(root))
            {
                if (!Directory.Exists(System.IO.Path.Combine(dir, "MQL5"))) continue;
                string caption = System.IO.Path.GetFileName(dir);
                try { string origin = System.IO.Path.Combine(dir, "origin.txt"); if (File.Exists(origin)) caption = File.ReadAllText(origin).Trim().Trim('\0') + "  [" + caption.Substring(0, Math.Min(6, caption.Length)) + "]"; } catch (IOException) { }
                AddPath(source, dir, caption); AddPath(receiver, dir, caption);
            }
        }
        void AddPath(ComboBox box, string path, string caption)
        {
            foreach (TerminalFolder existing in box.Items) if (Wire.SamePath(existing.Path, path)) return;
            box.Items.Add(new TerminalFolder { Path = System.IO.Path.GetFullPath(path).TrimEnd('\\'), Caption = caption });
        }
        void SelectPath(ComboBox box, string path)
        {
            if (path.Length == 0) return;
            AddPath(box, path, path);
            foreach (TerminalFolder item in box.Items) if (Wire.SamePath(item.Path, path)) { box.SelectedItem = item; return; }
        }
        void Browse(ComboBox box)
        {
            using (FolderBrowserDialog d = new FolderBrowserDialog())
            {
                d.Description = "在 MT5 点“文件 → 打开数据文件夹”，选择该目录（里面有 MQL5）。";
                d.SelectedPath = Selected(box);
                if (d.ShowDialog(this) != DialogResult.OK) return;
                if (!Directory.Exists(System.IO.Path.Combine(d.SelectedPath, "MQL5"))) { MessageBox.Show(this, "请选择包含 MQL5 文件夹的 MT5 数据目录。", Text); return; }
                SelectPath(box, d.SelectedPath);
            }
        }
        void Copy(ComboBox box, bool isSource)
        {
            try
            {
                if (Selected(box) == "") throw new IOException("请先选择 MT5 数据目录。");
                if (Wire.SamePath(Selected(source), Selected(receiver))) throw new IOException("源端和接收端请选择不同的 MT5。");
                Installer.Install(Selected(box), isSource);
                MessageBox.Show(this, "已复制。\nMT5 导航器刷新后，把 " + (isSource ? "CopierSource" : "CopierReceiver") + " 挂到独立图表，开启算法交易。", Text);
            }
            catch (Exception e) { MessageBox.Show(this, e.Message, Text); }
        }
        void Changed(object sender, EventArgs args) { UpdateInputs(); SaveSettings(); }
        int Mode { get { return exact.Checked ? 0 : convert.Checked ? 1 : 2; } }
        int Rounding { get { return halfUp.Checked ? 1 : 0; } }
        void UpdateInputs()
        {
            source.Enabled = receiver.Enabled = sourceBrowse.Enabled = receiverBrowse.Enabled = sourceCopy.Enabled = receiverCopy.Enabled = !running;
            exact.Enabled = convert.Enabled = fixedMode.Enabled = !running;
            operation.Enabled = factor.Enabled = !running && convert.Checked;
            fixedLots.Enabled = !running && fixedMode.Checked;
            halfUp.Enabled = truncate.Enabled = !running && !exact.Checked;
            decimal lots = Wire.Lots(0.32M, Mode, operation.SelectedIndex, factor.Value, fixedLots.Value, Rounding, 0.32M);
            example.Text = "示例：源端 0.32 手  →  接收端 " + lots.ToString("0.00", Wire.Inv) + " 手" + (lots < .01M ? "（不足 0.01，不开仓）" : "");
        }
        Peer ReadPeer(string role, string selected, Peer previous)
        {
            Peer next = Peer.Read(System.IO.Path.Combine(common, "pair1." + role + ".status"));
            if (next != null && Wire.SamePath(next.Path, selected)) return next;
            return previous != null && Wire.SamePath(previous.Path, selected) && Wire.Fresh(Wire.GetTickCount64(), previous.Tick) ? previous : null;
        }
        void RefreshPeers()
        {
            sourcePeer = ReadPeer("source", Selected(source), sourcePeer);
            receiverPeer = ReadPeer("receiver", Selected(receiver), receiverPeer);
            sourceInfo.Text = sourcePeer == null ? "等待源端 EA" : sourcePeer.Login + " · " + sourcePeer.Server + (sourcePeer.Code == "ready" ? " · 已连接" : " · 等待连接");
            receiverInfo.Text = receiverPeer == null ? "等待接收端 EA" : receiverPeer.Login + " · " + receiverPeer.Server + (receiverPeer.Allowed ? " · 已连接" : " · 请检查算法交易 / 连接");
            tips.SetToolTip(source, Selected(source)); tips.SetToolTip(receiver, Selected(receiver));
            tips.SetToolTip(status, receiverPeer == null ? "" : receiverPeer.Message);
            if (pulseFailed) status.Text = "控制文件写入失败，已停止；请检查目录权限。";
            else if (receiverPeer != null && receiverPeer.Code == "halted") status.Text = "已暂停：成交回报不明确，请检查 MT5 EA 日志。";
            else if (!running) status.Text = receiverPeer != null && receiverPeer.Pending > 0 ? "停止中：正在撤销复制挂单…" : "已停止";
            else if (receiverPeer == null || sourcePeer == null) status.Text = "等待终端恢复连接…";
            else if (!receiverPeer.Allowed) status.Text = "等待接收端连接 / 算法交易…";
            else if (receiverPeer.Enabled && receiverPeer.Code == "ready") status.Text = "运行中 · 已同步";
            else status.Text = "运行中 · 等待同步（详情见 MT5 EA 日志）";
        }
        string ControlPacket()
        {
            string[] x = { "LTCCTRL2", Wire.GetTickCount64().ToString(Wire.Inv), running ? "1" : "0",
                boundSource == null ? "0" : boundSource.Login.ToString(Wire.Inv), boundSource == null ? "-" : boundSource.Server,
                boundReceiver == null ? "0" : boundReceiver.Login.ToString(Wire.Inv), boundReceiver == null ? "-" : boundReceiver.Server,
                Mode.ToString(Wire.Inv), operation.SelectedIndex.ToString(Wire.Inv), factor.Value.ToString(Wire.Inv),
                fixedLots.Value.ToString(Wire.Inv), Rounding.ToString(Wire.Inv), boundSource == null ? "-" : boundSource.Path,
                boundReceiver == null ? "-" : boundReceiver.Path };
            foreach (string value in x) if (value.IndexOfAny(new char[] { '\t', '\r', '\n' }) >= 0) throw new IOException("目录或服务器名包含不支持的字符。");
            return Wire.Packet(string.Join("\t", x));
        }
        bool WriteControl()
        {
            try { Wire.Write(System.IO.Path.Combine(common, "pair1.control"), ControlPacket()); failures = 0; return true; }
            catch (IOException) { return false; }
            catch (UnauthorizedAccessException) { return false; }
        }
        void Pulse(object sender, EventArgs args)
        {
            if (!WriteControl() && ++failures >= 3)
            { running = false; pulseFailed = true; toggle.Text = "启动"; UpdateInputs(); }
            RefreshPeers();
        }
        void Toggle(object sender, EventArgs args)
        {
            if (running)
            { running = false; WriteControl(); toggle.Text = "启动"; UpdateInputs(); RefreshPeers(); return; }
            RefreshPeers();
            string error = null;
            if (sourcePeer == null || sourcePeer.Code != "ready") error = "请先在源端 MT5 挂载 CopierSource，并等待连接。";
            else if (receiverPeer == null || receiverPeer.Code == "offline") error = "请先在接收 MT5 挂载 CopierReceiver。";
            else if (receiverPeer.Code == "manual") error = "请在接收 EA 参数中设置 DesktopControl=true，让窗口控制启动和停止。";
            else if (!receiverPeer.Allowed) error = "请检查接收 MT5 的连接和“算法交易”开关。";
            else if (sourcePeer.Login == receiverPeer.Login && sourcePeer.Server == receiverPeer.Server) error = "源端和接收端不能是同一账户。";
            else if (receiverPeer.Code == "halted") error = "接收端已暂停，请先检查 MT5 EA 日志与成交记录。";
            if (error != null) { MessageBox.Show(this, error, Text); return; }
            boundSource = sourcePeer; boundReceiver = receiverPeer;
            running = true; pulseFailed = false;
            if (!WriteControl()) { running = false; MessageBox.Show(this, "控制文件暂时不可写，请重试。", Text); }
            toggle.Text = running ? "停止" : "启动"; UpdateInputs(); SaveSettings(); RefreshPeers();
        }
        void SaveSettings()
        {
            try
            {
                Directory.CreateDirectory(System.IO.Path.GetDirectoryName(settings));
                string[] values = { Selected(source), Selected(receiver), Mode.ToString(), operation.SelectedIndex.ToString(), factor.Value.ToString(Wire.Inv), fixedLots.Value.ToString(Wire.Inv), Rounding.ToString() };
                File.WriteAllLines(settings, values.Select(v => Convert.ToBase64String(Encoding.UTF8.GetBytes(v))).ToArray());
            }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        void LoadSettings()
        {
            try
            {
                if (!File.Exists(settings)) return;
                string[] v = File.ReadAllLines(settings).Select(s => Encoding.UTF8.GetString(Convert.FromBase64String(s))).ToArray();
                if (v.Length != 7) return;
                SelectPath(source, v[0]); SelectPath(receiver, v[1]);
                int mode = int.Parse(v[2]), op = int.Parse(v[3]), round = int.Parse(v[6]);
                decimal f = decimal.Parse(v[4], Wire.Inv), fixedValue = decimal.Parse(v[5], Wire.Inv);
                if (mode < 0 || mode > 2 || op < 0 || op > 1 || round < 0 || round > 1 || f < factor.Minimum || f > factor.Maximum || fixedValue < fixedLots.Minimum || fixedValue > fixedLots.Maximum) return;
                exact.Checked = mode == 0; convert.Checked = mode == 1; fixedMode.Checked = mode == 2;
                operation.SelectedIndex = op; factor.Value = f; fixedLots.Value = fixedValue;
                halfUp.Checked = round == 1; truncate.Checked = round == 0;
            }
            catch (Exception) { }
        }
        void ClosingWindow(object sender, FormClosingEventArgs args)
        {
            timer.Stop(); running = false;
            for (int i = 0; i < 3 && !WriteControl(); i++) Thread.Sleep(15);
            SaveSettings(); ownership.Dispose();
        }
    }
    internal static class Program
    {
        [STAThread]
        static int Main(string[] args)
        {
            if (args.Length > 0 && args[0] == "--self-test") return SelfTest.Run(args.Length > 1 ? args[1] : null);
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            try { Application.Run(new CopierForm()); return 0; }
            catch (Exception e) { MessageBox.Show(e.Message, "MT5 交易复制器"); return 1; }
        }
    }
}
