using System;
using System.Collections.Generic;
using System.IO;

namespace revit_mcp_plugin.Utils
{
    /// <summary>
    /// Locates the folders that hold claude_desktop_config.json.
    /// Claude Desktop has kept its config in different places depending on how and when
    /// it was installed, and several of them can exist on one machine, so callers should
    /// treat every returned folder as a config that Claude Desktop may read.
    /// </summary>
    public static class ClaudeDesktopPaths
    {
        public const string ConfigFileName = "claude_desktop_config.json";

        /// <summary>
        /// %APPDATA%\Claude — the classic installer location. Used as the target when
        /// no Claude Desktop folder exists yet.
        /// </summary>
        public static string StandardDirectory =>
            Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Claude");

        /// <summary>
        /// Returns every existing Claude Desktop config folder, in this order:
        /// %LOCALAPPDATA%\Claude-Data\claude_*,
        /// %LOCALAPPDATA%\Packages\Claude_*\LocalCache\Roaming\Claude (MSIX virtualized AppData),
        /// %APPDATA%\Claude.
        /// </summary>
        public static List<string> GetExistingDirectories()
        {
            var dirs = new List<string>();
            string localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);

            AddMatches(dirs, Path.Combine(localAppData, "Claude-Data"), "claude_*", null);
            AddMatches(dirs, Path.Combine(localAppData, "Packages"), "Claude_*",
                Path.Combine("LocalCache", "Roaming", "Claude"));

            if (Directory.Exists(StandardDirectory))
                dirs.Add(StandardDirectory);

            return dirs;
        }

        private static void AddMatches(List<string> dirs, string parent, string pattern, string subPath)
        {
            try
            {
                if (!Directory.Exists(parent))
                    return;

                foreach (string match in Directory.GetDirectories(parent, pattern))
                {
                    string dir = subPath == null ? match : Path.Combine(match, subPath);
                    if (Directory.Exists(dir))
                        dirs.Add(dir);
                }
            }
            catch
            {
                // Permission issue reading the parent folder — skip it
            }
        }
    }
}
