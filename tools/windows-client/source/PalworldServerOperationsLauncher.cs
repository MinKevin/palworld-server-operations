using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

#if ADMIN
[assembly: AssemblyTitle("Palworld Server Operations - Admin")]
[assembly: AssemblyDescription("Portable administration client for Palworld dedicated servers")]
[assembly: AssemblyProduct("Palworld Server Operations - Admin")]
#else
[assembly: AssemblyTitle("Palworld Server Operations - Client")]
[assembly: AssemblyDescription("Trusted-operator client for managed Palworld dedicated servers")]
[assembly: AssemblyProduct("Palworld Server Operations - Client")]
#endif
[assembly: AssemblyCompany("MinKevin")]
[assembly: AssemblyCopyright("Copyright © 2026 MinKevin and contributors")]
[assembly: AssemblyVersion("1.0.2.0")]
[assembly: AssemblyFileVersion("1.0.2.0")]

internal static class Program
{
    private const uint JobObjectLimitKillOnJobClose = 0x00002000;
    private const uint JobObjectLimitSilentBreakawayOk = 0x00001000;
    private const string ResourceName = "PalworldServerOperations.Client.ps1";
    private const string IconResourceName = "PalworldServerOperations.Icon.ico";
    private const string ProjectLicenseResourceName = "PalworldServerOperations.License.txt";
#if ADMIN
    private const string SshModuleResourceName = "PalworldServerOperations.SshModule.ps1";
    private const string SshRuntimeResourcePrefix = "PalworldServerOperations.SshRuntime.";
    private const string SshPayloadResourcePrefix = "PalworldServerOperations.SshPayload.";
    private const string ThirdPartyResourceName = "PalworldServerOperations.ThirdParty.txt";
    private const string Edition = "admin";
    private const string ProductTitle = "Palworld Server Operations - Admin";
#else
    private const string Edition = "user";
    private const string ProductTitle = "Palworld Server Operations - Client";
#endif

    [STAThread]
    private static int Main(string[] args)
    {
        string temporaryBaseName =
            "PalworldServerOperations-" + Guid.NewGuid().ToString("N");
        string temporaryScript = Path.Combine(
            Path.GetTempPath(),
            temporaryBaseName + ".ps1"
        );
        string temporaryIcon = Path.Combine(Path.GetTempPath(), temporaryBaseName + ".ico");
        string temporaryProjectLicense = Path.Combine(
            Path.GetTempPath(),
            temporaryBaseName + "-LICENSE.txt"
        );
#if ADMIN
        string temporarySshDirectory = Path.Combine(
            Path.GetTempPath(),
            "PalworldServerOperationsAdmin-" + Guid.NewGuid().ToString("N")
        );
#endif

        try
        {
            ExtractClient(temporaryScript);
            ExtractResource(IconResourceName, temporaryIcon);
            ExtractResource(ProjectLicenseResourceName, temporaryProjectLicense);
#if ADMIN
            Directory.CreateDirectory(temporarySshDirectory);
            string temporarySshModule = Path.Combine(
                temporarySshDirectory,
                "palworld-ssh-management.ps1"
            );
            ExtractResource(SshModuleResourceName, temporarySshModule);
            ExtractResourcesWithPrefix(SshRuntimeResourcePrefix, temporarySshDirectory);
            ExtractResourcesWithPrefix(SshPayloadResourcePrefix, temporarySshDirectory);
            string temporaryThirdParty = Path.Combine(temporarySshDirectory, "THIRD_PARTY.txt");
            ExtractResource(ThirdPartyResourceName, temporaryThirdParty);
#endif
            if (GetLauncherTestMode(args) == "launcher-smoke")
            {
                return 0;
            }
            string systemDirectory = Environment.GetFolderPath(Environment.SpecialFolder.System);
            string powerShell = Path.Combine(
                systemDirectory,
                @"WindowsPowerShell\v1.0\powershell.exe"
            );
            if (!File.Exists(powerShell))
            {
                powerShell = "powershell.exe";
            }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = powerShell;
            string launcherTestMode = GetLauncherTestMode(args);
            if (launcherTestMode == "launcher-job-hold")
            {
                startInfo.Arguments =
                    "-NoLogo -NoProfile -NonInteractive -Command "
                    + QuoteArgument("Start-Sleep -Seconds 300");
            }
            else
            {
                startInfo.Arguments =
                    "-NoLogo -NoProfile -NonInteractive -STA -ExecutionPolicy Bypass -File "
                    + QuoteArgument(temporaryScript);
                if (!String.IsNullOrEmpty(launcherTestMode))
                {
                    startInfo.Arguments +=
                        " -LauncherTestMode " + QuoteArgument(launcherTestMode);
                }
            }
            startInfo.WorkingDirectory = AppDomain.CurrentDomain.BaseDirectory;
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            Dictionary<string, string> childEnvironment =
                new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            childEnvironment["PALWORLD_CLIENT_EDITION"] = Edition;
            childEnvironment["PALWORLD_CLIENT_BASE_DIR"] =
                AppDomain.CurrentDomain.BaseDirectory;
            childEnvironment["PALWORLD_CLIENT_EXE_PATH"] =
                Assembly.GetExecutingAssembly().Location;
            childEnvironment["PALWORLD_CLIENT_ICON_PATH"] = temporaryIcon;
            childEnvironment["PALWORLD_PROJECT_LICENSE_PATH"] = temporaryProjectLicense;
#if ADMIN
            childEnvironment["PALWORLD_SSH_MODULE_PATH"] = temporarySshModule;
            childEnvironment["PALWORLD_SSH_RUNTIME_DIR"] = temporarySshDirectory;
            childEnvironment["PALWORLD_SSH_PAYLOAD_DIR"] = temporarySshDirectory;
            childEnvironment["PALWORLD_THIRD_PARTY_PATH"] = temporaryThirdParty;
#endif

            IntPtr childLifetimeJob = CreateChildLifetimeJob();
            try
            {
                using (Process process = StartProcessWithEnvironment(startInfo, childEnvironment))
                {
                    if (process == null)
                    {
                        throw new InvalidOperationException("Windows PowerShell could not be started.");
                    }
                    try
                    {
                        AssignChildToLifetimeJob(childLifetimeJob, process);
                    }
                    catch
                    {
                        StopUnassignedChild(process);
                        throw;
                    }
                    WriteLauncherJobTestChildPid(launcherTestMode, process.Id);
                    process.WaitForExit();
                    return process.ExitCode;
                }
            }
            finally
            {
                if (childLifetimeJob != IntPtr.Zero)
                {
                    CloseHandle(childLifetimeJob);
                }
            }
        }
        catch (Exception error)
        {
            string testMode = GetLauncherTestMode(args);
            if (!String.IsNullOrEmpty(testMode))
            {
                string errorFile = Environment.GetEnvironmentVariable(
                    "PALWORLD_LAUNCHER_TEST_ERROR_FILE"
                );
                if (!String.IsNullOrEmpty(errorFile))
                {
                    try
                    {
                        File.WriteAllText(Path.GetFullPath(errorFile), error.ToString());
                    }
                    catch
                    {
                        // The original launcher error is still represented by exit code 1.
                    }
                }
                return 1;
            }
            MessageBox.Show(
                error.Message,
                ProductTitle,
                MessageBoxButtons.OK,
                MessageBoxIcon.Error
            );
            return 1;
        }
        finally
        {
            DeleteTemporaryFile(temporaryScript);
            DeleteTemporaryFile(temporaryIcon);
            DeleteTemporaryFile(temporaryProjectLicense);
#if ADMIN
            DeleteTemporaryDirectory(temporarySshDirectory);
#endif
        }
    }

    private static void ExtractClient(string destination)
    {
        ExtractResource(ResourceName, destination);
    }

    private static void ExtractResource(string resourceName, string destination)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        using (Stream input = assembly.GetManifestResourceStream(resourceName))
        {
            if (input == null)
            {
                throw new InvalidOperationException("Embedded resource is missing: " + resourceName);
            }
            using (FileStream output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write))
            {
                input.CopyTo(output);
            }
        }
    }

    private static void ExtractResourcesWithPrefix(string prefix, string destinationDirectory)
    {
        Assembly assembly = Assembly.GetExecutingAssembly();
        foreach (string resourceName in assembly.GetManifestResourceNames())
        {
            if (!resourceName.StartsWith(prefix, StringComparison.Ordinal))
            {
                continue;
            }
            string fileName = resourceName.Substring(prefix.Length);
            if (fileName.Length == 0 || fileName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            {
                throw new InvalidOperationException("Invalid embedded resource file name.");
            }
            ExtractResource(resourceName, Path.Combine(destinationDirectory, fileName));
        }
    }

    private static string QuoteArgument(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static string GetLauncherTestMode(string[] args)
    {
        if (args != null && args.Length == 2 && args[0] == "--test-mode")
        {
            return args[1];
        }
        return Environment.GetEnvironmentVariable("PALWORLD_CLIENT_TEST_MODE");
    }

    private static IntPtr CreateChildLifetimeJob()
    {
        IntPtr job = CreateJobObject(IntPtr.Zero, null);
        if (job == IntPtr.Zero)
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "A Windows child-process lifetime job could not be created."
            );
        }

        IntPtr informationPointer = IntPtr.Zero;
        try
        {
            JobObjectExtendedLimitInformation information =
                new JobObjectExtendedLimitInformation();
            // Keep the hosted PowerShell tied to this launcher, while allowing explicit
            // follow-up processes such as the language-change restart or a web browser
            // to outlive the closing instance.
            information.BasicLimitInformation.LimitFlags =
                JobObjectLimitKillOnJobClose | JobObjectLimitSilentBreakawayOk;
            int informationLength = Marshal.SizeOf(
                typeof(JobObjectExtendedLimitInformation)
            );
            informationPointer = Marshal.AllocHGlobal(informationLength);
            Marshal.StructureToPtr(information, informationPointer, false);
            if (!SetInformationJobObject(
                job,
                JobObjectInformationClass.ExtendedLimitInformation,
                informationPointer,
                (uint)informationLength
            ))
            {
                throw new Win32Exception(
                    Marshal.GetLastWin32Error(),
                    "The Windows child-process lifetime job could not be configured."
                );
            }
            return job;
        }
        catch
        {
            CloseHandle(job);
            throw;
        }
        finally
        {
            if (informationPointer != IntPtr.Zero)
            {
                Marshal.FreeHGlobal(informationPointer);
            }
        }
    }

    private static void AssignChildToLifetimeJob(IntPtr job, Process process)
    {
        if (!AssignProcessToJobObject(job, process.Handle))
        {
            throw new Win32Exception(
                Marshal.GetLastWin32Error(),
                "Windows PowerShell could not be attached to the application lifetime."
            );
        }
    }

    private static void StopUnassignedChild(Process process)
    {
        try
        {
            if (!process.HasExited)
            {
                process.Kill();
                process.WaitForExit();
            }
        }
        catch
        {
            // Preserve the original job-assignment error shown to the user.
        }
    }

    private static void WriteLauncherJobTestChildPid(string testMode, int processId)
    {
        if (testMode != "launcher-job-hold")
        {
            return;
        }
        string destination = Environment.GetEnvironmentVariable(
            "PALWORLD_LAUNCHER_JOB_TEST_CHILD_PID_FILE"
        );
        if (String.IsNullOrEmpty(destination))
        {
            throw new InvalidOperationException(
                "PALWORLD_LAUNCHER_JOB_TEST_CHILD_PID_FILE is required for launcher-job-hold."
            );
        }
        File.WriteAllText(
            Path.GetFullPath(destination),
            processId.ToString(CultureInfo.InvariantCulture)
        );
    }

    private static Process StartProcessWithEnvironment(
        ProcessStartInfo startInfo,
        IDictionary<string, string> overrides
    )
    {
        // Do not access ProcessStartInfo.EnvironmentVariables. On Windows, a
        // parent launched with both `Path` and `PATH` can make that legacy
        // case-insensitive collection throw before PowerShell starts. Apply
        // only our fixed values to this short-lived single-threaded launcher,
        // let CreateProcess inherit the original block, then restore it.
        Dictionary<string, string> originals =
            new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (KeyValuePair<string, string> item in overrides)
        {
            originals[item.Key] = Environment.GetEnvironmentVariable(item.Key);
            Environment.SetEnvironmentVariable(item.Key, item.Value);
        }
        try
        {
            return Process.Start(startInfo);
        }
        finally
        {
            foreach (KeyValuePair<string, string> item in originals)
            {
                Environment.SetEnvironmentVariable(item.Key, item.Value);
            }
        }
    }

    private static void DeleteTemporaryFile(string path)
    {
        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                if (File.Exists(path))
                {
                    File.Delete(path);
                }
                return;
            }
            catch (IOException)
            {
                Thread.Sleep(100);
            }
            catch (UnauthorizedAccessException)
            {
                Thread.Sleep(100);
            }
        }
    }

    private static void DeleteTemporaryDirectory(string path)
    {
        for (int attempt = 0; attempt < 10; attempt++)
        {
            try
            {
                if (Directory.Exists(path))
                {
                    Directory.Delete(path, true);
                }
                return;
            }
            catch (IOException)
            {
                Thread.Sleep(150);
            }
            catch (UnauthorizedAccessException)
            {
                Thread.Sleep(150);
            }
        }
    }

    private enum JobObjectInformationClass
    {
        ExtendedLimitInformation = 9
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct IoCounters
    {
        public ulong ReadOperationCount;
        public ulong WriteOperationCount;
        public ulong OtherOperationCount;
        public ulong ReadTransferCount;
        public ulong WriteTransferCount;
        public ulong OtherTransferCount;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectBasicLimitInformation
    {
        public long PerProcessUserTimeLimit;
        public long PerJobUserTimeLimit;
        public uint LimitFlags;
        public UIntPtr MinimumWorkingSetSize;
        public UIntPtr MaximumWorkingSetSize;
        public uint ActiveProcessLimit;
        public UIntPtr Affinity;
        public uint PriorityClass;
        public uint SchedulingClass;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct JobObjectExtendedLimitInformation
    {
        public JobObjectBasicLimitInformation BasicLimitInformation;
        public IoCounters IoInfo;
        public UIntPtr ProcessMemoryLimit;
        public UIntPtr JobMemoryLimit;
        public UIntPtr PeakProcessMemoryUsed;
        public UIntPtr PeakJobMemoryUsed;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateJobObject(IntPtr securityAttributes, string name);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(
        IntPtr job,
        JobObjectInformationClass informationClass,
        IntPtr information,
        uint informationLength
    );

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(IntPtr job, IntPtr process);

    [DllImport("kernel32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseHandle(IntPtr handle);
}
