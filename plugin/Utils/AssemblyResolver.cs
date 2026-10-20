using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;

namespace revit_mcp_plugin.Utils
{
    /// <summary>
    /// Stands in for binding redirects for command set dependencies.
    /// Revit ignores an add-in's .dll.config, so on Revit versions that do not ship these
    /// libraries with their own redirects (e.g. Revit 2019), a dependency that asks for an
    /// older version of a shared assembly fails to load — for example System.Memory asking for
    /// System.Runtime.CompilerServices.Unsafe 4.0.4.1 while the command set ships 6.0.0.0.
    /// This resolves such requests to the copy shipped in a registered folder.
    /// </summary>
    public static class AssemblyResolver
    {
        private static readonly object Sync = new object();
        private static readonly List<string> Directories = new List<string>();
        private static bool _registered;

        /// <summary>
        /// Lets assemblies in <paramref name="directory"/> satisfy requests for any version.
        /// </summary>
        public static void AddDirectory(string directory)
        {
            lock (Sync)
            {
                if (!Directories.Contains(directory, StringComparer.OrdinalIgnoreCase))
                    Directories.Add(directory);

                if (!_registered)
                {
                    AppDomain.CurrentDomain.AssemblyResolve += OnAssemblyResolve;
                    _registered = true;
                }
            }
        }

        private static Assembly OnAssemblyResolve(object sender, ResolveEventArgs args)
        {
            AssemblyName requested;
            try
            {
                requested = new AssemblyName(args.Name);
            }
            catch
            {
                return null;
            }

            // Only handle assemblies we ship, so other add-ins' resolution is left alone
            string path = FindInDirectories(requested.Name + ".dll");
            if (path == null)
                return null;

            // Prefer a copy that is already loaded and at least as new as the one requested
            byte[] requestedToken = requested.GetPublicKeyToken();
            foreach (Assembly loaded in AppDomain.CurrentDomain.GetAssemblies())
            {
                AssemblyName name = loaded.GetName();
                if (string.Equals(name.Name, requested.Name, StringComparison.OrdinalIgnoreCase) &&
                    (requested.Version == null || name.Version >= requested.Version) &&
                    SameToken(name.GetPublicKeyToken(), requestedToken))
                {
                    return loaded;
                }
            }

            try
            {
                return Assembly.LoadFrom(path);
            }
            catch
            {
                return null;
            }
        }

        private static string FindInDirectories(string fileName)
        {
            string[] dirs;
            lock (Sync)
            {
                dirs = Directories.ToArray();
            }

            foreach (string dir in dirs)
            {
                string path = Path.Combine(dir, fileName);
                if (File.Exists(path))
                    return path;
            }
            return null;
        }

        private static bool SameToken(byte[] a, byte[] b)
        {
            // A request without a token (simple name) matches any copy
            if (b == null || b.Length == 0)
                return true;
            return a != null && a.SequenceEqual(b);
        }
    }
}
