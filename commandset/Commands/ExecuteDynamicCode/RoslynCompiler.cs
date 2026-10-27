using System.IO;
using System.Reflection;
using System.Text;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;

namespace RevitMCPCommandSet.Commands.ExecuteDynamicCode
{
    /// <summary>
    /// Compiles C# source with Roslyn into an in-memory assembly image.
    /// This class must not touch Revit API types: on Revit 2019-2022 it also runs in a
    /// separate AppDomain that has no access to Revit.
    /// </summary>
    public static class RoslynCompiler
    {
        /// <summary>
        /// Compiles <paramref name="source"/> against the assemblies at <paramref name="referencePaths"/>.
        /// Throws with the compiler errors when compilation fails.
        /// </summary>
        public static byte[] Compile(string source, string[] referencePaths)
        {
#if REVIT2023_OR_GREATER
            return CompileHere(source, referencePaths);
#else
            return CompileInIsolatedDomain(source, referencePaths);
#endif
        }

        private static byte[] CompileHere(string source, string[] referencePaths)
        {
            var syntaxTree = CSharpSyntaxTree.ParseText(source);
            var references = referencePaths
                .Select(path => MetadataReference.CreateFromFile(path))
                .Cast<MetadataReference>()
                .ToList();

            var compilation = CSharpCompilation.Create(
                "AIGeneratedCode",
                syntaxTrees: new[] { syntaxTree },
                references: references,
                options: new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary)
            );

            using (var ms = new MemoryStream())
            {
                var result = compilation.Emit(ms);

                if (!result.Success)
                {
                    var errors = string.Join("\n", result.Diagnostics
                        .Where(d => d.Severity == DiagnosticSeverity.Error)
                        .Select(d => $"Line {d.Location.GetLineSpan().StartLinePosition.Line}: {d.GetMessage()}"));
                    throw new Exception($"Code compilation error:\n{errors}");
                }

                return ms.ToArray();
            }
        }

#if !REVIT2023_OR_GREATER
        // Roslyn's dependencies only load with binding redirects: System.Memory asks for
        // System.Runtime.CompilerServices.Unsafe 4.0.4.1 while Roslyn needs and ships 6.0.0.0.
        // Revit ignores an add-in's .config, and in Revit's own AppDomain an older copy loaded by
        // Revit or another add-in can win (MissingMethodException for Unsafe.ByteOffset). A private
        // AppDomain rooted at the command set folder, with redirects to the shipped versions,
        // loads exactly the libraries we ship. Only the compiled image crosses back.
        private const string SourceKey = "RevitMCP.Source";
        private const string ReferencesKey = "RevitMCP.References";
        private const string ImageKey = "RevitMCP.Image";
        private const string ErrorKey = "RevitMCP.Error";

        private static readonly object Sync = new object();
        private static AppDomain _compilerDomain;

        private static byte[] CompileInIsolatedDomain(string source, string[] referencePaths)
        {
            lock (Sync)
            {
                if (_compilerDomain == null)
                    _compilerDomain = CreateCompilerDomain();

                _compilerDomain.SetData(SourceKey, source);
                _compilerDomain.SetData(ReferencesKey, referencePaths);
                _compilerDomain.SetData(ImageKey, null);
                _compilerDomain.SetData(ErrorKey, null);

                _compilerDomain.DoCallBack(CompileInCurrentDomain);

                var error = (string)_compilerDomain.GetData(ErrorKey);
                if (error != null)
                    throw new Exception(error);
                return (byte[])_compilerDomain.GetData(ImageKey);
            }
        }

        /// <summary>
        /// Runs inside the compiler AppDomain. Public so the cross-domain callback can bind to it.
        /// </summary>
        public static void CompileInCurrentDomain()
        {
            var domain = AppDomain.CurrentDomain;
            try
            {
                var image = CompileHere((string)domain.GetData(SourceKey), (string[])domain.GetData(ReferencesKey));
                domain.SetData(ImageKey, image);
            }
            catch (Exception ex)
            {
                // Passed back as text: Roslyn's exception types are not loaded in Revit's AppDomain.
                // Built here rather than via ExecuteCodeEventHandler, which would pull Revit API types in.
                var messages = new List<string>();
                for (var e = ex; e != null; e = e.InnerException)
                    messages.Add(e.Message);
                domain.SetData(ErrorKey, string.Join(" -> ", messages));
            }
        }

        private static AppDomain CreateCompilerDomain()
        {
            string directory = Path.GetDirectoryName(typeof(RoslynCompiler).Assembly.Location);
            var setup = new AppDomainSetup { ApplicationBase = directory };
            setup.SetConfigurationBytes(Encoding.UTF8.GetBytes(BuildBindingRedirects(directory)));
            return AppDomain.CreateDomain("RevitMCP code compiler", null, setup);
        }

        /// <summary>
        /// Builds an app config that redirects every strong-named assembly in
        /// <paramref name="directory"/> to the version shipped there.
        /// </summary>
        private static string BuildBindingRedirects(string directory)
        {
            var config = new StringBuilder();
            config.Append("<?xml version=\"1.0\" encoding=\"utf-8\"?><configuration><runtime>");
            config.Append("<assemblyBinding xmlns=\"urn:schemas-microsoft-com:asm.v1\">");

            foreach (string file in Directory.GetFiles(directory, "*.dll"))
            {
                AssemblyName name;
                try
                {
                    name = AssemblyName.GetAssemblyName(file);
                }
                catch
                {
                    continue; // Not a managed assembly
                }

                byte[] token = name.GetPublicKeyToken();
                if (token == null || token.Length == 0)
                    continue; // Binding redirects only apply to strong-named assemblies

                string tokenHex = BitConverter.ToString(token).Replace("-", "").ToLowerInvariant();
                config.Append("<dependentAssembly>");
                config.Append($"<assemblyIdentity name=\"{name.Name}\" publicKeyToken=\"{tokenHex}\" culture=\"neutral\" />");
                config.Append($"<bindingRedirect oldVersion=\"0.0.0.0-{name.Version}\" newVersion=\"{name.Version}\" />");
                config.Append("</dependentAssembly>");
            }

            config.Append("</assemblyBinding></runtime></configuration>");
            return config.ToString();
        }
#endif
    }
}
