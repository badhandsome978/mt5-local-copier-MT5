// Build with CopierWindow.cs, SelfTest.cs and /main:LocalCopier.UITestProgram.
// Synthetic telemetry only; no trading library or real MT5 data paths.
using System;
using System.IO;
using System.Text;
using System.Windows.Forms;
namespace LocalCopier
{
    internal static class UITestProgram
    {
        [STAThread]
        static int Main(string[] args)
        {
            string root = Path.GetFullPath(args.Length == 1 ? args[0] : Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "desktop-ui-fixture"));
            Directory.CreateDirectory(Path.Combine(root, "Files"));
            Directory.CreateDirectory(Path.Combine(root, "Source", "MQL5"));
            Directory.CreateDirectory(Path.Combine(root, "Receiver", "MQL5"));
            string common = Path.Combine(root, "Files");
            bool enabled = false; string previous = "";
            Action pulse = delegate
            {
                try
                {
                    string[] x = Wire.Parse(Wire.Read(Path.Combine(common, "pair1.control")), "LTCCTRL2", 14);
                    if (x != null)
                    {
                        enabled = x[2] == "1";
                        string state = string.Join("\t", x, 2, x.Length - 2);
                        if (state != previous)
                        { File.AppendAllText(Path.Combine(root, "control-transitions.log"), state + "\r\n", Encoding.UTF8); previous = state; }
                    }
                }
                catch (IOException) { }
                foreach (string role in new string[] { "source", "receiver" })
                {
                    bool source = role == "source";
                    string path = Path.Combine(root, source ? "Source" : "Receiver");
                    string line = "LTCSTATUS2\t" + Wire.GetTickCount64() + "\t" + (source ? "123" : "456") + "\tTEST-SERVER\t" + path + "\t" + (source || enabled ? "1" : "0") + "\t0\t" + (source || enabled ? "ready" : "stopped") + "\tSimulated telemetry only\t1";
                    try { Wire.Write(Path.Combine(common, "pair1." + role + ".status"), Wire.Packet(line)); }
                    catch (IOException) { }
                }
            };
            pulse();
            Application.EnableVisualStyles(); Application.SetCompatibleTextRenderingDefault(false);
            using (CopierForm form = new CopierForm(root))
            using (Timer timer = new Timer())
            {
                timer.Interval = 100; timer.Tick += delegate { pulse(); }; timer.Start();
                Application.Run(form); pulse();
            }
            return 0;
        }
    }
}
