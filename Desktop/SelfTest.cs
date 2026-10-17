using System;
using System.IO;
using System.Text;
using System.Reflection;

namespace LocalCopier
{
    internal static class SelfTest
    {
        static int count;
        static void Check(bool condition, string name)
        { count++; if (!condition) throw new Exception("FAIL: " + name); }
        internal static int Run(string report)
        {
            string result;
            try
            {
                Check(Wire.Lots(.32M, 0, 0, 99M, .01M, 0, .32M) == .32M, "exact ignores conversion");
                Check(Wire.Lots(.32M, 1, 0, 1.5M, .01M, 0, .32M) == .48M, "multiply");
                Check(Wire.Lots(.32M, 1, 1, 3M, .01M, 0, .32M) == .10M, "divide truncate");
                Check(Wire.Lots(.32M, 1, 1, 3M, .01M, 1, .32M) == .11M, "divide round");
                Check(Wire.Lots(.03M, 1, 0, .5M, .01M, 1, .03M) == .02M, "half up");
                Check(Wire.Lots(.32M, 2, 0, 123M, .07M, 0, .32M) == .07M, "fixed entry");
                Check(Wire.Lots(.16M, 2, 0, 123M, .08M, 0, .32M) == .04M, "fixed partial close");
                Check(Wire.Lots(.01M, 1, 1, 3M, .01M, 1, .01M) == 0, "subminimum zero");
                bool bad = false;
                try { Wire.Lots(.32M, 1, 1, 0, .01M, 0, .32M); } catch (ArgumentException) { bad = true; }
                Check(bad, "division zero rejected");
                Check(Wire.Fresh(3000, 1000) && !Wire.Fresh(3001, 1000) && !Wire.Fresh(1000, 1001), "heartbeat lease boundaries");
                string line = "LTCCTRL2\t1000\t1\t123\t测试服务器\t456\t接收服务器\t1\t1\t3\t0.01\t1\tC:\\源\tC:\\接收";
                string packet = Wire.Packet(line);
                Check(Wire.Parse(packet, "LTCCTRL2", 14) != null, "Unicode control roundtrip");
                Check(Wire.Parse(packet.Replace("\t123\t", "\t124\t"), "LTCCTRL2", 14) == null, "modified packet rejected");
                Check(Wire.Parse(packet.Substring(0, packet.Length - 8), "LTCCTRL2", 14) == null, "torn packet rejected");
                Check(Wire.Parse(packet + "extra\r\n", "LTCCTRL2", 14) == null, "extra rows rejected");
                Check(Wire.SamePath(@"C:\test\", @"c:\TEST"), "path identity case and trailing slash");
                string temp = Path.Combine(Path.GetTempPath(), "MT5CopierTest-" + Guid.NewGuid().ToString("N"));
                Directory.CreateDirectory(Path.Combine(temp, "MQL5"));
                Installer.Install(temp, true); Installer.Install(temp, false);
                string destination = Path.Combine(temp, "MQL5", "Experts", "LocalCopier");
                foreach (string name in new string[] { "CopierSource.ex5", "CopierReceiver.ex5", "CopyCore.mqh", "CopyProtocol.mqh", "CopyDesktop.mqh" })
                {
                    using (Stream r = Assembly.GetExecutingAssembly().GetManifestResourceStream("EA." + name))
                    using (MemoryStream m = new MemoryStream())
                    { r.CopyTo(m); Check(Convert.ToBase64String(m.ToArray()) == Convert.ToBase64String(File.ReadAllBytes(Path.Combine(destination, name))), "embedded install " + name); }
                }
                Check(Directory.GetDirectories(Path.Combine(temp, "MQL5", "Experts"), "LocalCopier.backup.*").Length == 1, "reinstall backup");
                string control = Path.Combine(temp, "test.control"); Wire.Write(control, packet);
                Check(Wire.Read(control) == packet, "exclusive UTF8 write roundtrip");
                using (FileStream held = new FileStream(control, FileMode.Open, FileAccess.Read, FileShare.None))
                {
                    bad = false; try { Wire.Write(control, packet); } catch (IOException) { bad = true; }
                    Check(bad, "exclusive contention fails safely");
                }
                // Isolated generated test directory retained for review; never touches MT5 data.
                result = "PASS: " + count + " desktop assertions. Fixture: " + temp;
            }
            catch (Exception e) { result = e.ToString(); if (report != null) File.WriteAllText(report, result, Encoding.UTF8); return 1; }
            if (report != null) File.WriteAllText(report, result, Encoding.UTF8);
            return 0;
        }
    }
}
