#requires -Version 5.1

# Dot-sourced by the Admin edition. The API and SSH stores remain in the main
# client so both views share one encrypted, portable connection database.

$script:PalworldSshClient = $null
$script:PalworldSshAutomationShell = $null
$script:PalworldSshTerminalClient = $null
$script:PalworldSshShell = $null
$script:PalworldSshTimer = $null
$script:PalworldSshCancelRequested = $false
$script:PalworldSshOutput = $null
$script:PalworldSshTerminalOutput = $null
$script:PalworldSshStatus = $null
$script:PalworldSshWorkDirectoryStatus = $null
$script:PalworldSshConnectionCombo = $null
$script:PalworldSshNoSelectionText = Get-PalworldLocalizedText `
    "— No SSH Connection selected —" `
    "— SSH 연결 선택 없음 —"
$script:PalworldSshTerminalConnectionCombo = $null
$script:PalworldSshServerCombo = $null
$script:PalworldSshApiLinkLabel = $null
$script:PalworldSshCurrentConnection = $null
$script:PalworldSshRuntimeLoaded = $false
$script:PalworldSshOwner = $null
$script:PalworldSshAddDialogOpened = $false
$script:PalworldSshSummary = $null
$script:PalworldSshAddButton = $null
$script:PalworldSshUpdateButton = $null
$script:PalworldSshDeleteButton = $null
$script:PalworldSshConnectButton = $null
$script:PalworldSshDisconnectButton = $null
$script:PalworldSshReconnectButton = $null
$script:PalworldSshHostCheckButton = $null
$script:PalworldSshCreateWorkDirectoryButton = $null
$script:PalworldSshReviewCommonSettingsButton = $null
$script:PalworldSshRefreshButton = $null
$script:PalworldSshRunButton = $null
$script:PalworldSshCancelOperationButton = $null
$script:PalworldSshCategoryCombo = $null
$script:PalworldSshActionCombo = $null
$script:PalworldSshActions = @()
$script:PalworldSshVisibleActions = @()
$script:PalworldSshTerminalInput = $null
$script:PalworldSshManagementSanitizer = $null
$script:PalworldSshTerminalSanitizer = $null
$script:PalworldSshSelectionSyncing = $false
$script:PalworldSshSetAvailability = $null
$script:PalworldSshShowSelected = $null
$script:PalworldSshRefreshConnections = $null
$script:PalworldSshRefreshServers = $null
$script:PalworldSshRefreshActions = $null
$script:PalworldSshUpdateActionTarget = $null
$script:PalworldSshSendTerminal = $null
$script:PalworldSshChannelTabs = $null
$script:PalworldSshNetworkNotice = $null
$script:PalworldSshTerminalPasswordMode = $false
$script:PalworldSshTerminalPasswordPromptSignature = ""
$script:PalworldSshTerminalHandledPasswordPromptSignature = ""
$script:PalworldSshUpdateNetworkNotice = $null
$script:PalworldSshRenderStatusNotice = $null
$script:PalworldSshBeginStatusOperation = $null
$script:PalworldSshLiveStatusLines = @()
$script:PalworldSshLastOperationFinding = ""
$script:PalworldSshStatusHistoryLines = @()
$script:PalworldSshStatusOperationTitle = ""
$script:PalworldSshStatusOperationSeenLines = @{}
$script:PalworldSshStatusOperationNeedsHeader = $true
$script:PalworldSshPinnedConnectionId = ""
$script:PalworldSshApiContextSshId = ""
$script:PalworldSshClosing = $false
$script:PalworldSshPreferNewServerAfterRefresh = $false
$script:PalworldSshServersBeforeOperation = @()
$script:PalworldSshLastRefreshServer = ""
$script:PalworldSshPostActionApiSyncMode = ""
$script:PalworldSshPostActionApiServer = ""
$script:PalworldSshPostActionShowToken = $false
$script:PalworldSshPostActionApiSyncAfterFailure = $false
$script:PalworldSshPostActionApiRemoveServer = ""
$script:PalworldSshToolTip = $null
$script:PalworldSshOperationRunning = $false
$script:PalworldSshNonCancelableTransaction = $false
$script:PalworldSshLastRemoteOperationOutput = ""
$script:PalworldSshAutomationCommandRunning = $false
$script:PalworldSshSetOperationState = $null
$script:PalworldSshTerminalSendButton = $null
$script:PalworldSshPreviousAcceptButton = $null
$script:PalworldSshRunHostCheck = $null
$script:PalworldSshHostReadyForManagement = $false
$script:PalworldSshProjectPrepared = $false
$script:PalworldSshCommonSettingsReviewed = $false
$script:PalworldSshPostActionWorldOptionPreserved = $false
$script:PalworldSshTerminalTick = $null

function Initialize-PalworldSshRuntime {
    if ($script:PalworldSshRuntimeLoaded) { return }
    $runtimeDirectory = if ($env:PALWORLD_SSH_RUNTIME_DIR) {
        [IO.Path]::GetFullPath($env:PALWORLD_SSH_RUNTIME_DIR)
    }
    else {
        Join-Path $PSScriptRoot "vendor"
    }
    $primary = Join-Path $runtimeDirectory "Renci.SshNet.dll"
    if (-not (Test-Path -LiteralPath $primary)) {
        throw "SSH runtime is missing. Rebuild Palworld Server Operations - Admin.exe."
    }
    foreach ($assembly in Get-ChildItem -LiteralPath $runtimeDirectory -Filter *.dll | Where-Object Name -ne "Renci.SshNet.dll") {
        try { [void][Reflection.Assembly]::LoadFrom($assembly.FullName) }
        catch [IO.FileLoadException] { }
    }
    [void][Reflection.Assembly]::LoadFrom($primary)
    if (-not ("Palworld.ServerManager.SshHostKeyVerifier" -as [type])) {
        $eventBridgeSource = @'
using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;
using Renci.SshNet.Common;

namespace Palworld.ServerManager
{
    public sealed class SshHostKeyVerifier
    {
        private readonly string expectedFingerprint;

        public string Fingerprint { get; private set; }
        public string Algorithm { get; private set; }
        public EventHandler<HostKeyEventArgs> Handler { get { return Handle; } }

        public SshHostKeyVerifier(string expected)
        {
            expectedFingerprint = expected ?? String.Empty;
            Fingerprint = String.Empty;
            Algorithm = String.Empty;
        }

        private void Handle(object sender, HostKeyEventArgs eventArgs)
        {
            Fingerprint = eventArgs.FingerPrintSHA256 ?? String.Empty;
            Algorithm = eventArgs.HostKeyName ?? String.Empty;
            eventArgs.CanTrust = expectedFingerprint.Length > 0 &&
                String.Equals(expectedFingerprint, Fingerprint, StringComparison.Ordinal);
        }
    }

    public sealed class SshPasswordPromptResponder
    {
        private readonly string password;

        public EventHandler<AuthenticationPromptEventArgs> Handler { get { return Handle; } }

        public SshPasswordPromptResponder(string value)
        {
            password = value ?? String.Empty;
        }

        private void Handle(object sender, AuthenticationPromptEventArgs eventArgs)
        {
            foreach (AuthenticationPrompt prompt in eventArgs.Prompts)
            {
                string request = prompt.Request ?? String.Empty;
                if (request.IndexOf("password", StringComparison.OrdinalIgnoreCase) >= 0 ||
                    request.IndexOf("passcode", StringComparison.OrdinalIgnoreCase) >= 0)
                {
                    prompt.Response = password;
                }
            }
        }
    }

    public sealed class TerminalStreamSanitizer
    {
        private enum ParserState
        {
            Normal,
            Escape,
            ControlSequence,
            OperatingSystemCommand,
            OperatingSystemCommandEscape,
            StringControl,
            StringControlEscape
        }

        private ParserState state = ParserState.Normal;
        private bool pendingCarriageReturn = false;

        public void Reset()
        {
            state = ParserState.Normal;
            pendingCarriageReturn = false;
        }

        public string Filter(string input)
        {
            if (String.IsNullOrEmpty(input))
            {
                return String.Empty;
            }

            System.Text.StringBuilder output = new System.Text.StringBuilder(input.Length);
            foreach (char value in input)
            {
                // SSH reads may split CRLF across two chunks.  Holding a final
                // carriage return prevents the UI renderer from treating that
                // split as an in-place progress-line rewrite and deleting the
                // command that preceded it.
                if (state == ParserState.Normal && pendingCarriageReturn)
                {
                    pendingCarriageReturn = false;
                    if (value == '\n')
                    {
                        output.Append("\r\n");
                        continue;
                    }
                    output.Append('\r');
                }
                switch (state)
                {
                    case ParserState.Normal:
                        if (value == '\u001b')
                        {
                            state = ParserState.Escape;
                        }
                        else if (value == '\u009b')
                        {
                            state = ParserState.ControlSequence;
                        }
                        else if (value == '\u009d')
                        {
                            state = ParserState.OperatingSystemCommand;
                        }
                        else if (value == '\u0090' || value == '\u0098' || value == '\u009e' || value == '\u009f')
                        {
                            state = ParserState.StringControl;
                        }
                        else if (value == '\r')
                        {
                            pendingCarriageReturn = true;
                        }
                        else if (value == '\n' || value == '\t' || value == '\b' || value >= ' ')
                        {
                            output.Append(value);
                        }
                        break;

                    case ParserState.Escape:
                        if (value == '[')
                        {
                            state = ParserState.ControlSequence;
                        }
                        else if (value == ']')
                        {
                            state = ParserState.OperatingSystemCommand;
                        }
                        else if (value == 'P' || value == 'X' || value == '^' || value == '_')
                        {
                            state = ParserState.StringControl;
                        }
                        else
                        {
                            state = ParserState.Normal;
                        }
                        break;

                    case ParserState.ControlSequence:
                        if (value >= '@' && value <= '~')
                        {
                            state = ParserState.Normal;
                        }
                        break;

                    case ParserState.OperatingSystemCommand:
                        if (value == '\u0007' || value == '\u009c')
                        {
                            state = ParserState.Normal;
                        }
                        else if (value == '\u001b')
                        {
                            state = ParserState.OperatingSystemCommandEscape;
                        }
                        break;

                    case ParserState.OperatingSystemCommandEscape:
                        state = value == '\\' ? ParserState.Normal : ParserState.OperatingSystemCommand;
                        break;

                    case ParserState.StringControl:
                        if (value == '\u009c')
                        {
                            state = ParserState.Normal;
                        }
                        else if (value == '\u001b')
                        {
                            state = ParserState.StringControlEscape;
                        }
                        break;

                    case ParserState.StringControlEscape:
                        state = value == '\\' ? ParserState.Normal : ParserState.StringControl;
                        break;
                }
            }
            return output.ToString();
        }
    }

    public sealed class Utf8ShellReadResult
    {
        public int BytesRead { get; private set; }
        public string Text { get; private set; }

        public Utf8ShellReadResult(int bytesRead, string text)
        {
            BytesRead = bytesRead;
            Text = text ?? String.Empty;
        }
    }

    // ShellStream.Read() materializes every currently buffered byte as one
    // string.  A noisy remote process can therefore stall the WinForms thread
    // and make shutdown appear hung.  Read fixed-size byte slices instead and
    // retain one Decoder per stream so a UTF-8 character split at a slice
    // boundary is emitted only after all of its bytes arrive.
    public static class BoundedUtf8ShellReader
    {
        private sealed class DecoderState
        {
            internal readonly Decoder Decoder = new UTF8Encoding(false, false).GetDecoder();
        }

        private static readonly ConditionalWeakTable<Stream, DecoderState> states =
            new ConditionalWeakTable<Stream, DecoderState>();

        public static Utf8ShellReadResult Read(Stream stream, int maximumBytes)
        {
            if (stream == null)
            {
                throw new ArgumentNullException("stream");
            }
            if (maximumBytes < 1 || maximumBytes > 65536)
            {
                throw new ArgumentOutOfRangeException("maximumBytes");
            }

            byte[] bytes = new byte[maximumBytes];
            int bytesRead = stream.Read(bytes, 0, bytes.Length);
            if (bytesRead <= 0)
            {
                Array.Clear(bytes, 0, bytes.Length);
                return new Utf8ShellReadResult(0, String.Empty);
            }

            DecoderState state = states.GetValue(stream, delegate { return new DecoderState(); });
            char[] characters = new char[Encoding.UTF8.GetMaxCharCount(bytesRead)];
            int characterCount;
            lock (state)
            {
                characterCount = state.Decoder.GetChars(
                    bytes,
                    0,
                    bytesRead,
                    characters,
                    0,
                    false
                );
            }
            string text = characterCount == 0
                ? String.Empty
                : new String(characters, 0, characterCount);
            Array.Clear(bytes, 0, bytes.Length);
            Array.Clear(characters, 0, characters.Length);
            return new Utf8ShellReadResult(bytesRead, text);
        }

        public static void Reset(Stream stream)
        {
            if (stream != null)
            {
                states.Remove(stream);
            }
        }
    }

    public static class RichTextBoxScrollHelper
    {
        private const int EM_SETSEL = 0x00B1;
        private const int EM_LINESCROLL = 0x00B6;
        private const int EM_SCROLLCARET = 0x00B7;
        private const int EM_GETFIRSTVISIBLELINE = 0x00CE;
        private const int WM_VSCROLL = 0x0115;
        private const int SB_BOTTOM = 7;

        [System.Runtime.InteropServices.DllImport("user32.dll")]
        private static extern IntPtr SendMessage(
            IntPtr window,
            int message,
            IntPtr wParam,
            IntPtr lParam
        );

        public static void ScrollToBottom(IntPtr window, int textLength)
        {
            if (window == IntPtr.Zero)
            {
                return;
            }
            IntPtr position = new IntPtr(textLength);
            SendMessage(window, EM_SETSEL, position, position);
            SendMessage(window, EM_SCROLLCARET, IntPtr.Zero, IntPtr.Zero);
            SendMessage(window, WM_VSCROLL, new IntPtr(SB_BOTTOM), IntPtr.Zero);
        }

        public static void ScrollLineToTop(IntPtr window, int targetLine)
        {
            if (window == IntPtr.Zero || targetLine < 0)
            {
                return;
            }
            int firstVisible = SendMessage(
                window,
                EM_GETFIRSTVISIBLELINE,
                IntPtr.Zero,
                IntPtr.Zero
            ).ToInt32();
            SendMessage(
                window,
                EM_LINESCROLL,
                IntPtr.Zero,
                new IntPtr(targetLine - firstVisible)
            );
        }
    }

    public sealed class BoundedMemoryStream : MemoryStream
    {
        private readonly long maximumLength;

        public BoundedMemoryStream(long maximumLength)
        {
            if (maximumLength < 1)
            {
                throw new ArgumentOutOfRangeException("maximumLength");
            }
            this.maximumLength = maximumLength;
        }

        private void EnsureCapacityForWrite(int count)
        {
            if (count < 0 || Position > maximumLength - count)
            {
                throw new IOException("The remote file exceeded the configured download limit.");
            }
        }

        public override void Write(byte[] buffer, int offset, int count)
        {
            EnsureCapacityForWrite(count);
            base.Write(buffer, offset, count);
        }

        public override void WriteByte(byte value)
        {
            EnsureCapacityForWrite(1);
            base.WriteByte(value);
        }

        public override System.Threading.Tasks.Task WriteAsync(
            byte[] buffer,
            int offset,
            int count,
            System.Threading.CancellationToken cancellationToken)
        {
            if (cancellationToken.IsCancellationRequested)
            {
                return System.Threading.Tasks.Task.FromCanceled(cancellationToken);
            }
            try
            {
                Write(buffer, offset, count);
                return System.Threading.Tasks.Task.FromResult<object>(null);
            }
            catch (Exception error)
            {
                return System.Threading.Tasks.Task.FromException(error);
            }
        }

        public override void SetLength(long value)
        {
            if (value < 0 || value > maximumLength)
            {
                throw new IOException("The remote file exceeded the configured download limit.");
            }
            base.SetLength(value);
        }
    }

    public static class AsyncTaskCleanup
    {
        public static void ObserveAndDispose(
            System.Threading.Tasks.Task task,
            object[] targets)
        {
            if (task == null)
            {
                BackgroundDisposer.Queue(targets);
                return;
            }
            task.ContinueWith(
                delegate(System.Threading.Tasks.Task completed)
                {
                    if (completed.IsFaulted)
                    {
                        AggregateException ignored = completed.Exception;
                    }
                    BackgroundDisposer.Queue(targets);
                },
                System.Threading.CancellationToken.None,
                System.Threading.Tasks.TaskContinuationOptions.ExecuteSynchronously,
                System.Threading.Tasks.TaskScheduler.Default
            );
        }
    }

    public static class BackgroundDisposer
    {
        public static void Queue(object[] targets)
        {
            if (targets == null || targets.Length == 0)
            {
                return;
            }
            System.Threading.ThreadPool.QueueUserWorkItem(delegate
            {
                foreach (object target in targets)
                {
                    IDisposable disposable = target as IDisposable;
                    if (disposable == null)
                    {
                        continue;
                    }
                    try
                    {
                        disposable.Dispose();
                    }
                    catch
                    {
                    }
                }
            });
        }
    }
}
'@
        Add-Type `
            -TypeDefinition $eventBridgeSource `
            -Language CSharp `
            -ReferencedAssemblies $primary `
            -ErrorAction Stop
    }
    $script:PalworldSshRuntimeLoaded = $true
}

function ConvertTo-PosixLiteral {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    $replacement = "'`"'`"'"
    return "'" + $Value.Replace("'", $replacement) + "'"
}

function Test-PalworldSshHost {
    param([Parameter(Mandatory = $true)][string]$Value)
    return (
        $Value -notmatch '^https?://' -and
        $Value -notmatch '[\s/\\`$;|&<>]' -and
        $Value.Length -le 253
    )
}

function Test-PalworldWorkDirectory {
    param([Parameter(Mandatory = $true)][string]$Value)
    if ($Value -notmatch '^(?:~/|/)[A-Za-z0-9._/-]+$') { return $false }
    if ($Value -match '(^|/)\.\.($|/)' -or $Value.Contains('//')) { return $false }
    $trimmed = $Value.TrimEnd('/')
    return $trimmed -notin @(
        "", "/", "/bin", "/boot", "/dev", "/etc", "/home", "/lib", "/lib64",
        "/opt", "/proc", "/root", "/run", "/sbin", "/srv", "/sys", "/tmp", "/usr", "/var"
    )
}

function Read-PalworldSshShellUtf8 {
    param(
        [Parameter(Mandatory = $true)]$Shell,
        [ValidateRange(1, 65536)][int]$MaximumBytes = 16384
    )
    if ($Shell -is [IO.Stream]) {
        return [Palworld.ServerManager.BoundedUtf8ShellReader]::Read(
            [IO.Stream]$Shell,
            $MaximumBytes
        )
    }

    # The executable regression harness uses small PowerShell fake shells.
    # Production SSH.NET ShellStream instances always take the byte[] path
    # above; a fake must explicitly expose an equally bounded read operation.
    if ($env:PALWORLD_CLIENT_TEST_MODE -and
        $Shell.PSObject.Methods["ReadPalworldBoundedUtf8"]) {
        $result = $Shell.ReadPalworldBoundedUtf8($MaximumBytes)
        $bytesRead = [int]$result.BytesRead
        if ($bytesRead -lt 0 -or $bytesRead -gt $MaximumBytes) {
            throw "The SSH test stream exceeded its bounded read budget."
        }
        return [pscustomobject]@{
            BytesRead = $bytesRead
            Text = [string]$result.Text
        }
    }
    throw "SSH stream does not support bounded byte reads. Reconnect and try again."
}

function Reset-PalworldSshShellUtf8Decoder {
    param([Parameter(Mandatory = $true)]$Shell)
    if ($Shell -is [IO.Stream]) {
        [Palworld.ServerManager.BoundedUtf8ShellReader]::Reset([IO.Stream]$Shell)
    }
    elseif ($env:PALWORLD_CLIENT_TEST_MODE -and
        $Shell.PSObject.Methods["ResetPalworldUtf8Decoder"]) {
        $Shell.ResetPalworldUtf8Decoder()
    }
}

function Read-PalworldSshAvailableUtf8 {
    param(
        [Parameter(Mandatory = $true)]$Shell,
        [ValidateRange(1024, 65536)][int]$TotalByteLimit = 65536,
        [ValidateRange(1024, 65536)][int]$PerReadByteLimit = 16384,
        [ValidateRange(1, 64)][int]$MaximumReads = 4
    )
    $received = New-Object Text.StringBuilder
    $totalBytesRead = 0
    $readCount = 0
    while ($Shell.DataAvailable -and
        $readCount -lt $MaximumReads -and
        $totalBytesRead -lt $TotalByteLimit) {
        $nextBudget = [Math]::Min(
            $PerReadByteLimit,
            $TotalByteLimit - $totalBytesRead
        )
        $readResult = Read-PalworldSshShellUtf8 `
            -Shell $Shell `
            -MaximumBytes $nextBudget
        if ($readResult.BytesRead -le 0) { break }
        $totalBytesRead += [int]$readResult.BytesRead
        $readCount++
        if ($readResult.Text) { [void]$received.Append([string]$readResult.Text) }
    }
    return [pscustomobject]@{
        BytesRead = $totalBytesRead
        ReadCount = $readCount
        Text = $received.ToString()
    }
}

function Clear-PalworldSshAvailableOutput {
    param(
        [Parameter(Mandatory = $true)]$Shell,
        [ValidateRange(1024, 65536)][int]$MaximumBytes = 65536,
        [ValidateRange(1, 2000)][int]$MaximumMilliseconds = 150,
        [ValidateRange(0, 1000)][int]$QuietMilliseconds = 0
    )
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $quietSince = [Diagnostics.Stopwatch]::StartNew()
    $totalBytesRead = 0
    while ($watch.ElapsedMilliseconds -lt $MaximumMilliseconds -and
        $totalBytesRead -lt $MaximumBytes) {
        if ($Shell.DataAvailable) {
            $nextBudget = [Math]::Min(16384, $MaximumBytes - $totalBytesRead)
            $readResult = Read-PalworldSshShellUtf8 `
                -Shell $Shell `
                -MaximumBytes $nextBudget
            if ($readResult.BytesRead -le 0) { break }
            $totalBytesRead += [int]$readResult.BytesRead
            $quietSince.Restart()
            continue
        }
        if ($QuietMilliseconds -eq 0 -or
            $quietSince.ElapsedMilliseconds -ge $QuietMilliseconds) {
            break
        }
        Start-Sleep -Milliseconds 20
    }
    $hasRemaining = $false
    try { $hasRemaining = [bool]$Shell.DataAvailable } catch { }
    # Only discard decoder state after the stream was observed quiet before
    # either bound.  If the byte cap was hit, an incomplete UTF-8 sequence can
    # still be waiting in SSH.NET's buffer and must remain associated with it.
    if (-not $hasRemaining -and $totalBytesRead -lt $MaximumBytes) {
        Reset-PalworldSshShellUtf8Decoder -Shell $Shell
    }
    return [pscustomobject]@{
        BytesRead = $totalBytesRead
        HasRemaining = $hasRemaining
    }
}

function ConvertTo-PalworldManagedWorkDirectory {
    param([Parameter(Mandatory = $true)][string]$Value)
    $candidate = $Value.Trim().TrimEnd('/')
    if (-not $candidate) { throw "Management directory is required." }
    if ($candidate -eq "~") {
        $project = "~/palworld-docker"
    }
    elseif ($candidate -match '(?:^|/)palworld-docker$') {
        $project = $candidate
    }
    else {
        $project = "$candidate/palworld-docker"
    }
    if (-not (Test-PalworldWorkDirectory $project)) {
        throw "Choose a safe ~ or absolute parent directory. The app uses its palworld-docker child directory."
    }
    return $project
}

function New-AdminSshConnection {
    param(
        [string]$Name = "",
        [string]$SshHost = "",
        [int]$Port = 22,
        [string]$Username = "",
        [ValidateSet("Password", "PrivateKey")][string]$AuthMode = "Password",
        [string]$Password = "",
        [string]$PrivateKeyPath = "",
        [string]$PrivateKeyPassphrase = "",
        [string]$SudoPassword = "",
        [string]$WorkDirectory = "~/palworld-docker",
        [string]$HostKeyFingerprint = "",
        [string]$LastUsedApiConnectionId = "",
        [string]$LastSelectedServer = ""
    )
    return [pscustomobject]@{
        Id = [Guid]::NewGuid().ToString("N")
        Name = $Name
        Host = $SshHost
        Port = $Port
        Username = $Username
        AuthMode = $AuthMode
        Password = $Password
        PrivateKeyPath = $PrivateKeyPath
        PrivateKeyPassphrase = $PrivateKeyPassphrase
        SudoPassword = $SudoPassword
        WorkDirectory = $WorkDirectory
        HostKeyFingerprint = $HostKeyFingerprint
        LastUsedApiConnectionId = $LastUsedApiConnectionId
        LastSelectedServer = $LastSelectedServer
    }
}

function Open-PalworldSshPrivateKeyFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [AllowEmptyString()][string]$Passphrase = ""
    )
    Initialize-PalworldSshRuntime
    $resolved = [IO.Path]::GetFullPath($Path.Trim())
    if (-not (Test-Path -LiteralPath $resolved -PathType Leaf)) {
        throw "SSH private key file was not found: $resolved"
    }
    try {
        if ($Passphrase) {
            return [Renci.SshNet.PrivateKeyFile]::new($resolved, $Passphrase)
        }
        return [Renci.SshNet.PrivateKeyFile]::new($resolved)
    }
    catch {
        throw "SSH private key file could not be opened. Check its format and passphrase: $([string]$_.Exception.Message)"
    }
}

function Get-SelectedAdminApiConnection {
    if (-not $script:AdminSelectedId) { return $null }
    return $script:AdminConnections |
        Where-Object { $_.Id -eq $script:AdminSelectedId } |
        Select-Object -First 1
}

function Get-LinkedSshConnection {
    param([AllowNull()]$ApiConnection)
    if ($null -eq $ApiConnection -or -not [string]$ApiConnection.SshConnectionId) { return $null }
    return $script:AdminSshConnections |
        Where-Object { $_.Id -eq [string]$ApiConnection.SshConnectionId } |
        Select-Object -First 1
}

function Get-PalworldSshConnectionById {
    param([AllowEmptyString()][string]$Id)
    if (-not $Id) { return $null }
    return $script:AdminSshConnections |
        Where-Object { [string]$_.Id -eq $Id } |
        Select-Object -First 1
}

function Get-PalworldLinkedApiConnections {
    param([AllowNull()]$SshConnection)
    if ($null -eq $SshConnection) { return @() }
    return @(
        $script:AdminConnections | Where-Object {
            [string]$_.SshConnectionId -eq [string]$SshConnection.Id
        }
    )
}

function Get-PalworldPreferredApiConnectionForSsh {
    param([AllowNull()]$SshConnection)
    $linked = @(Get-PalworldLinkedApiConnections $SshConnection)
    if ($linked.Count -eq 0) { return $null }
    $recent = $linked | Where-Object {
        [string]$_.Id -eq [string]$SshConnection.LastUsedApiConnectionId
    } | Select-Object -First 1
    if ($recent) { return $recent }
    return $linked[0]
}

function Set-PalworldApiSshLink {
    param(
        [Parameter(Mandatory = $true)]$ApiConnection,
        [AllowEmptyString()][string]$SshConnectionId
    )
    $newSsh = Get-PalworldSshConnectionById $SshConnectionId
    if ($SshConnectionId -and $null -eq $newSsh) {
        throw "The selected SSH Connection no longer exists."
    }
    $oldSsh = Get-PalworldSshConnectionById ([string]$ApiConnection.SshConnectionId)
    $ApiConnection.SshConnectionId = if ($newSsh) { [string]$newSsh.Id } else { "" }
    if ($oldSsh -and [string]$oldSsh.Id -ne [string]$ApiConnection.SshConnectionId -and
        [string]$oldSsh.LastUsedApiConnectionId -eq [string]$ApiConnection.Id) {
        $replacement = Get-PalworldPreferredApiConnectionForSsh $oldSsh
        $oldSsh.LastUsedApiConnectionId = if ($replacement) { [string]$replacement.Id } else { "" }
    }
    if ($newSsh) { $newSsh.LastUsedApiConnectionId = [string]$ApiConnection.Id }
}

function Get-PalworldManagedApiConnection {
    param(
        [Parameter(Mandatory = $true)]$SshConnection,
        [Parameter(Mandatory = $true)][string]$Server
    )
    Assert-PalworldServerName $Server
    return @(
        $script:AdminConnections | Where-Object {
            [string]$_.SshConnectionId -eq [string]$SshConnection.Id -and
            [string]$_.ManagedServerName -eq $Server
        }
    ) | Select-Object -First 1
}

function Set-PalworldManagedApiConnection {
    param(
        [Parameter(Mandatory = $true)]$SshConnection,
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)]$Settings,
        [ValidateSet("Full", "Token")][string]$Mode = "Full"
    )
    Assert-PalworldServerName $Server
    $apiName = "$([string]$SshConnection.Name) - $Server"
    $mappedConnections = @(
        $script:AdminConnections | Where-Object {
            [string]$_.SshConnectionId -eq [string]$SshConnection.Id -and
            [string]$_.ManagedServerName -eq $Server
        }
    )
    if ($mappedConnections.Count -gt 1) {
        throw "Multiple Server API Connections are mapped to $([string]$SshConnection.Name) / $Server."
    }
    $api = if ($mappedConnections.Count -eq 1) { $mappedConnections[0] } else { $null }
    if ($null -eq $api) {
        $legacy = @(
            $script:AdminConnections | Where-Object {
                -not [string]$_.ManagedServerName -and
                [string]$_.SshConnectionId -eq [string]$SshConnection.Id -and
                [string]$_.ServerHost -ieq [string]$Settings.ServerHost -and
                [int]$_.Port -eq [int]$Settings.Port
            }
        )
        if ($legacy.Count -eq 1) { $api = $legacy[0] }
    }
    if ($null -eq $api) {
        $sameName = @(
            $script:AdminConnections | Where-Object { [string]$_.Name -ieq $apiName }
        )
        $sameNameSshId = if ($sameName.Count -eq 1) {
            [string]$sameName[0].SshConnectionId
        }
        else { "" }
        if ($sameName.Count -eq 1 -and -not [string]$sameName[0].ManagedServerName -and
            $sameNameSshId -in @("", [string]$SshConnection.Id)) {
            $api = $sameName[0]
        }
        elseif ($sameName.Count -gt 0) {
            throw "A different Server API Connection already uses the required name: $apiName"
        }
    }
    $created = $false
    if ($null -eq $api) {
        $api = New-AdminConnection `
            -Name $apiName `
            -ServerHost ([string]$Settings.ServerHost) `
            -Port ([int]$Settings.Port) `
            -Username ([string]$Settings.Username) `
            -Password ([string]$Settings.Password) `
            -AccessToken ([string]$Settings.AccessToken) `
            -SshConnectionId ([string]$SshConnection.Id) `
            -ManagedServerName $Server
        $script:AdminConnections = @($script:AdminConnections) + @($api)
        $created = $true
    }
    if ($api.PSObject.Properties.Name -notcontains "ManagedServerName") {
        $api | Add-Member -MemberType NoteProperty -Name ManagedServerName -Value ""
    }
    $api.ManagedServerName = $Server
    if ($created) {
        $api.Name = $apiName
    }
    if ($Mode -eq "Full" -or $created) {
        # A mapped HTTPS endpoint may be a reverse proxy with its own host and
        # listener port. Preserve that explicit operator choice when SSH sync
        # refreshes origin credentials and token after Setup/Update/ENV Apply.
        $usesCustomTlsEndpoint = -not $created -and
            [string]$api.ServerHost -match '^(?i)https://'
        if (-not $usesCustomTlsEndpoint) {
            $api.ServerHost = [string]$Settings.ServerHost
            $api.Port = [int]$Settings.Port
        }
        $api.Username = [string]$Settings.Username
        $api.Password = [string]$Settings.Password
    }
    $api.AccessToken = [string]$Settings.AccessToken
    Set-PalworldApiSshLink -ApiConnection $api -SshConnectionId ([string]$SshConnection.Id)
    Set-ActiveAdminConnection $api
    if ($script:AdminRefreshApiConnections) {
        & $script:AdminRefreshApiConnections ([string]$api.Id)
    }
    Update-PalworldSshApiLinkStatus
    Save-AdminConnectionStore
    return [pscustomobject]@{
        Connection = $api
        Created = $created
    }
}

function Remove-PalworldManagedApiConnections {
    param(
        [Parameter(Mandatory = $true)]$SshConnection,
        [AllowEmptyString()][string]$Server = ""
    )
    if ($Server) { Assert-PalworldServerName $Server }
    $targets = @(
        $script:AdminConnections | Where-Object {
            [string]$_.SshConnectionId -eq [string]$SshConnection.Id -and
            [string]$_.ManagedServerName -and
            (-not $Server -or [string]$_.ManagedServerName -eq $Server)
        }
    )
    if ($targets.Count -eq 0) { return @() }
    $removedIds = @{}
    foreach ($target in $targets) { $removedIds[[string]$target.Id] = $true }
    $script:AdminConnections = @(
        $script:AdminConnections | Where-Object { -not $removedIds.ContainsKey([string]$_.Id) }
    )
    foreach ($ssh in $script:AdminSshConnections) {
        if ($removedIds.ContainsKey([string]$ssh.LastUsedApiConnectionId)) {
            $replacement = Get-PalworldPreferredApiConnectionForSsh $ssh
            $ssh.LastUsedApiConnectionId = if ($replacement) { [string]$replacement.Id } else { "" }
        }
    }
    if ($removedIds.ContainsKey([string]$script:AdminSelectedId)) {
        $replacement = Get-PalworldPreferredApiConnectionForSsh $SshConnection
        Set-ActiveAdminConnection $replacement
    }
    if ($script:AdminRefreshApiConnections) {
        & $script:AdminRefreshApiConnections ([string]$script:AdminSelectedId)
    }
    Update-PalworldSshApiLinkStatus
    Save-AdminConnectionStore
    return @($targets | ForEach-Object { [string]$_.Name })
}

function Get-SelectedPalworldSshConnection {
    if (-not $script:PalworldSshConnectionCombo) { return $null }
    $index = $script:PalworldSshConnectionCombo.SelectedIndex - 1
    if ($index -lt 0 -or $index -ge $script:AdminSshConnections.Count) { return $null }
    return $script:AdminSshConnections[$index]
}

function Set-PalworldSshLastSelectedServer {
    param(
        [AllowNull()]$Connection,
        [AllowEmptyString()][string]$Server
    )
    if ($null -eq $Connection) { return }
    if ($Server -and $Server -notmatch '^server[1-9][0-9]*$') { return }
    if ($Connection.PSObject.Properties.Name -notcontains "LastSelectedServer") {
        $Connection | Add-Member -MemberType NoteProperty -Name LastSelectedServer -Value ""
    }
    if ([string]$Connection.LastSelectedServer -eq $Server) { return }
    $Connection.LastSelectedServer = $Server
    try { Save-AdminConnectionStore }
    catch { Add-PalworldSshOutput "`r`n[WARN] Last selected server could not be saved: $([string]$_.Exception.Message)`r`n" }
    if ($script:ResourceUsageRefreshContext) { & $script:ResourceUsageRefreshContext }
}

function Show-PalworldSshConnectionDialog {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [ValidateSet("Add", "Update")][string]$Mode,
        [AllowNull()]$Connection,
        [AllowNull()]$ApiConnection
    )
    if ($Mode -eq "Add") { $script:PalworldSshAddDialogOpened = $true }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = if ($Mode -eq "Add") {
        Get-PalworldLocalizedText "Add SSH Connection" "SSH 연결 추가"
    }
    else {
        Get-PalworldLocalizedText "Update SSH Connection" "SSH 연결 수정"
    }
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(610, 590)
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog

    $defaults = if ($Connection) { $Connection } else {
        [pscustomobject]@{
            Name = if ($ApiConnection) { [string]$ApiConnection.Name } else { "" }
            Host = if ($ApiConnection) { [string]$ApiConnection.ServerHost } else { "" }
            Port = 22; Username = ""; AuthMode = "Password"; Password = ""
            PrivateKeyPath = ""; PrivateKeyPassphrase = ""; SudoPassword = ""
            WorkDirectory = "~/palworld-docker"; HostKeyFingerprint = ""
        }
    }

    $labels = @(
        @{ Text = (Get-PalworldLocalizedText "Name" "이름"); Y = 18 },
        @{ Text = (Get-PalworldLocalizedText "SSH Host/IP" "SSH 호스트/IP"); Y = 68 },
        @{ Text = (Get-PalworldLocalizedText "SSH Port" "SSH 포트"); Y = 118 },
        @{ Text = (Get-PalworldLocalizedText "SSH Username" "SSH 사용자명"); Y = 168 },
        @{ Text = (Get-PalworldLocalizedText "Authentication" "인증 방식"); Y = 218 },
        @{ Text = (Get-PalworldLocalizedText "SSH Password" "SSH 비밀번호"); Y = 268 },
        @{ Text = (Get-PalworldLocalizedText "Private Key File" "개인 키 파일"); Y = 318 },
        @{ Text = (Get-PalworldLocalizedText "Key Passphrase" "키 암호"); Y = 368 },
        @{ Text = (Get-PalworldLocalizedText "Linux Sudo Password" "Linux sudo 비밀번호"); Y = 418 },
        @{ Text = (Get-PalworldLocalizedText "Management parent / project" "관리 상위/project 경로"); Y = 468 }
    )
    foreach ($item in $labels) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $item.Text
        $label.Location = New-Object System.Drawing.Point(16, $item.Y)
        $label.AutoSize = $true
        $dialog.Controls.Add($label)
    }

    function New-SshDialogTextBox([int]$y, [int]$width = 390) {
        $textBox = New-Object System.Windows.Forms.TextBox
        $textBox.Location = New-Object System.Drawing.Point(175, $y)
        $textBox.Size = New-Object System.Drawing.Size($width, 23)
        $dialog.Controls.Add($textBox)
        return $textBox
    }

    $nameText = New-SshDialogTextBox 15
    $nameText.Text = [string]$defaults.Name
    $hostText = New-SshDialogTextBox 65
    $hostText.Text = [string]$defaults.Host
    $portText = New-SshDialogTextBox 115 100
    $portText.Text = [string]$defaults.Port
    $usernameText = New-SshDialogTextBox 165
    $usernameText.Text = [string]$defaults.Username
    $authCombo = New-Object System.Windows.Forms.ComboBox
    $authCombo.Location = New-Object System.Drawing.Point(175, 215)
    $authCombo.Size = New-Object System.Drawing.Size(180, 23)
    $authCombo.DropDownStyle = "DropDownList"
    [void]$authCombo.Items.Add("Password")
    [void]$authCombo.Items.Add("Private Key File")
    $authCombo.SelectedItem = if ([string]$defaults.AuthMode -eq "PrivateKey") {
        "Private Key File"
    }
    else { "Password" }
    $dialog.Controls.Add($authCombo)
    $passwordText = New-SshDialogTextBox 265
    $passwordText.UseSystemPasswordChar = $true
    $passwordText.Text = [string]$defaults.Password
    $keyText = New-SshDialogTextBox 315 330
    $keyText.Text = [string]$defaults.PrivateKeyPath
    $browseButton = New-Object System.Windows.Forms.Button
    $browseButton.Text = "Browse"
    $browseButton.Location = New-Object System.Drawing.Point(515, 313)
    $browseButton.Size = New-Object System.Drawing.Size(70, 27)
    $dialog.Controls.Add($browseButton)
    $keyPassphraseText = New-SshDialogTextBox 365
    $keyPassphraseText.UseSystemPasswordChar = $true
    $keyPassphraseText.Text = [string]$defaults.PrivateKeyPassphrase
    $sudoText = New-SshDialogTextBox 415
    $sudoText.UseSystemPasswordChar = $true
    $sudoText.Text = [string]$defaults.SudoPassword
    $workDirectoryText = New-SshDialogTextBox 465
    $workDirectoryText.Text = [string]$defaults.WorkDirectory
    $workDirectoryPreview = New-Object System.Windows.Forms.Label
    $workDirectoryPreview.Location = New-Object System.Drawing.Point(175, 491)
    $workDirectoryPreview.Size = New-Object System.Drawing.Size(410, 20)
    $dialog.Controls.Add($workDirectoryPreview)
    $dialogToolTip = New-Object System.Windows.Forms.ToolTip
    $dialogToolTip.SetToolTip(
        $workDirectoryText,
        (Get-PalworldLocalizedText `
            "Default project: ~/palworld-docker. Enter a parent such as /srv to use /srv/palworld-docker. An existing full path ending in palworld-docker is also accepted." `
            "기본 project는 ~/palworld-docker입니다. /srv 같은 상위 경로를 입력하면 /srv/palworld-docker를 사용하며, palworld-docker로 끝나는 기존 전체 경로도 사용할 수 있습니다.")
    )
    $dialogToolTip.SetToolTip(
        $keyText,
        (Get-PalworldLocalizedText `
            "Select a local OpenSSH/PEM private key file. Encrypted keys also require the passphrase below." `
            "로컬 OpenSSH/PEM 개인 키 파일을 선택하세요. 암호화된 키는 아래 키 암호도 필요합니다.")
    )

    $showSecrets = New-Object System.Windows.Forms.CheckBox
    $showSecrets.Text = "Show passwords"
    $showSecrets.Location = New-Object System.Drawing.Point(373, 216)
    $showSecrets.AutoSize = $true
    $dialog.Controls.Add($showSecrets)
    $clearFingerprint = New-Object System.Windows.Forms.CheckBox
    $clearFingerprint.Text = if ([string]$defaults.HostKeyFingerprint) {
        Get-PalworldLocalizedText `
            "Forget trusted host key: $([string]$defaults.HostKeyFingerprint)" `
            "신뢰한 호스트 키 삭제: $([string]$defaults.HostKeyFingerprint)"
    }
    else {
        Get-PalworldLocalizedText "No trusted host key yet" "아직 신뢰한 호스트 키 없음"
    }
    $clearFingerprint.Location = New-Object System.Drawing.Point(16, 518)
    $clearFingerprint.Size = New-Object System.Drawing.Size(420, 22)
    $clearFingerprint.Enabled = [bool][string]$defaults.HostKeyFingerprint
    $dialog.Controls.Add($clearFingerprint)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(420, 550)
    $cancelButton.Size = New-Object System.Drawing.Size(80, 28)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)
    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = "Save"
    $saveButton.Location = New-Object System.Drawing.Point(505, 550)
    $saveButton.Size = New-Object System.Drawing.Size(80, 28)
    $dialog.Controls.Add($saveButton)

    $sshHostValidator = ${function:Test-PalworldSshHost}
    $workDirectoryNormalizer = ${function:ConvertTo-PalworldManagedWorkDirectory}
    $updateAuthControls = {
        $passwordMode = [string]$authCombo.SelectedItem -eq "Password"
        $passwordText.Enabled = $passwordMode
        $keyText.Enabled = -not $passwordMode
        $browseButton.Enabled = -not $passwordMode
        $keyPassphraseText.Enabled = -not $passwordMode
    }.GetNewClosure()
    $authCombo.Add_SelectedIndexChanged($updateAuthControls)
    & $updateAuthControls
    $showSecrets.Add_CheckedChanged({
        $hidden = -not $showSecrets.Checked
        $passwordText.UseSystemPasswordChar = $hidden
        $keyPassphraseText.UseSystemPasswordChar = $hidden
        $sudoText.UseSystemPasswordChar = $hidden
    }.GetNewClosure())
    $updateWorkDirectoryPreview = {
        try {
            $effective = & $workDirectoryNormalizer $workDirectoryText.Text
            $workDirectoryPreview.Text = Get-PalworldLocalizedText `
                "Actual project directory: $effective" `
                "실제 project 디렉터리: $effective"
            $workDirectoryPreview.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        catch {
            $workDirectoryPreview.Text = Get-PalworldLocalizedText `
                "Enter ~, a safe absolute parent, or a full palworld-docker path." `
                "~, 안전한 절대 상위 경로 또는 palworld-docker 전체 경로를 입력하세요."
            $workDirectoryPreview.ForeColor = [System.Drawing.Color]::DarkRed
        }
    }.GetNewClosure()
    $workDirectoryText.Add_TextChanged($updateWorkDirectoryPreview)
    & $updateWorkDirectoryPreview
    $browseButton.Add_Click({
        $picker = New-Object System.Windows.Forms.OpenFileDialog
        $picker.Title = Get-PalworldLocalizedText "Select SSH private key" "SSH 개인 키 선택"
        $picker.Filter = Get-PalworldLocalizedText `
            "SSH private keys|id_*;*.pem;*.key;*.ppk|All files|*.*" `
            "SSH 개인 키|id_*;*.pem;*.key;*.ppk|모든 파일|*.*"
        if ($picker.ShowDialog($dialog) -eq [System.Windows.Forms.DialogResult]::OK) {
            $keyText.Text = $picker.FileName
        }
        $picker.Dispose()
    }.GetNewClosure())
    $saveButton.Add_Click({
        try {
            $name = $nameText.Text.Trim()
            $hostValue = $hostText.Text.Trim()
            $username = $usernameText.Text.Trim()
            $port = 0
            if (-not $name) {
                throw (Get-PalworldLocalizedText "Name is required." "이름을 입력하세요.")
            }
            if (-not $hostValue -or -not (& $sshHostValidator $hostValue)) {
                throw (Get-PalworldLocalizedText `
                    "Enter only a valid SSH host or IP without a URL or shell characters." `
                    "URL이나 shell 문자를 제외한 올바른 SSH 호스트 또는 IP만 입력하세요.")
            }
            if (-not [int]::TryParse($portText.Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                throw (Get-PalworldLocalizedText `
                    "SSH port must be an integer between 1 and 65535." `
                    "SSH 포트는 1~65535 사이의 정수여야 합니다.")
            }
            if ($username -notmatch '^[A-Za-z_][A-Za-z0-9._-]*$') {
                throw (Get-PalworldLocalizedText `
                    "SSH Username contains unsupported characters." `
                    "SSH 사용자명에 지원하지 않는 문자가 있습니다.")
            }
            $authMode = if ([string]$authCombo.SelectedItem -eq "Private Key File") {
                "PrivateKey"
            }
            else { "Password" }
            if ($authMode -eq "Password" -and -not $passwordText.Text) {
                throw (Get-PalworldLocalizedText `
                    "SSH Password is required for password authentication." `
                    "비밀번호 인증에는 SSH 비밀번호가 필요합니다.")
            }
            if ($authMode -eq "PrivateKey") {
                $keyValidation = Open-PalworldSshPrivateKeyFile `
                    -Path $keyText.Text -Passphrase $keyPassphraseText.Text
                $keyValidation.Dispose()
            }
            if (-not $sudoText.Text) {
                throw (Get-PalworldLocalizedText `
                    "Sudo Password is required for automated management." `
                    "자동 관리에는 sudo 비밀번호가 필요합니다.")
            }
            $workDirectory = & $workDirectoryNormalizer $workDirectoryText.Text
            $dialog.Tag = [pscustomobject]@{
                Name = $name; Host = $hostValue; Port = $port; Username = $username
                AuthMode = $authMode; Password = $passwordText.Text
                PrivateKeyPath = $keyText.Text.Trim()
                PrivateKeyPassphrase = $keyPassphraseText.Text
                SudoPassword = $sudoText.Text; WorkDirectory = $workDirectory
                HostKeyFingerprint = if ($clearFingerprint.Checked) { "" } else { [string]$defaults.HostKeyFingerprint }
            }
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                [string]$_.Exception.Message,
                "SSH Connection",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
        }
    }.GetNewClosure())
    $dialog.AcceptButton = $saveButton
    $dialog.CancelButton = $cancelButton
    if ($env:PALWORLD_CLIENT_TEST_MODE -in @("ssh-dialog-events", "ssh-private-key-dialog")) {
        $nameText.Text = "Dialog Regression"
        $hostText.Text = "example.invalid"
        $portText.Text = "22"
        $usernameText.Text = "guest"
        if ($env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-private-key-dialog") {
            if (-not $env:PALWORLD_SSH_PRIVATE_KEY_TEST_PATH) {
                throw "The private-key dialog test requires PALWORLD_SSH_PRIVATE_KEY_TEST_PATH."
            }
            $authCombo.SelectedItem = "Private Key File"
            $keyText.Text = [string]$env:PALWORLD_SSH_PRIVATE_KEY_TEST_PATH
            $keyPassphraseText.Text = [string]$env:PALWORLD_SSH_PRIVATE_KEY_TEST_PASSPHRASE
        }
        else {
            $authCombo.SelectedItem = "Password"
            $passwordText.Text = "secret"
        }
        $sudoText.Text = "secret"
        $workDirectoryText.Text = "/home/guest/palworld-docker"
        $dialog.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $saveButton.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        $result = $dialog.Tag
        $dialog.Dispose()
        return $result
    }
    if ($env:PALWORLD_CLIENT_TEST_MODE -in @("ssh-dialog", "ssh-add")) {
        $bitmap = New-Object System.Drawing.Bitmap(610, 590)
        try { $dialog.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, 610, 590))) }
        finally { $bitmap.Dispose(); $dialog.Dispose() }
        return $null
    }
    try {
        if ($dialog.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.Tag }
        return $null
    }
    finally { $dialog.Dispose() }
}

function New-PalworldSshConnectionInfo {
    param([Parameter(Mandatory = $true)]$Connection)
    Initialize-PalworldSshRuntime
    $methods = New-Object System.Collections.Generic.List[Renci.SshNet.AuthenticationMethod]
    if ([string]$Connection.AuthMode -eq "PrivateKey") {
        $key = Open-PalworldSshPrivateKeyFile `
            -Path ([string]$Connection.PrivateKeyPath) `
            -Passphrase ([string]$Connection.PrivateKeyPassphrase)
        $keyMethod = New-Object Renci.SshNet.PrivateKeyAuthenticationMethod(
            [string]$Connection.Username,
            [Renci.SshNet.IPrivateKeySource[]]@($key)
        )
        $methods.Add($keyMethod)
    }
    else {
        $password = [string]$Connection.Password
        $passwordMethod = New-Object Renci.SshNet.PasswordAuthenticationMethod(
            [string]$Connection.Username,
            $password
        )
        $keyboardMethod = New-Object Renci.SshNet.KeyboardInteractiveAuthenticationMethod(
            [string]$Connection.Username
        )
        $promptResponder = New-Object Palworld.ServerManager.SshPasswordPromptResponder($password)
        $keyboardMethod.add_AuthenticationPrompt($promptResponder.Handler)
        $methods.Add($passwordMethod)
        $methods.Add($keyboardMethod)
    }
    $information = New-Object Renci.SshNet.ConnectionInfo(
        [string]$Connection.Host,
        [int]$Connection.Port,
        [string]$Connection.Username,
        [Renci.SshNet.AuthenticationMethod[]]$methods.ToArray()
    )
    $information.Timeout = [TimeSpan]::FromSeconds(15)
    return $information
}

function Connect-PalworldSshService {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [ValidateSet("Ssh", "Sftp")][string]$Kind = "Ssh",
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [ValidateRange(15, 1800)][int]$OperationTimeoutSeconds = 120,
        [switch]$AllowTrustPrompt
    )
    $information = New-PalworldSshConnectionInfo $Connection
    $client = if ($Kind -eq "Sftp") {
        New-Object Renci.SshNet.SftpClient($information)
    }
    else {
        New-Object Renci.SshNet.SshClient($information)
    }
    # Management and interactive terminal sessions are intentionally separate.
    # A long Setup/Manage operation can otherwise leave the terminal channel
    # idle long enough for a firewall, NAT device, or SSH server to drop it.
    # SSH.NET keepalives are tiny transport messages and do not execute a
    # remote command or add load to the game container.
    $client.KeepAliveInterval = [TimeSpan]::FromSeconds(30)
    if ($Kind -eq "Sftp") {
        $client.OperationTimeout = [TimeSpan]::FromSeconds($OperationTimeoutSeconds)
    }
    $expected = [string]$Connection.HostKeyFingerprint
    $hostKeyVerifier = New-Object Palworld.ServerManager.SshHostKeyVerifier($expected)
    $client.add_HostKeyReceived($hostKeyVerifier.Handler)
    $connectCancellation = New-Object Threading.CancellationTokenSource
    $connectTask = $null
    $deferredCleanup = $false
    try {
        $connectTask = $client.ConnectAsync($connectCancellation.Token)
        [void](Wait-PalworldSshTask `
            -Task $connectTask `
            -Cancellation $connectCancellation `
            -Operation "$Kind connection" `
            -TimeoutSeconds 15)
        return $client
    }
    catch {
        $errorMessage = [string]$_.Exception.Message
        $observed = [string]$hostKeyVerifier.Fingerprint
        $algorithm = [string]$hostKeyVerifier.Algorithm
        if ($connectTask -and -not $connectTask.IsCompleted) {
            [Palworld.ServerManager.AsyncTaskCleanup]::ObserveAndDispose(
                $connectTask,
                [object[]]@($client, $connectCancellation)
            )
            $deferredCleanup = $true
        }
        else {
            try { $client.Dispose() } catch { }
        }
        if ($script:PalworldSshClosing -or $script:PalworldSshCancelRequested) {
            throw [OperationCanceledException]::new("$Kind connection was canceled while closing or canceling the operation.")
        }
        if ($expected -and $observed -and $expected -ne $observed) {
            throw "SSH host key changed. Connection blocked.`r`nSaved: $expected`r`nReceived: $observed"
        }
        if (-not $expected -and $observed -and $AllowTrustPrompt) {
            $answer = [System.Windows.Forms.MessageBox]::Show(
                "Trust this SSH host key?`r`n`r`nHost: $([string]$Connection.Host):$([int]$Connection.Port)`r`nAlgorithm: $algorithm`r`nFingerprint: $observed`r`n`r`nVerify this fingerprint with the server administrator before continuing.",
                "SSH host key verification",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            )
            if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
                throw "SSH host key was not trusted."
            }
            $Connection.HostKeyFingerprint = $observed
            Save-AdminConnectionStore
            return Connect-PalworldSshService `
                -Connection $Connection `
                -Kind $Kind `
                -Owner $Owner
        }
        throw "SSH connection failed: $errorMessage"
    }
    finally {
        if (-not $deferredCleanup) {
            try { $connectCancellation.Dispose() } catch { }
        }
    }
}

function Add-PalworldSshOutputToControl {
    param(
        [AllowNull()][System.Windows.Forms.RichTextBox]$Control,
        [AllowEmptyString()][string]$Text,
        [ValidateSet("Management", "Terminal")][string]$Channel,
        [switch]$TerminalStream
    )
    if ($script:PalworldSshClosing -or -not $Control -or $Control.IsDisposed -or -not $Text) { return }
    $clean = $Text
    if ($TerminalStream) {
        Initialize-PalworldSshRuntime
        if ($Channel -eq "Management") {
            if (-not $script:PalworldSshManagementSanitizer) {
                $script:PalworldSshManagementSanitizer = New-Object Palworld.ServerManager.TerminalStreamSanitizer
            }
            $clean = $script:PalworldSshManagementSanitizer.Filter($Text)
        }
        else {
            if (-not $script:PalworldSshTerminalSanitizer) {
                $script:PalworldSshTerminalSanitizer = New-Object Palworld.ServerManager.TerminalStreamSanitizer
            }
            $clean = $script:PalworldSshTerminalSanitizer.Filter($Text)
        }
    }
    if ($script:PalworldSshCurrentConnection) {
        foreach ($secret in @(
            [string]$script:PalworldSshCurrentConnection.Password,
            [string]$script:PalworldSshCurrentConnection.PrivateKeyPassphrase,
            [string]$script:PalworldSshCurrentConnection.SudoPassword
        )) {
            if ($secret) { $clean = $clean.Replace($secret, "[hidden]") }
        }
    }
    # Normal command output is overwhelmingly plain text with CRLF line endings.
    # Append it as one chunk; only use the character-level terminal emulation
    # path when the stream actually contains backspace, bare CR, bell, or other
    # control characters.
    $requiresControlProcessing = [Text.RegularExpressions.Regex]::IsMatch(
        $clean,
        '[\x00-\x08\x0B\x0C\x0E-\x1F]|\r(?!\n)'
    )
    if (-not $requiresControlProcessing) {
        $Control.AppendText($clean)
    }
    else {
        $literal = New-Object Text.StringBuilder
        $flushLiteral = {
            if ($literal.Length -gt 0) {
                $Control.AppendText($literal.ToString())
                [void]$literal.Clear()
            }
        }
        for ($index = 0; $index -lt $clean.Length; $index++) {
            $value = $clean[$index]
            $codePoint = [int][char]$value
            if ($codePoint -eq 8) {
                & $flushLiteral
                if ($Control.TextLength -gt 0) {
                    $Control.Select($Control.TextLength - 1, 1)
                    $last = $Control.SelectedText[0]
                    $lastCodePoint = [int][char]$last
                    if ($lastCodePoint -ne 13 -and $lastCodePoint -ne 10) {
                        $wasReadOnly = $Control.ReadOnly
                        try {
                            if ($wasReadOnly) { $Control.ReadOnly = $false }
                            $Control.SelectedText = [string]::Empty
                        }
                        finally {
                            if ($wasReadOnly) { $Control.ReadOnly = $true }
                        }
                    }
                }
            }
            elseif ($codePoint -eq 13) {
                if ($index + 1 -lt $clean.Length -and [int][char]$clean[$index + 1] -eq 10) {
                    [void]$literal.Append("`r`n")
                    $index++
                }
                else {
                    & $flushLiteral
                    $lineIndex = $Control.GetLineFromCharIndex($Control.TextLength)
                    $lineStart = $Control.GetFirstCharIndexFromLine($lineIndex)
                    if ($lineStart -lt 0) { $lineStart = 0 }
                    $Control.Select($lineStart, $Control.TextLength - $lineStart)
                    $wasReadOnly = $Control.ReadOnly
                    try {
                        if ($wasReadOnly) { $Control.ReadOnly = $false }
                        $Control.SelectedText = [string]::Empty
                    }
                    finally {
                        if ($wasReadOnly) { $Control.ReadOnly = $true }
                    }
                }
            }
            elseif ($codePoint -eq 7 -or ($codePoint -lt 32 -and $codePoint -notin @(9, 10))) {
                continue
            }
            else {
                [void]$literal.Append($value)
            }
        }
        & $flushLiteral
    }
    if ($Control.TextLength -gt 2000000) {
        $removeLength = $Control.TextLength - 1800000
        $nextLine = $Control.Text.IndexOf("`n", $removeLength)
        # Prefer a line boundary, but never discard nearly all retained output
        # merely because a command or JSON response contains one very long line.
        $latestSafeCut = $Control.TextLength - 1000000
        $cutStart = if ($nextLine -ge 0 -and $nextLine -le $latestSafeCut) {
            $nextLine + 1
        }
        else { $removeLength }
        $trimNotice = "[INFO] Earlier $Channel output was trimmed to keep the UI responsive.`r`n"
        $Control.Text = $trimNotice + $Control.Text.Substring($cutStart)
    }
    Scroll-PalworldSshOutputToBottom -Control $Control
}

function Get-PalworldCompleteStreamPrefixLength {
    param(
        [AllowEmptyString()][string]$Text,
        [ValidateRange(0, [int]::MaxValue)][int]$SafeLength
    )
    $limit = [Math]::Min($SafeLength, $Text.Length)
    for ($index = $limit - 1; $index -ge 0; $index--) {
        $codePoint = [int][char]$Text[$index]
        if ($codePoint -eq 10) { return $index + 1 }
        if ($codePoint -eq 13) {
            if ($index + 1 -ge $Text.Length) { continue }
            if ([int][char]$Text[$index + 1] -eq 10) {
                if ($index + 1 -ge $limit) { continue }
                return $index + 2
            }
            return $index + 1
        }
    }
    return 0
}

function Get-PalworldSshVisibleFlushPrefixLength {
    param(
        [AllowEmptyString()][string]$Text,
        [ValidateRange(0, [int]::MaxValue)][int]$HoldLength,
        [ValidateRange(1024, [int]::MaxValue)][int]$MaximumBufferedLength = 65536
    )
    if (-not $Text -or $Text.Length -le $HoldLength) { return 0 }
    $safeLength = $Text.Length - $HoldLength
    $completeLength = Get-PalworldCompleteStreamPrefixLength `
        -Text $Text -SafeLength $safeLength
    if ($completeLength -gt 0) { return $completeLength }
    if ($Text.Length -le $MaximumBufferedLength) { return 0 }

    # A command can legitimately emit a very long line (for example JSON).
    # Flush the safe prefix even without a newline, but do not split a UTF-16
    # surrogate pair. The held suffix still protects split secrets/markers.
    $forcedLength = $safeLength
    if ($forcedLength -gt 0 -and $forcedLength -lt $Text.Length -and
        [char]::IsHighSurrogate($Text[$forcedLength - 1]) -and
        [char]::IsLowSurrogate($Text[$forcedLength])) {
        $forcedLength--
    }
    return $forcedLength
}

function Scroll-PalworldSshOutputToBottom {
    param([AllowNull()][System.Windows.Forms.RichTextBox]$Control)
    if (-not $Control -or $Control.IsDisposed) { return }
    if (-not $Control.IsHandleCreated) { [void]$Control.Handle }
    $Control.SelectionStart = $Control.TextLength
    $Control.SelectionLength = 0
    $Control.ScrollToCaret()
    Initialize-PalworldSshRuntime
    [Palworld.ServerManager.RichTextBoxScrollHelper]::ScrollToBottom(
        $Control.Handle,
        $Control.TextLength
    )
    $Control.Update()
}

function Set-PalworldSshWorkDirectoryStatus {
    param(
        [ValidateSet(
            "Unknown", "Checking", "Creating", "Preparing", "Ready", "Missing",
            "Unwritable", "NeedPrepare", "NeedCommonReview", "ReadyForHostCheck", "Failed"
        )]
        [string]$State,
        [AllowEmptyString()][string]$Path = ""
    )
    if ($script:PalworldSshClosing -or -not $script:PalworldSshWorkDirectoryStatus -or
        $script:PalworldSshWorkDirectoryStatus.IsDisposed) { return }
    switch ($State) {
        "Checking" {
            $text = Get-PalworldLocalizedText "Work dir · checking host and project path..." "작업 디렉터리 · 호스트와 project 경로 확인 중..."
            $color = [System.Drawing.Color]::DarkOrange
        }
        { $_ -in @("Creating", "Preparing") } {
            $text = Get-PalworldLocalizedText "Preparation · preparing project files..." "준비 상태 · 프로젝트 파일 준비 중..."
            $color = [System.Drawing.Color]::DarkOrange
        }
        "Ready" {
            $text = Get-PalworldLocalizedText "[PASS] Host ready for Automated Management" "[PASS] 자동 관리 준비 완료"
            $color = [System.Drawing.Color]::DarkGreen
        }
        "Missing" {
            $text = Get-PalworldLocalizedText "[ACTION REQUIRED] Select Prepare Work Dir" "[조치 필요] 작업 디렉터리 준비를 선택하세요"
            $color = [System.Drawing.Color]::DarkRed
        }
        "Unwritable" {
            $text = Get-PalworldLocalizedText "[ACTION REQUIRED] Select Prepare Work Dir to repair access" "[조치 필요] 작업 디렉터리 준비로 권한을 복구하세요"
            $color = [System.Drawing.Color]::DarkRed
        }
        "NeedPrepare" {
            $text = Get-PalworldLocalizedText "[ACTION REQUIRED] Select Prepare Work Dir" "[조치 필요] 작업 디렉터리 준비를 선택하세요"
            $color = [System.Drawing.Color]::DarkRed
        }
        "NeedCommonReview" {
            $text = Get-PalworldLocalizedText "[ACTION REQUIRED] Select Review Common Settings" "[조치 필요] 공통 설정 검토를 선택하세요"
            $color = [System.Drawing.Color]::DarkRed
        }
        "ReadyForHostCheck" {
            $text = Get-PalworldLocalizedText "[READY] Common Settings confirmed · run Host Check" "[준비됨] 공통 설정 확인 완료 · 호스트 검사를 실행하세요"
            $color = [System.Drawing.Color]::DarkOrange
        }
        "Failed" {
            $text = Get-PalworldLocalizedText "[FAIL] Preparation status unavailable · reconnect and retry" "[실패] 준비 상태 확인 불가 · 다시 연결한 뒤 재시도하세요"
            $color = [System.Drawing.Color]::DarkRed
        }
        default {
            $text = Get-PalworldLocalizedText "Preparation · not checked" "준비 상태 · 확인하지 않음"
            $color = [System.Drawing.Color]::DimGray
        }
    }
    $script:PalworldSshWorkDirectoryStatus.Text = $text
    $script:PalworldSshWorkDirectoryStatus.ForeColor = $color
    if ($script:PalworldSshToolTip) {
        $detail = if ($Path) {
            Get-PalworldLocalizedText "Actual project directory: $Path" "실제 project directory: $Path"
        }
        else { $text }
        $script:PalworldSshToolTip.SetToolTip($script:PalworldSshWorkDirectoryStatus, $detail)
    }
}

function Add-PalworldSshOutput {
    param(
        [AllowEmptyString()][string]$Text,
        [switch]$TerminalStream
    )
    Add-PalworldSshOutputToControl `
        -Control $script:PalworldSshOutput `
        -Text $Text `
        -Channel Management `
        -TerminalStream:$TerminalStream
}

function Add-PalworldSshTerminalOutput {
    param(
        [AllowEmptyString()][string]$Text,
        [switch]$TerminalStream
    )
    Add-PalworldSshOutputToControl `
        -Control $script:PalworldSshTerminalOutput `
        -Text $Text `
        -Channel Terminal `
        -TerminalStream:$TerminalStream
}

function Set-PalworldSshTerminalPasswordInputMode {
    param(
        [Parameter(Mandatory = $true)][bool]$Enabled,
        [AllowEmptyString()][string]$PromptSignature = ""
    )
    $script:PalworldSshTerminalPasswordMode = $Enabled
    $script:PalworldSshTerminalPasswordPromptSignature = if ($Enabled) {
        $PromptSignature
    }
    else { "" }
    if (-not $script:PalworldSshTerminalInput -or $script:PalworldSshTerminalInput.IsDisposed) {
        return
    }
    # Set both properties so a previous password prompt cannot leave this
    # otherwise ordinary command input masked after the secret is submitted.
    $script:PalworldSshTerminalInput.PasswordChar = [char]0
    $script:PalworldSshTerminalInput.UseSystemPasswordChar = $Enabled
    $script:PalworldSshTerminalInput.Invalidate()
}

function Get-PalworldSshTerminalPasswordPromptSignature {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return "" }
    $tailLength = [Math]::Min(500, $Text.Length)
    $tail = $Text.Substring($Text.Length - $tailLength)
    if ($tail -notmatch '(?is)(?:^|\r?\n)[^\r\n]{0,300}password(?:\s+for\s+[^:\r\n]+)?\s*:[ \t]*$') {
        return ""
    }
    # The whole tail is intentional: a retry has the same final prompt line,
    # but includes new failure output and therefore receives a new signature.
    return $tail
}

function Get-PalworldSshOutputTail {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.RichTextBox]$Control,
        [ValidateRange(1, 4096)][int]$MaximumLength = 500
    )
    if ($Control.IsDisposed -or $Control.TextLength -le 0) { return "" }
    $length = [Math]::Min($MaximumLength, $Control.TextLength)
    $Control.Select($Control.TextLength - $length, $length)
    $tail = [string]$Control.SelectedText
    # Output append already follows the latest data, so preserve that caret policy.
    $Control.Select($Control.TextLength, 0)
    return $tail
}

function Send-PalworldSshTerminalInput {
    if (-not $script:PalworldSshTerminalInput -or
        $script:PalworldSshTerminalInput.IsDisposed -or
        -not $script:PalworldSshTerminalInput.Text) { return }
    if (-not $script:PalworldSshShell) {
        if ($script:PalworldSshTerminalPasswordMode) {
            $script:PalworldSshTerminalInput.Clear()
        }
        Set-PalworldSshTerminalPasswordInputMode -Enabled $false
        if ($script:PalworldSshChannelTabs) { $script:PalworldSshChannelTabs.SelectedIndex = 1 }
        Add-PalworldSshTerminalOutput "`r`n[FAIL] Connect the SSH terminal first.`r`n"
        return
    }

    $inputText = [string]$script:PalworldSshTerminalInput.Text
    $wasPassword = [bool]$script:PalworldSshTerminalPasswordMode
    $promptSignature = [string]$script:PalworldSshTerminalPasswordPromptSignature
    $sent = $false
    try {
        $script:PalworldSshShell.WriteLine($inputText)
        $sent = $true
        if ($wasPassword) {
            Add-PalworldSshTerminalOutput "`r`n[SSH] Password submitted (hidden).`r`n"
        }
        else {
            # Shell echo can contain cursor-control sequences and may arrive
            # split at CR/LF boundaries.  This local line guarantees that the
            # exact command the user sent remains visible.
            Add-PalworldSshTerminalOutput "`r`n[INPUT] $inputText`r`n"
        }
    }
    catch {
        if ($wasPassword) {
            # Do not include an exception that could repeat the submitted
            # payload when the failed input was a secret.
            Add-PalworldSshTerminalOutput "`r`n[FAIL] SSH terminal password could not be sent. Reconnect and try again.`r`n"
        }
        else {
            Add-PalworldSshTerminalOutput "`r`n[FAIL] SSH terminal input could not be sent: $([string]$_.Exception.Message)`r`n"
        }
    }
    finally {
        $script:PalworldSshTerminalInput.Clear()
        if ($wasPassword) {
            $script:PalworldSshTerminalHandledPasswordPromptSignature = $promptSignature
        }
        Set-PalworldSshTerminalPasswordInputMode -Enabled $false
        if ($script:PalworldSshStatus -and -not $script:PalworldSshStatus.IsDisposed) {
            $script:PalworldSshStatus.Text = if ($sent) {
                Get-PalworldLocalizedText "Connected · management + terminal channels" "연결됨 · 관리 + 터미널 채널"
            }
            else { Get-PalworldLocalizedText "Connected · terminal input failed" "연결됨 · 터미널 입력 실패" }
            $script:PalworldSshStatus.ForeColor = if ($sent) {
                [System.Drawing.Color]::DarkGreen
            }
            else { [System.Drawing.Color]::DarkRed }
        }
    }
}

function New-PalworldThirdPartyPage {
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = "Licenses"
    $page.Padding = New-Object System.Windows.Forms.Padding(8)
    $text = New-Object System.Windows.Forms.RichTextBox
    $text.Dock = "Fill"
    $text.ReadOnly = $true
    $text.BackColor = [System.Drawing.SystemColors]::Window
    $text.Font = New-Object System.Drawing.Font("Consolas", 9)
    $text.WordWrap = $true
    $path = [string]$env:PALWORLD_THIRD_PARTY_PATH
    if (-not $path) { $path = Join-Path $PSScriptRoot "vendor\THIRD_PARTY.txt" }
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $text.Text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
    }
    else {
        $text.Text = "Third-party notices are missing. Rebuild Palworld Server Operations - Admin.exe."
    }
    $page.Controls.Add($text)
    return $page
}

function Invoke-PalworldSshOrphanCleanup {
    param([Parameter(Mandatory = $true)]$Client)
    $cleanupCommand = $null
    $cancellation = New-Object Threading.CancellationTokenSource
    $task = $null
    $deferredCleanup = $false
    try {
        $cleanup = @'
for d in $(find /tmp -regextype posix-extended -maxdepth 1 -type d -regex '/tmp/palworld-ssh-manager-[a-f0-9]{32}-(setup|test|manage)' -print); do [ -f "$d/.palworld-ssh-session" ] || continue; if find "$d/.palworld-ssh-session" -mmin +60 -print -quit | grep -q .; then rm -rf -- "$d"; fi; done
'@.Trim()
        $cleanupCommand = $Client.CreateCommand(
            (ConvertTo-PalworldUnixShellText -Command $cleanup)
        )
        $cleanupCommand.CommandTimeout = [TimeSpan]::FromSeconds(5)
        $task = $cleanupCommand.ExecuteAsync($cancellation.Token)
        $cancelCommand = { $cleanupCommand.CancelAsync($true, 100) }.GetNewClosure()
        [void](Wait-PalworldSshTask `
            -Task $task `
            -Cancellation $cancellation `
            -Operation "SSH temporary cleanup" `
            -TimeoutSeconds 5 `
            -OnCancel $cancelCommand)
    }
    catch { }
    finally {
        if ($task -and -not $task.IsCompleted -and $cleanupCommand) {
            Initialize-PalworldSshRuntime
            [Palworld.ServerManager.AsyncTaskCleanup]::ObserveAndDispose(
                $task,
                [object[]]@($cleanupCommand, $cancellation)
            )
            $deferredCleanup = $true
        }
        if (-not $deferredCleanup) {
            try { $cancellation.Cancel() } catch { }
            try { $cancellation.Dispose() } catch { }
            if ($cleanupCommand) { try { $cleanupCommand.Dispose() } catch { } }
        }
    }
}

function Disconnect-PalworldSshManagementSession {
    if ($script:PalworldSshAutomationShell) {
        try { Reset-PalworldSshShellUtf8Decoder -Shell $script:PalworldSshAutomationShell } catch { }
        try { $script:PalworldSshAutomationShell.Dispose() } catch { }
        $script:PalworldSshAutomationShell = $null
    }
    if ($script:PalworldSshClient) {
        try {
            if ($script:PalworldSshClient.IsConnected) { $script:PalworldSshClient.Disconnect() }
        } catch { }
        try { $script:PalworldSshClient.Dispose() } catch { }
        $script:PalworldSshClient = $null
    }
    if ($script:PalworldSshManagementSanitizer) { $script:PalworldSshManagementSanitizer.Reset() }
}

function Disconnect-PalworldSshTerminalSession {
    if ($script:PalworldSshTimer) { $script:PalworldSshTimer.Stop() }
    if ($script:PalworldSshShell) {
        try { Reset-PalworldSshShellUtf8Decoder -Shell $script:PalworldSshShell } catch { }
        try { $script:PalworldSshShell.Dispose() } catch { }
        $script:PalworldSshShell = $null
    }
    if ($script:PalworldSshTerminalClient) {
        try {
            if ($script:PalworldSshTerminalClient.IsConnected) { $script:PalworldSshTerminalClient.Disconnect() }
        } catch { }
        try { $script:PalworldSshTerminalClient.Dispose() } catch { }
        $script:PalworldSshTerminalClient = $null
    }
    if ($script:PalworldSshTerminalSanitizer) { $script:PalworldSshTerminalSanitizer.Reset() }
    $script:PalworldSshTerminalHandledPasswordPromptSignature = ""
    Set-PalworldSshTerminalPasswordInputMode -Enabled $false
    if ($script:PalworldSshStatus) {
        $script:PalworldSshStatus.Text = Get-PalworldLocalizedText "Disconnected" "연결 끊김"
        $script:PalworldSshStatus.ForeColor = [System.Drawing.Color]::DarkRed
    }
}

function Stop-PalworldSshTerminalAfterTransportFailure {
    param([AllowEmptyString()][string]$Reason = "")

    # This function runs from a WinForms Timer event while a management command
    # may be inside Application.DoEvents().  Nothing from a failed, independent
    # terminal channel is allowed to escape that event and open the framework's
    # unhandled-exception dialog or cancel the management operation.
    try {
        if ($script:PalworldSshTimer) {
            try { $script:PalworldSshTimer.Stop() } catch { }
        }
        $terminalTargets = [object[]]@(
            $script:PalworldSshShell,
            $script:PalworldSshTerminalClient
        )
        $script:PalworldSshShell = $null
        $script:PalworldSshTerminalClient = $null
        if ($script:PalworldSshTerminalSanitizer) {
            try { $script:PalworldSshTerminalSanitizer.Reset() } catch { }
        }
        $script:PalworldSshTerminalHandledPasswordPromptSignature = ""
        try { Set-PalworldSshTerminalPasswordInputMode -Enabled $false } catch { }

        $disposableTargets = [object[]]@($terminalTargets | Where-Object { $null -ne $_ })
        if ($disposableTargets.Count -gt 0) {
            try {
                Initialize-PalworldSshRuntime
                [Palworld.ServerManager.BackgroundDisposer]::Queue($disposableTargets)
            }
            catch { }
        }

        $safeReason = ([string]$Reason -replace '[\r\n]+', ' ').Trim()
        if ($safeReason.Length -gt 300) { $safeReason = $safeReason.Substring(0, 300) }
        $operationSuffix = if ($script:PalworldSshOperationRunning) {
            " The current SSH Management operation continues on its separate channel."
        }
        else { "" }
        try {
            Add-PalworldSshTerminalOutput (
                "`r`n[WARN] SSH Terminal channel disconnected" +
                $(if ($safeReason) { ": $safeReason" } else { "." }) +
                "$operationSuffix Use Reconnect after the current operation finishes.`r`n"
            )
        }
        catch { }
        if ($script:PalworldSshStatus -and -not $script:PalworldSshStatus.IsDisposed) {
            $script:PalworldSshStatus.Text = if ($script:PalworldSshOperationRunning) {
                Get-PalworldLocalizedText "Management operation continues · terminal disconnected" "관리 작업 계속 진행 중 · 터미널 연결 끊김"
            }
            else { Get-PalworldLocalizedText "Management connected · terminal disconnected · use Reconnect" "관리 채널 연결됨 · 터미널 연결 끊김 · Reconnect를 사용하세요" }
            $script:PalworldSshStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        }
    }
    catch {
        # Last-resort containment for a UI timer callback.  The next Reconnect
        # recreates the terminal session; management state remains untouched.
        try { if ($script:PalworldSshTimer) { $script:PalworldSshTimer.Stop() } } catch { }
        $script:PalworldSshShell = $null
        $script:PalworldSshTerminalClient = $null
    }
}

function Disconnect-PalworldSshSession {
    Disconnect-PalworldSshManagementSession
    Disconnect-PalworldSshTerminalSession
    $script:PalworldSshHostReadyForManagement = $false
    Set-PalworldSshWorkDirectoryStatus -State Unknown
    if ($script:ResourceUsageRefreshContext) {
        try { & $script:ResourceUsageRefreshContext } catch { }
    }
}

function Stop-PalworldSshUiForExit {
    if ($script:PalworldSshClosing) { return }
    $script:PalworldSshClosing = $true
    $script:PalworldSshCancelRequested = $true
    $script:PalworldSshOperationRunning = $false
    $script:PalworldSshPinnedConnectionId = ""
    if ($script:PalworldSshTimer) {
        try { $script:PalworldSshTimer.Stop() } catch { }
        try { $script:PalworldSshTimer.Dispose() } catch { }
        $script:PalworldSshTimer = $null
    }
    $targets = [object[]]@(
        $script:PalworldSshAutomationShell,
        $script:PalworldSshShell,
        $script:PalworldSshClient,
        $script:PalworldSshTerminalClient
    )
    $script:PalworldSshAutomationShell = $null
    $script:PalworldSshShell = $null
    $script:PalworldSshClient = $null
    $script:PalworldSshTerminalClient = $null
    if ($script:PalworldSshManagementSanitizer) {
        try { $script:PalworldSshManagementSanitizer.Reset() } catch { }
    }
    if ($script:PalworldSshTerminalSanitizer) {
        try { $script:PalworldSshTerminalSanitizer.Reset() } catch { }
    }
    $disposableTargets = [object[]]@($targets | Where-Object { $null -ne $_ })
    if ($disposableTargets.Count -gt 0) {
        Initialize-PalworldSshRuntime
        [Palworld.ServerManager.BackgroundDisposer]::Queue($disposableTargets)
    }
}

function Connect-PalworldSshManagementSession {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    if ($script:PalworldSshClient -and $script:PalworldSshClient.IsConnected) { return }
    Disconnect-PalworldSshManagementSession
    $script:PalworldSshCurrentConnection = $Connection
    $script:PalworldSshClient = Connect-PalworldSshService `
        -Connection $Connection `
        -Owner $Owner `
        -AllowTrustPrompt
    Invoke-PalworldSshOrphanCleanup -Client $script:PalworldSshClient
    Add-PalworldSshOutput "`r`n[SSH] Management channel connected: $([string]$Connection.Name).`r`n"
}

function Connect-PalworldSshTerminal {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    Disconnect-PalworldSshTerminalSession
    $script:PalworldSshCurrentConnection = $Connection
    $script:PalworldSshTerminalClient = Connect-PalworldSshService `
        -Connection $Connection `
        -Owner $Owner `
        -AllowTrustPrompt
    $script:PalworldSshShell = $script:PalworldSshTerminalClient.CreateShellStream(
        "xterm",
        [uint32]120,
        [uint32]40,
        [uint32]1200,
        [uint32]800,
        4096
    )
    Invoke-PalworldSshOrphanCleanup -Client $script:PalworldSshTerminalClient
    $script:PalworldSshTerminalHandledPasswordPromptSignature = ""
    Set-PalworldSshTerminalPasswordInputMode -Enabled $false
    if ($script:PalworldSshTimer) { $script:PalworldSshTimer.Start() }
    if ($script:PalworldSshStatus) {
        $script:PalworldSshStatus.Text = Get-PalworldLocalizedText "Connected · management + terminal channels" "연결됨 · 관리 + 터미널 채널"
        $script:PalworldSshStatus.ForeColor = [System.Drawing.Color]::DarkGreen
    }
    Add-PalworldSshTerminalOutput "`r`n[SSH] Interactive terminal connected: $([string]$Connection.Name).`r`n"
}

function Connect-PalworldSshDualSession {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    Disconnect-PalworldSshSession
    $script:PalworldSshCurrentConnection = $Connection
    try {
        Connect-PalworldSshManagementSession -Connection $Connection -Owner $Owner
        Connect-PalworldSshTerminal -Connection $Connection -Owner $Owner
        if ($script:ResourceUsageRefreshContext) {
            try { & $script:ResourceUsageRefreshContext } catch { }
        }
    }
    catch {
        Disconnect-PalworldSshSession
        throw
    }
}

function New-PalworldAutomationShellStream {
    param([Parameter(Mandatory = $true)]$Client)
    $modes = New-Object 'System.Collections.Generic.Dictionary[Renci.SshNet.Common.TerminalModes,System.UInt32]'
    $modes[[Renci.SshNet.Common.TerminalModes]::ECHO] = [uint32]0
    $modes[[Renci.SshNet.Common.TerminalModes]::ECHOE] = [uint32]0
    $modes[[Renci.SshNet.Common.TerminalModes]::ECHOK] = [uint32]0
    $modes[[Renci.SshNet.Common.TerminalModes]::ECHONL] = [uint32]0
    $modes[[Renci.SshNet.Common.TerminalModes]::ECHOCTL] = [uint32]0
    $shell = $Client.CreateShellStream(
        "dumb",
        [uint32]120,
        [uint32]40,
        [uint32]1200,
        [uint32]800,
        4096,
        $modes
    )
    # A login banner is discarded before the first framed command, but both
    # time and bytes are bounded so a noisy shell cannot freeze the UI here.
    [void](Clear-PalworldSshAvailableOutput `
        -Shell $shell `
        -MaximumBytes 65536 `
        -MaximumMilliseconds 1000 `
        -QuietMilliseconds 150)
    return $shell
}

function Get-PalworldAutomationShellStream {
    param([Parameter(Mandatory = $true)]$Client)
    if ($script:PalworldSshAutomationShell) {
        try {
            if ($script:PalworldSshAutomationShell.CanRead -and
                $script:PalworldSshAutomationShell.CanWrite) {
                return $script:PalworldSshAutomationShell
            }
        }
        catch { }
        try { $script:PalworldSshAutomationShell.Dispose() } catch { }
        $script:PalworldSshAutomationShell = $null
    }
    $script:PalworldSshAutomationShell = New-PalworldAutomationShellStream -Client $Client
    return $script:PalworldSshAutomationShell
}

function Reset-PalworldAutomationShellStream {
    if ($script:PalworldSshAutomationShell) {
        try { Reset-PalworldSshShellUtf8Decoder -Shell $script:PalworldSshAutomationShell } catch { }
        try { $script:PalworldSshAutomationShell.Dispose() } catch { }
        $script:PalworldSshAutomationShell = $null
    }
}

function ConvertTo-PalworldUnixShellText {
    param([Parameter(Mandatory = $true)][string]$Command)
    # PowerShell here-strings inherit the Windows source file's CRLF endings.
    # Bash treats the retained carriage return in commands such as `set -eu`
    # as part of the option text, so normalize every remote script to Unix LF
    # before handing it to either SSH execution channel.
    return $Command.Replace("`r`n", "`n").Replace("`r", "`n")
}

function ConvertTo-PalworldShellExecutionCommand {
    param([Parameter(Mandatory = $true)][string]$Command)
    $normalizedCommand = ConvertTo-PalworldUnixShellText -Command $Command
    if ($normalizedCommand -notmatch "`n") { return $normalizedCommand }
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    $bytes = $encoding.GetBytes($normalizedCommand)
    try { $encoded = [Convert]::ToBase64String($bytes) }
    finally { [Array]::Clear($bytes, 0, $bytes.Length) }
    # Keep the interactive PTY stdin attached to bash so sudo -S can read the
    # password, while avoiding PS2 prompts and command-marker echo from a
    # multi-line script.
    return 'bash -c "$(printf %s ' + (ConvertTo-PosixLiteral $encoded) + ' | base64 -d)"'
}

function Get-PalworldSudoPromptPattern {
    param([Parameter(Mandatory = $true)][string]$Marker)
    $escaped = [Text.RegularExpressions.Regex]::Escape($Marker)
    # The marker also exists inside the command text (sudo -p 'marker').
    # Some SSH servers echo that text even when ECHO=0 was requested. Match
    # only a marker emitted as an actual prompt at the start of a terminal
    # line, including Ubuntu's "[sudo: marker] Password:" presentation.
    return '(?:\A|(?<=[\r\n]))[ \t]*(?:' + $escaped +
        '|\[sudo:\s*' + $escaped + '\]\s*Password:)'
}

function Add-PalworldBoundedSshCommandOutput {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.LinkedList[System.Text.StringBuilder]]$Chunks,
        [Parameter(Mandatory = $true)][ref]$RetainedLength,
        [Parameter(Mandatory = $true)][ref]$OmittedLength,
        [AllowNull()][AllowEmptyString()][string]$Text,
        [ValidateRange(1024, 16777216)][int]$MaximumLength = 4194304
    )
    if (-not $Text) { return }

    $blockLength = [Math]::Min(16384, $MaximumLength)
    $position = 0
    while ($position -lt $Text.Length) {
        $block = if ($Chunks.Last -and $Chunks.Last.Value.Length -lt $blockLength) {
            $Chunks.Last.Value
        }
        else {
            $created = New-Object Text.StringBuilder -ArgumentList $blockLength
            [void]$Chunks.AddLast($created)
            $created
        }
        $available = $blockLength - $block.Length
        if ($available -eq 1 -and $position + 1 -lt $Text.Length -and
            [char]::IsHighSurrogate($Text[$position]) -and
            [char]::IsLowSurrogate($Text[$position + 1])) {
            $block = New-Object Text.StringBuilder -ArgumentList $blockLength
            [void]$Chunks.AddLast($block)
            $available = $blockLength
        }
        $take = [Math]::Min($available, $Text.Length - $position)
        if ($position + $take -lt $Text.Length -and
            [char]::IsHighSurrogate($Text[$position + $take - 1]) -and
            [char]::IsLowSurrogate($Text[$position + $take])) {
            $take--
        }
        [void]$block.Append($Text, $position, $take)
        $position += $take
        $RetainedLength.Value += $take
        # Drop whole blocks. This retains slightly less than the exact maximum
        # at a trim boundary, but keeps both memory and work per read bounded;
        # subsequent data immediately fills the released block-sized space.
        while ($RetainedLength.Value -gt $MaximumLength) {
            $firstLength = $Chunks.First.Value.Length
            $Chunks.RemoveFirst()
            $RetainedLength.Value -= $firstLength
            $OmittedLength.Value += $firstLength
        }
    }
}

function Get-PalworldBoundedSshCommandOutput {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][System.Collections.Generic.LinkedList[System.Text.StringBuilder]]$Chunks,
        [long]$OmittedLength = 0
    )
    $output = New-Object Text.StringBuilder
    if ($OmittedLength -gt 0) {
        [void]$output.Append(
            "[SSH] Earlier SSH command output was truncated; $OmittedLength characters omitted.`r`n"
        )
    }
    foreach ($chunk in $Chunks) { [void]$output.Append($chunk.ToString()) }
    return $output.ToString()
}

function Expand-PalworldSudoPlaceholders {
    param([Parameter(Mandatory = $true)][string]$Command)
    $placeholder = "__PALWORLD_SUDO__"
    $expanded = $Command
    $markers = New-Object System.Collections.Generic.List[string]
    while ($true) {
        $position = $expanded.IndexOf($placeholder, [StringComparison]::Ordinal)
        if ($position -lt 0) { break }
        $marker = "__PALWORLD_SUDO_$([Guid]::NewGuid().ToString('N'))__"
        $markers.Add($marker)
        $prefix = "sudo -S -p " + (ConvertTo-PosixLiteral $marker)
        $expanded = $expanded.Substring(0, $position) + $prefix +
            $expanded.Substring($position + $placeholder.Length)
    }
    return [pscustomobject]@{
        Command = $expanded
        Markers = @($markers)
    }
}

function Write-PalworldShellSecretUtf8 {
    param(
        [Parameter(Mandatory = $true)]$Shell,
        [Parameter(Mandatory = $true)][string]$Secret
    )
    if ($Secret.IndexOf([char]0) -ge 0 -or $Secret.Contains("`r") -or $Secret.Contains("`n")) {
        throw "Sudo Password must not contain NUL, CR, or LF characters."
    }
    $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false, $true
    # ShellStream.WriteLine uses CR for an allocated PTY. Match that behavior
    # explicitly so sudo receives a completed line even on hosts whose tty
    # input flags do not accept a bare LF.
    $bytes = $encoding.GetBytes($Secret + "`r")
    try {
        $Shell.Write($bytes, 0, $bytes.Length)
        $Shell.Flush()
    }
    finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Get-PalworldSudoAuthenticationErrorMessage {
    return "Sudo authentication failed. The saved password was sent unchanged as UTF-8 but sudo rejected it. Open SSH Connection > Update, verify the Linux Sudo Password and SSH Username, then run Host Check."
}

function Invoke-PalworldSshCommand {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Command,
        [ValidateRange(1, 7200)][int]$TimeoutSeconds = 60,
        [ValidateRange(1024, 16777216)][int]$OutputLimitCharacters = 4194304,
        [ValidateRange(256, 65536)][int]$MarkerWindowCharacters = 8192,
        [ValidateRange(1024, 1048576)][int]$VisibleBufferLimitCharacters = 65536,
        [ValidateRange(1, 10)][int]$CancelGraceSeconds = 2,
        [switch]$Quiet
    )
    if ($script:PalworldSshClosing) {
        throw [OperationCanceledException]::new("Palworld Server Operations - Admin is closing.")
    }
    $connectionId = [string]$Connection.Id
    $ownsConnectionPin = -not [string]$script:PalworldSshPinnedConnectionId
    if ($script:PalworldSshPinnedConnectionId -and
        [string]$script:PalworldSshPinnedConnectionId -ne $connectionId) {
        throw "Another SSH Connection is pinned by the current management operation."
    }
    if (-not $script:PalworldSshClient -or -not $script:PalworldSshClient.IsConnected) {
        Connect-PalworldSshManagementSession -Connection $Connection -Owner $Owner
    }
    $doneMarker = "__PALWORLD_DONE_$([Guid]::NewGuid().ToString('N'))__"
    $sudoExpansion = Expand-PalworldSudoPlaceholders -Command $Command
    $sudoMarkers = @($sudoExpansion.Markers)
    $needsSudo = $sudoMarkers.Count -gt 0
    if ($needsSudo -and -not [string]$Connection.SudoPassword) {
        throw "This operation requires the saved Sudo Password."
    }
    $expanded = ConvertTo-PalworldShellExecutionCommand -Command ([string]$sudoExpansion.Command)
    $wrapped = "set +e; ( $expanded ); pal_rc=`$?; printf '\n%s:%s\n' " +
        (ConvertTo-PosixLiteral $doneMarker) + " `"`$pal_rc`""
    $shell = Get-PalworldAutomationShellStream -Client $script:PalworldSshClient
    $script:PalworldSshCancelRequested = $false
    $resultChunks = New-Object 'System.Collections.Generic.LinkedList[System.Text.StringBuilder]'
    [long]$resultLength = 0
    [long]$omittedResultLength = 0
    $markerBuffer = ""
    [long]$markerBufferOffset = 0
    $markerBufferStartsAtLineBoundary = $true
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $sudoPromptsAnswered = @{}
    $lastSudoPromptOffsets = @{}
    $sudoPromptPatterns = @{}
    foreach ($sudoMarker in $sudoMarkers) {
        $sudoPromptPatterns[$sudoMarker] = Get-PalworldSudoPromptPattern -Marker $sudoMarker
        $lastSudoPromptOffsets[$sudoMarker] = [long]-1
    }
    $donePattern = [Text.RegularExpressions.Regex]::Escape($doneMarker) + ':(\d+)'
    $cancelSent = $false
    $cancelDeadline = [DateTime]::MaxValue
    $visibleBuffer = ""
    $secretValues = @(
        [string]$Connection.Password,
        [string]$Connection.PrivateKeyPassphrase,
        [string]$Connection.SudoPassword
    ) | Where-Object { $_ }
    $maxSecretLength = 0
    foreach ($secretValue in $secretValues) {
        if ($secretValue.Length -gt $maxSecretLength) { $maxSecretLength = $secretValue.Length }
    }
    $maxMarkerLength = $doneMarker.Length
    foreach ($sudoMarker in $sudoMarkers) {
        if ($sudoMarker.Length -gt $maxMarkerLength) { $maxMarkerLength = $sudoMarker.Length }
    }
    $visibleHoldLength = [Math]::Max($maxMarkerLength, $maxSecretLength) + 64
    $visibleBufferLimit = [Math]::Max(
        $VisibleBufferLimitCharacters,
        [Math]::Min([int]::MaxValue, [long]$visibleHoldLength * 2)
    )
    $completed = $false
    if ($script:PalworldSshAutomationCommandRunning) {
        throw "Another SSH management command is already running. Wait for it to finish or cancel it first."
    }
    $script:PalworldSshAutomationCommandRunning = $true
    if ($ownsConnectionPin) { $script:PalworldSshPinnedConnectionId = $connectionId }
    try {
        [void](Clear-PalworldSshAvailableOutput `
            -Shell $shell `
            -MaximumBytes 65536 `
            -MaximumMilliseconds 150)
        $shell.WriteLine($wrapped)
        while ([DateTime]::UtcNow -lt $deadline) {
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:PalworldSshClosing) {
                throw [OperationCanceledException]::new("Palworld Server Operations - Admin is closing.")
            }
            if ($shell.DataAvailable) {
                $readBatch = Read-PalworldSshAvailableUtf8 `
                    -Shell $shell `
                    -TotalByteLimit 65536 `
                    -PerReadByteLimit 16384 `
                    -MaximumReads 4
                $chunk = [string]$readBatch.Text
                if (-not $chunk) {
                    Start-Sleep -Milliseconds 10
                    continue
                }
                Add-PalworldBoundedSshCommandOutput `
                    -Chunks $resultChunks `
                    -RetainedLength ([ref]$resultLength) `
                    -OmittedLength ([ref]$omittedResultLength) `
                    -Text $chunk `
                    -MaximumLength $OutputLimitCharacters
                $completionMatch = $null
                $chunkPosition = 0
                $maximumMarkerSegmentLength = [Math]::Max(
                    64,
                    [Math]::Min(4096, [int]($MarkerWindowCharacters / 2))
                )
                # The byte reader caps this batch at 64 KiB. Feed its decoded
                # text to a still-smaller rolling window so prompts cannot
                # disappear before they are inspected.
                while ($chunkPosition -lt $chunk.Length) {
                    $segmentLength = [Math]::Min(
                        $maximumMarkerSegmentLength,
                        $chunk.Length - $chunkPosition
                    )
                    $markerBuffer += $chunk.Substring($chunkPosition, $segmentLength)
                    $chunkPosition += $segmentLength
                    if ($markerBuffer.Length -gt $MarkerWindowCharacters) {
                        $removeLength = $markerBuffer.Length - $MarkerWindowCharacters
                        $removedTail = $markerBuffer[$removeLength - 1]
                        $markerBuffer = $markerBuffer.Substring($removeLength)
                        $markerBufferOffset += $removeLength
                        $markerBufferStartsAtLineBoundary = $removedTail -eq "`r" -or $removedTail -eq "`n"
                    }
                    # Prefix a non-newline character when the window starts in
                    # the middle of a line. This prevents an echoed command
                    # fragment at the boundary from looking like a sudo prompt.
                    $markerScanPrefixLength = if ($markerBufferStartsAtLineBoundary) { 0 } else { 1 }
                    $markerScanText = if ($markerScanPrefixLength -eq 0) {
                        $markerBuffer
                    }
                    else {
                        "x$markerBuffer"
                    }
                    foreach ($sudoMarker in $sudoMarkers) {
                        $promptMatches = [Text.RegularExpressions.Regex]::Matches(
                            $markerScanText,
                            [string]$sudoPromptPatterns[$sudoMarker],
                            [Text.RegularExpressions.RegexOptions]::CultureInvariant
                        )
                        foreach ($promptMatch in $promptMatches) {
                            $markerWithinMatch = $promptMatch.Value.IndexOf(
                                $sudoMarker,
                                [StringComparison]::Ordinal
                            )
                            if ($markerWithinMatch -lt 0) { continue }
                            $relativeOffset = $promptMatch.Index - $markerScanPrefixLength +
                                $markerWithinMatch
                            if ($relativeOffset -lt 0) { continue }
                            $absoluteOffset = $markerBufferOffset + $relativeOffset
                            if ($absoluteOffset -le [long]$lastSudoPromptOffsets[$sudoMarker]) { continue }
                            $lastSudoPromptOffsets[$sudoMarker] = $absoluteOffset
                            if ($sudoPromptsAnswered.ContainsKey($sudoMarker)) {
                                try { $shell.Write([string][char]3) } catch { }
                                throw (Get-PalworldSudoAuthenticationErrorMessage)
                            }
                            Write-PalworldShellSecretUtf8 `
                                -Shell $shell -Secret ([string]$Connection.SudoPassword)
                            $sudoPromptsAnswered[$sudoMarker] = $true
                        }
                    }
                    $candidateMatch = [Text.RegularExpressions.Regex]::Match(
                        $markerScanText,
                        $donePattern,
                        [Text.RegularExpressions.RegexOptions]::CultureInvariant
                    )
                    if ($candidateMatch.Success) {
                        $completionMatch = $candidateMatch
                        break
                    }
                }
                $visibleChunkPosition = 0
                while ($visibleChunkPosition -lt $chunk.Length) {
                    $visibleSegmentLength = [Math]::Min(
                        16384,
                        $chunk.Length - $visibleChunkPosition
                    )
                    $visibleBuffer += $chunk.Substring(
                        $visibleChunkPosition,
                        $visibleSegmentLength
                    )
                    $visibleChunkPosition += $visibleSegmentLength
                    foreach ($sudoMarker in $sudoMarkers) {
                        $visibleBuffer = $visibleBuffer.Replace($sudoMarker, "[sudo authentication]")
                    }
                    foreach ($secretValue in $secretValues) {
                        $visibleBuffer = $visibleBuffer.Replace($secretValue, "[hidden]")
                    }
                    $visibleBuffer = [Text.RegularExpressions.Regex]::Replace(
                        $visibleBuffer,
                        '\[sudo:\s*\[sudo authentication\]\]\s*Password:\s*',
                        "[sudo authentication]`r`n"
                    )
                    $visibleBuffer = [Text.RegularExpressions.Regex]::Replace(
                        $visibleBuffer,
                        [Text.RegularExpressions.Regex]::Escape($doneMarker) + ':\d+',
                        ''
                    )
                    if ($Quiet -and $visibleBuffer.Length -gt $visibleHoldLength) {
                        $visibleBuffer = $visibleBuffer.Substring($visibleBuffer.Length - $visibleHoldLength)
                    }
                    elseif ($visibleBuffer.Length -gt $visibleHoldLength) {
                        # A completed line can be followed by a second, very long
                        # unterminated line in the same read. Keep draining until
                        # the remainder is below the bound or only the safety hold
                        # suffix remains.
                        while ($visibleBuffer.Length -gt $visibleHoldLength) {
                            $visibleLength = Get-PalworldSshVisibleFlushPrefixLength `
                                -Text $visibleBuffer `
                                -HoldLength $visibleHoldLength `
                                -MaximumBufferedLength $visibleBufferLimit
                            if ($visibleLength -le 0) { break }
                            Add-PalworldSshOutput `
                                -Text $visibleBuffer.Substring(0, $visibleLength) `
                                -TerminalStream
                            $visibleBuffer = $visibleBuffer.Substring($visibleLength)
                        }
                    }
                }
                if ($completionMatch) {
                    if ($cancelSent) {
                        throw [OperationCanceledException]::new("SSH management operation was canceled.")
                    }
                    $completed = $true
                    return [pscustomobject]@{
                        ExitCode = [int]$completionMatch.Groups[1].Value
                        Output = Get-PalworldBoundedSshCommandOutput `
                            -Chunks $resultChunks -OmittedLength $omittedResultLength
                        OutputTruncated = $omittedResultLength -gt 0
                        OmittedCharacters = $omittedResultLength
                    }
                }
            }
            if ($script:PalworldSshCancelRequested -and -not $cancelSent) {
                $shell.Write([string][char]3)
                $cancelSent = $true
                $cancelDeadline = [DateTime]::UtcNow.AddSeconds($CancelGraceSeconds)
                if (-not $Quiet) {
                    Add-PalworldSshOutput "`r`n[SSH] Cancellation requested...`r`n"
                }
            }
            if ($cancelSent -and [DateTime]::UtcNow -ge $cancelDeadline) {
                # The automation PTY is separate from the manual Terminal PTY.
                # Throwing here lets finally dispose only this stuck stream;
                # the SSH client and interactive terminal remain independent.
                throw [OperationCanceledException]::new("SSH management operation was canceled.")
            }
            Start-Sleep -Milliseconds 40
        }
        throw "SSH command timed out after $TimeoutSeconds seconds."
    }
    finally {
        if ($visibleBuffer -and -not $Quiet -and -not $script:PalworldSshClosing) {
            foreach ($sudoMarker in $sudoMarkers) {
                $visibleBuffer = $visibleBuffer.Replace($sudoMarker, "[sudo authentication]")
            }
            foreach ($secretValue in $secretValues) {
                $visibleBuffer = $visibleBuffer.Replace($secretValue, "[hidden]")
            }
            $visibleBuffer = [Text.RegularExpressions.Regex]::Replace(
                $visibleBuffer,
                '\[sudo:\s*\[sudo authentication\]\]\s*Password:\s*',
                "[sudo authentication]`r`n"
            )
            $visibleBuffer = [Text.RegularExpressions.Regex]::Replace(
                $visibleBuffer,
                [Text.RegularExpressions.Regex]::Escape($doneMarker) + ':\d+',
                ''
            )
            Add-PalworldSshOutput -Text $visibleBuffer -TerminalStream
        }
        if (-not $completed -and -not $script:PalworldSshClosing) {
            Reset-PalworldAutomationShellStream
        }
        if ($script:PalworldSshManagementSanitizer) { $script:PalworldSshManagementSanitizer.Reset() }
        if ($ownsConnectionPin) { $script:PalworldSshPinnedConnectionId = "" }
        $script:PalworldSshAutomationCommandRunning = $false
    }
}

function Wait-PalworldSshTask {
    param(
        [Parameter(Mandatory = $true)][Threading.Tasks.Task]$Task,
        [Parameter(Mandatory = $true)][Threading.CancellationTokenSource]$Cancellation,
        [Parameter(Mandatory = $true)][string]$Operation,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds,
        [scriptblock]$OnCancel = $null
    )
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while (-not $Task.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:PalworldSshClosing -or $script:PalworldSshCancelRequested) {
            try { $Cancellation.Cancel() } catch { }
            if ($OnCancel) { try { & $OnCancel } catch { } }
            throw [OperationCanceledException]::new(
                "$Operation was canceled while closing or canceling the operation."
            )
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            try { $Cancellation.Cancel() } catch { }
            if ($OnCancel) { try { & $OnCancel } catch { } }
            throw "$Operation timed out after $TimeoutSeconds seconds."
        }
        Start-Sleep -Milliseconds 25
    }
    if ($script:PalworldSshClosing -or $script:PalworldSshCancelRequested) {
        try { $Cancellation.Cancel() } catch { }
        if ($OnCancel) { try { & $OnCancel } catch { } }
        throw [OperationCanceledException]::new(
            "$Operation was canceled while closing or canceling the operation."
        )
    }
    return $Task.GetAwaiter().GetResult()
}

function Invoke-PalworldSshSimpleCommand {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Command,
        [ValidateRange(1, 600)][int]$TimeoutSeconds = 30
    )
    if ($script:PalworldSshClosing) {
                throw [OperationCanceledException]::new("Palworld Server Operations - Admin is closing.")
    }
    if (-not $script:PalworldSshClient -or -not $script:PalworldSshClient.IsConnected) {
        Connect-PalworldSshManagementSession -Connection $Connection -Owner $Owner
    }
    $sshCommand = $null
    $cancellation = New-Object Threading.CancellationTokenSource
    $task = $null
    $deferredCleanup = $false
    try {
        $normalizedCommand = ConvertTo-PalworldUnixShellText -Command $Command
        $sshCommand = $script:PalworldSshClient.CreateCommand($normalizedCommand)
        $sshCommand.CommandTimeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
        $task = $sshCommand.ExecuteAsync($cancellation.Token)
        $cancelCommand = { $sshCommand.CancelAsync($true, 100) }.GetNewClosure()
        [void](Wait-PalworldSshTask `
            -Task $task `
            -Cancellation $cancellation `
            -Operation "SSH command" `
            -TimeoutSeconds $TimeoutSeconds `
            -OnCancel $cancelCommand)
        if ($sshCommand.ExitStatus -ne 0) {
            throw ($sshCommand.Error.Trim() -replace '^$', "Remote command failed with exit code $($sshCommand.ExitStatus).")
        }
        return [string]$sshCommand.Result
    }
    finally {
        if ($task -and -not $task.IsCompleted -and $sshCommand) {
            Initialize-PalworldSshRuntime
            [Palworld.ServerManager.AsyncTaskCleanup]::ObserveAndDispose(
                $task,
                [object[]]@($sshCommand, $cancellation)
            )
            $deferredCleanup = $true
        }
        if (-not $deferredCleanup) {
            try { $cancellation.Cancel() } catch { }
            try { $cancellation.Dispose() } catch { }
            if ($sshCommand) { try { $sshCommand.Dispose() } catch { } }
        }
    }
}

function Send-PalworldSftpFile {
    param(
        [Parameter(Mandatory = $true)]$Sftp,
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [ValidateRange(15, 1800)][int]$TimeoutSeconds = 600
    )
    $cancellation = New-Object Threading.CancellationTokenSource
    $task = $null
    $deferredCleanup = $false
    try {
        $task = $Sftp.UploadFileAsync($Stream, $RemotePath, $cancellation.Token)
        [void](Wait-PalworldSshTask `
            -Task $task `
            -Cancellation $cancellation `
            -Operation "SFTP upload" `
            -TimeoutSeconds $TimeoutSeconds)
    }
    finally {
        if ($task -and -not $task.IsCompleted) {
            Initialize-PalworldSshRuntime
            [Palworld.ServerManager.AsyncTaskCleanup]::ObserveAndDispose(
                $task,
                [object[]]@($cancellation)
            )
            $deferredCleanup = $true
        }
        if (-not $deferredCleanup) {
            try { $cancellation.Cancel() } catch { }
            try { $cancellation.Dispose() } catch { }
        }
    }
}

function Test-PalworldSftpPathExists {
    param(
        [Parameter(Mandatory = $true)]$Sftp,
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 30
    )
    $cancellation = New-Object Threading.CancellationTokenSource
    $task = $null
    $deferredCleanup = $false
    try {
        $task = $Sftp.ExistsAsync($RemotePath, $cancellation.Token)
        return [bool](Wait-PalworldSshTask `
            -Task $task `
            -Cancellation $cancellation `
            -Operation "SFTP path check" `
            -TimeoutSeconds $TimeoutSeconds)
    }
    finally {
        if ($task -and -not $task.IsCompleted) {
            Initialize-PalworldSshRuntime
            [Palworld.ServerManager.AsyncTaskCleanup]::ObserveAndDispose(
                $task,
                [object[]]@($cancellation)
            )
            $deferredCleanup = $true
        }
        if (-not $deferredCleanup) {
            try { $cancellation.Cancel() } catch { }
            try { $cancellation.Dispose() } catch { }
        }
    }
}

function Receive-PalworldSftpFile {
    param(
        [Parameter(Mandatory = $true)]$Sftp,
        [Parameter(Mandatory = $true)][string]$RemotePath,
        [Parameter(Mandatory = $true)][IO.Stream]$Stream,
        [ValidateRange(1, 1800)][int]$TimeoutSeconds = 30
    )
    $cancellation = New-Object Threading.CancellationTokenSource
    $task = $null
    $deferredCleanup = $false
    try {
        $task = $Sftp.DownloadFileAsync($RemotePath, $Stream, $cancellation.Token)
        [void](Wait-PalworldSshTask `
            -Task $task `
            -Cancellation $cancellation `
            -Operation "SFTP download" `
            -TimeoutSeconds $TimeoutSeconds)
    }
    finally {
        if ($task -and -not $task.IsCompleted) {
            Initialize-PalworldSshRuntime
            [Palworld.ServerManager.AsyncTaskCleanup]::ObserveAndDispose(
                $task,
                [object[]]@($cancellation)
            )
            $deferredCleanup = $true
        }
        if (-not $deferredCleanup) {
            try { $cancellation.Cancel() } catch { }
            try { $cancellation.Dispose() } catch { }
        }
    }
}

function Close-PalworldSftpClient {
    param($Sftp)
    if (-not $Sftp) { return }
    if ($script:PalworldSshClosing -or $script:PalworldSshCancelRequested) {
        Initialize-PalworldSshRuntime
        [Palworld.ServerManager.BackgroundDisposer]::Queue([object[]]@($Sftp))
        return
    }
    try { if ($Sftp.IsConnected) { $Sftp.Disconnect() } } catch { }
    try { $Sftp.Dispose() } catch { }
}

function Resolve-PalworldRemoteWorkDirectory {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    $value = [string]$Connection.WorkDirectory
    if (-not (Test-PalworldWorkDirectory $value)) { throw "Unsafe project directory: $value" }
    $literal = ConvertTo-PosixLiteral $value
    $command = @'
value=__VALUE__; case "$value" in "~/"*) candidate="$HOME/${value#\~/}" ;; /*) candidate="$value" ;; *) exit 64 ;; esac; readlink -m -- "$candidate"
'@.Replace("__VALUE__", $literal).Trim()
    $resolved = (Invoke-PalworldSshSimpleCommand -Connection $Connection -Owner $Owner -Command $command).Trim()
    if ($resolved -notmatch '^/' -or -not (Test-PalworldWorkDirectory $resolved)) {
        throw "The remote server resolved an unsafe work directory: $resolved"
    }
    return $resolved
}

function Assert-PalworldServerName {
    param([Parameter(Mandatory = $true)][string]$Server)
    if ($Server -notmatch '^server[1-9][0-9]*$') {
        throw "Invalid server name: $Server"
    }
}

function Get-PalworldRemoteTextFile {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$RemotePath
    )
    $sftp = $null
    $stream = $null
    try {
        $sftp = Connect-PalworldSshService `
            -Connection $Connection -Kind Sftp -Owner $Owner -OperationTimeoutSeconds 30
        if (-not (Test-PalworldSftpPathExists `
            -Sftp $sftp -RemotePath $RemotePath -TimeoutSeconds 30)) {
            throw "Remote file was not found: $RemotePath"
        }
        # The cap is enforced by the destination stream on every write, not
        # only after download, so a remote file cannot grow memory unbounded.
        $stream = New-Object Palworld.ServerManager.BoundedMemoryStream(1048576)
        Receive-PalworldSftpFile `
            -Sftp $sftp -RemotePath $RemotePath -Stream $stream -TimeoutSeconds 30
        return [Text.Encoding]::UTF8.GetString($stream.ToArray()).TrimStart([char]0xFEFF)
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($sftp) {
            Close-PalworldSftpClient -Sftp $sftp
        }
    }
}

function ConvertFrom-PalworldEnvText {
    param([Parameter(Mandatory = $true)][string]$Content)
    if ($Content.IndexOf([char]0) -ge 0) { throw "env content contains a NUL character." }
    $values = [ordered]@{}
    $lineNumber = 0
    foreach ($line in $Content -split "`r?`n") {
        $lineNumber++
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) { continue }
        $separator = $line.IndexOf('=')
        if ($separator -lt 1) { throw "env line $lineNumber must use KEY=value format." }
        $key = $line.Substring(0, $separator).Trim()
        if ($key -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
            throw "env line $lineNumber has an invalid key: $key"
        }
        if ($values.Contains($key)) { throw "env key is duplicated: $key" }
        $values[$key] = $line.Substring($separator + 1).Trim()
    }
    return $values
}

function Test-PalworldServerEnvText {
    param([Parameter(Mandatory = $true)][string]$Content)
    $values = ConvertFrom-PalworldEnvText $Content
    foreach ($required in @(
        "SERVER_PORT",
        "REST_API_EXPOSE",
        "PAL_SETTING_RESTAPIEnabled",
        "PAL_SETTING_RESTAPIPort"
    )) {
        if (-not $values.Contains($required) -or -not [string]$values[$required]) {
            throw "Required env key is missing or empty: $required"
        }
    }
    $gamePort = 0
    $restPort = 0
    if (-not [int]::TryParse([string]$values.SERVER_PORT, [ref]$gamePort) -or $gamePort -lt 1 -or $gamePort -gt 65535) {
        throw "SERVER_PORT must be an integer from 1 to 65535."
    }
    if (-not [int]::TryParse([string]$values.PAL_SETTING_RESTAPIPort, [ref]$restPort) -or $restPort -lt 1 -or $restPort -gt 65535) {
        throw "PAL_SETTING_RESTAPIPort must be an integer from 1 to 65535."
    }
    if ($gamePort -eq $restPort) { throw "Game and REST API ports must be different." }
    if ([string]$values.REST_API_EXPOSE -notmatch '^(?i:true|false)$') {
        throw "REST_API_EXPOSE must be true or false."
    }
    if ([string]$values.PAL_SETTING_RESTAPIEnabled -notmatch '^(?i:true)$') {
        throw "PAL_SETTING_RESTAPIEnabled=True is required by Test and management operations."
    }
    $serverArguments = if ($values.Contains("SERVER_ARGS")) { [string]$values.SERVER_ARGS } else { "" }
    if ($serverArguments -match '(?i)(^|\s)-(?:port(?:=|\s)|publiclobby(?:\s|$))') {
        throw "Use SERVER_PORT and COMMUNITY_SERVER instead of adding -port or -publiclobby to SERVER_ARGS."
    }
    $warnings = New-Object System.Collections.Generic.List[string]
    if (-not $values.Contains("PAL_SETTING_AdminPassword") -or -not [string]$values.PAL_SETTING_AdminPassword) {
        $warnings.Add("PAL_SETTING_AdminPassword is empty.")
    }
    if (-not $values.Contains("API_ACCESS_TOKEN") -or ([string]$values.API_ACCESS_TOKEN).Length -lt 32) {
        $warnings.Add("API_ACCESS_TOKEN is empty or shorter than 32 characters.")
    }
    return [pscustomobject]@{
        Values = $values
        GamePort = $gamePort
        RestPort = $restPort
        Warnings = @($warnings)
    }
}

function ConvertTo-PalworldDurationSeconds {
    param(
        [Parameter(Mandatory = $true)][string]$Value,
        [Parameter(Mandatory = $true)][string]$Name
    )
    $match = [Regex]::Match($Value, '^(?<number>[0-9]+(?:\.[0-9]+)?)(?<unit>[smh])$')
    if (-not $match.Success) {
        throw "$Name must use an explicit duration suffix, for example 60s, 5m, or 1h."
    }
    $number = 0.0
    if (-not [double]::TryParse(
        $match.Groups['number'].Value,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$number
    )) {
        throw "$Name contains an invalid duration."
    }
    $multiplier = switch ($match.Groups['unit'].Value) {
        'm' { 60.0 }
        'h' { 3600.0 }
        default { 1.0 }
    }
    return $number * $multiplier
}

function Test-PalworldCommonEnvText {
    param([Parameter(Mandatory = $true)][string]$Content)
    $values = ConvertFrom-PalworldEnvText $Content
    foreach ($required in @(
        "TZ", "GAME_PORT_BASE", "REST_API_PORT_BASE", "SERVER_PORT_STEP",
        "UPDATE_ON_START", "AUTO_UPDATE_ENABLED", "UPDATE_CHECK_INTERVAL",
        "UPDATE_RETRY_INTERVAL", "STEAMCMD_PROGRESS_TIMEOUT",
        "UPDATE_WARNING_SECONDS", "UPDATE_WARNING_MESSAGE", "VALIDATE_ON_UPDATE",
        "CRASH_RESTART_DELAY", "SHUTDOWN_WAIT", "RESTART_WARNING_SECONDS",
        "RESTART_WARNING_MESSAGE", "RESTART_COUNTDOWN_MESSAGE",
        "SHUTDOWN_WARNING_SECONDS", "SHUTDOWN_WARNING_MESSAGE",
        "SHUTDOWN_COUNTDOWN_MESSAGE", "API_USERNAME", "MANAGER_API_PORT",
        "RUNTIME_LOG_MAX_SIZE_MB", "RUNTIME_LOG_BACKUP_COUNT"
    )) {
        if (-not $values.Contains($required) -or -not [string]$values[$required]) {
            throw "Required Common Settings key is missing or empty: $required"
        }
    }
    if ([string]$values.TZ -notmatch '^[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*$') {
        throw "TZ must be an IANA timezone such as UTC, Asia/Seoul, America/New_York, or Europe/London."
    }
    $ports = @{}
    foreach ($key in @("GAME_PORT_BASE", "REST_API_PORT_BASE", "MANAGER_API_PORT")) {
        $parsed = 0
        if (-not [int]::TryParse([string]$values[$key], [ref]$parsed) -or
            $parsed -lt 1 -or $parsed -gt 65535) {
            throw "$key must be an integer from 1 to 65535."
        }
        $ports[$key] = $parsed
    }
    if ($ports.REST_API_PORT_BASE -ne $ports.GAME_PORT_BASE + 1) {
        throw "REST_API_PORT_BASE must equal GAME_PORT_BASE + 1."
    }
    $step = 0
    if (-not [int]::TryParse([string]$values.SERVER_PORT_STEP, [ref]$step) -or
        $step -lt 1 -or $step -gt 65535) {
        throw "SERVER_PORT_STEP must be an integer from 1 to 65535."
    }
    foreach ($key in @("UPDATE_ON_START", "AUTO_UPDATE_ENABLED", "VALIDATE_ON_UPDATE")) {
        if ([string]$values[$key] -notmatch '^(?i:true|false|yes|no|on|off|1|0)$') {
            throw "$key must be true or false."
        }
    }
    $durationSeconds = @{}
    foreach ($key in @(
        "UPDATE_CHECK_INTERVAL", "UPDATE_RETRY_INTERVAL", "UPDATE_WARNING_SECONDS",
        "STEAMCMD_PROGRESS_TIMEOUT", "CRASH_RESTART_DELAY", "SHUTDOWN_WAIT", "RESTART_WARNING_SECONDS",
        "SHUTDOWN_WARNING_SECONDS"
    )) {
        $durationSeconds[$key] = ConvertTo-PalworldDurationSeconds `
            -Value ([string]$values[$key]) -Name $key
    }
    foreach ($key in @("UPDATE_CHECK_INTERVAL", "UPDATE_RETRY_INTERVAL", "STEAMCMD_PROGRESS_TIMEOUT")) {
        if ([double]$durationSeconds[$key] -lt 60.0) {
            throw "$key must be at least 60s."
        }
    }
    foreach ($key in @(
        "UPDATE_WARNING_MESSAGE", "RESTART_WARNING_MESSAGE", "RESTART_COUNTDOWN_MESSAGE",
        "SHUTDOWN_WARNING_MESSAGE", "SHUTDOWN_COUNTDOWN_MESSAGE"
    )) {
        if (-not ([string]$values[$key]).Trim()) { throw "$key must not be empty." }
    }
    foreach ($key in @("RUNTIME_LOG_MAX_SIZE_MB", "RUNTIME_LOG_BACKUP_COUNT")) {
        $integer = 0
        if (-not [int]::TryParse([string]$values[$key], [ref]$integer) -or $integer -lt 1) {
            throw "$key must be an integer of 1 or greater."
        }
    }
    if (-not [string]$values.API_USERNAME -or ([string]$values.API_USERNAME).Contains(':')) {
        throw "API_USERNAME must not be empty or contain ':'."
    }
    return [pscustomobject]@{ Values = $values; Warnings = @() }
}

function Set-PalworldEnvTextValue {
    param(
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][string]$Key,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value
    )
    $lines = [System.Collections.Generic.List[string]]::new()
    $replaced = $false
    foreach ($line in ($Content -split "`r?`n")) {
        if (-not $replaced -and $line -match ('^\s*' + [Regex]::Escape($Key) + '\s*=')) {
            $lines.Add("$Key=$Value")
            $replaced = $true
        }
        else { $lines.Add($line) }
    }
    if (-not $replaced) { $lines.Add("$Key=$Value") }
    return ($lines -join "`r`n").TrimEnd("`r", "`n") + "`r`n"
}

function Get-PalworldRemoteCommonEnv {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    $project = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $path = "$project/config/common.env"
    $pathLiteral = ConvertTo-PosixLiteral $path
    $reviewLiteral = ConvertTo-PosixLiteral "$project/runtime/common-settings.reviewed.sha256"
    $command = @'
file=__FILE__; reviewed_file=__REVIEW__; test -f "$file"; actual="$(sha256sum -- "$file" | awk '{print $1}')"; reviewed=""; test -f "$reviewed_file" && reviewed="$(tr -d '[:space:]' < "$reviewed_file")"; timezone=""; if command -v timedatectl >/dev/null 2>&1; then timezone="$(timedatectl show --property=Timezone --value 2>/dev/null || true)"; fi; test -n "$timezone" || { test -r /etc/timezone && timezone="$(tr -d '[:space:]' < /etc/timezone)"; }; printf 'PAL_COMMON_HASH=%s\nPAL_COMMON_REVIEWED=%s\nPAL_HOST_TZ=%s\n' "$actual" "$reviewed" "${timezone:-unknown}"
'@.Replace("__FILE__", $pathLiteral).Replace("__REVIEW__", $reviewLiteral).Trim()
    $status = Invoke-PalworldSshSimpleCommand `
        -Connection $Connection -Owner $Owner -Command $command
    $actual = ([Regex]::Match($status, '(?m)^PAL_COMMON_HASH=([a-f0-9]{64})\r?$')).Groups[1].Value
    $reviewed = ([Regex]::Match($status, '(?m)^PAL_COMMON_REVIEWED=([a-f0-9]{64})?\r?$')).Groups[1].Value
    $timezone = ([Regex]::Match($status, '(?m)^PAL_HOST_TZ=([^\r\n]+)')).Groups[1].Value.Trim()
    $content = Get-PalworldRemoteTextFile -Connection $Connection -Owner $Owner -RemotePath $path
    $verifiedStatus = Invoke-PalworldSshSimpleCommand `
        -Connection $Connection -Owner $Owner `
        -Command "sha256sum -- $pathLiteral | awk '{print `$1}'"
    $verifiedHash = ([Regex]::Match($verifiedStatus, '(?m)^([a-f0-9]{64})\r?$')).Groups[1].Value
    if (-not $actual -or $verifiedHash -ne $actual) {
        throw "Common Settings changed while it was being opened. Open it again before editing."
    }
    return [pscustomobject]@{
        Project = $project
        Path = $path
        Content = $content
        Hash = $actual
        ReviewedHash = $reviewed
        Reviewed = [bool]$actual -and $actual -eq $reviewed
        HostTimezone = if ($timezone) { $timezone } else { "unknown" }
    }
}

function Save-PalworldRemoteCommonEnv {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedHash
    )
    [void](Test-PalworldCommonEnvText $Content)
    $project = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $normalized = ($Content -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n") + "`n"
    $remoteUpload = Send-PalworldRemoteTemporaryText `
        -Connection $Connection -Owner $Owner -Content $normalized -Prefix "palworld-common"
    $uploadLiteral = ConvertTo-PosixLiteral $remoteUpload
    $arguments = "write-env --kind common --source $uploadLiteral --expected-sha256 $ExpectedHash"
    try {
        $result = Invoke-PalworldPackagedSshOperation `
            -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 180 `
            -BuildCommand {
                param($remoteProject, $tools)
                New-PalworldManagerCommand `
                    -Project $remoteProject -Tools $tools -Arguments $arguments
            }.GetNewClosure()
        if ($result.ExitCode -ne 0 -or $result.Output -notmatch 'PAL_COMMON_HASH=[a-f0-9]{64}') {
            throw "Common Settings could not be saved and marked as reviewed."
        }
        Add-PalworldSshOutput "`r`n[PASS] Common Settings validated, saved, and marked as reviewed.`r`n"
        return Get-PalworldRemoteCommonEnv -Connection $Connection -Owner $Owner
    }
    finally {
        try {
            [void](Invoke-PalworldSshSimpleCommand `
                -Connection $Connection -Owner $Owner -Command "rm -f -- $uploadLiteral")
        } catch { }
    }
}

function Get-PalworldRemoteServerEnv {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Server
    )
    Assert-PalworldServerName $Server
    $project = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $path = "$project/config/$Server.env"
    $pathLiteral = ConvertTo-PosixLiteral $path
    $beforeOutput = Invoke-PalworldSshSimpleCommand `
        -Connection $Connection -Owner $Owner `
        -Command "test -f $pathLiteral; sha256sum -- $pathLiteral | awk '{print `$1}'"
    $beforeHash = ([Regex]::Match($beforeOutput, '(?m)^([a-f0-9]{64})\r?$')).Groups[1].Value
    $content = Get-PalworldRemoteTextFile -Connection $Connection -Owner $Owner -RemotePath $path
    $afterOutput = Invoke-PalworldSshSimpleCommand `
        -Connection $Connection -Owner $Owner `
        -Command "sha256sum -- $pathLiteral | awk '{print `$1}'"
    $afterHash = ([Regex]::Match($afterOutput, '(?m)^([a-f0-9]{64})\r?$')).Groups[1].Value
    if (-not $beforeHash -or $afterHash -ne $beforeHash) {
        throw "$Server.env changed while it was being opened. Open it again before editing."
    }
    return [pscustomobject]@{
        Project = $project
        Path = $path
        Content = $content
        Hash = $beforeHash
    }
}

function Get-PalworldRemoteServerApiSettings {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Server
    )
    $remote = Get-PalworldRemoteServerEnv `
        -Connection $Connection -Owner $Owner -Server $Server
    $serverEnv = Test-PalworldServerEnvText $remote.Content
    $commonPath = "$($remote.Project)/config/common.env"
    $commonContent = Get-PalworldRemoteTextFile `
        -Connection $Connection -Owner $Owner -RemotePath $commonPath
    $commonEnv = ConvertFrom-PalworldEnvText $commonContent
    $username = if ($commonEnv.Contains("API_USERNAME")) {
        [string]$commonEnv.API_USERNAME
    }
    else { "admin" }
    $password = if ($serverEnv.Values.Contains("PAL_SETTING_AdminPassword")) {
        [string]$serverEnv.Values.PAL_SETTING_AdminPassword
    }
    else { "" }
    $accessToken = if ($serverEnv.Values.Contains("API_ACCESS_TOKEN")) {
        ([string]$serverEnv.Values.API_ACCESS_TOKEN).Trim()
    }
    else { "" }
    if (-not $username -or $username.Contains(":")) {
        throw "$Server API_USERNAME is empty or invalid in config/common.env."
    }
    if (-not $password) {
        throw "$Server PAL_SETTING_AdminPassword is empty in config/$Server.env."
    }
    if ($accessToken -notmatch '^[A-Za-z0-9_-]{32,128}$') {
        throw "$Server API_ACCESS_TOKEN is missing or invalid in config/$Server.env."
    }
    return [pscustomobject]@{
        ServerName = $Server
        ServerHost = [string]$Connection.Host
        GamePort = [int]$serverEnv.GamePort
        Port = [int]$serverEnv.RestPort
        Username = $username
        Password = $password
        AccessToken = $accessToken
        RestApiExposed = [string]$serverEnv.Values.REST_API_EXPOSE -match '^(?i:true)$'
    }
}

function Save-PalworldRemoteServerEnv {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Content,
        [Parameter(Mandatory = $true)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedHash
    )
    Assert-PalworldServerName $Server
    [void](Test-PalworldServerEnvText $Content)
    $project = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $normalized = ($Content -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n") + "`n"
    $remoteUpload = Send-PalworldRemoteTemporaryText `
        -Connection $Connection -Owner $Owner -Content $normalized -Prefix "palworld-env"
    $uploadLiteral = ConvertTo-PosixLiteral $remoteUpload
    $serverLiteral = ConvertTo-PosixLiteral $Server
    $arguments = "write-env --kind server --server $serverLiteral --source $uploadLiteral --expected-sha256 $ExpectedHash"
    try {
        $result = Invoke-PalworldPackagedSshOperation `
            -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 180 `
            -BuildCommand {
                param($remoteProject, $tools)
                New-PalworldManagerCommand `
                    -Project $remoteProject -Tools $tools -Arguments $arguments
            }.GetNewClosure()
        if ($result.ExitCode -ne 0) { throw "Remote env save failed with exit code $($result.ExitCode)." }
        $backupMatch = [Text.RegularExpressions.Regex]::Match($result.Output, 'PAL_ENV_BACKUP=([^\r\n]+)')
        if (-not $backupMatch.Success) {
            throw "The remote server.env save did not return its recovery backup path."
        }
        $backup = $backupMatch.Groups[1].Value.Trim()
        [void](Add-PalworldSshOutput "`r`n[PASS] $Server.env saved. Previous file: $backup`r`n")
        return $backup
    }
    finally {
        try {
            [void](Invoke-PalworldSshSimpleCommand `
                -Connection $Connection -Owner $Owner -Command "rm -f -- $uploadLiteral")
        } catch { }
    }
}

function Show-PalworldServerEnvEditor {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)][string]$Content
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "[only Windows] $Server.env"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(860, 700)
    $dialog.MinimumSize = New-Object System.Drawing.Size(700, 560)
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog
    $notice = New-Object System.Windows.Forms.Label
    $notice.Text = Get-PalworldLocalizedText `
        "This is the original env, including the server password and API token. Saving preserves the previous file under backups/$Server/env." `
        "서버 비밀번호와 API token을 포함한 원본 env입니다. 저장 시 기존 파일은 backups/$Server/env에 보존됩니다."
    $notice.Location = New-Object System.Drawing.Point(12, 12)
    $notice.Size = New-Object System.Drawing.Size(830, 22)
    $notice.Anchor = "Top,Left,Right"
    $notice.ForeColor = [System.Drawing.Color]::DarkOrange
    $dialog.Controls.Add($notice)
    $editor = New-Object System.Windows.Forms.RichTextBox
    $editor.Location = New-Object System.Drawing.Point(12, 40)
    $editor.Size = New-Object System.Drawing.Size(836, 590)
    $editor.Anchor = "Top,Bottom,Left,Right"
    $editor.Font = New-Object System.Drawing.Font("Consolas", 9)
    $editor.AcceptsTab = $true
    $editor.WordWrap = $false
    $editor.Text = $Content
    $dialog.Controls.Add($editor)
    $validationLabel = New-Object System.Windows.Forms.Label
    $validationLabel.Text = Get-PalworldLocalizedText `
        "Edit the file, then select Validate or a save action." `
        "수정 후 Validate 또는 저장 버튼으로 검사"
    $validationLabel.Location = New-Object System.Drawing.Point(12, 642)
    $validationLabel.Size = New-Object System.Drawing.Size(380, 24)
    $validationLabel.Anchor = "Bottom,Left,Right"
    $validationLabel.ForeColor = [System.Drawing.Color]::DimGray
    $dialog.Controls.Add($validationLabel)
    $validateButton = New-Object System.Windows.Forms.Button
    $validateButton.Text = "Validate"
    $validateButton.Location = New-Object System.Drawing.Point(400, 638)
    $validateButton.Size = New-Object System.Drawing.Size(92, 32)
    $validateButton.Anchor = "Bottom,Right"
    $dialog.Controls.Add($validateButton)
    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = "Save only"
    $saveButton.Location = New-Object System.Drawing.Point(500, 638)
    $saveButton.Size = New-Object System.Drawing.Size(100, 32)
    $saveButton.Anchor = "Bottom,Right"
    $dialog.Controls.Add($saveButton)
    $applyButton = New-Object System.Windows.Forms.Button
    $applyButton.Text = "Save && Apply"
    $applyButton.Location = New-Object System.Drawing.Point(608, 638)
    $applyButton.Size = New-Object System.Drawing.Size(112, 32)
    $applyButton.Anchor = "Bottom,Right"
    $dialog.Controls.Add($applyButton)
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(728, 638)
    $cancelButton.Size = New-Object System.Drawing.Size(120, 32)
    $cancelButton.Anchor = "Bottom,Right"
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)
    $envTextValidator = ${function:Test-PalworldServerEnvText}
    $validate = {
        try {
            $result = & $envTextValidator $editor.Text
            if ($result.Warnings.Count -gt 0) {
                $validationLabel.Text = "WARN · " + ($result.Warnings -join " ")
                $validationLabel.ForeColor = [System.Drawing.Color]::DarkOrange
            }
            else {
                $validationLabel.Text = Get-PalworldLocalizedText `
                    "PASS · env syntax and required ports" `
                    "PASS · env 문법과 필수 포트"
                $validationLabel.ForeColor = [System.Drawing.Color]::DarkGreen
            }
            return $true
        }
        catch {
            $validationLabel.Text = "FAIL · $([string]$_.Exception.Message)"
            $validationLabel.ForeColor = [System.Drawing.Color]::DarkRed
            return $false
        }
    }.GetNewClosure()
    $validateButton.Add_Click({ [void](& $validate) }.GetNewClosure())
    $saveButton.Add_Click({
        if (& $validate) {
            $dialog.Tag = "Save"
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    }.GetNewClosure())
    $applyButton.Add_Click({
        if (& $validate) {
            $dialog.Tag = "Apply"
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    }.GetNewClosure())
    $dialog.CancelButton = $cancelButton
    if ($env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-dialog-events") {
        $dialog.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $validateButton.PerformClick()
        $saveButton.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        $result = if ($dialog.DialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
            [pscustomobject]@{ Action = [string]$dialog.Tag; Content = [string]$editor.Text }
        }
        else { $null }
        $dialog.Dispose()
        return $result
    }
    try {
        if ($dialog.ShowDialog($Owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return [pscustomobject]@{ Action = [string]$dialog.Tag; Content = [string]$editor.Text }
    }
    finally { $dialog.Dispose() }
}

function Show-PalworldCommonSettingsEditor {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Content,
        [AllowEmptyString()][string]$HostTimezone = ""
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = Get-PalworldLocalizedText "Review Common Settings" "공통 설정 검토"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(900, 720)
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog

    $notice = New-Object System.Windows.Forms.Label
    $notice.Text = Get-PalworldLocalizedText `
        "Review project-wide ports, update policy, API username, and timezone. Confirming saves a backup and allows Host Check to apply TZ to the Linux host." `
        "프로젝트 전체 포트·업데이트 정책·API 사용자명·시간대를 확인하세요. 확인하면 기존 파일을 백업하고, 호스트 검사가 TZ를 Linux 호스트에 적용할 수 있게 됩니다."
    $notice.Location = New-Object System.Drawing.Point(12, 12)
    $notice.Size = New-Object System.Drawing.Size(876, 38)
    $notice.ForeColor = [System.Drawing.Color]::DarkOrange
    $dialog.Controls.Add($notice)

    $timezoneLabel = New-Object System.Windows.Forms.Label
    $timezoneLabel.Text = Get-PalworldLocalizedText `
        "Detected host timezone: $HostTimezone" `
        "감지한 호스트 시간대: $HostTimezone"
    $timezoneLabel.Location = New-Object System.Drawing.Point(12, 55)
    $timezoneLabel.Size = New-Object System.Drawing.Size(610, 24)
    $dialog.Controls.Add($timezoneLabel)

    $useTimezoneButton = New-Object System.Windows.Forms.Button
    $useTimezoneButton.Text = Get-PalworldLocalizedText "Use Detected Timezone" "감지한 시간대 사용"
    $useTimezoneButton.Location = New-Object System.Drawing.Point(692, 50)
    $useTimezoneButton.Size = New-Object System.Drawing.Size(196, 30)
    $useTimezoneButton.Enabled = $HostTimezone -match '^[A-Za-z0-9_+.-]+(?:/[A-Za-z0-9_+.-]+)*$'
    $dialog.Controls.Add($useTimezoneButton)

    $editor = New-Object System.Windows.Forms.RichTextBox
    $editor.Location = New-Object System.Drawing.Point(12, 86)
    $editor.Size = New-Object System.Drawing.Size(876, 570)
    $editor.Font = New-Object System.Drawing.Font("Consolas", 9)
    $editor.AcceptsTab = $true
    $editor.WordWrap = $false
    $editor.Text = $Content
    $dialog.Controls.Add($editor)

    $validationLabel = New-Object System.Windows.Forms.Label
    $validationLabel.Text = Get-PalworldLocalizedText `
        "Review the values, then Validate or Confirm && Save." `
        "값을 확인한 뒤 Validate 또는 확인 후 저장을 누르세요."
    $validationLabel.Location = New-Object System.Drawing.Point(12, 668)
    $validationLabel.Size = New-Object System.Drawing.Size(430, 24)
    $validationLabel.ForeColor = [System.Drawing.Color]::DimGray
    $dialog.Controls.Add($validationLabel)

    $validateButton = New-Object System.Windows.Forms.Button
    $validateButton.Text = "Validate"
    $validateButton.Location = New-Object System.Drawing.Point(460, 664)
    $validateButton.Size = New-Object System.Drawing.Size(100, 32)
    $dialog.Controls.Add($validateButton)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = Get-PalworldLocalizedText "Confirm && Save" "확인 후 저장"
    $saveButton.Location = New-Object System.Drawing.Point(568, 664)
    $saveButton.Size = New-Object System.Drawing.Size(150, 32)
    $dialog.Controls.Add($saveButton)

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = Get-PalworldLocalizedText "Cancel" "취소"
    $cancelButton.Location = New-Object System.Drawing.Point(726, 664)
    $cancelButton.Size = New-Object System.Drawing.Size(162, 32)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)

    $validate = {
        try {
            [void](Test-PalworldCommonEnvText $editor.Text)
            $validationLabel.Text = Get-PalworldLocalizedText `
                "PASS · Common Settings syntax and required values" `
                "PASS · 공통 설정 문법과 필수 값"
            $validationLabel.ForeColor = [System.Drawing.Color]::DarkGreen
            return $true
        }
        catch {
            $validationLabel.Text = "FAIL · $([string]$_.Exception.Message)"
            $validationLabel.ForeColor = [System.Drawing.Color]::DarkRed
            return $false
        }
    }.GetNewClosure()
    $validateButton.Add_Click({ [void](& $validate) }.GetNewClosure())
    $useTimezoneButton.Add_Click({
        $editor.Text = Set-PalworldEnvTextValue `
            -Content $editor.Text -Key "TZ" -Value $HostTimezone
        $validationLabel.Text = Get-PalworldLocalizedText `
            "Detected timezone applied. Validate or Confirm && Save." `
            "감지한 시간대를 반영했습니다. Validate 또는 확인 후 저장을 누르세요."
        $validationLabel.ForeColor = [System.Drawing.Color]::DimGray
    }.GetNewClosure())
    $saveButton.Add_Click({
        if (& $validate) {
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
    }.GetNewClosure())
    $dialog.CancelButton = $cancelButton
    try {
        if ($dialog.ShowDialog($Owner) -ne [System.Windows.Forms.DialogResult]::OK) { return $null }
        return [string]$editor.Text
    }
    finally { $dialog.Dispose() }
}

function Format-PalworldImportByteSize {
    param([long]$Bytes)
    if ($Bytes -ge 1GB) { return ("{0:N1} GB" -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ("{0:N1} MB" -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ("{0:N1} KB" -f ($Bytes / 1KB)) }
    return "$Bytes B"
}

function Format-PalworldImportModifiedTime {
    param([AllowEmptyString()][string]$Value)
    $parsed = [DateTimeOffset]::MinValue
    if ([DateTimeOffset]::TryParse($Value, [ref]$parsed)) {
        return $parsed.ToString("yyyy-MM-dd HH:mm")
    }
    return $Value
}

function Get-PalworldImportReviewDisplay {
    param([Parameter(Mandatory = $true)]$Row)
    $sourceKey = [string]$Row.source_key
    $envKeys = @($Row.env_keys | ForEach-Object { [string]$_ })
    $reservedValues = @($Row.reserved_values | ForEach-Object { [string]$_ })
    $scope = [string]$Row.scope
    $setting = if ($envKeys.Count -gt 0 -and $sourceKey) {
        "$sourceKey ($($envKeys -join ' / '))"
    }
    elseif ($envKeys.Count -gt 0) { $envKeys -join " / " }
    elseif ($scope -eq "common.env") { "$sourceKey (common.env)" }
    elseif ($scope -eq "GameUserSettings.ini") { "$sourceKey (GameUserSettings.ini)" }
    elseif ($scope -eq "unmapped") { "$sourceKey (unmapped)" }
    else { $sourceKey }
    $description = [string]$Row.description
    if ($script:ApplicationLanguage -eq "ko") {
        switch ([string]$Row.id) {
            "game-port" {
                $description = if ([string]$Row.status -eq "BLOCKED" -and [string]$Row.value) {
                    $ownerMatch = [Regex]::Match([string]$Row.description, 'already assigned to (server[1-9][0-9]*)')
                    if ($ownerMatch.Success) {
                        "원본 서버가 현재 이 포트를 사용하는 것은 정상이며 차단 대상이 아닙니다. 하지만 $($ownerMatch.Groups[1].Value) 설정에도 같은 게임 UDP 포트가 배정되어 두 관리 서버를 함께 실행할 수 없습니다. 사용하지 않는 포트로 변경한 뒤 ENV에 반영하세요."
                    }
                    else {
                        "원본 서버의 현재 포트 점유가 아닌 관리 프로젝트 설정 충돌입니다. 사용하지 않는 게임 UDP 포트로 변경한 뒤 ENV에 반영하세요."
                    }
                }
                elseif ([string]$Row.status -eq "BLOCKED") {
                    "실행 중인 원본 프로세스에서 게임 UDP 포트를 감지하지 못했습니다. 기존 포트를 입력한 뒤 ENV에 반영하세요."
                }
                else { "선택한 원본 서버가 현재 이 게임 UDP 포트를 사용하는 것은 정상이며 검토를 막지 않습니다. 감지한 값이 맞는지 확인하세요." }
            }
            "rest-port" {
                $description = if ([string]$Row.status -eq "BLOCKED" -and [string]$Row.value) {
                    $ownerMatch = [Regex]::Match([string]$Row.description, 'already assigned to (server[1-9][0-9]*)')
                    if ($ownerMatch.Success) {
                        "원본 서버가 현재 이 포트를 사용하는 것은 정상이며 차단 대상이 아닙니다. 하지만 $($ownerMatch.Groups[1].Value) 설정에도 같은 REST API TCP 포트가 배정되어 두 관리 서버를 함께 실행할 수 없습니다. 사용하지 않는 포트로 변경한 뒤 ENV에 반영하세요."
                    }
                    elseif ([string]$Row.description -match 'MANAGER_API_PORT') {
                        "REST API TCP 포트가 공통 MANAGER_API_PORT와 충돌합니다. 사용하지 않는 포트로 변경한 뒤 ENV에 반영하세요."
                    }
                    else {
                        "원본 서버의 현재 포트 점유가 아닌 관리 프로젝트 설정 충돌입니다. 사용하지 않는 REST API TCP 포트로 변경한 뒤 ENV에 반영하세요."
                    }
                }
                elseif ([string]$Row.status -eq "BLOCKED") {
                    "PalWorldSettings.ini에서 REST API TCP 포트를 확인하지 못했습니다. 포트를 입력한 뒤 ENV에 반영하세요."
                }
                else { "선택한 원본 서버가 현재 이 REST API TCP 포트를 사용하는 것은 정상이며 검토를 막지 않습니다. PalWorldSettings.ini에서 가져온 값이 맞는지 확인하세요." }
            }
            "rest-exposure" { $description = "Windows 앱에서 직접 연결하려면 True를 권장합니다. 방화벽·VPN·TLS 게이트웨이로 보호하세요." }
            "community-server" { $description = "원본 실행 옵션에서 감지한 -publiclobby 값을 기본값으로 사용합니다." }
            "rest-api-enabled" { $description = "통합 관리 API가 공식 REST API를 사용하므로 이 값은 True로 유지합니다." }
            "active-window" { $description = "always는 24시간 운영합니다. 14:00-02:00처럼 날짜가 바뀌는 HH:MM-HH:MM 범위도 사용할 수 있습니다." }
            "restart-times" { $description = "공통 설정의 시간대를 기준으로 예약 재시작합니다. 여러 시각은 쉼표로 구분하세요." }
            "automatic-updates" { $description = "현재 프로젝트의 공통 설정을 사용합니다. 확인 주기와 사전 안내 시간은 공통 설정 검토에서 조정할 수 있습니다." }
            "world-guid" { $description = "GameUserSettings.ini가 선택한 기존 월드 디렉터리를 가리키도록 설정합니다." }
            "api-token" { $description = "가져온 서버에 사용할 새 프로젝트 API 토큰입니다." }
            default {
                if ([string]$Row.id -like "pal-setting-*") {
                    $description = if ([string]$Row.status -eq "UNMAPPED") {
                        "현재 프로젝트 서버 템플릿에 없는 설정입니다. 값은 serverN.env의 템플릿 외 설정 보존 구역에 남깁니다."
                    }
                    else { "PalWorldSettings.ini에서 가져와 프로젝트 템플릿의 알려진 위치에 반영한 값입니다. 필요한 경우 값을 바꾸고 ENV에 반영하세요." }
                }
                elseif ($scope -eq "unmapped") {
                    $description = "환경 변수 이름으로 안전하게 표현할 수 없어 자동 변환하지 않은 원본 설정입니다."
                }
            }
        }
    }
    elseif ([string]$Row.status -eq "BLOCKED" -and [string]$Row.value -and
        [string]$Row.id -in @("game-port", "rest-port")) {
        $description = "The source server's current listener is allowed. This is a managed-project assignment conflict: $description Change the port and sync it to ENV."
    }
    return [pscustomobject]@{
        id = [string]$Row.id
        status = [string]$Row.status
        setting = $setting
        source_key = $sourceKey
        env_keys = $envKeys
        value = [string]$Row.value
        value_type = [string]$Row.value_type
        editable = [bool]$Row.editable
        required = [bool]$Row.required
        scope = $scope
        description = $description
        reserved_values = $reservedValues
    }
}

function Show-PalworldImportSourceDialog {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Worlds,
        [Parameter(Mandatory = $true)][string]$SearchRoot
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = Get-PalworldLocalizedText "Import Existing Server · Select World" "기존 서버 가져오기 · 월드 선택"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(1120, 550)
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog

    $notice = New-Object System.Windows.Forms.Label
    $notice.Text = Get-PalworldLocalizedText `
        "Select a validated Palworld world. The full Pal/Saved directory is copied; the source is never modified. Level.sav time helps identify the latest world." `
        "검증된 팰월드 월드를 선택하세요. 원본은 수정하지 않고 Pal/Saved 전체를 복사합니다. 최근 월드는 Level.sav 수정 시각으로 확인할 수 있습니다."
    $notice.Location = New-Object System.Drawing.Point(12, 10)
    $notice.Size = New-Object System.Drawing.Size(1096, 36)
    $dialog.Controls.Add($notice)

    $rootLabel = New-Object System.Windows.Forms.Label
    $rootLabel.Text = Get-PalworldLocalizedText "Search root" "검색 시작 경로"
    $rootLabel.Location = New-Object System.Drawing.Point(12, 55)
    $rootLabel.Size = New-Object System.Drawing.Size(90, 23)
    $dialog.Controls.Add($rootLabel)
    $rootBox = New-Object System.Windows.Forms.TextBox
    $rootBox.Location = New-Object System.Drawing.Point(104, 52)
    $rootBox.Size = New-Object System.Drawing.Size(844, 23)
    $rootBox.Text = $SearchRoot
    $dialog.Controls.Add($rootBox)
    $rescanButton = New-Object System.Windows.Forms.Button
    $rescanButton.Text = Get-PalworldLocalizedText "Search Again" "다시 검색"
    $rescanButton.Location = New-Object System.Drawing.Point(956, 49)
    $rescanButton.Size = New-Object System.Drawing.Size(152, 30)
    $dialog.Controls.Add($rescanButton)

    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(12, 86)
    $list.Size = New-Object System.Drawing.Size(1096, 340)
    $list.View = "Details"
    $list.FullRowSelect = $true
    $list.GridLines = $true
    $list.HideSelection = $false
    $list.MultiSelect = $false
    [void]$list.Columns.Add((Get-PalworldLocalizedText "Active" "활성"), 50)
    [void]$list.Columns.Add((Get-PalworldLocalizedText "Server name" "서버 이름"), 190)
    [void]$list.Columns.Add("Pal directory", 300)
    [void]$list.Columns.Add("World GUID", 225)
    [void]$list.Columns.Add((Get-PalworldLocalizedText "Level.sav modified" "Level.sav 수정"), 145)
    [void]$list.Columns.Add((Get-PalworldLocalizedText "Players" "플레이어"), 60)
    [void]$list.Columns.Add((Get-PalworldLocalizedText "State" "상태"), 100)
    foreach ($world in @($Worlds)) {
        $serverName = if ([string]$world.server_name) { [string]$world.server_name } else { "(unnamed)" }
        $item = New-Object System.Windows.Forms.ListViewItem($(if ([bool]$world.active) { (Get-PalworldLocalizedText "Yes" "예") } else { "" }))
        [void]$item.SubItems.Add($serverName)
        [void]$item.SubItems.Add([string]$world.pal_directory)
        [void]$item.SubItems.Add([string]$world.world_guid)
        [void]$item.SubItems.Add((Format-PalworldImportModifiedTime ([string]$world.level_modified_at)))
        [void]$item.SubItems.Add([string]$world.player_count)
        [void]$item.SubItems.Add($(if ([bool]$world.running) { (Get-PalworldLocalizedText "Running" "실행 중") } else { (Get-PalworldLocalizedText "Stopped" "중지됨") }))
        $item.Tag = $world
        if ([bool]$world.active) { $item.ForeColor = [System.Drawing.Color]::DarkGreen }
        [void]$list.Items.Add($item)
    }
    $dialog.Controls.Add($list)

    $selectionDetail = New-Object System.Windows.Forms.Label
    $selectionDetail.Text = Get-PalworldLocalizedText "Select one discovered world." "검색된 월드 하나를 선택하세요."
    $selectionDetail.Location = New-Object System.Drawing.Point(12, 434)
    $selectionDetail.Size = New-Object System.Drawing.Size(1096, 42)
    $selectionDetail.AutoEllipsis = $true
    $dialog.Controls.Add($selectionDetail)

    $validation = New-Object System.Windows.Forms.Label
    $validation.Text = if (@($Worlds).Count -eq 0) {
        Get-PalworldLocalizedText `
            "No validated Palworld worlds were found. Enter another search root or cancel." `
            "검증 가능한 팰월드 월드를 찾지 못했습니다. 다른 검색 경로를 입력하거나 취소하세요."
    }
    else {
        Get-PalworldLocalizedText `
            "Ports and management options are reviewed on the next screen." `
            "포트와 관리 옵션은 다음 설정 검토 화면에서 확인합니다."
    }
    $validation.Location = New-Object System.Drawing.Point(12, 482)
    $validation.Size = New-Object System.Drawing.Size(720, 32)
    $validation.ForeColor = if (@($Worlds).Count -eq 0) {
        [System.Drawing.Color]::DarkOrange
    }
    else { [System.Drawing.Color]::DimGray }
    $dialog.Controls.Add($validation)

    $importButton = New-Object System.Windows.Forms.Button
    $importButton.Text = Get-PalworldLocalizedText "Review Selected World" "선택한 월드 검토"
    $importButton.Location = New-Object System.Drawing.Point(752, 504)
    $importButton.Size = New-Object System.Drawing.Size(184, 34)
    $importButton.Enabled = $false
    $dialog.Controls.Add($importButton)
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = Get-PalworldLocalizedText "Cancel" "취소"
    $cancelButton.Location = New-Object System.Drawing.Point(944, 504)
    $cancelButton.Size = New-Object System.Drawing.Size(164, 34)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)

    $list.Add_SelectedIndexChanged({
        if ($list.SelectedItems.Count -eq 0) {
            $importButton.Enabled = $false
            return
        }
        $world = $list.SelectedItems[0].Tag
        $worldOptionText = if ([bool]$world.world_option_present) {
            Get-PalworldLocalizedText "present" "있음"
        }
        else { Get-PalworldLocalizedText "not present" "없음" }
        $selectionDetail.Text = "Pal/Saved: $([string]$world.saved_directory) · Level.sav $(Format-PalworldImportByteSize ([long]$world.level_size_bytes)) · WorldOption.sav $worldOptionText"
        $selectionDetail.ForeColor = if ([bool]$world.running) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::DimGray }
        $importButton.Enabled = $true
    }.GetNewClosure())
    $rescanButton.Add_Click({
        if (-not $rootBox.Text.Trim()) {
            $validation.Text = Get-PalworldLocalizedText "Enter an absolute Linux search path." "Linux 절대 검색 경로를 입력하세요."
            $validation.ForeColor = [System.Drawing.Color]::DarkRed
            return
        }
        $dialog.Tag = [pscustomobject]@{ Action = "Rescan"; SearchRoot = $rootBox.Text.Trim() }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::Retry
        $dialog.Close()
    }.GetNewClosure())
    $importButton.Add_Click({
        if ($list.SelectedItems.Count -eq 0) { return }
        $world = $list.SelectedItems[0].Tag
        $dialog.Tag = [pscustomobject]@{
            Action = "Import"
            SearchRoot = $rootBox.Text.Trim()
            World = $world
        }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    }.GetNewClosure())
    $dialog.CancelButton = $cancelButton
    if ($env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-import-source-ui") {
        try {
            $dialog.Show()
            if ($list.Items.Count -gt 0) { $list.Items[0].Selected = $true }
            [System.Windows.Forms.Application]::DoEvents()
            if ($env:PALWORLD_CLIENT_TEST_SCREENSHOT) {
                $bitmap = New-Object System.Drawing.Bitmap($dialog.Width, $dialog.Height)
                try {
                    $dialog.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $dialog.Width, $dialog.Height)))
                    $bitmap.Save([IO.Path]::GetFullPath($env:PALWORLD_CLIENT_TEST_SCREENSHOT))
                }
                finally { $bitmap.Dispose() }
            }
            return $null
        }
        finally {
            $dialog.Close()
            $dialog.Dispose()
        }
    }
    try {
        [void]$dialog.ShowDialog($Owner)
        return $dialog.Tag
    }
    finally { $dialog.Dispose() }
}

function Select-PalworldImportEditorKey {
    param(
        [AllowNull()][System.Windows.Forms.RichTextBox]$Editor,
        [AllowEmptyString()][string]$Needle
    )
    if (-not $Editor -or -not $Needle) { return }
    $index = $Editor.Text.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase)
    if ($index -lt 0) { return }
    $lineStart = $Editor.Text.LastIndexOf("`n", $index)
    $lineStart = if ($lineStart -lt 0) { 0 } else { $lineStart + 1 }
    $Editor.SelectionStart = $index
    $Editor.SelectionLength = [Math]::Min($Needle.Length, $Editor.TextLength - $index)
    $Editor.ScrollToCaret()
    $lineIndex = $Editor.GetLineFromCharIndex($lineStart)
    [Palworld.ServerManager.RichTextBoxScrollHelper]::ScrollLineToTop(
        $Editor.Handle,
        $lineIndex
    )
}

function Get-PalworldImportStatusColor {
    param([Parameter(Mandatory = $true)][string]$Status)
    switch ($Status) {
        "FAILED" { return [System.Drawing.Color]::DarkRed }
        "BLOCKED" { return [System.Drawing.Color]::DarkRed }
        "UNMAPPED" { return [System.Drawing.Color]::DarkMagenta }
        "REVIEW" { return [System.Drawing.Color]::DarkOrange }
        default { return [System.Drawing.Color]::DimGray }
    }
}

function ConvertTo-PalworldImportEnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [AllowEmptyString()][string]$Value,
        [Parameter(Mandatory = $true)][string]$ValueType
    )
    if ($Value.Contains("`r") -or $Value.Contains("`n")) {
        throw "ENV values cannot contain line breaks."
    }
    if ($ValueType -eq "boolean") {
        if ($Value -notmatch '^(?i:true|false)$') {
            throw "Boolean values must be True or False."
        }
        if ($Key -in @("REST_API_EXPOSE", "COMMUNITY_SERVER")) {
            return $Value.ToLowerInvariant()
        }
        if ($Value -match '^(?i:true)$') { return "True" }
        return "False"
    }
    return $Value
}

function Show-PalworldImportReviewDialog {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)]$Inspection
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = Get-PalworldLocalizedText `
        "Import Existing Server · Settings Review" `
        "기존 서버 가져오기 · 설정 검토"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(1280, 820)
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog

    $notice = New-Object System.Windows.Forms.Label
    $notice.Text = Get-PalworldLocalizedText `
        "Items are ordered FAILED → BLOCKED → UNMAPPED → REVIEW → AUTO. UNMAPPED values are preserved in a dedicated template-external section; synchronize edited values to the generated ENV." `
        "FAILED → BLOCKED → UNMAPPED → REVIEW → AUTO 순서입니다. UNMAPPED 값은 템플릿 외 설정 보존 구역에 남기며, 변경한 값은 생성될 ENV에 반영해야 합니다."
    $notice.Location = New-Object System.Drawing.Point(12, 10)
    $notice.Size = New-Object System.Drawing.Size(1256, 34)
    $dialog.Controls.Add($notice)

    $reviewList = New-Object System.Windows.Forms.ListView
    $reviewList.Location = New-Object System.Drawing.Point(12, 50)
    $reviewList.Size = New-Object System.Drawing.Size(520, 510)
    $reviewList.View = "Details"
    $reviewList.FullRowSelect = $true
    $reviewList.GridLines = $true
    $reviewList.HideSelection = $false
    $reviewList.MultiSelect = $false
    [void]$reviewList.Columns.Add((Get-PalworldLocalizedText "Status" "처리"), 75)
    [void]$reviewList.Columns.Add(
        (Get-PalworldLocalizedText `
            "Setting · PalWorldSettings.ini (serverN.env)" `
            "설정 · PalWorldSettings.ini (serverN.env)"),
        300
    )
    [void]$reviewList.Columns.Add((Get-PalworldLocalizedText "Value" "값"), 140)
    $reviewRows = @()
    $reviewIndex = 0
    foreach ($sourceRow in @($Inspection.review)) {
        $row = Get-PalworldImportReviewDisplay $sourceRow
        Add-Member -InputObject $row -NotePropertyName SortIndex -NotePropertyValue $reviewIndex
        $reviewRows += $row
        $reviewIndex++
    }
    $dialog.Controls.Add($reviewList)

    $detailTitle = New-Object System.Windows.Forms.Label
    $detailTitle.Text = Get-PalworldLocalizedText "Select a setting." "설정을 선택하세요."
    $detailTitle.Location = New-Object System.Drawing.Point(12, 570)
    $detailTitle.Size = New-Object System.Drawing.Size(520, 24)
    $detailTitle.Font = New-Object System.Drawing.Font("Segoe UI Semibold", 9)
    $dialog.Controls.Add($detailTitle)

    $valueLabel = New-Object System.Windows.Forms.Label
    $valueLabel.Text = Get-PalworldLocalizedText "Selected value" "선택한 값"
    $valueLabel.Location = New-Object System.Drawing.Point(12, 600)
    $valueLabel.Size = New-Object System.Drawing.Size(160, 22)
    $dialog.Controls.Add($valueLabel)

    $valueText = New-Object System.Windows.Forms.TextBox
    $valueText.Location = New-Object System.Drawing.Point(12, 624)
    $valueText.Size = New-Object System.Drawing.Size(300, 23)
    $valueText.Enabled = $false
    $dialog.Controls.Add($valueText)

    $valueBoolean = New-Object System.Windows.Forms.ComboBox
    $valueBoolean.DropDownStyle = "DropDownList"
    $valueBoolean.Location = New-Object System.Drawing.Point(12, 624)
    $valueBoolean.Size = New-Object System.Drawing.Size(300, 23)
    [void]$valueBoolean.Items.Add("True")
    [void]$valueBoolean.Items.Add("False")
    $valueBoolean.Visible = $false
    $dialog.Controls.Add($valueBoolean)

    $syncButton = New-Object System.Windows.Forms.Button
    $syncButton.Text = Get-PalworldLocalizedText "Sync Value to ENV" "값을 ENV에 반영"
    $syncButton.Location = New-Object System.Drawing.Point(320, 620)
    $syncButton.Size = New-Object System.Drawing.Size(212, 31)
    $syncButton.Enabled = $false
    $dialog.Controls.Add($syncButton)

    $detailText = New-Object System.Windows.Forms.TextBox
    $detailText.Location = New-Object System.Drawing.Point(12, 660)
    $detailText.Size = New-Object System.Drawing.Size(520, 92)
    $detailText.Multiline = $true
    $detailText.ReadOnly = $true
    $detailText.ScrollBars = "Vertical"
    $dialog.Controls.Add($detailText)

    $sourceLabel = New-Object System.Windows.Forms.Label
    $sourceLabel.Text = Get-PalworldLocalizedText `
        "Source · PalWorldSettings.ini" `
        "원본 · PalWorldSettings.ini"
    $sourceLabel.Location = New-Object System.Drawing.Point(548, 50)
    $sourceLabel.Size = New-Object System.Drawing.Size(720, 24)
    $dialog.Controls.Add($sourceLabel)
    $sourceEditor = New-Object System.Windows.Forms.RichTextBox
    $sourceEditor.Location = New-Object System.Drawing.Point(548, 76)
    $sourceEditor.Size = New-Object System.Drawing.Size(720, 285)
    $sourceEditor.ReadOnly = $true
    $sourceEditor.WordWrap = $false
    $sourceEditor.HideSelection = $false
    $sourceEditor.Font = New-Object System.Drawing.Font("Consolas", 9)
    $sourceEditor.Text = [string]$Inspection.source_ini
    $dialog.Controls.Add($sourceEditor)

    $targetLabel = New-Object System.Windows.Forms.Label
    $targetLabel.Text = Get-PalworldLocalizedText `
        "Target · $([string]$Inspection.server).env" `
        "생성 결과 · $([string]$Inspection.server).env"
    $targetLabel.Location = New-Object System.Drawing.Point(548, 374)
    $targetLabel.Size = New-Object System.Drawing.Size(720, 24)
    $dialog.Controls.Add($targetLabel)
    $targetEditor = New-Object System.Windows.Forms.RichTextBox
    $targetEditor.Location = New-Object System.Drawing.Point(548, 400)
    $targetEditor.Size = New-Object System.Drawing.Size(720, 346)
    $targetEditor.ReadOnly = $true
    $targetEditor.WordWrap = $false
    $targetEditor.HideSelection = $false
    $targetEditor.Font = New-Object System.Drawing.Font("Consolas", 9)
    $targetEditor.Text = [string]$Inspection.target_env
    $dialog.Controls.Add($targetEditor)

    $validation = New-Object System.Windows.Forms.Label
    $validation.Text = Get-PalworldLocalizedText `
        "Resolve every FAILED or BLOCKED item before importing." `
        "가져오기 전에 모든 FAILED 또는 BLOCKED 항목을 해결하세요."
    $validation.Location = New-Object System.Drawing.Point(548, 752)
    $validation.Size = New-Object System.Drawing.Size(720, 24)
    $validation.ForeColor = [System.Drawing.Color]::DimGray
    $dialog.Controls.Add($validation)

    $continueButton = New-Object System.Windows.Forms.Button
    $continueButton.Text = Get-PalworldLocalizedText "Stop Source and Import" "원본 서버 정지 후 가져오기"
    $continueButton.Location = New-Object System.Drawing.Point(862, 774)
    $continueButton.Size = New-Object System.Drawing.Size(214, 34)
    $dialog.Controls.Add($continueButton)
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = Get-PalworldLocalizedText "Cancel" "취소"
    $cancelButton.Location = New-Object System.Drawing.Point(1084, 774)
    $cancelButton.Size = New-Object System.Drawing.Size(184, 34)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)

    $state = [pscustomobject]@{
        Item = $null
        Row = $null
        Loading = $false
        Dirty = $false
    }
    $statusRank = {
        param([string]$Status)
        switch ($Status) {
            "FAILED" { 0 }
            "BLOCKED" { 1 }
            "UNMAPPED" { 2 }
            "REVIEW" { 3 }
            default { 4 }
        }
    }
    $populateReviewList = {
        param([AllowEmptyString()][string]$SelectId = "")
        $reviewList.BeginUpdate()
        try {
            $reviewList.Items.Clear()
            $orderedRows = @($reviewRows | Sort-Object `
                @{ Expression = { & $statusRank ([string]$_.status) } }, `
                @{ Expression = { [int]$_.SortIndex } })
            foreach ($row in $orderedRows) {
                $item = New-Object System.Windows.Forms.ListViewItem([string]$row.status)
                [void]$item.SubItems.Add([string]$row.setting)
                [void]$item.SubItems.Add([string]$row.value)
                $item.Tag = $row
                $item.ForeColor = Get-PalworldImportStatusColor ([string]$row.status)
                [void]$reviewList.Items.Add($item)
                if ($SelectId -and [string]$row.id -eq $SelectId) {
                    $item.Selected = $true
                    $item.Focused = $true
                }
            }
        }
        finally { $reviewList.EndUpdate() }
    }.GetNewClosure()

    $setDirty = {
        if (-not $state.Loading -and $state.Row -and [bool]$state.Row.editable) {
            $state.Dirty = $true
            $validation.Text = Get-PalworldLocalizedText `
                "Value changed · select Sync Value to ENV." `
                "값이 변경되었습니다. '값을 ENV에 반영'을 누르세요."
            $validation.ForeColor = [System.Drawing.Color]::DarkOrange
        }
    }.GetNewClosure()
    $valueText.Add_TextChanged($setDirty)
    $valueBoolean.Add_SelectedIndexChanged($setDirty)

    $reviewList.Add_SelectedIndexChanged({
        if ($reviewList.SelectedItems.Count -eq 0) { return }
        $row = $reviewList.SelectedItems[0].Tag
        $state.Item = $reviewList.SelectedItems[0]
        $state.Row = $row
        $state.Loading = $true
        try {
            $state.Dirty = $false
            $detailTitle.Text = "$([string]$row.status) · $([string]$row.setting)"
            $detailText.Text = [string]$row.description
            $isBoolean = [string]$row.value_type -eq "boolean"
            $valueBoolean.Visible = $isBoolean
            $valueText.Visible = -not $isBoolean
            $valueText.Enabled = [bool]$row.editable
            $valueBoolean.Enabled = [bool]$row.editable
            if ($isBoolean) {
                $valueBoolean.SelectedItem = if ([string]$row.value -match '^(?i:true)$') { "True" } else { "False" }
            }
            else { $valueText.Text = [string]$row.value }
            $syncButton.Enabled = [bool]$row.editable -and @($row.env_keys).Count -gt 0
        }
        finally { $state.Loading = $false }
        $sourceNeedle = switch ([string]$row.id) {
            "game-port" { "PublicPort=" }
            "rest-exposure" { "RESTAPIEnabled=" }
            "community-server" { "-publiclobby" }
            default { if ([string]$row.source_key) { "$([string]$row.source_key)=" } else { "" } }
        }
        $targetNeedle = if (@($row.env_keys).Count -gt 0) {
            "$([string]@($row.env_keys)[0])="
        }
        else { "" }
        Select-PalworldImportEditorKey -Editor $sourceEditor -Needle $sourceNeedle
        Select-PalworldImportEditorKey -Editor $targetEditor -Needle $targetNeedle
    }.GetNewClosure())

    $syncButton.Add_Click({
        if (-not $state.Row -or -not [bool]$state.Row.editable) { return }
        $row = $state.Row
        $value = if ([string]$row.value_type -eq "boolean") {
            [string]$valueBoolean.SelectedItem
        }
        else { [string]$valueText.Text }
        try {
            if ([bool]$row.required -and -not $value.Trim()) {
                throw (Get-PalworldLocalizedText `
                    "$([string]$row.setting) requires a value." `
                    "$([string]$row.setting) 값을 입력하세요.")
            }
            if ([string]$row.id -in @("game-port", "rest-port")) {
                $port = 0
                if (-not [int]::TryParse($value.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
                    throw (Get-PalworldLocalizedText `
                        "$([string]$row.setting) must be an integer from 1 to 65535." `
                        "$([string]$row.setting) 값은 1~65535 사이의 정수여야 합니다.")
                }
                $value = [string]$port
                if (@($row.reserved_values) -contains $value) {
                    throw (Get-PalworldLocalizedText `
                        "$([string]$row.setting) $value is already reserved by this managed project." `
                        "$([string]$row.setting) $value 포트는 현재 관리 프로젝트에서 이미 사용 중입니다.")
                }
                $currentEnvValues = ConvertFrom-PalworldEnvText ([string]$targetEditor.Text)
                $otherPortKey = if ([string]$row.id -eq "game-port") {
                    "PAL_SETTING_RESTAPIPort"
                }
                else { "SERVER_PORT" }
                $otherPort = if ($currentEnvValues.Contains($otherPortKey)) {
                    [string]$currentEnvValues[$otherPortKey]
                }
                else { "" }
                if ($otherPort -and $otherPort -eq $value) {
                    throw (Get-PalworldLocalizedText `
                        "Game UDP and REST API TCP ports must be different." `
                        "게임 UDP 포트와 REST API TCP 포트는 서로 달라야 합니다.")
                }
            }
            $updatedEnv = [string]$targetEditor.Text
            foreach ($key in @($row.env_keys)) {
                $envValue = ConvertTo-PalworldImportEnvValue `
                    -Key ([string]$key) -Value $value -ValueType ([string]$row.value_type)
                $updatedEnv = Set-PalworldEnvTextValue `
                    -Content $updatedEnv -Key ([string]$key) -Value $envValue
            }
            $targetEditor.Text = $updatedEnv
            $row.value = $value
            if ([string]$row.status -eq "BLOCKED") { $row.status = "REVIEW" }
            $state.Dirty = $false
            & $populateReviewList ([string]$row.id)
            $validation.Text = Get-PalworldLocalizedText `
                "PASS · Value synchronized to the generated ENV." `
                "PASS · 값을 생성될 ENV에 반영했습니다."
            $validation.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        catch {
            $validation.Text = [string]$_.Exception.Message
            $validation.ForeColor = [System.Drawing.Color]::DarkRed
        }
    }.GetNewClosure())

    $continueButton.Add_Click({
        if ($state.Dirty) {
            $validation.Text = Get-PalworldLocalizedText `
                "Synchronize the selected value to ENV before importing." `
                "선택한 값을 ENV에 반영한 뒤 가져오기를 실행하세요."
            $validation.ForeColor = [System.Drawing.Color]::DarkRed
            return
        }
        $failedItem = $reviewList.Items | Where-Object {
            [string]$_.Tag.status -eq "FAILED"
        } | Select-Object -First 1
        if ($failedItem) {
            $failedItem.Selected = $true
            $failedItem.EnsureVisible()
            $validation.Text = Get-PalworldLocalizedText `
                "Import cannot continue because $([string]$failedItem.Tag.setting) could not be represented safely." `
                "$([string]$failedItem.Tag.setting) 설정을 안전하게 표현할 수 없어 가져오기를 진행할 수 없습니다."
            $validation.ForeColor = [System.Drawing.Color]::DarkRed
            return
        }
        $blockedItem = $reviewList.Items | Where-Object {
            [string]$_.Tag.status -eq "BLOCKED"
        } | Select-Object -First 1
        if ($blockedItem) {
            $blockedItem.Selected = $true
            $blockedItem.EnsureVisible()
            $validation.Text = if ([string]$blockedItem.Tag.value) {
                Get-PalworldLocalizedText `
                    "Resolve the conflict for $([string]$blockedItem.Tag.setting), then sync an unused value to ENV." `
                    "$([string]$blockedItem.Tag.setting) 충돌을 해결하고 사용하지 않는 값을 ENV에 반영하세요."
            }
            else {
                Get-PalworldLocalizedText `
                    "Set $([string]$blockedItem.Tag.setting) before importing." `
                    "가져오기 전에 $([string]$blockedItem.Tag.setting) 값을 입력하세요."
            }
            $validation.ForeColor = [System.Drawing.Color]::DarkRed
            return
        }
        try {
            $envValidation = Test-PalworldServerEnvText ([string]$targetEditor.Text)
            $dialog.Tag = [pscustomobject]@{
                TargetEnv = [string]$targetEditor.Text
                GamePort = [int]$envValidation.GamePort
                RestPort = [int]$envValidation.RestPort
            }
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
        }
        catch {
            $validation.Text = Get-PalworldLocalizedText `
                "Generated ENV is not ready: $([string]$_.Exception.Message)" `
                "생성될 ENV를 확인하세요: $([string]$_.Exception.Message)"
            $validation.ForeColor = [System.Drawing.Color]::DarkRed
        }
    }.GetNewClosure())
    $dialog.AcceptButton = $continueButton
    $dialog.CancelButton = $cancelButton
    & $populateReviewList
    if ($env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-import-review-ui") {
        try {
            $dialog.Show()
            if ($reviewList.Items.Count -gt 0) { $reviewList.Items[0].Selected = $true }
            [System.Windows.Forms.Application]::DoEvents()
            if ($env:PALWORLD_CLIENT_TEST_SCREENSHOT) {
                $bitmap = New-Object System.Drawing.Bitmap($dialog.Width, $dialog.Height)
                try {
                    $dialog.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $dialog.Width, $dialog.Height)))
                    $bitmap.Save([IO.Path]::GetFullPath($env:PALWORLD_CLIENT_TEST_SCREENSHOT))
                }
                finally { $bitmap.Dispose() }
            }
            return $null
        }
        finally {
            $dialog.Close()
            $dialog.Dispose()
        }
    }
    try {
        [void]$dialog.ShowDialog($Owner)
        return $dialog.Tag
    }
    finally { $dialog.Dispose() }
}

function Show-PalworldImportStopRequiredDialog {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Message
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = Get-PalworldLocalizedText "Source Server Must Be Stopped" "원본 서버를 먼저 종료하세요"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(620, 230)
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog
    $label = New-Object System.Windows.Forms.Label
    $label.Text = (Get-PalworldLocalizedText `
        "The existing server is still running or could not be identified safely. Stop it without changing Pal/Saved, then select Continue After Stopping.`r`n`r`nDetails: " `
        "기존 서버가 아직 실행 중이거나 안전하게 식별되지 않았습니다. Pal/Saved를 변경하지 말고 서버를 종료한 뒤 '종료 후 계속'을 누르세요.`r`n`r`n상세: ") + $Message
    $label.Location = New-Object System.Drawing.Point(16, 16)
    $label.Size = New-Object System.Drawing.Size(588, 145)
    $dialog.Controls.Add($label)
    $continueButton = New-Object System.Windows.Forms.Button
    $continueButton.Text = Get-PalworldLocalizedText "Continue After Stopping" "종료 후 계속"
    $continueButton.Location = New-Object System.Drawing.Point(286, 178)
    $continueButton.Size = New-Object System.Drawing.Size(180, 34)
    $continueButton.DialogResult = [System.Windows.Forms.DialogResult]::Retry
    $dialog.Controls.Add($continueButton)
    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = Get-PalworldLocalizedText "Cancel Import" "가져오기 취소"
    $cancelButton.Location = New-Object System.Drawing.Point(474, 178)
    $cancelButton.Size = New-Object System.Drawing.Size(130, 34)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)
    $dialog.AcceptButton = $continueButton
    $dialog.CancelButton = $cancelButton
    try { return $dialog.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::Retry }
    finally { $dialog.Dispose() }
}

function Test-PalworldTcpPort {
    param(
        [Parameter(Mandatory = $true)][string]$TargetHost,
        [Parameter(Mandatory = $true)][int]$Port,
        [ValidateRange(100, 10000)][int]$TimeoutMilliseconds = 1500
    )
    $client = New-Object System.Net.Sockets.TcpClient
    $async = $null
    try {
        $async = $client.BeginConnect($TargetHost, $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne($TimeoutMilliseconds, $false)) { return $false }
        $client.EndConnect($async)
        return $client.Connected
    }
    catch { return $false }
    finally {
        if ($async -and $async.AsyncWaitHandle) { $async.AsyncWaitHandle.Close() }
        $client.Close()
    }
}

function Get-PalworldNetworkNotice {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Server
    )
    Assert-PalworldServerName $Server
    $remote = Get-PalworldRemoteServerEnv -Connection $Connection -Owner $Owner -Server $Server
    $validation = Test-PalworldServerEnvText $remote.Content
    $commonPath = "$($remote.Project)/config/common.env"
    $commonText = Get-PalworldRemoteTextFile -Connection $Connection -Owner $Owner -RemotePath $commonPath
    $common = ConvertFrom-PalworldEnvText $commonText
    $managerPort = 18080
    if ($common.Contains("MANAGER_API_PORT")) {
        if (-not [int]::TryParse([string]$common.MANAGER_API_PORT, [ref]$managerPort) -or $managerPort -lt 1 -or $managerPort -gt 65535) {
            throw "common.env MANAGER_API_PORT is invalid."
        }
    }
    $container = "palworld-$Server"
    $containerLiteral = ConvertTo-PosixLiteral $container
    $gameKeyLiteral = ConvertTo-PosixLiteral "$($validation.GamePort)/udp"
    $managerKeyLiteral = ConvertTo-PosixLiteral "$managerPort/tcp"
    $probeScript = @'
set +e
state="$(docker inspect --format '{{.State.Status}}' "$PAL_CONTAINER" 2>/dev/null)"
if test -n "$state"; then printf 'PAL_STATE=%s\n' "$state"; else printf 'PAL_STATE=missing\n'; fi
docker port "$PAL_CONTAINER" "$PAL_GAME_KEY" 2>/dev/null | sed 's/^/PAL_GAME_MAP=/'
docker port "$PAL_CONTAINER" "$PAL_MANAGER_KEY" 2>/dev/null | sed 's/^/PAL_REST_MAP=/'
exit 0
'@.Trim()
    $inspectCommand = "__PALWORLD_SUDO__ env PAL_CONTAINER=$containerLiteral " +
        "PAL_GAME_KEY=$gameKeyLiteral PAL_MANAGER_KEY=$managerKeyLiteral bash -c " +
        (ConvertTo-PosixLiteral $probeScript)
    $inspect = Invoke-PalworldSshCommand `
        -Connection $Connection -Owner $Owner -Command $inspectCommand -TimeoutSeconds 15 -Quiet
    $stateMatch = [Text.RegularExpressions.Regex]::Match($inspect.Output, 'PAL_STATE=([^\r\n]*)')
    $state = if ($stateMatch.Success) { $stateMatch.Groups[1].Value.Trim() } else { "missing" }
    $gameMappings = @([Text.RegularExpressions.Regex]::Matches($inspect.Output, 'PAL_GAME_MAP=([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
    $restMappings = @([Text.RegularExpressions.Regex]::Matches($inspect.Output, 'PAL_REST_MAP=([^\r\n]+)') | ForEach-Object { $_.Groups[1].Value.Trim() })
    $lines = New-Object System.Collections.Generic.List[string]
    if ($gameMappings | Where-Object { $_ -match ":$($validation.GamePort)$" }) {
        $lines.Add("[PASS] $Server game UDP $($validation.GamePort) · Docker mapping present")
    }
    else {
        $lines.Add("[WARN] $Server game UDP $($validation.GamePort) · Docker mapping not confirmed")
    }
    $expose = [string]$validation.Values.REST_API_EXPOSE -match '^(?i:true)$'
    $restPortMapped = @($restMappings | Where-Object { $_ -match ":$($validation.RestPort)$" })
    if ($restPortMapped.Count -eq 0) {
        $lines.Add("[WARN] $Server REST API TCP $($validation.RestPort) · Docker mapping not confirmed")
    }
    elseif (-not $expose -and @($restPortMapped | Where-Object { $_ -notmatch '^127\.0\.0\.1:' }).Count -gt 0) {
        $lines.Add("[WARN] $Server REST API is configured private but its Docker mapping is not localhost-only")
    }
    elseif ($expose -and @($restPortMapped | Where-Object { $_ -match '^127\.0\.0\.1:' }).Count -eq $restPortMapped.Count) {
        $lines.Add("[WARN] $Server REST_API_EXPOSE=true but TCP $($validation.RestPort) is localhost-only")
    }
    elseif ($state -ne "running") {
        $lines.Add("[INFO] $Server container state: $state · live Server API connection check skipped")
    }
    elseif (-not $expose) {
        $lines.Add("[PASS] $Server origin REST API TCP $($validation.RestPort) · localhost-only as configured")
    }
    else {
        $lines.Add("[PASS] $Server origin REST API TCP $($validation.RestPort) · host-accessible Docker mapping")
    }

    $mappedApi = Get-SelectedAdminApiConnection
    if (-not ($mappedApi -and
        [string]$mappedApi.SshConnectionId -eq [string]$Connection.Id -and
        [string]$mappedApi.ManagedServerName -eq $Server -and
        [string]$mappedApi.ServerHost)) {
        $mappedApi = $null
    }
    if ($state -eq "running" -and ($mappedApi -or $expose)) {
        $tcpTarget = [string]$Connection.Host
        $tcpPort = [int]$validation.RestPort
        $endpointLabel = "direct Server API ${tcpTarget}:$tcpPort"
        if ($mappedApi) {
            $apiAddress = [string]$mappedApi.ServerHost
            $tcpPort = [int]$mappedApi.Port
            if ($apiAddress -match '^(?i)https?://') {
                $tcpTarget = ([Uri]$apiAddress).Host
                $endpointLabel = "configured Server API $($apiAddress.TrimEnd('/')):$tcpPort"
            }
            else {
                $tcpTarget = $apiAddress
                $endpointLabel = "configured Server API ${apiAddress}:$tcpPort"
            }
        }
        if (Test-PalworldTcpPort -TargetHost $tcpTarget -Port $tcpPort) {
            $lines.Add("[PASS] $Server $endpointLabel · TCP reachable from this Windows PC")
        }
        else {
            $lines.Add("[WARN] $Server $endpointLabel · TCP not reachable from this Windows PC")
        }
    }
    $forwardingPorts = "game UDP $($validation.GamePort)"
    if ($mappedApi -and [string]$mappedApi.ServerHost -match '^(?i)https://') {
        $forwardingPorts += ", HTTPS proxy TCP $([int]$mappedApi.Port) (keep origin REST TCP $($validation.RestPort) private)"
    }
    elseif ($expose) {
        $forwardingPorts += ", REST API TCP $($validation.RestPort)"
    }
    $lines.Add(
        "[WARN] $Server external path is not automatically verified · confirm router/NAT/cloud firewall forwarding for $forwardingPorts"
    )
    $community = $validation.Values.Contains("COMMUNITY_SERVER") -and
        [string]$validation.Values.COMMUNITY_SERVER -match '^(?i:true)$'
    if ($community) {
        $lines.Add("[INFO] Community mode enabled · 27015/27016 TCP/UDP are advisory only, not fixed Palworld requirements")
    }
    return @($lines)
}

function Get-PalworldSshPayloadPath {
    param([ValidateSet("setup", "test", "manage")][string]$Name)
    $directory = if ($env:PALWORLD_SSH_PAYLOAD_DIR) {
        [IO.Path]::GetFullPath($env:PALWORLD_SSH_PAYLOAD_DIR)
    }
    else {
        Join-Path $PSScriptRoot "generated"
    }
    $path = Join-Path $directory "$Name.tar.gz"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "SSH operation payload is missing: $Name"
    }
    return $path
}

function Send-PalworldSshPayload {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [ValidateSet("setup", "test", "manage")][string]$Name
    )
    $payload = Get-PalworldSshPayloadPath $Name
    $hash = (Get-FileHash -LiteralPath $payload -Algorithm SHA256).Hash.ToLowerInvariant()
    $remoteDirectory = "/tmp/palworld-ssh-manager-$([Guid]::NewGuid().ToString('N'))-$Name"
    $remoteArchive = "$remoteDirectory/payload.tar.gz"
    $directoryLiteral = ConvertTo-PosixLiteral $remoteDirectory
    [void](Invoke-PalworldSshSimpleCommand `
        -Connection $Connection `
        -Owner $Owner `
        -Command "umask 077; mkdir -p -- $directoryLiteral; printf 'palworld-ssh-manager-v1\n' > $directoryLiteral/.palworld-ssh-session")
    $sftp = $null
    $stream = $null
    try {
        $sftp = Connect-PalworldSshService `
            -Connection $Connection `
            -Kind Sftp `
            -Owner $Owner `
            -OperationTimeoutSeconds 600
        $stream = [IO.File]::OpenRead($payload)
        Send-PalworldSftpFile `
            -Sftp $sftp `
            -Stream $stream `
            -RemotePath $remoteArchive `
            -TimeoutSeconds 600
    }
    catch {
        try {
            [void](Invoke-PalworldSshSimpleCommand -Connection $Connection -Owner $Owner -Command "rm -rf -- $directoryLiteral")
        } catch { }
        throw
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($sftp) {
            Close-PalworldSftpClient -Sftp $sftp
        }
    }
    $archiveLiteral = ConvertTo-PosixLiteral $remoteArchive
    $verify = "printf '%s  %s\n' " + (ConvertTo-PosixLiteral $hash) + " $archiveLiteral | sha256sum -c - >/dev/null; tar -xzf $archiveLiteral -C $directoryLiteral; rm -f -- $archiveLiteral"
    [void](Invoke-PalworldSshSimpleCommand `
        -Connection $Connection `
        -Owner $Owner `
        -Command $verify `
        -TimeoutSeconds 120)
    return $remoteDirectory
}

function Remove-PalworldSshTemporaryDirectory {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$RemoteDirectory
    )
    if ($RemoteDirectory -notmatch '^/tmp/palworld-ssh-manager-[a-f0-9]{32}-(?:setup|test|manage)$') {
        throw "Refusing to remove an unrecognized SSH temporary directory."
    }
    try {
        [void](Invoke-PalworldSshSimpleCommand `
            -Connection $Connection `
            -Owner $Owner `
            -Command ("rm -rf -- " + (ConvertTo-PosixLiteral $RemoteDirectory)))
    }
    catch {
        Add-PalworldSshOutput "`r`n[WARN] Temporary cleanup deferred until the next connection: $RemoteDirectory`r`n"
    }
}

function Get-PalworldRemoteOperationFailureDetail {
    param([AllowEmptyString()][string]$Output)
    if (-not $Output) { return "" }
    try {
        $payload = Get-PalworldJsonFromSshOutput $Output
        if ($payload -and $payload.PSObject.Properties["error"] -and [string]$payload.error) {
            return ([string]$payload.error).Trim()
        }
    }
    catch { }
    $clean = [Text.RegularExpressions.Regex]::Replace(
        $Output,
        "\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])",
        ""
    )
    $candidate = @(
        $clean -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object {
                $_ -and (
                    $_ -match '^(?:\[FAIL\]|ERROR:|오류:|치명적 경고:|[A-Za-z]+Error:)' -or
                    $_ -match '(?i)failed|conflict|already assigned|not found|invalid|실패|충돌|사용 중|찾을 수|잘못'
                )
            }
    ) | Select-Object -Last 1
    if (-not $candidate) { return "" }
    if ($candidate.Length -gt 800) { return $candidate.Substring(0, 800) + "…" }
    return [string]$candidate
}

function Invoke-PalworldPackagedSshOperation {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [ValidateSet("setup", "test", "manage")][string]$Payload,
        [Parameter(Mandatory = $true)][scriptblock]$BuildCommand,
        [ValidateRange(1, 7200)][int]$TimeoutSeconds = 1800
    )
    $workDirectory = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $temporary = Send-PalworldSshPayload -Connection $Connection -Owner $Owner -Name $Payload
    try {
        $command = & $BuildCommand $workDirectory $temporary
        $result = Invoke-PalworldSshCommand `
            -Connection $Connection `
            -Owner $Owner `
            -Command $command `
            -TimeoutSeconds $TimeoutSeconds
        $script:PalworldSshLastRemoteOperationOutput = [string]$result.Output
        if ($result.ExitCode -ne 0) {
            $detail = Get-PalworldRemoteOperationFailureDetail ([string]$result.Output)
            if ($detail) {
                throw "Remote operation failed with exit code $($result.ExitCode): $detail"
            }
            throw "Remote operation failed with exit code $($result.ExitCode)."
        }
        return $result
    }
    finally {
        Remove-PalworldSshTemporaryDirectory `
            -Connection $Connection `
            -Owner $Owner `
            -RemoteDirectory $temporary
    }
}

function New-PalworldSetupCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Tools,
        [AllowEmptyString()][string]$Server = "",
        [ValidateSet("setup", "update")][string]$Mode = "setup"
    )
    if ($Server -and $Server -notmatch '^server[1-9][0-9]*$') { throw "Invalid server name." }
    $projectLiteral = ConvertTo-PosixLiteral $Project
    $toolsLiteral = ConvertTo-PosixLiteral $Tools
    if ($Mode -eq "update" -and -not $Server) { throw "Update requires a server name." }
    $serverArguments = if ($Server) { " --server " + (ConvertTo-PosixLiteral $Server) } else { "" }
    $templateRefreshArgument = if ($Mode -eq "update") { " --refresh-server-template" } else { "" }
    $envLanguage = if ($script:ApplicationLanguage -eq "en") { "en" } else { "ko" }
    $template = @'
project=__PROJECT__; tools=__TOOLS__; test -d "$project" && __PALWORLD_SUDO__ env PALWORLD_PROJECT_DIR="$project" PALWORLD_INSTALL_DIR="$tools/install" PALWORLD_ENV_LANGUAGE=__ENV_LANGUAGE__ PYTHONDONTWRITEBYTECODE=1 bash "$tools/install/manager" prepare-scaffold --scaffold "$tools/scaffold" --language __ENV_LANGUAGE____TEMPLATE_REFRESH__ && __PALWORLD_SUDO__ env PALWORLD_PROJECT_DIR="$project" PALWORLD_INSTALL_DIR="$tools/install" PALWORLD_ENV_LANGUAGE=__ENV_LANGUAGE__ PYTHONDONTWRITEBYTECODE=1 bash "$tools/install/manager" __MODE____SERVER_ARGS__
'@
    return $template.Replace("__PROJECT__", $projectLiteral).
        Replace("__TOOLS__", $toolsLiteral).
        Replace("__ENV_LANGUAGE__", $envLanguage).
        Replace("__TEMPLATE_REFRESH__", $templateRefreshArgument).
        Replace("__MODE__", $Mode).
        Replace("__SERVER_ARGS__", $serverArguments).Trim()
}

function New-PalworldPrepareHostCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Tools
    )
    $projectLiteral = ConvertTo-PosixLiteral $Project
    $toolsLiteral = ConvertTo-PosixLiteral $Tools
    $envLanguage = if ($script:ApplicationLanguage -eq "en") { "en" } else { "ko" }
    $template = @'
project=__PROJECT__; tools=__TOOLS__; test -d "$project" && __PALWORLD_SUDO__ env PALWORLD_PROJECT_DIR="$project" PALWORLD_INSTALL_DIR="$tools/install" PALWORLD_ENV_LANGUAGE=__ENV_LANGUAGE__ PYTHONDONTWRITEBYTECODE=1 bash "$tools/install/manager" prepare-scaffold --scaffold "$tools/scaffold" --language __ENV_LANGUAGE__ && __PALWORLD_SUDO__ env PALWORLD_PROJECT_DIR="$project" PALWORLD_INSTALL_DIR="$tools/install" PALWORLD_ENV_LANGUAGE=__ENV_LANGUAGE__ PYTHONDONTWRITEBYTECODE=1 bash "$tools/install/manager" prepare
'@
    return $template.Replace("__PROJECT__", $projectLiteral).
        Replace("__TOOLS__", $toolsLiteral).
        Replace("__ENV_LANGUAGE__", $envLanguage).Trim()
}

function New-PalworldImportToolCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Tools,
        [Parameter(Mandatory = $true)][string]$Arguments
    )
    $projectLiteral = ConvertTo-PosixLiteral $Project
    $toolsLiteral = ConvertTo-PosixLiteral $Tools
    $envLanguage = if ($script:ApplicationLanguage -eq "en") { "en" } else { "ko" }
    $templateLanguage = if ($envLanguage -eq "ko") { "kr" } else { "en" }
    $template = @'
project=__PROJECT__; tools=__TOOLS__; test -d "$project"; __PALWORLD_SUDO__ env PALWORLD_PROJECT_DIR="$project" PALWORLD_INSTALL_DIR="$tools/install" PALWORLD_ENV_LANGUAGE=__ENV_LANGUAGE__ PALWORLD_SERVER_TEMPLATE_SOURCE="$tools/scaffold/config/__TEMPLATE_LANGUAGE__/server.template.env" PYTHONDONTWRITEBYTECODE=1 bash "$tools/install/manager" import-tool __ARGS__
'@
    return $template.Replace("__PROJECT__", $projectLiteral).
        Replace("__TOOLS__", $toolsLiteral).
        Replace("__ENV_LANGUAGE__", $envLanguage).
        Replace("__TEMPLATE_LANGUAGE__", $templateLanguage).
        Replace("__ARGS__", $Arguments).Trim()
}

function Invoke-PalworldImportTool {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Arguments,
        [ValidateRange(1, 7200)][int]$TimeoutSeconds = 300
    )
    $result = Invoke-PalworldPackagedSshOperation `
        -Connection $Connection -Owner $Owner -Payload setup -TimeoutSeconds $TimeoutSeconds `
        -BuildCommand {
            param($project, $tools)
            New-PalworldImportToolCommand `
                -Project $project -Tools $tools -Arguments $Arguments
        }.GetNewClosure()
    return Get-PalworldJsonFromSshOutput $result.Output
}

function Send-PalworldRemoteTemporaryText {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Content,
        [string]$Prefix = "palworld-import-env"
    )
    if ($Prefix -notmatch '^[A-Za-z0-9._-]+$') { throw "Invalid remote temporary file prefix." }
    $remotePath = "/tmp/$Prefix-$([Guid]::NewGuid().ToString('N')).tmp"
    $remotePathLiteral = ConvertTo-PosixLiteral $remotePath
    $sftp = $null
    $stream = $null
    $uploadComplete = $false
    try {
        $encoding = New-Object System.Text.UTF8Encoding -ArgumentList $false
        $normalized = ($Content -replace "`r`n", "`n" -replace "`r", "`n").TrimEnd("`n") + "`n"
        $stream = New-Object System.IO.MemoryStream(,$encoding.GetBytes($normalized))
        # Create the exact destination with a restrictive mode before SFTP
        # writes any credentials. Uploading a new SFTP file directly can honor
        # the remote account's permissive umask and briefly expose server ENV.
        [void](Invoke-PalworldSshSimpleCommand `
            -Connection $Connection `
            -Owner $Owner `
            -Command "umask 077; : > $remotePathLiteral; chmod 0600 $remotePathLiteral" `
            -TimeoutSeconds 30)
        $sftp = Connect-PalworldSshService -Connection $Connection -Kind Sftp -Owner $Owner
        Send-PalworldSftpFile `
            -Sftp $sftp -Stream $stream -RemotePath $remotePath -TimeoutSeconds 120
        $uploadComplete = $true
        return $remotePath
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ($sftp) { Close-PalworldSftpClient -Sftp $sftp }
        if (-not $uploadComplete -and -not $script:PalworldSshClosing) {
            try {
                [void](Invoke-PalworldSshSimpleCommand `
                    -Connection $Connection `
                    -Owner $Owner `
                    -Command "rm -f -- $remotePathLiteral" `
                    -TimeoutSeconds 15)
            }
            catch {
                # Preserve the upload failure. The incomplete file is mode 0600
                # and uses an unguessable path if transport cleanup also fails.
            }
        }
    }
}

function New-PalworldManagerCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Tools,
        [Parameter(Mandatory = $true)][string]$Arguments
    )
    $projectLiteral = ConvertTo-PosixLiteral $Project
    $toolsLiteral = ConvertTo-PosixLiteral $Tools
    $template = @'
project=__PROJECT__; tools=__TOOLS__; test -d "$project"; __PALWORLD_SUDO__ env PALWORLD_PROJECT_DIR="$project" PALWORLD_INSTALL_DIR="$tools/install" PYTHONDONTWRITEBYTECODE=1 bash "$tools/install/manager" __ARGS__
'@
    return $template.Replace("__PROJECT__", $projectLiteral).
        Replace("__TOOLS__", $toolsLiteral).
        Replace("__ARGS__", $Arguments).Trim()
}

function New-PalworldTestCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$Tools,
        [Parameter(Mandatory = $true)][string]$Server,
        [ValidateSet("yes", "no")][string]$ManualStart = "no"
    )
    if ($Server -ne "all" -and $Server -notmatch '^server[1-9][0-9]*$') { throw "Invalid server name." }
    $projectLiteral = ConvertTo-PosixLiteral $Project
    $toolsLiteral = ConvertTo-PosixLiteral $Tools
    $serverLiteral = ConvertTo-PosixLiteral $Server
    $manualStartLiteral = ConvertTo-PosixLiteral $ManualStart
    $template = @'
project=__PROJECT__; tools=__TOOLS__; test -d "$project"; __PALWORLD_SUDO__ env PALWORLD_PROJECT_DIR="$project" PALWORLD_INSTALL_DIR="$tools/install" PYTHONDONTWRITEBYTECODE=1 bash "$tools/install/test" --server __SERVER__ --manual-start __MANUAL_START__
'@
    return $template.Replace("__PROJECT__", $projectLiteral).
        Replace("__TOOLS__", $toolsLiteral).
        Replace("__SERVER__", $serverLiteral).
        Replace("__MANUAL_START__", $manualStartLiteral).Trim()
}

function Test-PalworldSshHostReadiness {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    $preflightCommand = @'
set -eu; printf 'kernel=%s\n' "$(uname -s)"; printf 'arch=%s\n' "$(uname -m)"; if [ -r /etc/os-release ]; then . /etc/os-release; printf 'os=%s\n' "${ID:-unknown}"; else printf 'os=unknown\n'; fi; printf 'user=%s\n' "$(id -un)"; for c in bash base64 tar sha256sum readlink; do command -v "$c" >/dev/null || { echo "missing=$c"; exit 1; }; done; date '+time=%Y-%m-%dT%H:%M:%S%z'
'@.Trim()
    $output = Invoke-PalworldSshSimpleCommand `
        -Connection $Connection `
        -Owner $Owner `
        -Command $preflightCommand
    $values = @{}
    foreach ($line in $output -split "`r?`n") {
        if ($line -match '^([^=]+)=(.*)$') { $values[$matches[1]] = $matches[2] }
    }
    if ($values.kernel -ne "Linux") { throw "Only Linux SSH hosts are supported." }
    if ($values.arch -notin @("x86_64", "amd64")) {
        throw "The current Palworld image supports x86-64 only. Remote architecture: $($values.arch)"
    }
    if ($values.os -notin @("ubuntu", "debian")) {
        throw "Automated Setup supports Ubuntu or Debian. Remote OS: $($values.os)"
    }
    $sudo = Invoke-PalworldSshCommand `
        -Connection $Connection `
        -Owner $Owner `
        -Command "__PALWORLD_SUDO__ -k true" `
        -TimeoutSeconds 30
    if ($sudo.ExitCode -ne 0) {
        throw (Get-PalworldSudoAuthenticationErrorMessage)
    }
    $workDirectory = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $workDirectoryLiteral = ConvertTo-PosixLiteral $workDirectory
    $directoryOutput = Invoke-PalworldSshSimpleCommand `
        -Connection $Connection `
        -Owner $Owner `
        -Command "if test -d $workDirectoryLiteral; then printf 'exists=yes\n'; if test -w $workDirectoryLiteral; then printf 'writable=yes\n'; else printf 'writable=no\n'; fi; else printf 'exists=no\nwritable=no\n'; fi"
    $directoryExists = $directoryOutput -match '(?m)^exists=yes\r?$'
    $directoryWritable = $directoryOutput -match '(?m)^writable=yes\r?$'
    $projectPrepared = $false
    $commonReviewed = $false
    $commonValid = $false
    $common = $null
    $timezoneApplied = $false
    $hostTimezone = "unknown"
    $clockSkewSeconds = $null
    $ntpSynchronized = "unknown"

    Add-PalworldSshOutput "`r`n[PASS] Connection preflight · Linux $($values.os) $($values.arch) · SSH user $($values.user) · sudo authentication`r`n[PASS] Required transfer tools: bash, base64, tar, sha256sum, readlink`r`n[PASS] Configured project path is safe: $workDirectory`r`n"
    if (-not $directoryExists) {
        Add-PalworldSshOutput "[ACTION REQUIRED] Prepare the project work directory first: $workDirectory`r`n[INFO] Review Common Settings and Host Check will be available afterward.`r`n"
    }
    elseif (-not $directoryWritable) {
        Add-PalworldSshOutput "[ACTION REQUIRED] Prepare Work Dir must repair SSH-user write access: $workDirectory`r`n"
    }
    else {
        Add-PalworldSshOutput "[PASS] Project directory exists and is writable: $workDirectory`r`n"
        $projectPrepared = Test-PalworldRemoteProjectInitialized `
            -Connection $Connection -Owner $Owner -Project $workDirectory
        if (-not $projectPrepared) {
            Add-PalworldSshOutput "[ACTION REQUIRED] Select Prepare Work Dir to install the project scaffold and Common Settings template.`r`n"
        }
        else {
            $common = Get-PalworldRemoteCommonEnv -Connection $Connection -Owner $Owner
            try {
                $commonValidation = Test-PalworldCommonEnvText $common.Content
                $commonValid = $true
                $commonReviewed = [bool]$common.Reviewed
            }
            catch {
                $commonValid = $false
                $commonReviewed = $false
                Add-PalworldSshOutput "[ACTION REQUIRED] Common Settings validation failed: $([string]$_.Exception.Message)`r`n"
            }
            if ($commonValid -and -not $commonReviewed) {
                Add-PalworldSshOutput "[ACTION REQUIRED] Select Review Common Settings, confirm the values, and save them before Host Check.`r`n"
            }
            elseif ($commonValid) {
                $timezone = [string]$commonValidation.Values.TZ
                $localEpoch = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                $timeResult = Invoke-PalworldPackagedSshOperation `
                    -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 180 `
                    -BuildCommand {
                        param($remoteProject, $tools)
                        New-PalworldManagerCommand `
                            -Project $remoteProject -Tools $tools -Arguments "host-time"
                    }
                if ($timeResult.ExitCode -ne 0) {
                    throw "Host timezone could not be checked or applied from Common Settings."
                }
                $previousTimezone = ([Regex]::Match($timeResult.Output, 'PAL_TZ_PREVIOUS=([^\r\n]+)')).Groups[1].Value.Trim()
                $hostTimezone = ([Regex]::Match($timeResult.Output, 'PAL_TZ_CURRENT=([^\r\n]+)')).Groups[1].Value.Trim()
                $zoneReady = $timeResult.Output -match 'PAL_TZ_READY=yes'
                $remoteEpochText = ([Regex]::Match($timeResult.Output, 'PAL_REMOTE_EPOCH=([0-9]+)')).Groups[1].Value
                $remoteTime = ([Regex]::Match($timeResult.Output, 'PAL_REMOTE_TIME=([^\r\n]+)')).Groups[1].Value.Trim()
                $ntpSynchronized = ([Regex]::Match($timeResult.Output, 'PAL_NTP=([^\r\n]+)')).Groups[1].Value.Trim()
                if ($remoteEpochText) {
                    $clockSkewSeconds = [Math]::Abs([int64]$remoteEpochText - [int64]$localEpoch)
                }
                $timezoneApplied = $zoneReady -and $hostTimezone -eq $timezone
                if ($timezoneApplied) {
                    if ($previousTimezone -eq $hostTimezone) {
                        Add-PalworldSshOutput "[PASS] Host timezone matches Common Settings: $hostTimezone`r`n"
                    }
                    else {
                        Add-PalworldSshOutput "[PASS] Host timezone applied from Common Settings: $previousTimezone -> $hostTimezone`r`n"
                    }
                }
                else {
                    Add-PalworldSshOutput "[WARN] Host timezone is not ready: requested $timezone · current $hostTimezone. Setup will install or repair tzdata.`r`n"
                }
                if ($null -ne $clockSkewSeconds -and $clockSkewSeconds -le 10) {
                    Add-PalworldSshOutput "[PASS] Remote clock is within $clockSkewSeconds second(s) of Windows · $remoteTime`r`n"
                }
                elseif ($null -ne $clockSkewSeconds) {
                    Add-PalworldSshOutput "[WARN] Remote clock differs from Windows by $clockSkewSeconds seconds · verify NTP before hosting.`r`n"
                }
                if ($ntpSynchronized -match '^(?i:yes|true)$') {
                    Add-PalworldSshOutput "[PASS] Host NTP synchronization is active.`r`n"
                }
                else {
                    Add-PalworldSshOutput "[WARN] Host NTP synchronization was not confirmed: $ntpSynchronized`r`n"
                }
            }
        }
    }
    $ready = $directoryExists -and $directoryWritable -and $projectPrepared -and
        $commonValid -and $commonReviewed
    return [pscustomobject]@{
        Values = $values
        WorkDirectory = $workDirectory
        WorkDirectoryExists = $directoryExists
        WorkDirectoryWritable = $directoryWritable
        ProjectPrepared = $projectPrepared
        CommonSettingsValid = $commonValid
        CommonSettingsReviewed = $commonReviewed
        CommonSettings = $common
        HostTimezone = $hostTimezone
        TimezoneApplied = $timezoneApplied
        ClockSkewSeconds = $clockSkewSeconds
        NtpSynchronized = $ntpSynchronized
        ReadyForManagement = $ready
    }
}

function Initialize-PalworldSshWorkDirectory {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    $project = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $projectLiteral = ConvertTo-PosixLiteral $project
    $command = @'
set -eu
project=__PROJECT__
uid="$(id -u)"
gid="$(id -g)"
if test -L "$project" || { test -e "$project" && ! test -d "$project"; }; then
    printf 'Unsafe project directory target: %s\n' "$project" >&2
    exit 1
fi
if test -d "$project"; then
    existed=yes
else
    existed=no
    __PALWORLD_SUDO__ env PAL_PROJECT="$project" PAL_UID="$uid" PAL_GID="$gid" bash -c 'install -d -m 0755 -o "$PAL_UID" -g "$PAL_GID" -- "$PAL_PROJECT"'
fi
test -d "$project"
owner="$(stat -c '%U:%G' -- "$project")"
printf 'PAL_WORK_EXISTED=%s\nPAL_WORK_READY=yes\nPAL_WORK_OWNER=%s\n' "$existed" "$owner"
'@.Replace("__PROJECT__", $projectLiteral).Trim()
    $result = Invoke-PalworldSshCommand `
        -Connection $Connection -Owner $Owner -Command $command -TimeoutSeconds 60
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch 'PAL_WORK_READY=yes') {
        throw "Project directory could not be created safely: $project"
    }
    $created = $result.Output -match 'PAL_WORK_EXISTED=no'
    $environmentLanguage = if ($script:ApplicationLanguage -eq "en") { "en" } else { "ko" }
    $prepareResult = Invoke-PalworldPackagedSshOperation `
        -Connection $Connection `
        -Owner $Owner `
        -Payload setup `
        -TimeoutSeconds 180 `
        -BuildCommand {
            param($remoteProject, $tools)
            $projectValue = ConvertTo-PosixLiteral $remoteProject
            $toolsValue = ConvertTo-PosixLiteral $tools
            $languageValue = ConvertTo-PosixLiteral $environmentLanguage
            return "project=$projectValue; tools=$toolsValue; test -d `"`$project`"; __PALWORLD_SUDO__ env PALWORLD_PROJECT_DIR=`"`$project`" PALWORLD_INSTALL_DIR=`"`$tools/install`" PYTHONDONTWRITEBYTECODE=1 bash `"`$tools/install/manager`" prepare-scaffold --scaffold `"`$tools/scaffold`" --language $languageValue"
        }.GetNewClosure()
    $ownerMatch = [Text.RegularExpressions.Regex]::Match(
        [string]$prepareResult.Output,
        'PAL_WORK_OWNER=([^\r\n]+)'
    )
    $ownerText = if ($ownerMatch.Success) { $ownerMatch.Groups[1].Value.Trim() } else { "verified" }
    $message = if ($created) {
        "`r`n[PASS] Project directory created and verified: $project · owner $ownerText`r`n"
    }
    else {
        "`r`n[PASS] Existing project directory ownership was preserved; safe permissions were verified or repaired: $project · owner $ownerText`r`n"
    }
    Add-PalworldSshOutput $message
    Add-PalworldSshOutput (
        Get-PalworldLocalizedText `
            "[PASS] Project scaffold prepared · Common Settings are ready for review.`r`n" `
            "[PASS] 프로젝트 기본 구조 준비 완료 · 이제 공통 설정을 검토하세요.`r`n"
    )
    return [pscustomobject]@{ Project = $project; Created = $created; Owner = $ownerText; Prepared = $true }
}

function Test-PalworldRemoteProjectInitialized {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Project
    )
    $projectLiteral = ConvertTo-PosixLiteral $Project
    $command = @'
project=__PROJECT__; if test -f "$project/config/common.env" && test -f "$project/config/server.template.env" && test -x "$project/operate/pal"; then printf yes; else printf no; fi
'@.Replace("__PROJECT__", $projectLiteral).Trim()
    $result = Invoke-PalworldSshSimpleCommand `
        -Connection $Connection -Owner $Owner -Command $command
    return $result.Trim() -eq "yes"
}

function ConvertFrom-PalworldActionPrerequisitesOutput {
    param(
        [Parameter(Mandatory = $true)][string]$Output,
        [Parameter(Mandatory = $true)][string]$Project
    )
    $values = @{}
    foreach ($match in [Text.RegularExpressions.Regex]::Matches(
        $Output,
        'PAL_([A-Z_]+)=([A-Za-z0-9._-]+)',
        [Text.RegularExpressions.RegexOptions]::CultureInvariant
    )) {
        # PTY prompts such as "guest@host:~$ " or "> " may share the line
        # with command output. The structured PAL_ token is authoritative.
        $values[$match.Groups[1].Value] = $match.Groups[2].Value
    }
    $exists = $values.WORK_EXISTS -eq "yes"
    $writable = $values.WORK_WRITABLE -eq "yes"
    $curlReady = $values.CURL -eq "yes"
    $pythonReady = $values.PYTHON -eq "yes"
    $dockerReady = $values.DOCKER -eq "yes"
    $composeReady = $values.COMPOSE -eq "yes"
    $daemonReady = $values.DAEMON -eq "yes"
    $scaffoldReady = $values.SCAFFOLD -eq "yes"
    return [pscustomobject]@{
        Project = $Project
        Exists = $exists
        Writable = $writable
        Curl = $curlReady
        Python = $pythonReady
        Docker = $dockerReady
        Compose = $composeReady
        Daemon = $daemonReady
        Scaffold = $scaffoldReady
        Ready = $exists -and $writable -and $curlReady -and $pythonReady -and
            $dockerReady -and $composeReady -and $daemonReady -and $scaffoldReady
    }
}

function Get-PalworldSshActionPrerequisites {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    $project = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $projectLiteral = ConvertTo-PosixLiteral $project
    $command = @'
set +e
project=__PROJECT__
if ! test -d "$project"; then
    printf 'PAL_WORK_EXISTS=no\nPAL_WORK_WRITABLE=no\nPAL_CURL=no\nPAL_PYTHON=no\nPAL_DOCKER=no\nPAL_COMPOSE=no\nPAL_DAEMON=no\nPAL_SCAFFOLD=no\n'
    exit 0
fi
printf 'PAL_WORK_EXISTS=yes\n'
if test -w "$project"; then printf 'PAL_WORK_WRITABLE=yes\n'; else printf 'PAL_WORK_WRITABLE=no\n'; fi
if command -v curl >/dev/null 2>&1; then printf 'PAL_CURL=yes\n'; else printf 'PAL_CURL=no\n'; fi
if command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 9) else 1)' >/dev/null 2>&1; then printf 'PAL_PYTHON=yes\n'; else printf 'PAL_PYTHON=no\n'; fi
if command -v docker >/dev/null 2>&1; then
    printf 'PAL_DOCKER=yes\n'
    if docker compose version >/dev/null 2>&1; then printf 'PAL_COMPOSE=yes\n'; else printf 'PAL_COMPOSE=no\n'; fi
    if docker info >/dev/null 2>&1 || (command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet docker); then
        printf 'PAL_DAEMON=yes\n'
    else
        printf 'PAL_DAEMON=no\n'
    fi
else
    printf 'PAL_DOCKER=no\nPAL_COMPOSE=no\nPAL_DAEMON=no\n'
fi
if test -f "$project/config/common.env" && test -f "$project/config/server.template.env" && test -x "$project/operate/pal"; then
    printf 'PAL_SCAFFOLD=yes\n'
else
    printf 'PAL_SCAFFOLD=no\n'
fi
'@.Replace("__PROJECT__", $projectLiteral).Trim()
    $result = Invoke-PalworldSshCommand `
        -Connection $Connection -Owner $Owner -Command $command -TimeoutSeconds 60
    if ($result.ExitCode -ne 0) {
        throw "Automated Management prerequisites check failed with remote exit code $($result.ExitCode)."
    }
    $readiness = ConvertFrom-PalworldActionPrerequisitesOutput `
        -Output $result.Output -Project $project
    $missing = @()
    foreach ($check in @(
        [pscustomobject]@{ Ready = $readiness.Exists; Name = "project directory" },
        [pscustomobject]@{ Ready = $readiness.Writable; Name = "write access" },
        [pscustomobject]@{ Ready = $readiness.Curl; Name = "curl" },
        [pscustomobject]@{ Ready = $readiness.Python; Name = "Python 3.9+" },
        [pscustomobject]@{ Ready = $readiness.Docker; Name = "Docker CLI" },
        [pscustomobject]@{ Ready = $readiness.Compose; Name = "Docker Compose" },
        [pscustomobject]@{ Ready = $readiness.Daemon; Name = "Docker daemon" },
        [pscustomobject]@{ Ready = $readiness.Scaffold; Name = "management scaffold" }
    )) {
        if (-not $check.Ready) { $missing += [string]$check.Name }
    }
    if ($readiness.Ready) {
        Add-PalworldSshOutput "[PASS] Automated Management prerequisites are ready.`r`n"
    }
    else {
        Add-PalworldSshOutput "[FAIL] Automated Management prerequisites are missing: $($missing -join ', '). Run Setup after preparing the project directory.`r`n"
    }
    return $readiness
}

function Get-PalworldJsonFromSshOutput {
    param([Parameter(Mandatory = $true)][string]$Output)
    $clean = [Text.RegularExpressions.Regex]::Replace(
        $Output,
        "\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])",
        ""
    )
    $lines = @($clean -split "`r?`n")
    for ($index = $lines.Count - 1; $index -ge 0; $index--) {
        $line = $lines[$index].Trim()
        for ($start = 0; $start -lt $line.Length; $start++) {
            if ($line[$start] -notin @('[', '{')) { continue }
            $candidate = $line.Substring($start)
            try {
                $parsed = $candidate | ConvertFrom-Json
                if ($parsed -is [System.Array]) {
                    # Windows PowerShell 5.1 emits a JSON array as one pipeline
                    # object. Enumerate it explicitly so callers receive the
                    # individual server records instead of one nested array.
                    foreach ($item in $parsed) { Write-Output $item }
                    return
                }
                return $parsed
            }
            catch { }
        }
    }
    throw "Remote command did not return valid JSON."
}

function Test-PalworldRemoteProjectExists {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    $project = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $projectLiteral = ConvertTo-PosixLiteral $project
    $result = Invoke-PalworldSshSimpleCommand `
        -Connection $Connection `
        -Owner $Owner `
        -Command "if test -d $projectLiteral; then printf yes; else printf no; fi"
    return $result.Trim() -eq "yes"
}

function Get-PalworldSshConfiguredServerNames {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    $project = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $projectLiteral = ConvertTo-PosixLiteral $project
    $command = @'
project=__PROJECT__
for path in "$project"/config/server*.env; do
    test -f "$path" || continue
    name="$(basename -- "$path" .env)"
    case "$name" in server[1-9]|server[1-9][0-9]*) printf '%s\n' "$name" ;; esac
done
'@.Replace("__PROJECT__", $projectLiteral).Trim()
    $output = Invoke-PalworldSshSimpleCommand `
        -Connection $Connection -Owner $Owner -Command $command
    return @(
        $output -split "`r?`n" |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -match '^server[1-9][0-9]*$' } |
            Sort-Object { [int]($_ -replace '^server', '') } -Unique
    )
}

function Merge-PalworldSshServerInventory {
    param(
        [AllowEmptyCollection()][object[]]$Installed = @(),
        [AllowEmptyCollection()][string[]]$ConfiguredNames = @()
    )
    $byName = @{}
    foreach ($item in @($Installed)) {
        if ($null -eq $item) { continue }
        $name = [string]$item.name
        if ($name -match '^server[1-9][0-9]*$') { $byName[$name] = $item }
    }
    foreach ($name in @($ConfiguredNames)) {
        if ($name -notmatch '^server[1-9][0-9]*$' -or $byName.ContainsKey($name)) { continue }
        $byName[$name] = [pscustomobject]@{
            name = $name
            container = "palworld-$name"
            image = ""
            state = "configured"
            status = "config only"
        }
    }
    return @(
        $byName.Values | Sort-Object { [int]([string]$_.name -replace '^server', '') }
    )
}

function Get-PalworldPreferredServerName {
    param(
        [AllowEmptyString()][string]$Current,
        [AllowEmptyCollection()][string[]]$Available = @(),
        [AllowEmptyCollection()][string[]]$Previous = @(),
        [switch]$PreferNew
    )
    $availableNames = @($Available | Where-Object { $_ })
    if ($PreferNew) {
        $previousSet = @{}
        foreach ($name in @($Previous)) { $previousSet[[string]$name] = $true }
        foreach ($name in $availableNames) {
            if (-not $previousSet.ContainsKey([string]$name)) { return [string]$name }
        }
    }
    if ($Current -and $availableNames -contains $Current) { return $Current }
    if ($availableNames.Count -gt 0) { return [string]$availableNames[0] }
    return ""
}

function Resolve-PalworldPostActionApiServer {
    param(
        [AllowEmptyString()][string]$Configured,
        [AllowEmptyString()][string]$Refreshed
    )
    foreach ($candidate in @($Configured, $Refreshed)) {
        if ([string]$candidate -match '^server[1-9][0-9]*$') {
            return [string]$candidate
        }
    }
    throw "Setup completed, but the newly created serverN could not be identified after Refresh Servers. Refresh the list and run Token Show for the new server."
}

function Get-PalworldSetupConnectionDetailLines {
    param(
        [Parameter(Mandatory = $true)][string]$Server,
        [Parameter(Mandatory = $true)]$Settings
    )
    Assert-PalworldServerName $Server
    $lines = if ($script:ApplicationLanguage -eq "ko") {
        @(
            "[PASS] 서버 연결 정보 · $Server",
            "  API 사용자명: $([string]$Settings.Username)",
            "  관리자 비밀번호: $([string]$Settings.Password)",
            "  API access token: $([string]$Settings.AccessToken)",
            "  게임 서버 포트 (UDP): $([int]$Settings.GamePort)",
            "  REST API 포트 (TCP): $([int]$Settings.Port)",
            "[WARN] 인증 정보가 평문으로 표시되었습니다. 로그와 화면 공유 전에 가리세요."
        )
    }
    else {
        @(
            "[PASS] Server connection details · $Server",
            "  API username: $([string]$Settings.Username)",
            "  Admin password: $([string]$Settings.Password)",
            "  API access token: $([string]$Settings.AccessToken)",
            "  Game server port (UDP): $([int]$Settings.GamePort)",
            "  REST API port (TCP): $([int]$Settings.Port)",
            "[WARN] Credentials are shown in plain text. Redact logs and screenshots before sharing."
        )
    }
    $lines += @(
        "[WARN] External port forwarding was not automatically verified.",
        "  Check game UDP $([int]$Settings.GamePort)."
    )
    if ($Settings.RestApiExposed) {
        $lines += "  REST_API_EXPOSE=true: also check REST API TCP $([int]$Settings.Port)."
    }
    return @($lines)
}

function Get-PalworldSshServerList {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    $result = Invoke-PalworldPackagedSshOperation `
        -Connection $Connection `
        -Owner $Owner `
        -Payload manage `
        -TimeoutSeconds 120 `
        -BuildCommand {
            param($project, $tools)
            New-PalworldManagerCommand `
                -Project $project `
                -Tools $tools `
                -Arguments "list --format json"
        }
    $installed = @(Get-PalworldJsonFromSshOutput $result.Output)
    $configured = @(Get-PalworldSshConfiguredServerNames -Connection $Connection -Owner $Owner)
    return @(Merge-PalworldSshServerInventory -Installed $installed -ConfiguredNames $configured)
}

function Test-PalworldTypedConfirmationText {
    param(
        [AllowEmptyString()][string]$Actual,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    return [string]::Equals($Actual, $Expected, [StringComparison]::Ordinal)
}

function New-PalworldTypedConfirmationDialog {
    param(
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $Title
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(520, 190)
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog
    $label = New-Object System.Windows.Forms.Label
    $instruction = Get-PalworldLocalizedText `
        "To continue, enter this exact text: $Expected" `
        "계속하려면 다음 문구를 정확히 입력하세요: $Expected"
    $label.Text = "$Message`r`n`r`n$instruction"
    $label.Location = New-Object System.Drawing.Point(16, 15)
    $label.Size = New-Object System.Drawing.Size(485, 78)
    $dialog.Controls.Add($label)
    $confirmationText = New-Object System.Windows.Forms.TextBox
    $confirmationText.Location = New-Object System.Drawing.Point(16, 100)
    $confirmationText.Size = New-Object System.Drawing.Size(485, 23)
    $dialog.Controls.Add($confirmationText)
    $validation = New-Object System.Windows.Forms.Label
    $validation.Location = New-Object System.Drawing.Point(16, 127)
    $validation.Size = New-Object System.Drawing.Size(300, 42)
    $validation.ForeColor = [System.Drawing.Color]::DarkRed
    $dialog.Controls.Add($validation)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.Location = New-Object System.Drawing.Point(331, 142)
    $cancel.Size = New-Object System.Drawing.Size(80, 30)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = "Continue"
    $ok.Location = New-Object System.Drawing.Point(421, 142)
    $ok.Size = New-Object System.Drawing.Size(80, 30)
    $ok.Enabled = $true
    $ok.Add_Click({
        if ([string]::Equals(
            $confirmationText.Text,
            $Expected,
            [StringComparison]::Ordinal
        )) {
            $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
            $dialog.Close()
            return
        }
        $validation.Text = Get-PalworldLocalizedText `
            "The text does not match. Enter the exact text shown above." `
            "입력 문구가 일치하지 않습니다. 위 문구를 정확히 입력하세요."
        $confirmationText.SelectAll()
        [void]$confirmationText.Focus()
    }.GetNewClosure())
    $dialog.Controls.Add($ok)
    $confirmationText.Add_TextChanged({ $validation.Text = "" }.GetNewClosure())
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    return [pscustomobject]@{
        Form = $dialog
        Input = $confirmationText
        ContinueButton = $ok
        CancelButton = $cancel
        ValidationLabel = $validation
        Expected = $Expected
    }
}

function Show-PalworldTypedConfirmation {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)][string]$Title,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter(Mandatory = $true)][string]$Expected
    )
    $ui = New-PalworldTypedConfirmationDialog `
        -Title $Title -Message $Message -Expected $Expected
    try {
        [void]$ui.Input.Focus()
        return $ui.Form.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK
    }
    finally { $ui.Form.Dispose() }
}

function Show-PalworldSshBackupDialog {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)]$Payload
    )
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "SSH World Restore"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(690, 430)
    $dialog.FormBorderStyle = "Sizable"
    $dialog.MinimumSize = New-Object System.Drawing.Size(600, 390)
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog
    $label = New-Object System.Windows.Forms.Label
    $label.Text = "World GUID: $([string]$Payload.world_guid)"
    $label.Location = New-Object System.Drawing.Point(12, 14)
    $label.Size = New-Object System.Drawing.Size(650, 22)
    $dialog.Controls.Add($label)
    $list = New-Object System.Windows.Forms.ListView
    $list.Location = New-Object System.Drawing.Point(12, 42)
    $list.Size = New-Object System.Drawing.Size(666, 320)
    $list.Anchor = "Top,Bottom,Left,Right"
    $list.View = "Details"
    $list.FullRowSelect = $true
    [void]$list.Columns.Add((Get-PalworldLocalizedText "Backup" "백업"), 250)
    [void]$list.Columns.Add((Get-PalworldLocalizedText "Kind" "유형"), 130)
    [void]$list.Columns.Add((Get-PalworldLocalizedText "Files" "파일 수"), 80)
    [void]$list.Columns.Add((Get-PalworldLocalizedText "Bytes" "바이트"), 130)
    foreach ($backup in @($Payload.backups)) {
        $item = New-Object System.Windows.Forms.ListViewItem([string]$backup.name)
        [void]$item.SubItems.Add([string]$backup.kind)
        [void]$item.SubItems.Add([string]$backup.file_count)
        [void]$item.SubItems.Add([string]$backup.size_bytes)
        $item.Tag = [string]$backup.name
        [void]$list.Items.Add($item)
    }
    $dialog.Controls.Add($list)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.Location = New-Object System.Drawing.Point(508, 375)
    $cancel.Size = New-Object System.Drawing.Size(80, 30)
    $cancel.Anchor = "Bottom,Right"
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)
    $restore = New-Object System.Windows.Forms.Button
    $restore.Text = "Select"
    $restore.Location = New-Object System.Drawing.Point(598, 375)
    $restore.Size = New-Object System.Drawing.Size(80, 30)
    $restore.Anchor = "Bottom,Right"
    $restore.Enabled = $false
    $restore.Add_Click({
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    }.GetNewClosure())
    $dialog.Controls.Add($restore)
    $list.Add_SelectedIndexChanged({
        $restore.Enabled = $list.SelectedItems.Count -eq 1
    }.GetNewClosure())
    $dialog.AcceptButton = $restore
    $dialog.CancelButton = $cancel
    if ($env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-dialog-events") {
        $dialog.Show()
        if ($list.Items.Count -gt 0) { $list.Items[0].Selected = $true }
        [System.Windows.Forms.Application]::DoEvents()
        $restore.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        $result = if ($dialog.DialogResult -eq [System.Windows.Forms.DialogResult]::OK) {
            [string]$list.SelectedItems[0].Tag
        }
        else { $null }
        $dialog.Dispose()
        return $result
    }
    try {
        if ($dialog.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK) {
            return [string]$list.SelectedItems[0].Tag
        }
        return $null
    }
    finally { $dialog.Dispose() }
}

function Get-PalworldRemoteHomeDirectory {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    $output = Invoke-PalworldSshSimpleCommand `
        -Connection $Connection -Owner $Owner `
        -Command "test -n `"`$HOME`"; cd -- `"`$HOME`"; pwd -P"
    $remoteHomeDirectory = @(
        $output -split "`r?`n" | Where-Object { $_ -match '^/' }
    ) | Select-Object -Last 1
    if (-not $remoteHomeDirectory) {
        throw "The SSH user's home directory could not be resolved."
    }
    return [string]$remoteHomeDirectory.Trim()
}

function Get-PalworldNextImportServerName {
    param(
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    $result = Invoke-PalworldPackagedSshOperation `
        -Connection $Connection -Owner $Owner -Payload setup -TimeoutSeconds 120 `
        -BuildCommand {
            param($project, $tools)
            $projectLiteral = ConvertTo-PosixLiteral $project
            $toolsLiteral = ConvertTo-PosixLiteral $tools
            "project=$projectLiteral; tools=$toolsLiteral; __PALWORLD_SUDO__ env PALWORLD_PROJECT_DIR=`"`$project`" PYTHONDONTWRITEBYTECODE=1 python3 -B `"`$tools/install/scripts/instances.py`" next"
        }
    $serverNameMatches = [Regex]::Matches($result.Output, '(?m)^server[1-9][0-9]*\r?$')
    if ($serverNameMatches.Count -eq 0) {
        throw "The next unused server number could not be determined."
    }
    return $serverNameMatches[$serverNameMatches.Count - 1].Value.Trim()
}

function Invoke-PalworldExistingServerImport {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)]$Connection
    )
    Add-PalworldSshOutput "[INFO] Import preparation installs or repairs Python, Docker, Compose, and the Docker daemon without creating a game server.`r`n"
    [void](Invoke-PalworldPackagedSshOperation `
        -Connection $Connection -Owner $Owner -Payload setup -TimeoutSeconds 1800 `
        -BuildCommand {
            param($project, $tools)
            New-PalworldPrepareHostCommand -Project $project -Tools $tools
        })
    Add-PalworldSshOutput "[PASS] Import host requirements are ready.`r`n"

    $project = Resolve-PalworldRemoteWorkDirectory -Connection $Connection -Owner $Owner
    $searchRoot = Get-PalworldRemoteHomeDirectory -Connection $Connection -Owner $Owner
    $selection = $null
    while ($true) {
        Add-PalworldSshOutput "`r`n[START] Searching for existing Pal/Saved worlds under $searchRoot ...`r`n"
        $discoverArguments = "discover --root " + (ConvertTo-PosixLiteral $searchRoot) +
            " --project " + (ConvertTo-PosixLiteral $project)
        $discovery = Invoke-PalworldImportTool `
            -Connection $Connection -Owner $Owner -Arguments $discoverArguments -TimeoutSeconds 900
        $worlds = @($discovery.worlds)
        Add-PalworldSshOutput "[PASS] Existing world search completed: $($worlds.Count) candidate(s).`r`n"
        $selection = Show-PalworldImportSourceDialog `
            -Owner $Owner -Worlds $worlds -SearchRoot $searchRoot
        if ($null -eq $selection) { return $false }
        if ([string]$selection.Action -eq "Rescan") {
            $searchRoot = [string]$selection.SearchRoot
            continue
        }
        break
    }

    $world = $selection.World
    $server = Get-PalworldNextImportServerName -Connection $Connection -Owner $Owner
    $inspectArgumentParts = @(
        "inspect",
        "--project", (ConvertTo-PosixLiteral $project),
        "--saved", (ConvertTo-PosixLiteral ([string]$world.saved_directory)),
        "--world-guid", (ConvertTo-PosixLiteral ([string]$world.world_guid)),
        "--server", (ConvertTo-PosixLiteral $server)
    )
    if ($world.game_port) {
        $inspectArgumentParts += @("--game-port", [string]$world.game_port)
    }
    if ($world.rest_api_port) {
        $inspectArgumentParts += @("--rest-port", [string]$world.rest_api_port)
    }
    $detectedCommunityServer = @(
        @($world.processes) | Where-Object { [bool]$_.community_server }
    ).Count -gt 0
    $inspectArgumentParts += @(
        "--rest-api-expose", "true",
        "--community-server", $(if ($detectedCommunityServer) { "true" } else { "false" })
    )
    $inspectArguments = $inspectArgumentParts -join " "
    $inspection = Invoke-PalworldImportTool `
        -Connection $Connection -Owner $Owner -Arguments $inspectArguments -TimeoutSeconds 300
    if ($inspection.template_sync -and [bool]$inspection.template_sync.updated) {
        Add-PalworldSshOutput "[PASS] Remote server.template.env was merged with the current $($script:ApplicationLanguage) template before review.`r`n"
        if ([string]$inspection.template_sync.backup) {
            Add-PalworldSshOutput "[INFO] Previous template backup: $([string]$inspection.template_sync.backup)`r`n"
        }
    }
    else {
        Add-PalworldSshOutput "[PASS] Remote server.template.env already matches the current template layout.`r`n"
    }
    $reviewResult = Show-PalworldImportReviewDialog -Owner $Owner -Inspection $inspection
    if ($null -eq $reviewResult) {
        return $false
    }

    $validatePortArguments = @(
        "validate-ports",
        "--project", (ConvertTo-PosixLiteral $project),
        "--game-port", [string]$reviewResult.GamePort,
        "--rest-port", [string]$reviewResult.RestPort
    ) -join " "
    [void](Invoke-PalworldImportTool `
        -Connection $Connection -Owner $Owner `
        -Arguments $validatePortArguments -TimeoutSeconds 120)
    Add-PalworldSshOutput "[PASS] Confirmed import ports do not conflict with managed servers.`r`n"

    $sourceType = if ([string]$world.source_type) { [string]$world.source_type } else { "unknown" }
    $controlId = [string]$world.control_id
    while ($true) {
        Add-PalworldSshOutput "`r`n[START] Verifying that the source server is stopped...`r`n"
        $stopArguments = "stop --saved " + (ConvertTo-PosixLiteral ([string]$world.saved_directory)) +
            " --source-type " + (ConvertTo-PosixLiteral $sourceType) +
            " --control-id " + (ConvertTo-PosixLiteral $controlId)
        $stopResult = Invoke-PalworldImportTool `
            -Connection $Connection -Owner $Owner -Arguments $stopArguments -TimeoutSeconds 240
        if ([bool]$stopResult.stopped) {
            Add-PalworldSshOutput "[PASS] $([string]$stopResult.message)`r`n"
            Add-PalworldSshOutput "[INFO] The source ports may remain occupied briefly while the process or container network exits; import will wait up to 30 seconds for release.`r`n"
            break
        }
        Add-PalworldSshOutput "[WARN] $([string]$stopResult.message)`r`n"
        if (-not (Show-PalworldImportStopRequiredDialog `
            -Owner $Owner -Message ([string]$stopResult.message))) {
            return $false
        }
    }

    $temporaryEnv = Send-PalworldRemoteTemporaryText `
        -Connection $Connection -Owner $Owner -Content ([string]$reviewResult.TargetEnv)
    $temporaryLiteral = ConvertTo-PosixLiteral $temporaryEnv
    try {
        $commitArguments = @(
            "import-commit",
            "--saved", (ConvertTo-PosixLiteral ([string]$world.saved_directory)),
            "--world-guid", (ConvertTo-PosixLiteral ([string]$world.world_guid)),
            "--server", (ConvertTo-PosixLiteral $server),
            "--env-file", $temporaryLiteral,
            "--game-port", [string]$reviewResult.GamePort,
            "--rest-port", [string]$reviewResult.RestPort
        ) -join " "
        Add-PalworldSshOutput "`r`n[START] Copying and SHA-256 verifying the full Pal/Saved directory...`r`n"
        $commitResult = Invoke-PalworldPackagedSshOperation `
            -Connection $Connection -Owner $Owner -Payload setup -TimeoutSeconds 7200 `
            -BuildCommand {
                param($remoteProject, $tools)
                New-PalworldManagerCommand `
                    -Project $remoteProject -Tools $tools -Arguments $commitArguments
            }.GetNewClosure()
        $metadata = Get-PalworldJsonFromSshOutput $commitResult.Output
        Add-PalworldSshOutput "[PASS] Imported $([int]$metadata.file_count) files ($(Format-PalworldImportByteSize ([long]$metadata.size_bytes))) into $server staging and committed atomically.`r`n"
        if ([bool]$metadata.world_option_preserved) {
            Add-PalworldSshOutput "[INFO] WorldOption.sav was preserved with the imported world.`r`n"
            $script:PalworldSshPostActionWorldOptionPreserved = $true
        }
    }
    finally {
        try {
            [void](Invoke-PalworldSshSimpleCommand `
                -Connection $Connection -Owner $Owner -Command "rm -f -- $temporaryLiteral")
        }
        catch { }
    }

    Add-PalworldSshOutput "`r`n[START] Installing and starting the imported server as $server...`r`n"
    [void](Invoke-PalworldPackagedSshOperation `
        -Connection $Connection -Owner $Owner -Payload setup -TimeoutSeconds 3600 `
        -BuildCommand {
            param($remoteProject, $tools)
            New-PalworldSetupCommand `
                -Project $remoteProject -Tools $tools -Server $server -Mode setup
        }.GetNewClosure())
    $script:PalworldSshPostActionApiSyncMode = "Full"
    $script:PalworldSshPostActionApiServer = $server
    Add-PalworldSshOutput "[PASS] Existing world is now managed as $server. The original Pal/Saved directory remains in place.`r`n"
    return $true
}

function Assert-PalworldSshManagementActionTarget {
    param(
        [Parameter(Mandatory = $true)][string]$Action,
        [AllowEmptyString()][string]$Server
    )
    $knownActions = @(
        "Setup", "Import", "Update", "EnvEdit", "Test", "Reset", "Restore",
        "TokenShow", "TokenRotate", "RemoveServer", "RemoveAll", "RemoveProject"
    )
    if ($Action -notin $knownActions) {
        throw "Unknown SSH management action: $Action"
    }
    if ($Action -eq "Test") {
        if ($Server -ne "all" -and $Server -notmatch '^server[1-9][0-9]*$') {
            throw "Select a server or all servers to test."
        }
        return
    }
    if ($Action -in @(
        "Update", "EnvEdit", "Reset", "Restore", "TokenShow", "TokenRotate", "RemoveServer"
    ) -and $Server -notmatch '^server[1-9][0-9]*$') {
        throw "Select a server for this operation."
    }
}

function New-PalworldManagerActionArguments {
    param(
        [ValidateSet(
            "EnvApply", "Reset", "RestoreList", "Restore", "TokenShow", "TokenRotate",
            "RemoveServer", "RemoveAll", "RemoveProject"
        )][string]$Action,
        [AllowEmptyString()][string]$Server = "",
        [AllowEmptyString()][string]$Backup = "",
        [AllowEmptyString()][string]$EnvBackup = ""
    )
    if ($Action -in @(
        "EnvApply", "Reset", "RestoreList", "Restore", "TokenShow", "TokenRotate", "RemoveServer"
    )) {
        Assert-PalworldServerName $Server
    }
    $serverLiteral = if ($Server) { ConvertTo-PosixLiteral $Server } else { "" }
    switch ($Action) {
        "EnvApply" {
            if (-not $EnvBackup.StartsWith("/")) {
                throw "Remote server.env backup path is invalid."
            }
            return "apply-env --server $serverLiteral --backup " +
                (ConvertTo-PosixLiteral $EnvBackup)
        }
        "Reset" { return "reset --server $serverLiteral" }
        "RestoreList" { return "restore --server $serverLiteral --list-json" }
        "Restore" {
            if ($Backup -notmatch '^[A-Za-z0-9._-]+$') {
                throw "Backup name contains unsupported characters."
            }
            return "restore --server $serverLiteral --backup " +
                (ConvertTo-PosixLiteral $Backup) + " --yes"
        }
        "TokenShow" { return "token --server $serverLiteral --show" }
        "TokenRotate" { return "token --server $serverLiteral --rotate" }
        "RemoveServer" { return "remove --servers $serverLiteral" }
        "RemoveAll" { return "remove --all" }
        "RemoveProject" { return "remove --project" }
    }
}

function Invoke-PalworldSshManagementAction {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner,
        [Parameter(Mandatory = $true)]$Connection,
        [Parameter(Mandatory = $true)][string]$Action,
        [AllowEmptyString()][string]$Server
    )
    Assert-PalworldSshManagementActionTarget -Action $Action -Server $Server
    $script:PalworldSshPostActionApiSyncMode = ""
    $script:PalworldSshPostActionApiServer = ""
    $script:PalworldSshPostActionShowToken = $false
    $script:PalworldSshPostActionApiSyncAfterFailure = $false
    $script:PalworldSshPostActionApiRemoveServer = ""
    $script:PalworldSshPostActionWorldOptionPreserved = $false
    $script:PalworldSshLastRemoteOperationOutput = ""
    Set-PalworldSshWorkDirectoryStatus -State Checking
    try {
        $hostReadiness = Test-PalworldSshHostReadiness -Connection $Connection -Owner $Owner
    }
    catch {
        $script:PalworldSshHostReadyForManagement = $false
        Set-PalworldSshWorkDirectoryStatus -State Failed
        throw
    }
    $script:PalworldSshHostReadyForManagement = [bool]$hostReadiness.ReadyForManagement
    $script:PalworldSshProjectPrepared = [bool]$hostReadiness.ProjectPrepared
    $script:PalworldSshCommonSettingsReviewed = [bool]$hostReadiness.CommonSettingsReviewed
    if (-not $hostReadiness.ReadyForManagement) {
        $directoryState = if (-not $hostReadiness.WorkDirectoryExists) {
            "Missing"
        }
        elseif (-not $hostReadiness.WorkDirectoryWritable) {
            "Unwritable"
        }
        elseif (-not $hostReadiness.ProjectPrepared) {
            "NeedPrepare"
        }
        else { "NeedCommonReview" }
        Set-PalworldSshWorkDirectoryStatus -State $directoryState -Path $hostReadiness.WorkDirectory
        throw "Host preparation is incomplete. Follow the highlighted preparation action, then run the operation again."
    }
    Set-PalworldSshWorkDirectoryStatus -State Ready -Path $hostReadiness.WorkDirectory
    if ($Action -in @("Setup", "Import")) {
        Add-PalworldSshOutput "[INFO] This operation installs or repairs curl, python3, Docker, Compose, the daemon, and the Palworld management scaffold as needed.`r`n"
    }
    else {
        $readiness = Get-PalworldSshActionPrerequisites `
            -Connection $Connection -Owner $Owner
        if (-not $readiness.Ready) {
            throw "Automated Management prerequisites are not ready. Run Setup first."
        }
    }
    switch ($Action) {
        "Setup" {
            $setupResult = Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload setup -TimeoutSeconds 3600 `
                -BuildCommand { param($project, $tools) New-PalworldSetupCommand -Project $project -Tools $tools }
            $setupTargets = [Regex]::Matches(
                [string]$setupResult.Output,
                '(?m)^PALWORLD_SETUP_SERVER=(server[1-9][0-9]*)\r?$'
            )
            if ($setupTargets.Count -eq 0) {
                throw "Setup completed, but its target server could not be identified."
            }
            $script:PalworldSshPostActionApiServer = `
                [string]$setupTargets[$setupTargets.Count - 1].Groups[1].Value
            $script:PalworldSshPostActionApiSyncMode = "Full"
        }
        "Import" {
            return Invoke-PalworldExistingServerImport -Owner $Owner -Connection $Connection
        }
        "Update" {
            [void](Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload setup -TimeoutSeconds 3600 `
                -BuildCommand {
                    param($project, $tools)
                    New-PalworldSetupCommand -Project $project -Tools $tools -Server $Server -Mode update
                }.GetNewClosure())
            $script:PalworldSshPostActionApiSyncMode = "Full"
            $script:PalworldSshPostActionApiServer = $Server
        }
        "EnvEdit" {
            $remote = Get-PalworldRemoteServerEnv -Connection $Connection -Owner $Owner -Server $Server
            $edited = Show-PalworldServerEnvEditor -Owner $Owner -Server $Server -Content $remote.Content
            if ($null -eq $edited) { return $false }
            $envBackup = Save-PalworldRemoteServerEnv `
                -Connection $Connection -Owner $Owner -Server $Server `
                -Content $edited.Content -ExpectedHash $remote.Hash
            if ($edited.Action -eq "Apply") {
                Add-PalworldSshOutput "`r`n[START] Validating and applying $Server.env with a lightweight safe container recreate...`r`n"
                $script:PalworldSshCancelOperationButton.Enabled = $false
                $script:PalworldSshNonCancelableTransaction = $true
                $script:PalworldSshCancelOperationButton.Text = Get-PalworldLocalizedText `
                    "Applying / restarting..." "적용 / 재시작 중..."
                $script:PalworldSshLiveStatusLines += @(
                    "[INFO] server.env apply and safe container recreation are in progress; this transaction cannot be canceled."
                )
                & $script:PalworldSshRenderStatusNotice
                $arguments = New-PalworldManagerActionArguments `
                    -Action EnvApply -Server $Server -EnvBackup ([string]$envBackup)
                [void](Invoke-PalworldPackagedSshOperation `
                    -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 3600 `
                    -BuildCommand {
                        param($project, $tools)
                        New-PalworldManagerCommand `
                            -Project $project -Tools $tools -Arguments $arguments
                    }.GetNewClosure())
                $script:PalworldSshPostActionApiSyncMode = "Full"
                $script:PalworldSshPostActionApiServer = $Server
            }
            else {
                Add-PalworldSshOutput "[INFO] Saved only. Running containers still use the previous environment until reapplied.`r`n"
            }
        }
        "Test" {
            # Selecting one server already expresses intent to inspect it. If it
            # is manually stopped, doctor.py starts it only for this check and
            # restores that state afterward. All keeps the explicit bulk choice.
            $manualStart = "yes"
            if ($Server -eq "all") {
                $manualChoice = [System.Windows.Forms.MessageBox]::Show(
                    (Get-PalworldLocalizedText `
                        "If a target is stopped by Advanced Shutdown, start it temporarily for the check and restore its manually stopped state afterward?`r`n`r`nSelect No to skip only that server." `
                        "검사 대상에 Advanced Shutdown 상태 서버가 있으면 임시로 시작한 뒤 검사하고, 완료 후 원래 수동 정지 상태로 복구할까요?`r`n`r`n아니요를 선택하면 해당 서버만 SKIP 처리합니다."),
                    (Get-PalworldLocalizedText "Temporary test start" "검사용 임시 시작"),
                    [System.Windows.Forms.MessageBoxButtons]::YesNoCancel,
                    [System.Windows.Forms.MessageBoxIcon]::Question
                )
                if ($manualChoice -eq [System.Windows.Forms.DialogResult]::Cancel) { return $false }
                $manualStart = if ($manualChoice -eq [System.Windows.Forms.DialogResult]::Yes) { "yes" } else { "no" }
            }
            [void](Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload test -TimeoutSeconds 1800 `
                -BuildCommand {
                    param($project, $tools)
                    New-PalworldTestCommand -Project $project -Tools $tools -Server $Server -ManualStart $manualStart
                }.GetNewClosure())
        }
        "Reset" {
            if (-not (Show-PalworldTypedConfirmation `
                -Owner $Owner -Title (Get-PalworldLocalizedText "Reset World" "월드 초기화") `
                -Message (Get-PalworldLocalizedText `
                    "Back up the $Server world and Saved settings, then initialize a new world." `
                    "$Server 월드와 Saved 설정을 백업한 후 새 월드로 초기화합니다.") `
                -Expected "RESET $Server")) { return $false }
            $arguments = New-PalworldManagerActionArguments -Action Reset -Server $Server
            [void](Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 1800 `
                -BuildCommand {
                    param($project, $tools)
                    New-PalworldManagerCommand -Project $project -Tools $tools -Arguments $arguments
                }.GetNewClosure())
        }
        "Restore" {
            $listArguments = New-PalworldManagerActionArguments -Action RestoreList -Server $Server
            $listResult = Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 120 `
                -BuildCommand {
                    param($project, $tools)
                    New-PalworldManagerCommand -Project $project -Tools $tools -Arguments $listArguments
                }.GetNewClosure()
            $payload = Get-PalworldJsonFromSshOutput $listResult.Output
            $backup = Show-PalworldSshBackupDialog -Owner $Owner -Payload $payload
            if (-not $backup) { return $false }
            if (-not (Show-PalworldTypedConfirmation `
                -Owner $Owner -Title (Get-PalworldLocalizedText "Restore World" "월드 복원") `
                -Message (Get-PalworldLocalizedText `
                    "Restore the $Server world from '$backup'. The current world is preserved as a deleted_ backup." `
                    "$Server 월드를 '$backup' 시점으로 복원합니다. 현재 월드는 deleted_ 백업으로 보존됩니다.") `
                -Expected "RESTORE $Server")) { return $false }
            $arguments = New-PalworldManagerActionArguments `
                -Action Restore -Server $Server -Backup $backup
            [void](Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 3600 `
                -BuildCommand {
                    param($project, $tools)
                    New-PalworldManagerCommand -Project $project -Tools $tools -Arguments $arguments
                }.GetNewClosure())
        }
        "TokenShow" {
            $arguments = New-PalworldManagerActionArguments -Action TokenShow -Server $Server
            [void](Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 120 `
                -BuildCommand {
                    param($project, $tools)
                    New-PalworldManagerCommand -Project $project -Tools $tools -Arguments $arguments
                }.GetNewClosure())
            $script:PalworldSshPostActionApiSyncMode = "Token"
            $script:PalworldSshPostActionApiServer = $Server
            $script:PalworldSshPostActionShowToken = $true
        }
        "TokenRotate" {
            if (-not (Show-PalworldTypedConfirmation `
                -Owner $Owner -Title (Get-PalworldLocalizedText "Rotate API Token" "API 토큰 재발급") `
                -Message (Get-PalworldLocalizedText `
                    "Rotate the $Server API token and apply any saved server.env changes. A running container is safely restarted and verified against the current persistent operating policy; a stopped container remains stopped." `
                    "$Server API token을 재발급하고 저장된 server.env 변경 사항을 적용합니다. 실행 중인 컨테이너는 안전하게 재시작한 뒤 현재 영구 운영 정책에 맞는 상태인지 검증하며, 정지된 컨테이너는 정지 상태를 유지합니다.") `
                -Expected "ROTATE $Server")) { return $false }
            # A modal confirmation blocks the main form. Disable cancellation
            # only after it succeeds because the remote transaction may then
            # replace the credential at any point before rollback completes.
            $script:PalworldSshCancelOperationButton.Enabled = $false
            $script:PalworldSshNonCancelableTransaction = $true
            $script:PalworldSshCancelOperationButton.Text = Get-PalworldLocalizedText `
                "Applying / restarting..." "적용 / 재시작 중..."
            $script:PalworldSshLiveStatusLines += @(
                "[INFO] Token apply and safe container recreation are in progress; this transaction cannot be canceled after confirmation."
            )
            & $script:PalworldSshRenderStatusNotice
            $arguments = New-PalworldManagerActionArguments -Action TokenRotate -Server $Server
            # Reconcile from serverN.env after success, or after a failure whose
            # rollback marker confirms that the old credential is active again.
            # Container recreation also applies every saved server.env value.
            # Refresh direct endpoints and credentials together with the token;
            # Set-PalworldManagedApiConnection preserves a custom HTTPS proxy.
            $script:PalworldSshPostActionApiSyncMode = "Full"
            $script:PalworldSshPostActionApiServer = $Server
            $script:PalworldSshPostActionShowToken = $true
            $script:PalworldSshPostActionApiSyncAfterFailure = $true
            [void](Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 3600 `
                -BuildCommand {
                    param($project, $tools)
                    New-PalworldManagerCommand -Project $project -Tools $tools -Arguments $arguments
                }.GetNewClosure())
        }
        "RemoveServer" {
            if (-not (Show-PalworldTypedConfirmation `
                -Owner $Owner -Title (Get-PalworldLocalizedText "Remove Server" "서버 제거") `
                -Message (Get-PalworldLocalizedText `
                    "Delete the $Server container, configuration, world data, backups, and server volume." `
                    "$Server 컨테이너, 설정, 월드 데이터, 백업과 서버 볼륨을 삭제합니다.") `
                -Expected "DELETE $Server")) { return $false }
            $arguments = New-PalworldManagerActionArguments -Action RemoveServer -Server $Server
            [void](Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 600 `
                -BuildCommand {
                    param($project, $tools)
                    New-PalworldManagerCommand -Project $project -Tools $tools -Arguments $arguments
                }.GetNewClosure())
            $script:PalworldSshPostActionApiRemoveServer = $Server
        }
        "RemoveAll" {
            if (-not (Show-PalworldTypedConfirmation `
                -Owner $Owner -Title (Get-PalworldLocalizedText "Remove All Servers" "모든 서버 제거") `
                -Message (Get-PalworldLocalizedText `
                    "Delete every server and its data managed in this work directory. Keep the management directory." `
                    "이 작업 디렉터리에서 관리하는 모든 서버와 데이터를 삭제합니다. 관리 디렉터리는 유지합니다.") `
                -Expected "DELETE ALL")) { return $false }
            $arguments = New-PalworldManagerActionArguments -Action RemoveAll
            [void](Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 900 `
                -BuildCommand {
                    param($project, $tools)
                    New-PalworldManagerCommand -Project $project -Tools $tools -Arguments $arguments
                }.GetNewClosure())
            $script:PalworldSshPostActionApiRemoveServer = "*"
        }
        "RemoveProject" {
            if (-not (Show-PalworldTypedConfirmation `
                -Owner $Owner -Title (Get-PalworldLocalizedText "Remove Management Directory" "관리 디렉터리 제거") `
                -Message (Get-PalworldLocalizedText `
                    "Delete every managed server and all paths owned by this project. Unrelated top-level files and their directory are preserved. Docker, installed packages, timezone, and docker-group settings remain." `
                    "모든 관리 서버와 이 프로젝트가 만든 경로를 삭제합니다. 관계없는 최상위 파일과 해당 디렉터리는 보존합니다. Docker, 설치된 패키지, 시간대와 docker 그룹 설정은 유지합니다.") `
                -Expected "DELETE PROJECT")) { return $false }
            $arguments = New-PalworldManagerActionArguments -Action RemoveProject
            [void](Invoke-PalworldPackagedSshOperation `
                -Connection $Connection -Owner $Owner -Payload manage -TimeoutSeconds 900 `
                -BuildCommand {
                    param($project, $tools)
                    New-PalworldManagerCommand -Project $project -Tools $tools -Arguments $arguments
                }.GetNewClosure())
            $script:PalworldSshPostActionApiRemoveServer = "*"
        }
    }
    return $true
}

function Test-PalworldSshActionNeedsRefresh {
    param([Parameter(Mandatory = $true)][string]$Action)
    return $Action -in @(
        "Setup", "Import", "Update", "EnvEdit", "Test", "Reset", "Restore", "TokenRotate",
        "RemoveServer", "RemoveAll", "RemoveProject"
    )
}

function Update-PalworldSshApiLinkStatus {
    if (-not $script:PalworldSshApiLinkLabel) { return }
    $ssh = Get-SelectedPalworldSshConnection
    if ($null -eq $ssh) {
        $script:PalworldSshApiLinkLabel.Text = Get-PalworldLocalizedText `
            "Linked Server APIs: no SSH Connection selected" `
            "연결된 서버 API: 선택한 SSH 연결 없음"
        $script:PalworldSshApiLinkLabel.ForeColor = [System.Drawing.Color]::DimGray
        return
    }
    $linkedApis = @(Get-PalworldLinkedApiConnections $ssh)
    if ($linkedApis.Count -eq 0) {
        $script:PalworldSshApiLinkLabel.Text = Get-PalworldLocalizedText `
            "Linked Server APIs: none · link one from Server API > Add/Update" `
            "연결된 서버 API: 없음 · Server API > 추가/수정에서 연결하세요"
        $script:PalworldSshApiLinkLabel.ForeColor = [System.Drawing.Color]::DarkOrange
        return
    }
    $preferred = Get-PalworldPreferredApiConnectionForSsh $ssh
    $names = @($linkedApis | ForEach-Object { [string]$_.Name }) -join ", "
    $script:PalworldSshApiLinkLabel.Text = Get-PalworldLocalizedText `
        "Linked Server APIs: $names · Recent: $([string]$preferred.Name)" `
        "연결된 서버 API: $names · 최근 사용: $([string]$preferred.Name)"
    $script:PalworldSshApiLinkLabel.ForeColor = [System.Drawing.Color]::DarkGreen
}

function Clear-PalworldSshApiSelectionContext {
    $script:PalworldSshApiContextSshId = ""
}

function Get-PalworldSshConnectionById {
    param([AllowEmptyString()][string]$ConnectionId)
    if (-not $ConnectionId) { return $null }
    return @(
        $script:AdminSshConnections |
            Where-Object { [string]$_.Id -eq $ConnectionId }
    ) | Select-Object -First 1
}

function Set-PalworldSshSelectedConnectionId {
    param([AllowEmptyString()][string]$ConnectionId)
    if (-not $script:PalworldSshConnectionCombo) { return }
    $targetIndex = 0
    for ($index = 0; $index -lt $script:AdminSshConnections.Count; $index++) {
        if ([string]$script:AdminSshConnections[$index].Id -eq $ConnectionId) {
            $targetIndex = $index + 1
            break
        }
    }
    $previousSyncState = $script:AdminSelectionSyncing
    $script:AdminSelectionSyncing = $true
    try {
        $previousIndex = $script:PalworldSshConnectionCombo.SelectedIndex
        $script:PalworldSshConnectionCombo.SelectedIndex = $targetIndex
        if ($previousIndex -eq $targetIndex -and $script:PalworldSshShowSelected) {
            & $script:PalworldSshShowSelected
        }
    }
    finally {
        $script:AdminSelectionSyncing = $previousSyncState
    }
    Update-PalworldSshApiLinkStatus
}

function Get-PalworldSshSynchronizationConnection {
    if ($script:PalworldSshPinnedConnectionId) {
        return Get-PalworldSshConnectionById $script:PalworldSshPinnedConnectionId
    }
    return Get-SelectedPalworldSshConnection
}

function Sync-PalworldSshSelectionFromApi {
    if ($script:AdminSelectionSyncing) { return }
    if ($script:PalworldSshPinnedConnectionId) {
        Set-PalworldSshSelectedConnectionId $script:PalworldSshPinnedConnectionId
        if ($script:ResourceUsageRefreshContext) { & $script:ResourceUsageRefreshContext }
        return
    }
    $api = Get-SelectedAdminApiConnection
    $targetSshId = ""
    if ($api) {
        $linked = Get-LinkedSshConnection $api
        $script:PalworldSshApiContextSshId = ""
        if ($linked) {
            $linked.LastUsedApiConnectionId = [string]$api.Id
            $targetSshId = [string]$linked.Id
        }
    }
    elseif ($script:PalworldSshApiContextSshId) {
        $targetSshId = [string]$script:PalworldSshApiContextSshId
    }
    Set-PalworldSshSelectedConnectionId $targetSshId
    if ($script:ResourceUsageRefreshContext) { & $script:ResourceUsageRefreshContext }
}

function Sync-PalworldApiSelectionFromSsh {
    if ($script:AdminSelectionSyncing -or -not $script:AdminSelectApiConnection) { return }
    $ssh = Get-PalworldSshSynchronizationConnection
    $apiId = ""
    $script:PalworldSshApiContextSshId = if ($ssh) { [string]$ssh.Id } else { "" }
    if ($ssh) {
        $preferred = Get-PalworldPreferredApiConnectionForSsh $ssh
        if ($preferred) {
            $apiId = [string]$preferred.Id
            $ssh.LastUsedApiConnectionId = $apiId
        }
    }
    $previousSyncState = $script:AdminSelectionSyncing
    $script:AdminSelectionSyncing = $true
    try {
        & $script:AdminSelectApiConnection $apiId
    }
    finally {
        $script:AdminSelectionSyncing = $previousSyncState
    }
    Update-PalworldSshApiLinkStatus
    if ($script:ResourceUsageRefreshContext) { & $script:ResourceUsageRefreshContext }
}

function New-PalworldSshManagementPage {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner)
    $script:PalworldSshOwner = $Owner
    $page = New-Object System.Windows.Forms.TabPage
    $page.Text = "SSH Management"
    $page.AutoScroll = $true
    $page.AutoScrollMinSize = New-Object System.Drawing.Size(880, 870)
    $toolTip = New-Object System.Windows.Forms.ToolTip
    $toolTip.AutoPopDelay = 20000
    $toolTip.InitialDelay = 350
    $toolTip.ReshowDelay = 100
    $script:PalworldSshToolTip = $toolTip

    $connectionGroup = New-Object System.Windows.Forms.GroupBox
    $connectionGroup.Text = Get-PalworldLocalizedText `
        "SSH Connections · encrypted portable store" `
        "SSH 연결 · 암호화된 휴대용 저장소"
    $connectionGroup.Location = New-Object System.Drawing.Point(8, 8)
    $connectionGroup.Size = New-Object System.Drawing.Size(860, 145)
    $connectionGroup.Anchor = "Top,Left,Right"
    $page.Controls.Add($connectionGroup)
    $script:PalworldSshConnectionCombo = New-Object System.Windows.Forms.ComboBox
    $script:PalworldSshConnectionCombo.Name = "AdminSshConnectionCombo"
    $script:PalworldSshConnectionCombo.Location = New-Object System.Drawing.Point(16, 27)
    $script:PalworldSshConnectionCombo.Size = New-Object System.Drawing.Size(380, 23)
    $script:PalworldSshConnectionCombo.DropDownStyle = "DropDownList"
    $connectionGroup.Controls.Add($script:PalworldSshConnectionCombo)
    $addButton = New-Object System.Windows.Forms.Button
    $addButton.Name = "SshConnectionAddButton"
    $addButton.Text = "Add"
    $addButton.Location = New-Object System.Drawing.Point(415, 24)
    $addButton.Size = New-Object System.Drawing.Size(75, 29)
    $connectionGroup.Controls.Add($addButton)
    $updateButton = New-Object System.Windows.Forms.Button
    $updateButton.Text = "Update"
    $updateButton.Location = New-Object System.Drawing.Point(497, 24)
    $updateButton.Size = New-Object System.Drawing.Size(80, 29)
    $connectionGroup.Controls.Add($updateButton)
    $deleteButton = New-Object System.Windows.Forms.Button
    $deleteButton.Text = "Delete"
    $deleteButton.Location = New-Object System.Drawing.Point(584, 24)
    $deleteButton.Size = New-Object System.Drawing.Size(80, 29)
    $connectionGroup.Controls.Add($deleteButton)
    $summary = New-Object System.Windows.Forms.Label
    $summary.Location = New-Object System.Drawing.Point(16, 63)
    $summary.Size = New-Object System.Drawing.Size(825, 22)
    $summary.ForeColor = [System.Drawing.Color]::DimGray
    $connectionGroup.Controls.Add($summary)
    $script:PalworldSshApiLinkLabel = New-Object System.Windows.Forms.Label
    $script:PalworldSshApiLinkLabel.Location = New-Object System.Drawing.Point(16, 94)
    $script:PalworldSshApiLinkLabel.Size = New-Object System.Drawing.Size(825, 22)
    $connectionGroup.Controls.Add($script:PalworldSshApiLinkLabel)

    $sessionGroup = New-Object System.Windows.Forms.GroupBox
    $sessionGroup.Text = "SSH Session"
    $sessionGroup.Location = New-Object System.Drawing.Point(8, 162)
    $sessionGroup.Size = New-Object System.Drawing.Size(860, 110)
    $sessionGroup.Anchor = "Top,Left,Right"
    $page.Controls.Add($sessionGroup)
    $connectButton = New-Object System.Windows.Forms.Button
    $connectButton.Text = "Connect"
    $connectButton.Location = New-Object System.Drawing.Point(16, 24)
    $connectButton.Size = New-Object System.Drawing.Size(90, 30)
    $sessionGroup.Controls.Add($connectButton)
    $disconnectButton = New-Object System.Windows.Forms.Button
    $disconnectButton.Text = "Disconnect"
    $disconnectButton.Location = New-Object System.Drawing.Point(112, 24)
    $disconnectButton.Size = New-Object System.Drawing.Size(95, 30)
    $sessionGroup.Controls.Add($disconnectButton)
    $reconnectButton = New-Object System.Windows.Forms.Button
    $reconnectButton.Text = "Reconnect"
    $reconnectButton.Location = New-Object System.Drawing.Point(213, 24)
    $reconnectButton.Size = New-Object System.Drawing.Size(95, 30)
    $sessionGroup.Controls.Add($reconnectButton)
    $hostCheckButton = New-Object System.Windows.Forms.Button
    $hostCheckButton.Name = "SshHostCheckButton"
    $hostCheckButton.Text = Get-PalworldLocalizedText "Host Check" "호스트 검사"
    $hostCheckButton.Location = New-Object System.Drawing.Point(356, 68)
    $hostCheckButton.Size = New-Object System.Drawing.Size(112, 30)
    $sessionGroup.Controls.Add($hostCheckButton)
    $toolTip.SetToolTip(
        $hostCheckButton,
        (Get-PalworldLocalizedText `
            "Available after Common Settings are confirmed. Applies the configured TZ, checks clock drift and NTP, and verifies that this Linux host can run Automated Management. Connect runs it automatically when preparation is already complete." `
            "공통 설정을 확인한 뒤 사용할 수 있습니다. 설정한 TZ를 적용하고 시간 차이·NTP·자동 관리 실행 가능 여부를 검사합니다. 준비가 끝난 호스트에서는 Connect할 때 자동으로 실행됩니다.")
    )
    $createWorkDirectoryButton = New-Object System.Windows.Forms.Button
    $createWorkDirectoryButton.Name = "SshCreateWorkDirectoryButton"
    $createWorkDirectoryButton.Text = Get-PalworldLocalizedText "Prepare Work Dir" "작업 디렉터리 준비"
    $createWorkDirectoryButton.Location = New-Object System.Drawing.Point(16, 68)
    $createWorkDirectoryButton.Size = New-Object System.Drawing.Size(142, 30)
    $sessionGroup.Controls.Add($createWorkDirectoryButton)
    $toolTip.SetToolTip(
        $createWorkDirectoryButton,
        (Get-PalworldLocalizedText `
            "Creates a missing dedicated project directory, or prepares an existing recognized project owned by the same SSH account while preserving its owner and repairing its safe mode. Projects owned by another account and unrelated non-empty directories are refused. It installs the Common Settings, server template, runtime, data, backup, and operate scaffold without installing Docker or starting a server." `
            "전용 프로젝트 디렉터리가 없으면 생성합니다. 현재 SSH 계정이 소유한 기존 관리 프로젝트는 소유자를 유지한 채 안전한 권한과 공통 설정·서버 템플릿·runtime·data·backup·operate 기본 구조를 준비합니다. 다른 계정이 소유한 프로젝트와 일반 파일이 든 디렉터리는 변경하지 않습니다. Docker를 설치하거나 서버를 시작하지는 않습니다.")
    )
    $reviewCommonSettingsButton = New-Object System.Windows.Forms.Button
    $reviewCommonSettingsButton.Name = "SshReviewCommonSettingsButton"
    $reviewCommonSettingsButton.Text = Get-PalworldLocalizedText "Review Common Settings" "공통 설정 검토"
    $reviewCommonSettingsButton.Location = New-Object System.Drawing.Point(164, 68)
    $reviewCommonSettingsButton.Size = New-Object System.Drawing.Size(186, 30)
    $sessionGroup.Controls.Add($reviewCommonSettingsButton)
    $toolTip.SetToolTip(
        $reviewCommonSettingsButton,
        (Get-PalworldLocalizedText `
            "Reviews project-wide timezone, new-server port allocation, update policy, warnings, and API settings. Confirming creates a backup and enables Host Check." `
            "프로젝트 전체 시간대·신규 서버 포트 할당·업데이트 정책·안내·API 설정을 검토합니다. 확인하면 기존 파일을 백업하고 호스트 검사를 사용할 수 있습니다.")
    )
    $script:PalworldSshStatus = New-Object System.Windows.Forms.Label
    $script:PalworldSshStatus.Text = Get-PalworldLocalizedText "Disconnected" "연결 끊김"
    $script:PalworldSshStatus.Location = New-Object System.Drawing.Point(330, 31)
    $script:PalworldSshStatus.Size = New-Object System.Drawing.Size(510, 22)
    $script:PalworldSshStatus.ForeColor = [System.Drawing.Color]::DarkRed
    $script:PalworldSshStatus.AutoEllipsis = $true
    $sessionGroup.Controls.Add($script:PalworldSshStatus)
    $script:PalworldSshWorkDirectoryStatus = New-Object System.Windows.Forms.Label
    $script:PalworldSshWorkDirectoryStatus.Name = "SshWorkDirectoryStatus"
    $script:PalworldSshWorkDirectoryStatus.Location = New-Object System.Drawing.Point(480, 75)
    $script:PalworldSshWorkDirectoryStatus.Size = New-Object System.Drawing.Size(360, 22)
    $script:PalworldSshWorkDirectoryStatus.AutoEllipsis = $true
    $sessionGroup.Controls.Add($script:PalworldSshWorkDirectoryStatus)
    Set-PalworldSshWorkDirectoryStatus -State Unknown

    $automationGroup = New-Object System.Windows.Forms.GroupBox
    $automationGroup.Text = Get-PalworldLocalizedText `
        "Automated Management · temporary files are removed after each action" `
        "자동 관리 · 작업용 임시 파일은 실행이 끝나면 제거됩니다"
    $automationGroup.Location = New-Object System.Drawing.Point(8, 281)
    $automationGroup.Size = New-Object System.Drawing.Size(860, 105)
    $automationGroup.Anchor = "Top,Left,Right"
    $page.Controls.Add($automationGroup)
    $categoryCombo = New-Object System.Windows.Forms.ComboBox
    $categoryCombo.Name = "SshManagementCategory"
    $categoryCombo.Location = New-Object System.Drawing.Point(16, 27)
    $categoryCombo.Size = New-Object System.Drawing.Size(115, 23)
    $categoryCombo.DropDownStyle = "DropDownList"
    foreach ($category in @("Setup", "Manage", "Test", "Remove")) {
        [void]$categoryCombo.Items.Add($category)
    }
    $automationGroup.Controls.Add($categoryCombo)
    $actionCombo = New-Object System.Windows.Forms.ComboBox
    $actionCombo.Name = "SshManagementAction"
    $actionCombo.Location = New-Object System.Drawing.Point(139, 27)
    $actionCombo.Size = New-Object System.Drawing.Size(330, 23)
    $actionCombo.DropDownWidth = 440
    $actionCombo.DropDownStyle = "DropDownList"
    $actions = @(
        [pscustomobject]@{ Category = "Setup"; Id = "Setup"; Label = (Get-PalworldLocalizedText "Install and start a new server" "신규 서버 설치 및 시작"); Server = $false },
        [pscustomobject]@{ Category = "Setup"; Id = "Import"; Label = (Get-PalworldLocalizedText "Import an existing server" "기존 서버 가져오기"); Server = $false },
        [pscustomobject]@{ Category = "Manage"; Id = "Update"; Label = (Get-PalworldLocalizedText "Update Docker image and reapply settings" "Docker 이미지 갱신 및 설정 재적용"); Server = $true },
        [pscustomobject]@{ Category = "Manage"; Id = "Reset"; Label = (Get-PalworldLocalizedText "Reset server world" "서버 월드 초기화"); Server = $true },
        [pscustomobject]@{ Category = "Manage"; Id = "Restore"; Label = (Get-PalworldLocalizedText "Restore server world" "서버 월드 복원"); Server = $true },
        [pscustomobject]@{ Category = "Manage"; Id = "TokenShow"; Label = (Get-PalworldLocalizedText "Show API token" "API token 확인"); Server = $true },
        [pscustomobject]@{ Category = "Manage"; Id = "TokenRotate"; Label = (Get-PalworldLocalizedText "Rotate API token" "API token 재발급"); Server = $true },
        [pscustomobject]@{ Category = "Manage"; Id = "EnvEdit"; Label = (Get-PalworldLocalizedText "[only Windows] Edit and apply server.env" "[only Windows] server.env 편집·적용"); Server = $true },
        [pscustomobject]@{ Category = "Test"; Id = "Test"; Label = (Get-PalworldLocalizedText "Check server" "서버 검사"); Server = $true },
        [pscustomobject]@{ Category = "Remove"; Id = "RemoveServer"; Label = (Get-PalworldLocalizedText "Remove selected server" "선택 서버 제거"); Server = $true },
        [pscustomobject]@{ Category = "Remove"; Id = "RemoveAll"; Label = (Get-PalworldLocalizedText "Remove all managed servers" "모든 관리 서버 제거"); Server = $false },
        [pscustomobject]@{ Category = "Remove"; Id = "RemoveProject"; Label = (Get-PalworldLocalizedText "Remove all servers and the project directory" "관리 디렉터리까지 전체 제거"); Server = $false }
    )
    $automationGroup.Controls.Add($actionCombo)
    $script:PalworldSshServerCombo = New-Object System.Windows.Forms.ComboBox
    $script:PalworldSshServerCombo.Location = New-Object System.Drawing.Point(477, 27)
    $script:PalworldSshServerCombo.Size = New-Object System.Drawing.Size(110, 23)
    $script:PalworldSshServerCombo.DropDownStyle = "DropDownList"
    $automationGroup.Controls.Add($script:PalworldSshServerCombo)
    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = "Refresh Servers"
    $refreshButton.Location = New-Object System.Drawing.Point(595, 24)
    $refreshButton.Size = New-Object System.Drawing.Size(120, 30)
    $automationGroup.Controls.Add($refreshButton)
    $toolTip.SetToolTip(
        $refreshButton,
        (Get-PalworldLocalizedText `
            "Queries serverN.env files and Docker state in the remote work directory again, then refreshes the target server list and status below. This does not reconnect SSH." `
            "원격 작업 디렉터리의 serverN.env와 Docker 상태를 다시 조회하여 대상 서버 목록과 아래 네트워크 상태를 갱신합니다. SSH 연결을 다시 여는 기능은 아닙니다.")
    )
    $runButton = New-Object System.Windows.Forms.Button
    $runButton.Text = "Run"
    $runButton.Location = New-Object System.Drawing.Point(723, 24)
    $runButton.Size = New-Object System.Drawing.Size(55, 30)
    $automationGroup.Controls.Add($runButton)
    $cancelOperationButton = New-Object System.Windows.Forms.Button
    $cancelOperationButton.Text = "Cancel"
    $cancelOperationButton.Location = New-Object System.Drawing.Point(786, 24)
    $cancelOperationButton.Size = New-Object System.Drawing.Size(55, 30)
    $cancelOperationButton.Enabled = $false
    $automationGroup.Controls.Add($cancelOperationButton)
    $automationHint = New-Object System.Windows.Forms.Label
    $automationHint.Text = Get-PalworldLocalizedText `
        "First use Prepare Work Dir → Review Common Settings → Host Check. Setup and Import then prepare Docker and server runtime requirements." `
        "작업 디렉터리 준비 → 공통 설정 검토 → 호스트 검사 순서로 진행하세요. 서버 설치·가져오기는 Docker와 실행 환경을 준비합니다."
    $automationHint.Location = New-Object System.Drawing.Point(16, 66)
    $automationHint.Size = New-Object System.Drawing.Size(825, 24)
    $automationHint.ForeColor = [System.Drawing.Color]::DimGray
    $automationGroup.Controls.Add($automationHint)

    $terminalTabs = New-Object System.Windows.Forms.TabControl
    $terminalTabs.Name = "SshChannelTabs"
    $terminalTabs.Location = New-Object System.Drawing.Point(8, 395)
    $terminalTabs.Size = New-Object System.Drawing.Size(860, 340)
    $terminalTabs.Anchor = "Top,Left,Right"
    $page.Controls.Add($terminalTabs)
    $managementOutputPage = New-Object System.Windows.Forms.TabPage
    $managementOutputPage.Text = "SSH Management"
    $managementOutputPage.Padding = New-Object System.Windows.Forms.Padding(6)
    $terminalPage = New-Object System.Windows.Forms.TabPage
    $terminalPage.Text = "SSH Terminal"
    $terminalPage.Padding = New-Object System.Windows.Forms.Padding(6)
    [void]$terminalTabs.TabPages.Add($managementOutputPage)
    [void]$terminalTabs.TabPages.Add($terminalPage)
    $script:PalworldSshOutput = New-Object System.Windows.Forms.RichTextBox
    $script:PalworldSshOutput.Dock = "Fill"
    $script:PalworldSshOutput.ReadOnly = $true
    $script:PalworldSshOutput.HideSelection = $false
    $script:PalworldSshOutput.WordWrap = $true
    $script:PalworldSshOutput.ScrollBars = "ForcedVertical"
    $script:PalworldSshOutput.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 28)
    $script:PalworldSshOutput.ForeColor = [System.Drawing.Color]::Gainsboro
    $script:PalworldSshOutput.Font = New-Object System.Drawing.Font("Consolas", 9)
    $managementOutputPage.Controls.Add($script:PalworldSshOutput)
    $terminalLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $terminalLayout.Dock = "Fill"
    $terminalLayout.ColumnCount = 1
    $terminalLayout.RowCount = 2
    [void]$terminalLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$terminalLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$terminalLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 40)))
    $terminalPage.Controls.Add($terminalLayout)
    $terminalInputPanel = New-Object System.Windows.Forms.Panel
    $terminalInputPanel.Name = "SshTerminalInputPanel"
    $terminalInputPanel.Dock = "Fill"
    $terminalLayout.Controls.Add($terminalInputPanel, 0, 1)
    $terminalCommandLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $terminalCommandLayout.Dock = "Fill"
    $terminalCommandLayout.ColumnCount = 4
    $terminalCommandLayout.RowCount = 1
    [void]$terminalCommandLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$terminalCommandLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 74)))
    [void]$terminalCommandLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 74)))
    [void]$terminalCommandLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, 74)))
    [void]$terminalCommandLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    $terminalInputPanel.Controls.Add($terminalCommandLayout)
    $script:PalworldSshTerminalOutput = New-Object System.Windows.Forms.RichTextBox
    $script:PalworldSshTerminalOutput.Name = "SshTerminalOutput"
    $script:PalworldSshTerminalOutput.Dock = "Fill"
    $script:PalworldSshTerminalOutput.ReadOnly = $true
    $script:PalworldSshTerminalOutput.HideSelection = $false
    $script:PalworldSshTerminalOutput.WordWrap = $true
    $script:PalworldSshTerminalOutput.ScrollBars = "ForcedVertical"
    $script:PalworldSshTerminalOutput.BackColor = [System.Drawing.Color]::FromArgb(20, 24, 28)
    $script:PalworldSshTerminalOutput.ForeColor = [System.Drawing.Color]::Gainsboro
    $script:PalworldSshTerminalOutput.Font = New-Object System.Drawing.Font("Consolas", 9)
    $terminalLayout.Controls.Add($script:PalworldSshTerminalOutput, 0, 0)
    $terminalInput = New-Object System.Windows.Forms.TextBox
    $terminalInput.Name = "SshTerminalInput"
    $terminalInput.Dock = "Fill"
    $terminalInput.Margin = New-Object System.Windows.Forms.Padding(0, 8, 8, 8)
    $terminalCommandLayout.Controls.Add($terminalInput, 0, 0)
    $sendTerminalButton = New-Object System.Windows.Forms.Button
    $sendTerminalButton.Name = "SshTerminalSendButton"
    $sendTerminalButton.Text = "Send"
    $sendTerminalButton.Dock = "Fill"
    $sendTerminalButton.Margin = New-Object System.Windows.Forms.Padding(0, 5, 6, 5)
    $terminalCommandLayout.Controls.Add($sendTerminalButton, 1, 0)
    $bottomTerminalButton = New-Object System.Windows.Forms.Button
    $bottomTerminalButton.Name = "SshTerminalBottomButton"
    $bottomTerminalButton.Text = "Bottom"
    $bottomTerminalButton.Dock = "Fill"
    $bottomTerminalButton.Margin = New-Object System.Windows.Forms.Padding(0, 5, 6, 5)
    $terminalCommandLayout.Controls.Add($bottomTerminalButton, 2, 0)
    $clearTerminalButton = New-Object System.Windows.Forms.Button
    $clearTerminalButton.Name = "SshTerminalClearButton"
    $clearTerminalButton.Text = "Clear"
    $clearTerminalButton.Dock = "Fill"
    $clearTerminalButton.Margin = New-Object System.Windows.Forms.Padding(0, 5, 0, 5)
    $terminalCommandLayout.Controls.Add($clearTerminalButton, 3, 0)

    $networkGroup = New-Object System.Windows.Forms.GroupBox
    $networkGroup.Text = Get-PalworldLocalizedText `
        "Status history · commands, readiness, selected server and network" `
        "상태 기록 · 실행 작업, 준비 상태, 선택 서버와 네트워크"
    $networkGroup.Location = New-Object System.Drawing.Point(8, 744)
    $networkGroup.Size = New-Object System.Drawing.Size(860, 125)
    $networkGroup.Anchor = "Top,Left,Right"
    $page.Controls.Add($networkGroup)
    $toolTip.SetToolTip(
        $networkGroup,
        (Get-PalworldLocalizedText `
            "Shows the latest operation result, project-directory and Setup prerequisites, selected-server container and port mappings, REST reachability from Windows, and external forwarding guidance." `
            "마지막 작업 결과, project directory·Setup 선행 조건, 선택 서버의 컨테이너·포트 매핑, Windows에서의 REST 도달 여부와 외부 포워딩 안내를 표시합니다.")
    )
    $script:PalworldSshNetworkNotice = New-Object System.Windows.Forms.RichTextBox
    $script:PalworldSshNetworkNotice.Name = "SshNetworkNotice"
    $script:PalworldSshNetworkNotice.Dock = "Fill"
    $script:PalworldSshNetworkNotice.ReadOnly = $true
    $script:PalworldSshNetworkNotice.WordWrap = $true
    $script:PalworldSshNetworkNotice.ScrollBars = "Vertical"
    $script:PalworldSshNetworkNotice.BackColor = [System.Drawing.SystemColors]::Window
    $script:PalworldSshNetworkNotice.ForeColor = [System.Drawing.Color]::DimGray
    $script:PalworldSshLiveStatusLines = @(
        (Get-PalworldLocalizedText `
            "[INFO] Connect to an SSH server to inspect operation, server, and network findings." `
            "[INFO] 작업·서버·네트워크 상태를 확인하려면 SSH 서버에 연결하세요.")
    )
    $script:PalworldSshLastOperationFinding = ""
    $script:PalworldSshStatusHistoryLines = @()
    $script:PalworldSshStatusOperationTitle = ""
    $script:PalworldSshStatusOperationSeenLines = @{}
    $script:PalworldSshStatusOperationNeedsHeader = $true
    $networkGroup.Controls.Add($script:PalworldSshNetworkNotice)

    $script:PalworldSshSummary = $summary
    $script:PalworldSshAddButton = $addButton
    $script:PalworldSshUpdateButton = $updateButton
    $script:PalworldSshDeleteButton = $deleteButton
    $script:PalworldSshConnectButton = $connectButton
    $script:PalworldSshDisconnectButton = $disconnectButton
    $script:PalworldSshReconnectButton = $reconnectButton
    $script:PalworldSshHostCheckButton = $hostCheckButton
    $script:PalworldSshCreateWorkDirectoryButton = $createWorkDirectoryButton
    $script:PalworldSshReviewCommonSettingsButton = $reviewCommonSettingsButton
    $script:PalworldSshRefreshButton = $refreshButton
    $script:PalworldSshRunButton = $runButton
    $script:PalworldSshCancelOperationButton = $cancelOperationButton
    $script:PalworldSshCategoryCombo = $categoryCombo
    $script:PalworldSshActionCombo = $actionCombo
    $script:PalworldSshActions = @($actions)
    $script:PalworldSshTerminalInput = $terminalInput
    $script:PalworldSshTerminalSendButton = $sendTerminalButton
    $script:PalworldSshChannelTabs = $terminalTabs

    $script:PalworldSshSetAvailability = {
        if ($script:PalworldSshClosing) { return }
        $available = $null -ne (Get-SelectedPalworldSshConnection)
        $idle = -not $script:PalworldSshOperationRunning
        $connected = $script:PalworldSshClient -and $script:PalworldSshClient.IsConnected -and
            $script:PalworldSshTerminalClient -and $script:PalworldSshTerminalClient.IsConnected
        $script:PalworldSshAddButton.Enabled = $idle
        $script:PalworldSshUpdateButton.Enabled = $available -and $idle
        $script:PalworldSshDeleteButton.Enabled = $available -and $idle
        $script:PalworldSshConnectButton.Enabled = $available -and $idle
        $script:PalworldSshDisconnectButton.Enabled = $available -and $idle
        $script:PalworldSshReconnectButton.Enabled = $available -and $idle
        $script:PalworldSshCreateWorkDirectoryButton.Enabled = $available -and $idle -and $connected
        $script:PalworldSshReviewCommonSettingsButton.Enabled = $available -and $idle -and
            $connected -and $script:PalworldSshProjectPrepared
        $script:PalworldSshHostCheckButton.Enabled = $available -and $idle -and
            $connected -and $script:PalworldSshCommonSettingsReviewed
        $script:PalworldSshRefreshButton.Enabled = $available -and $idle -and
            $connected -and $script:PalworldSshProjectPrepared
        $script:PalworldSshRunButton.Enabled = $available -and $idle -and
            $script:PalworldSshHostReadyForManagement
        $script:PalworldSshCancelOperationButton.Enabled = $script:PalworldSshOperationRunning
    }
    $script:PalworldSshSetOperationState = {
        param([bool]$Running)
        $script:PalworldSshOperationRunning = $Running
        if ($script:PalworldSshClosing) { return }
        $script:PalworldSshCancelOperationButton.Text = Get-PalworldLocalizedText "Cancel" "취소"
        $script:PalworldSshConnectionCombo.Enabled = -not $Running
        $script:PalworldSshCategoryCombo.Enabled = -not $Running
        $script:PalworldSshActionCombo.Enabled = -not $Running
        if ($Running) { $script:PalworldSshServerCombo.Enabled = $false }
        if ($script:PalworldServerApiSetSshOperationState) {
            try { & $script:PalworldServerApiSetSshOperationState $Running } catch { }
        }
        & $script:PalworldSshSetAvailability
        if (-not $Running) { & $script:PalworldSshUpdateActionTarget }
        if ($script:ResourceUsageRefreshContext) {
            try { & $script:ResourceUsageRefreshContext } catch { }
        }
    }
    $script:PalworldSshBeginStatusOperation = {
        param([Parameter(Mandatory = $true)][string]$Title)
        $script:PalworldSshStatusOperationTitle = $Title.Trim()
        $script:PalworldSshStatusOperationSeenLines = @{}
        $script:PalworldSshStatusOperationNeedsHeader = $true
        $script:PalworldSshLastOperationFinding = ""
        $script:PalworldSshLiveStatusLines = @()
    }
    $script:PalworldSshRenderStatusNotice = {
        if ($script:PalworldSshClosing -or -not $script:PalworldSshNetworkNotice -or
            $script:PalworldSshNetworkNotice.IsDisposed) { return }
        $lines = @()
        if ($script:PalworldSshLastOperationFinding) {
            $lines += [string]$script:PalworldSshLastOperationFinding
        }
        $lines += @($script:PalworldSshLiveStatusLines | Where-Object { $_ })
        if ($lines.Count -eq 0) {
            $lines = @((Get-PalworldLocalizedText `
                "[INFO] No status or findings are available yet." `
                "[INFO] 아직 표시할 상태나 진단 결과가 없습니다."))
        }
        $operationTitle = [string]$script:PalworldSshStatusOperationTitle
        if (-not $operationTitle) {
            $operationTitle = if ($script:PalworldSshLastOperationFinding) {
                (([string]$script:PalworldSshLastOperationFinding) `
                    -replace '^\[[A-Z]+\]\s*', '' `
                    -replace '^Running:\s*', '') -split ':', 2 | Select-Object -First 1
            }
            else { Get-PalworldLocalizedText "Status update" "상태 갱신" }
        }
        if ($script:PalworldSshStatusOperationNeedsHeader -or
            $script:PalworldSshStatusHistoryLines.Count -eq 0) {
            if ($script:PalworldSshStatusHistoryLines.Count -gt 0) {
                $script:PalworldSshStatusHistoryLines += ""
            }
            $script:PalworldSshStatusHistoryLines += (
                "[{0}] COMMAND · {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $operationTitle
            )
            $script:PalworldSshStatusHistoryLines += ('─' * 71)
            $script:PalworldSshStatusOperationNeedsHeader = $false
        }
        foreach ($line in $lines) {
            $statusLine = [string]$line
            if (-not $script:PalworldSshStatusOperationSeenLines.ContainsKey($statusLine)) {
                $script:PalworldSshStatusHistoryLines += $statusLine
                $script:PalworldSshStatusOperationSeenLines[$statusLine] = $true
            }
        }
        # Keep a generous in-session history while bounding memory for an admin
        # window that may remain open for days.
        if ($script:PalworldSshStatusHistoryLines.Count -gt 1600) {
            $script:PalworldSshStatusHistoryLines = @(
                $script:PalworldSshStatusHistoryLines |
                    Select-Object -Last 1400
            )
        }
        $script:PalworldSshNetworkNotice.ForeColor = [System.Drawing.Color]::DimGray
        $script:PalworldSshNetworkNotice.Lines = $script:PalworldSshStatusHistoryLines
        $renderedStatusLines = @($script:PalworldSshNetworkNotice.Lines)
        $continuedColor = [System.Drawing.Color]::DimGray
        for ($lineIndex = 0; $lineIndex -lt $renderedStatusLines.Count; $lineIndex++) {
            $renderedStatusLine = [string]$renderedStatusLines[$lineIndex]
            $lineColor = switch -Regex ($renderedStatusLine) {
                '^\[FAIL\]' { [System.Drawing.Color]::DarkRed; break }
                '^\[WARN\]' { [System.Drawing.Color]::DarkOrange; break }
                '^\[PASS\]' { [System.Drawing.Color]::DarkGreen; break }
                '^\s+' { $continuedColor; break }
                default { [System.Drawing.Color]::DimGray }
            }
            if ($renderedStatusLine -match '^\[(?:FAIL|WARN|PASS)\]') {
                $continuedColor = $lineColor
            }
            elseif ($renderedStatusLine -notmatch '^\s+') {
                $continuedColor = [System.Drawing.Color]::DimGray
            }
            $lineStart = $script:PalworldSshNetworkNotice.GetFirstCharIndexFromLine($lineIndex)
            if ($lineStart -ge 0 -and $renderedStatusLine.Length -gt 0) {
                $script:PalworldSshNetworkNotice.SelectionStart = $lineStart
                $script:PalworldSshNetworkNotice.SelectionLength = $renderedStatusLine.Length
                $script:PalworldSshNetworkNotice.SelectionColor = $lineColor
            }
        }
        $script:PalworldSshNetworkNotice.SelectionStart = $script:PalworldSshNetworkNotice.TextLength
        $script:PalworldSshNetworkNotice.SelectionLength = 0
        $script:PalworldSshNetworkNotice.ScrollToCaret()
    }
    $script:PalworldSshShowSelected = {
        if ($script:PalworldSshClosing) { return }
        $selected = Get-SelectedPalworldSshConnection
        if ($null -eq $selected) {
            if ($script:PalworldSshCurrentConnection) {
                Disconnect-PalworldSshSession
            }
            $script:PalworldSshCurrentConnection = $null
            $script:PalworldSshHostReadyForManagement = $false
            $script:PalworldSshProjectPrepared = $false
            $script:PalworldSshCommonSettingsReviewed = $false
            $script:PalworldSshSummary.Text = if ($script:AdminSshConnections.Count -gt 0) {
                Get-PalworldLocalizedText `
                    "No SSH Connection selected. Select one or Add a new one." `
                    "선택한 SSH 연결이 없습니다. 하나를 선택하거나 새로 추가하세요."
            }
            else {
                Get-PalworldLocalizedText `
                    "No SSH Connections. Select Add; an API Host/IP is used as the initial value when available." `
                    "저장된 SSH 연결이 없습니다. 추가를 누르세요. 가능하면 API 호스트/IP를 초기값으로 사용합니다."
            }
            $script:AdminSelectedSshId = ""
            $script:PalworldSshSelectionSyncing = $true
            $script:PalworldSshServerCombo.Items.Clear()
            $script:PalworldSshSelectionSyncing = $false
            $script:PalworldSshLastOperationFinding = ""
            & $script:PalworldSshBeginStatusOperation (
                Get-PalworldLocalizedText "SSH Connection selection" "SSH 연결 선택"
            )
            $script:PalworldSshLiveStatusLines = @(
                (Get-PalworldLocalizedText `
                    "[INFO] Select an SSH Connection to inspect managed servers and status." `
                    "[INFO] 관리 서버와 상태를 확인하려면 SSH 연결을 선택하세요.")
            )
            & $script:PalworldSshRenderStatusNotice
        }
        else {
            if ($script:PalworldSshCurrentConnection -and $script:PalworldSshCurrentConnection.Id -ne $selected.Id) {
                Disconnect-PalworldSshSession
                $script:PalworldSshHostReadyForManagement = $false
                $script:PalworldSshProjectPrepared = $false
                $script:PalworldSshCommonSettingsReviewed = $false
                $script:PalworldSshSelectionSyncing = $true
                $script:PalworldSshServerCombo.Items.Clear()
                $script:PalworldSshSelectionSyncing = $false
                $script:PalworldSshLastOperationFinding = ""
                & $script:PalworldSshBeginStatusOperation (
                    "$(Get-PalworldLocalizedText 'SSH Connection selection' 'SSH 연결 선택') · $([string]$selected.Name)"
                )
                $script:PalworldSshLiveStatusLines = @(
                    (Get-PalworldLocalizedText `
                        "[INFO] Connect to refresh this SSH server's managed server list and status." `
                        "[INFO] 이 SSH 서버의 관리 서버 목록과 상태를 갱신하려면 연결하세요.")
                )
                & $script:PalworldSshRenderStatusNotice
            }
            $script:PalworldSshCurrentConnection = $selected
            $script:AdminSelectedSshId = [string]$selected.Id
            $script:PalworldSshSummary.Text = "$([string]$selected.Name) · $([string]$selected.Host):$([int]$selected.Port) · $([string]$selected.Username) · $([string]$selected.WorkDirectory)"
        }
        Update-PalworldSshApiLinkStatus
        & $script:PalworldSshSetAvailability
    }
    $script:PalworldSshRefreshConnections = {
        param([string]$SelectedId)
        $previousSyncState = $script:AdminSelectionSyncing
        $script:AdminSelectionSyncing = $true
        try {
            $script:PalworldSshConnectionCombo.Items.Clear()
            [void]$script:PalworldSshConnectionCombo.Items.Add($script:PalworldSshNoSelectionText)
            $selectedIndex = 0
            for ($index = 0; $index -lt $script:AdminSshConnections.Count; $index++) {
                [void]$script:PalworldSshConnectionCombo.Items.Add([string]$script:AdminSshConnections[$index].Name)
                if ([string]$script:AdminSshConnections[$index].Id -eq $SelectedId) {
                    $selectedIndex = $index + 1
                }
            }
            $script:PalworldSshConnectionCombo.SelectedIndex = $selectedIndex
        }
        finally {
            $script:AdminSelectionSyncing = $previousSyncState
        }
        & $script:PalworldSshShowSelected
    }
    $script:PalworldSshConnectionCombo.Add_SelectedIndexChanged({
        if (-not $script:AdminSelectionSyncing -and $script:PalworldSshPinnedConnectionId) {
            $selectedDuringOperation = Get-SelectedPalworldSshConnection
            if ($null -eq $selectedDuringOperation -or
                [string]$selectedDuringOperation.Id -ne [string]$script:PalworldSshPinnedConnectionId) {
                Set-PalworldSshSelectedConnectionId $script:PalworldSshPinnedConnectionId
                return
            }
        }
        & $script:PalworldSshShowSelected
        if ($script:AdminSelectionSyncing) { return }
        Sync-PalworldApiSelectionFromSsh
        try { Save-AdminConnectionStore } catch { }
    })
    $addButton.Add_Click({
        try {
            $api = Get-SelectedAdminApiConnection
            $values = Show-PalworldSshConnectionDialog -Owner $script:PalworldSshOwner -Mode Add -Connection $null -ApiConnection $api
            if ($null -eq $values) { return }
            if ($script:AdminSshConnections | Where-Object { $_.Name -ieq $values.Name }) {
                throw (Get-PalworldLocalizedText `
                    "An SSH Connection with that name already exists." `
                    "같은 이름의 SSH 연결이 이미 있습니다.")
            }
            $created = New-AdminSshConnection `
                -Name $values.Name -SshHost $values.Host -Port $values.Port -Username $values.Username `
                -AuthMode $values.AuthMode -Password $values.Password `
                -PrivateKeyPath $values.PrivateKeyPath -PrivateKeyPassphrase $values.PrivateKeyPassphrase `
                -SudoPassword $values.SudoPassword -WorkDirectory $values.WorkDirectory `
                -HostKeyFingerprint $values.HostKeyFingerprint
            $script:AdminSshConnections = @($script:AdminSshConnections) + @($created)
            $script:AdminSelectedSshId = $created.Id
            & $script:PalworldSshRefreshConnections $created.Id
            Sync-PalworldApiSelectionFromSsh
            Save-AdminConnectionStore
        }
        catch { [void][System.Windows.Forms.MessageBox]::Show([string]$_.Exception.Message, "SSH Connection") }
    })
    $updateButton.Add_Click({
        $selected = Get-SelectedPalworldSshConnection
        if ($null -eq $selected) { return }
        $values = Show-PalworldSshConnectionDialog -Owner $script:PalworldSshOwner -Mode Update -Connection $selected -ApiConnection (Get-SelectedAdminApiConnection)
        if ($null -eq $values) { return }
        try {
            if ($script:AdminSshConnections | Where-Object { $_.Id -ne $selected.Id -and $_.Name -ieq $values.Name }) {
                throw (Get-PalworldLocalizedText `
                    "An SSH Connection with that name already exists." `
                    "같은 이름의 SSH 연결이 이미 있습니다.")
            }
            $oldSshName = [string]$selected.Name
            foreach ($property in @("Name", "Host", "Port", "Username", "AuthMode", "Password", "PrivateKeyPath", "PrivateKeyPassphrase", "SudoPassword", "WorkDirectory", "HostKeyFingerprint")) {
                $selected.$property = $values.$property
            }
            if ([string]$values.Name -ne $oldSshName) {
                foreach ($api in @($script:AdminConnections)) {
                    if ([string]$api.SshConnectionId -eq [string]$selected.Id -and
                        [string]$api.ManagedServerName -match '^server[1-9][0-9]*$' -and
                        [string]$api.Name -eq "$oldSshName - $([string]$api.ManagedServerName)") {
                        $api.Name = "$([string]$values.Name) - $([string]$api.ManagedServerName)"
                    }
                }
            }
            Disconnect-PalworldSshSession
            Save-AdminConnectionStore
            & $script:PalworldSshRefreshConnections $selected.Id
            if ($script:AdminRefreshApiConnections) {
                $activeApi = Get-SelectedAdminApiConnection
                & $script:AdminRefreshApiConnections $(if ($activeApi) { [string]$activeApi.Id } else { "" })
            }
        }
        catch { [void][System.Windows.Forms.MessageBox]::Show([string]$_.Exception.Message, "SSH Connection") }
    })
    $deleteButton.Add_Click({
        $selected = Get-SelectedPalworldSshConnection
        if ($null -eq $selected) { return }
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (Get-PalworldLocalizedText `
                "Delete SSH Connection '$([string]$selected.Name)'? Linked API Connections are preserved but become unlinked." `
                "SSH 연결 '$([string]$selected.Name)'을 삭제하시겠습니까? 연결된 API 연결은 보존되지만 SSH 연결이 해제됩니다."),
            (Get-PalworldLocalizedText "SSH Connection delete" "SSH 연결 삭제"),
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        Disconnect-PalworldSshSession
        foreach ($api in $script:AdminConnections) {
            if ([string]$api.SshConnectionId -eq [string]$selected.Id) { $api.SshConnectionId = "" }
        }
        $script:AdminSshConnections = @($script:AdminSshConnections | Where-Object { $_.Id -ne $selected.Id })
        $script:AdminSelectedSshId = ""
        & $script:PalworldSshRefreshConnections ""
        Save-AdminConnectionStore
        Update-PalworldSshApiLinkStatus
        & $script:PalworldSshSetAvailability
    })
    $script:PalworldSshRunHostCheck = {
        param([Parameter(Mandatory = $true)]$Connection)
        Set-PalworldSshWorkDirectoryStatus -State Checking
        try {
            $check = Test-PalworldSshHostReadiness `
                -Connection $Connection -Owner $script:PalworldSshOwner
            $script:PalworldSshProjectPrepared = [bool]$check.ProjectPrepared
            $script:PalworldSshCommonSettingsReviewed = [bool]$check.CommonSettingsReviewed
            if ($check.ReadyForManagement) {
                $script:PalworldSshHostReadyForManagement = $true
                Set-PalworldSshWorkDirectoryStatus -State Ready -Path $check.WorkDirectory
                $script:PalworldSshLastOperationFinding = "[PASS] Host Check"
                $script:PalworldSshLiveStatusLines = @(
                    "[PASS] SSH access, Common Settings, timezone, and project preparation are ready.",
                    "[INFO] Setup installs or repairs Docker and server runtime requirements."
                )
            }
            else {
                $script:PalworldSshHostReadyForManagement = $false
                $script:PalworldSshSelectionSyncing = $true
                $script:PalworldSshServerCombo.Items.Clear()
                $script:PalworldSshSelectionSyncing = $false
                $directoryState = if (-not $check.WorkDirectoryExists) {
                    "Missing"
                }
                elseif (-not $check.WorkDirectoryWritable) {
                    "Unwritable"
                }
                elseif (-not $check.ProjectPrepared) {
                    "NeedPrepare"
                }
                elseif (-not $check.CommonSettingsValid -or -not $check.CommonSettingsReviewed) {
                    "NeedCommonReview"
                }
                else { "Failed" }
                Set-PalworldSshWorkDirectoryStatus `
                    -State $directoryState -Path $check.WorkDirectory
                $script:PalworldSshLastOperationFinding = "[WARN] Host Check · preparation required"
                $script:PalworldSshLiveStatusLines = if (-not $check.WorkDirectoryExists) {
                    @(
                        "[ACTION REQUIRED] Prepare the project work directory first: $([string]$check.WorkDirectory)",
                        "[INFO] Review Common Settings and Host Check will be available afterward."
                    )
                }
                elseif (-not $check.WorkDirectoryWritable -or -not $check.ProjectPrepared) {
                    @(
                        "[ACTION REQUIRED] Select Prepare Work Dir to verify access and install the project scaffold.",
                        "[INFO] This step does not install Docker or start a game server."
                    )
                }
                else {
                    @(
                        "[ACTION REQUIRED] Select Review Common Settings and confirm the project-wide values.",
                        "[INFO] Host Check becomes available after the settings are saved."
                    )
                }
            }
            & $script:PalworldSshRenderStatusNotice
            & $script:PalworldSshSetAvailability
            return $check
        }
        catch {
            if ($script:PalworldSshClosing) { return $null }
            $script:PalworldSshHostReadyForManagement = $false
            $script:PalworldSshProjectPrepared = $false
            $script:PalworldSshCommonSettingsReviewed = $false
            Set-PalworldSshWorkDirectoryStatus -State Failed
            $message = [string]$_.Exception.Message
            $script:PalworldSshSelectionSyncing = $true
            $script:PalworldSshServerCombo.Items.Clear()
            $script:PalworldSshSelectionSyncing = $false
            $script:PalworldSshLastOperationFinding = "[FAIL] Host Check: $message"
            $script:PalworldSshLiveStatusLines = @(
                "[FAIL] This SSH host is not ready for Palworld administration: $message"
            )
            & $script:PalworldSshRenderStatusNotice
            & $script:PalworldSshSetAvailability
            Add-PalworldSshOutput "`r`n[FAIL] Host Check: $message`r`n"
            return $null
        }
    }
    $connectButton.Add_Click({
        if ($script:PalworldSshOperationRunning) { return }
        try {
            $connection = Get-SelectedPalworldSshConnection
            if ($null -eq $connection) { return }
            & $script:PalworldSshBeginStatusOperation "Connect · $([string]$connection.Name)"
            & $script:PalworldSshSetOperationState $true
            Connect-PalworldSshDualSession `
                -Connection $connection `
                -Owner $script:PalworldSshOwner
            $hostCheck = & $script:PalworldSshRunHostCheck $connection
            if ($hostCheck -and $hostCheck.ReadyForManagement) {
                & $script:PalworldSshRefreshServers
            }
        }
        catch {
            $script:PalworldSshChannelTabs.SelectedIndex = 0
            $message = [string]$_.Exception.Message
            Set-PalworldSshWorkDirectoryStatus -State Failed
            $script:PalworldSshLastOperationFinding = "[FAIL] Connect: $message"
            & $script:PalworldSshRenderStatusNotice
            Add-PalworldSshOutput "`r`n[FAIL] $message`r`n"
        }
        finally {
            if ($script:PalworldSshClosing) { $script:PalworldSshOperationRunning = $false }
            else { & $script:PalworldSshSetOperationState $false }
            $script:PalworldSshCancelRequested = $false
        }
    })
    $disconnectButton.Add_Click({
        $connection = Get-SelectedPalworldSshConnection
        $connectionName = if ($connection) { [string]$connection.Name } else { "SSH" }
        & $script:PalworldSshBeginStatusOperation "Disconnect · $connectionName"
        Disconnect-PalworldSshSession
        $script:PalworldSshHostReadyForManagement = $false
        $script:PalworldSshProjectPrepared = $false
        $script:PalworldSshCommonSettingsReviewed = $false
        Set-PalworldSshWorkDirectoryStatus -State Unknown
        & $script:PalworldSshSetOperationState $false
        $script:PalworldSshLastOperationFinding = ""
        $script:PalworldSshLiveStatusLines = @("[INFO] Disconnected. Status is not being refreshed.")
        & $script:PalworldSshRenderStatusNotice
    })
    $reconnectButton.Add_Click({
        if ($script:PalworldSshOperationRunning) { return }
        try {
            $connection = Get-SelectedPalworldSshConnection
            if ($null -eq $connection) { return }
            & $script:PalworldSshBeginStatusOperation "Reconnect · $([string]$connection.Name)"
            & $script:PalworldSshSetOperationState $true
            Add-PalworldSshOutput "`r`n[SSH] Reconnecting management and terminal channels...`r`n"
            Connect-PalworldSshDualSession -Connection $connection -Owner $script:PalworldSshOwner
            $hostCheck = & $script:PalworldSshRunHostCheck $connection
            if ($hostCheck -and $hostCheck.ReadyForManagement) {
                & $script:PalworldSshRefreshServers
            }
        }
        catch {
            $script:PalworldSshChannelTabs.SelectedIndex = 0
            $message = [string]$_.Exception.Message
            Set-PalworldSshWorkDirectoryStatus -State Failed
            $script:PalworldSshLastOperationFinding = "[FAIL] Reconnect: $message"
            & $script:PalworldSshRenderStatusNotice
            Add-PalworldSshOutput "`r`n[FAIL] Reconnect failed: $message`r`n"
        }
        finally {
            if ($script:PalworldSshClosing) { $script:PalworldSshOperationRunning = $false }
            else { & $script:PalworldSshSetOperationState $false }
            $script:PalworldSshCancelRequested = $false
        }
    })
    $hostCheckButton.Add_Click({
        if ($script:PalworldSshOperationRunning) { return }
        try {
            $connection = Get-SelectedPalworldSshConnection
            if ($null -eq $connection) { return }
            & $script:PalworldSshBeginStatusOperation "Host Check · $([string]$connection.Name)"
            & $script:PalworldSshSetOperationState $true
            if (-not $script:PalworldSshClient -or -not $script:PalworldSshClient.IsConnected -or
                -not $script:PalworldSshTerminalClient -or -not $script:PalworldSshTerminalClient.IsConnected) {
                Connect-PalworldSshDualSession -Connection $connection -Owner $script:PalworldSshOwner
            }
            $hostCheck = & $script:PalworldSshRunHostCheck $connection
            if ($hostCheck -and $hostCheck.ReadyForManagement) {
                & $script:PalworldSshRefreshServers
            }
        }
        catch {
            $message = [string]$_.Exception.Message
            $script:PalworldSshLastOperationFinding = "[FAIL] Host Check: $message"
            & $script:PalworldSshRenderStatusNotice
            Add-PalworldSshOutput "`r`n[FAIL] $message`r`n"
        }
        finally {
            if ($script:PalworldSshClosing) { $script:PalworldSshOperationRunning = $false }
            else { & $script:PalworldSshSetOperationState $false }
            $script:PalworldSshCancelRequested = $false
        }
    })
    $createWorkDirectoryButton.Add_Click({
        if ($script:PalworldSshOperationRunning) { return }
        try {
            $connection = Get-SelectedPalworldSshConnection
            if ($null -eq $connection) { return }
            & $script:PalworldSshBeginStatusOperation "Prepare Work Dir · $([string]$connection.Name)"
            & $script:PalworldSshSetOperationState $true
            if (-not $script:PalworldSshClient -or -not $script:PalworldSshClient.IsConnected -or
                -not $script:PalworldSshTerminalClient -or -not $script:PalworldSshTerminalClient.IsConnected) {
                Connect-PalworldSshDualSession -Connection $connection -Owner $script:PalworldSshOwner
            }
            $hostCheck = & $script:PalworldSshRunHostCheck $connection
            if ($null -eq $hostCheck) { return }
            Set-PalworldSshWorkDirectoryStatus -State Preparing -Path $hostCheck.WorkDirectory
            [void](Initialize-PalworldSshWorkDirectory `
                -Connection $connection -Owner $script:PalworldSshOwner)
            $verified = & $script:PalworldSshRunHostCheck $connection
            if ($verified -and $verified.ProjectPrepared) {
                $script:PalworldSshLastOperationFinding = "[PASS] Prepare Work Dir"
                if (-not $verified.CommonSettingsReviewed) {
                    Set-PalworldSshWorkDirectoryStatus -State NeedCommonReview -Path $verified.WorkDirectory
                }
            }
        }
        catch {
            $message = [string]$_.Exception.Message
            Set-PalworldSshWorkDirectoryStatus -State Failed
            $script:PalworldSshLastOperationFinding = "[FAIL] Prepare Work Dir: $message"
            $script:PalworldSshLiveStatusLines = @(
                "[FAIL] Automated Management remains blocked until the project directory is ready."
            )
            & $script:PalworldSshRenderStatusNotice
            Add-PalworldSshOutput "`r`n[FAIL] $message`r`n"
        }
        finally {
            if ($script:PalworldSshClosing) { $script:PalworldSshOperationRunning = $false }
            else { & $script:PalworldSshSetOperationState $false }
            $script:PalworldSshCancelRequested = $false
        }
    })
    $reviewCommonSettingsButton.Add_Click({
        if ($script:PalworldSshOperationRunning) { return }
        try {
            $connection = Get-SelectedPalworldSshConnection
            if ($null -eq $connection) { return }
            & $script:PalworldSshBeginStatusOperation "Review Common Settings · $([string]$connection.Name)"
            & $script:PalworldSshSetOperationState $true
            if (-not $script:PalworldSshClient -or -not $script:PalworldSshClient.IsConnected -or
                -not $script:PalworldSshTerminalClient -or -not $script:PalworldSshTerminalClient.IsConnected) {
                Connect-PalworldSshDualSession -Connection $connection -Owner $script:PalworldSshOwner
            }
            $remote = Get-PalworldRemoteCommonEnv `
                -Connection $connection -Owner $script:PalworldSshOwner
            $edited = Show-PalworldCommonSettingsEditor `
                -Owner $script:PalworldSshOwner `
                -Content $remote.Content `
                -HostTimezone $remote.HostTimezone
            if ($null -eq $edited) {
                $script:PalworldSshLastOperationFinding = "[INFO] Common Settings review canceled."
                & $script:PalworldSshRenderStatusNotice
                return
            }
            $saved = Save-PalworldRemoteCommonEnv `
                -Connection $connection -Owner $script:PalworldSshOwner `
                -Content $edited -ExpectedHash $remote.Hash
            $script:PalworldSshProjectPrepared = $true
            $script:PalworldSshCommonSettingsReviewed = [bool]$saved.Reviewed
            $script:PalworldSshLastOperationFinding = "[PASS] Review Common Settings"
            Set-PalworldSshWorkDirectoryStatus -State ReadyForHostCheck -Path $saved.Project
            $script:PalworldSshLiveStatusLines = @(
                "[PASS] Common Settings were validated, backed up, and confirmed.",
                "[INFO] Running Host Check now to apply TZ and verify the host."
            )
            & $script:PalworldSshRenderStatusNotice
            & $script:PalworldSshSetAvailability
            $verified = & $script:PalworldSshRunHostCheck $connection
            if ($verified -and $verified.ReadyForManagement) {
                & $script:PalworldSshRefreshServers
            }
        }
        catch {
            $message = [string]$_.Exception.Message
            $script:PalworldSshHostReadyForManagement = $false
            $script:PalworldSshCommonSettingsReviewed = $false
            Set-PalworldSshWorkDirectoryStatus -State NeedCommonReview
            $script:PalworldSshLastOperationFinding = "[FAIL] Review Common Settings: $message"
            $script:PalworldSshLiveStatusLines = @(
                "[ACTION REQUIRED] Correct and confirm Common Settings before running Host Check."
            )
            & $script:PalworldSshRenderStatusNotice
            & $script:PalworldSshSetAvailability
            Add-PalworldSshOutput "`r`n[FAIL] Common Settings review failed: $message`r`n"
        }
        finally {
            if ($script:PalworldSshClosing) { $script:PalworldSshOperationRunning = $false }
            else { & $script:PalworldSshSetOperationState $false }
            $script:PalworldSshCancelRequested = $false
        }
    })
    $script:PalworldSshRefreshServers = {
        try {
            $script:PalworldSshLastRefreshServer = ""
            $connection = Get-SelectedPalworldSshConnection
            if ($null -eq $connection) { return }
            $currentServer = if ($script:PalworldSshServerCombo.SelectedIndex -ge 0) {
                [string]$script:PalworldSshServerCombo.SelectedItem
            }
            elseif ([string]$connection.LastSelectedServer -match '^server[1-9][0-9]*$') {
                [string]$connection.LastSelectedServer
            }
            else { "" }
            $servers = @()
            $projectExists = Test-PalworldRemoteProjectExists -Connection $connection -Owner $script:PalworldSshOwner
            $resolvedProject = Resolve-PalworldRemoteWorkDirectory `
                -Connection $connection -Owner $script:PalworldSshOwner
            $projectInitialized = $false
            if ($projectExists) {
                $projectInitialized = Test-PalworldRemoteProjectInitialized `
                    -Connection $connection -Owner $script:PalworldSshOwner -Project $resolvedProject
            }
            if ($projectInitialized) {
                $servers = @(Get-PalworldSshServerList -Connection $connection -Owner $script:PalworldSshOwner)
            }
            $script:PalworldSshSelectionSyncing = $true
            $script:PalworldSshServerCombo.Items.Clear()
            foreach ($serverItem in $servers) { [void]$script:PalworldSshServerCombo.Items.Add([string]$serverItem.name) }
            if ($currentServer -eq "all") { [void]$script:PalworldSshServerCombo.Items.Add("all") }
            $availableNames = @(
                $script:PalworldSshServerCombo.Items | ForEach-Object { [string]$_ }
            )
            $operationServer = [string]$script:PalworldSshPostActionApiServer
            $preferredServer = if (
                $script:PalworldSshPreferNewServerAfterRefresh -and
                $operationServer -match '^server[1-9][0-9]*$' -and
                $availableNames -contains $operationServer
            ) {
                $operationServer
            }
            else {
                Get-PalworldPreferredServerName `
                    -Current $currentServer `
                    -Available $availableNames `
                    -Previous $script:PalworldSshServersBeforeOperation `
                    -PreferNew:$script:PalworldSshPreferNewServerAfterRefresh
            }
            if ($preferredServer) {
                $script:PalworldSshServerCombo.SelectedIndex = `
                    $script:PalworldSshServerCombo.Items.IndexOf($preferredServer)
            }
            if ($script:PalworldSshPreferNewServerAfterRefresh -and
                $preferredServer -match '^server[1-9][0-9]*$' -and
                ($preferredServer -eq $operationServer -or
                    @($script:PalworldSshServersBeforeOperation) -notcontains $preferredServer)) {
                $script:PalworldSshLastRefreshServer = [string]$preferredServer
            }
            $script:PalworldSshSelectionSyncing = $false
            if ($preferredServer -match '^server[1-9][0-9]*$') {
                Set-PalworldSshLastSelectedServer -Connection $connection -Server $preferredServer
            }
            elseif ($servers.Count -eq 0) {
                Set-PalworldSshLastSelectedServer -Connection $connection -Server ""
            }
            & $script:PalworldSshUpdateActionTarget
            $dockerCount = @($servers | Where-Object { [string]$_.state -ne "configured" }).Count
            $configOnlyCount = @($servers | Where-Object { [string]$_.state -eq "configured" }).Count
            if ($servers.Count -gt 0) {
                Add-PalworldSshOutput "`r`n[PASS] Server list refreshed: $($servers.Count) · Docker $dockerCount · config only $configOnlyCount · $resolvedProject`r`n"
            }
            elseif (-not $projectExists) {
                $script:PalworldSshHostReadyForManagement = $false
                $script:PalworldSshProjectPrepared = $false
                $script:PalworldSshCommonSettingsReviewed = $false
                Set-PalworldSshWorkDirectoryStatus -State Missing -Path $resolvedProject
                Add-PalworldSshOutput "`r`n[ACTION REQUIRED] Server list is unavailable because the project directory does not exist: $resolvedProject`r`n"
            }
            elseif (-not $projectInitialized) {
                Add-PalworldSshOutput "`r`n[WARN] Server list refreshed: 0 · project directory exists but Setup has not prepared management files: $resolvedProject`r`n"
            }
            else {
                Add-PalworldSshOutput "`r`n[WARN] Server list refreshed: 0 · no config/serverN.env or palworld-serverN container in $resolvedProject`r`n"
            }
            if ($servers.Count -gt 0) {
                & $script:PalworldSshUpdateNetworkNotice
            }
            else {
                $script:PalworldSshLiveStatusLines = if (-not $projectExists) {
                    @("[ACTION REQUIRED] Automated Management is blocked · select Prepare Work Dir first: $resolvedProject")
                }
                elseif (-not $projectInitialized) {
                    @("[INFO] Project directory is ready · run Setup to prepare management files and the first server.")
                }
                else {
                    @("[INFO] No managed server was found in the selected project directory.")
                }
                & $script:PalworldSshRenderStatusNotice
                & $script:PalworldSshSetAvailability
            }
        }
        catch {
            $script:PalworldSshSelectionSyncing = $false
            $script:PalworldSshLastRefreshServer = ""
            $message = [string]$_.Exception.Message
            Add-PalworldSshOutput "`r`n[FAIL] $message`r`n"
            $script:PalworldSshLiveStatusLines = @("[FAIL] Server status refresh: $message")
            & $script:PalworldSshRenderStatusNotice
        }
        finally {
            $script:PalworldSshPreferNewServerAfterRefresh = $false
            $script:PalworldSshServersBeforeOperation = @()
        }
    }
    $refreshButton.Add_Click({
        if ($script:PalworldSshOperationRunning) { return }
        try {
            $connection = Get-SelectedPalworldSshConnection
            if ($null -eq $connection) { return }
            & $script:PalworldSshBeginStatusOperation "Refresh Servers · $([string]$connection.Name)"
            & $script:PalworldSshSetOperationState $true
            $connectedNow = $false
            if (-not $script:PalworldSshClient -or -not $script:PalworldSshClient.IsConnected -or
                -not $script:PalworldSshTerminalClient -or -not $script:PalworldSshTerminalClient.IsConnected) {
                Connect-PalworldSshDualSession -Connection $connection -Owner $script:PalworldSshOwner
                $connectedNow = $true
            }
            if ($connectedNow) {
                $hostCheck = & $script:PalworldSshRunHostCheck $connection
                if (-not $hostCheck -or -not $hostCheck.ReadyForManagement) { return }
            }
            & $script:PalworldSshRefreshServers
        }
        catch { Add-PalworldSshOutput "`r`n[FAIL] Refresh failed: $([string]$_.Exception.Message)`r`n" }
        finally {
            if ($script:PalworldSshClosing) { $script:PalworldSshOperationRunning = $false }
            else { & $script:PalworldSshSetOperationState $false }
            $script:PalworldSshCancelRequested = $false
        }
    })
    $script:PalworldSshUpdateNetworkNotice = {
        if ($script:PalworldSshSelectionSyncing -or -not $script:PalworldSshNetworkNotice) { return }
        $server = if ($script:PalworldSshServerCombo.SelectedIndex -ge 0) {
            [string]$script:PalworldSshServerCombo.SelectedItem
        }
        else { "" }
        if ($server -notmatch '^server[1-9][0-9]*$') {
            $script:PalworldSshLiveStatusLines = @(
                "[INFO] Select one server to inspect its env, container, and port mappings."
            )
            & $script:PalworldSshRenderStatusNotice
            return
        }
        try {
            $connection = Get-SelectedPalworldSshConnection
            if ($null -eq $connection) { return }
            $lines = @(Get-PalworldNetworkNotice `
                -Connection $connection -Owner $script:PalworldSshOwner -Server $server)
            $script:PalworldSshLiveStatusLines = @($lines)
            & $script:PalworldSshRenderStatusNotice
        }
        catch {
            $statusMessage = [string]$_.Exception.Message
            $script:PalworldSshLiveStatusLines = @(
                if ($statusMessage -match 'timed out') {
                    "[WARN] Live server details timed out; the completed action and server inventory remain valid. Use Refresh Servers to retry."
                }
                else {
                    "[WARN] Live server details are unavailable: $statusMessage"
                }
            )
            & $script:PalworldSshRenderStatusNotice
        }
    }
    $script:PalworldSshServerCombo.Add_SelectedIndexChanged({
        if (-not $script:PalworldSshSelectionSyncing -and
            $script:PalworldSshServerCombo.SelectedIndex -ge 0) {
            $selectedServer = [string]$script:PalworldSshServerCombo.SelectedItem
            if ($script:PalworldSshOperationRunning) { return }
            & $script:PalworldSshBeginStatusOperation "Server status · $selectedServer"
            if ($selectedServer -match '^server[1-9][0-9]*$') {
                Set-PalworldSshLastSelectedServer `
                    -Connection (Get-SelectedPalworldSshConnection) `
                    -Server $selectedServer
            }
        }
        & $script:PalworldSshUpdateNetworkNotice
        if ($script:ResourceUsageRefreshContext) { & $script:ResourceUsageRefreshContext }
    })
    $script:PalworldSshUpdateActionTarget = {
        if ($script:PalworldSshActionCombo.SelectedIndex -lt 0 -or $script:PalworldSshVisibleActions.Count -eq 0) {
            $script:PalworldSshServerCombo.Enabled = $false
            $previousSyncState = $script:PalworldSshSelectionSyncing
            $script:PalworldSshSelectionSyncing = $true
            $script:PalworldSshServerCombo.SelectedIndex = -1
            $script:PalworldSshSelectionSyncing = $previousSyncState
            return
        }
        $definition = $script:PalworldSshVisibleActions[$script:PalworldSshActionCombo.SelectedIndex]
        if (-not $definition.Server) {
            [void]$script:PalworldSshServerCombo.Items.Remove("all")
            $previousSyncState = $script:PalworldSshSelectionSyncing
            $script:PalworldSshSelectionSyncing = $true
            $script:PalworldSshServerCombo.SelectedIndex = -1
            $script:PalworldSshSelectionSyncing = $previousSyncState
            $script:PalworldSshServerCombo.Enabled = $false
            return
        }
        $script:PalworldSshServerCombo.Enabled = $true
        if ($definition.Id -eq "Test") {
            if (-not $script:PalworldSshServerCombo.Items.Contains("all")) { [void]$script:PalworldSshServerCombo.Items.Add("all") }
        }
        else {
            [void]$script:PalworldSshServerCombo.Items.Remove("all")
        }
        if ($script:PalworldSshServerCombo.SelectedIndex -lt 0 -and $script:PalworldSshServerCombo.Items.Count -gt 0) {
            $connection = Get-SelectedPalworldSshConnection
            $lastServer = if ($connection) { [string]$connection.LastSelectedServer } else { "" }
            $lastIndex = if ($lastServer) {
                $script:PalworldSshServerCombo.Items.IndexOf($lastServer)
            }
            else { -1 }
            $script:PalworldSshServerCombo.SelectedIndex = if ($lastIndex -ge 0) { $lastIndex } else { 0 }
        }
    }
    $script:PalworldSshRefreshActions = {
        $selectedCategory = [string]$script:PalworldSshCategoryCombo.SelectedItem
        $script:PalworldSshVisibleActions = @(
            $script:PalworldSshActions | Where-Object { $_.Category -eq $selectedCategory }
        )
        $script:PalworldSshActionCombo.Items.Clear()
        foreach ($definition in $script:PalworldSshVisibleActions) {
            [void]$script:PalworldSshActionCombo.Items.Add([string]$definition.Label)
        }
        if ($script:PalworldSshActionCombo.Items.Count -gt 0) {
            $script:PalworldSshActionCombo.SelectedIndex = 0
        }
        & $script:PalworldSshUpdateActionTarget
    }
    $categoryCombo.Add_SelectedIndexChanged({ & $script:PalworldSshRefreshActions })
    $actionCombo.Add_SelectedIndexChanged({
        & $script:PalworldSshUpdateActionTarget
    })
    $runButton.Add_Click({
        $connection = Get-SelectedPalworldSshConnection
        if ($null -eq $connection) { return }
        if ($script:PalworldSshActionCombo.SelectedIndex -lt 0) { return }
        $definition = $script:PalworldSshVisibleActions[$script:PalworldSshActionCombo.SelectedIndex]
        $server = if ($script:PalworldSshServerCombo.SelectedIndex -ge 0) { [string]$script:PalworldSshServerCombo.SelectedItem } else { "" }
        $refreshAfter = Test-PalworldSshActionNeedsRefresh -Action $definition.Id
        $executed = $false
        $postActionStatusLines = @()
        $script:PalworldSshPostActionApiSyncMode = ""
        $script:PalworldSshPostActionApiServer = ""
        $script:PalworldSshPostActionShowToken = $false
        $script:PalworldSshPostActionApiSyncAfterFailure = $false
        $script:PalworldSshPostActionApiRemoveServer = ""
        $script:PalworldSshPostActionWorldOptionPreserved = $false
        $script:PalworldSshLastRefreshServer = ""
        $script:PalworldSshServersBeforeOperation = @(
            $script:PalworldSshServerCombo.Items |
                ForEach-Object { [string]$_ } |
                Where-Object { $_ -match '^server[1-9][0-9]*$' }
        )
        $script:PalworldSshPreferNewServerAfterRefresh = $definition.Id -in @("Setup", "Import")
        & $script:PalworldSshBeginStatusOperation "$($definition.Category) · $($definition.Label)"
        $script:PalworldSshLastOperationFinding = "[INFO] Running: $($definition.Category) · $($definition.Label)"
        $script:PalworldSshLiveStatusLines = @(
            "[INFO] Previous live details were cleared; state-changing operations refresh them after success."
        )
        & $script:PalworldSshRenderStatusNotice
        $script:PalworldSshPinnedConnectionId = [string]$connection.Id
        & $script:PalworldSshSetOperationState $true
        try {
            if ($definition.Server -and -not $server) { throw "Select a target server first." }
            $script:PalworldSshChannelTabs.SelectedIndex = 0
            Add-PalworldSshOutput "`r`n[START] $($definition.Category) · $($definition.Label)`r`n"
            $executed = Invoke-PalworldSshManagementAction `
                -Owner $script:PalworldSshOwner `
                -Connection $connection `
                -Action $definition.Id `
                -Server $server
            if ($executed) {
                $script:PalworldSshLastOperationFinding = "[PASS] $($definition.Category) · $($definition.Label)"
                Add-PalworldSshOutput "`r`n[PASS] $($definition.Category) · $($definition.Label)`r`n"
            }
            else {
                $refreshAfter = $false
                $script:PalworldSshLastOperationFinding = "[INFO] Operation canceled by user."
                Add-PalworldSshOutput "`r`n[INFO] Operation canceled by user.`r`n"
            }
        }
        catch {
            $refreshAfter = $false
            if ($script:PalworldSshClosing) {
                # FormClosing owns shutdown; do not touch disposed UI controls.
            }
            elseif ($script:PalworldSshCancelRequested) {
                $script:PalworldSshLastOperationFinding = "[INFO] Operation canceled by user."
                Add-PalworldSshOutput "`r`n[INFO] Operation canceled by user.`r`n"
            }
            else {
                $message = [string]$_.Exception.Message
                if ($definition.Id -eq "TokenRotate") {
                    $tokenStateMatch = [Regex]::Match(
                        [string]$script:PalworldSshLastRemoteOperationOutput,
                        '(?m)^PALWORLD_TOKEN_STATE=(rolled-back|indeterminate)\r?$'
                    )
                    $tokenState = if ($tokenStateMatch.Success) {
                        [string]$tokenStateMatch.Groups[1].Value
                    }
                    else { "unknown" }
                    if ($tokenState -ne "rolled-back") {
                        $script:PalworldSshPostActionApiSyncAfterFailure = $false
                        $script:PalworldSshPostActionShowToken = $false
                        $script:PalworldSshLiveStatusLines += @(
                            (Get-PalworldLocalizedText `
                                "[FAIL] Token recovery was not confirmed. Automatic Server API synchronization was stopped; repair or verify the server with Setup/Manage before using the saved connection." `
                                "[FAIL] 토큰 복구 완료를 확인하지 못했습니다. Server API 자동 동기화를 중단했습니다. 저장된 연결을 사용하기 전에 Setup/Manage로 서버를 복구하거나 확인하세요.")
                        )
                    }
                }
                $script:PalworldSshLastOperationFinding = "[FAIL] $($definition.Category) · $($definition.Label): $message"
                Add-PalworldSshOutput "`r`n[FAIL] $message`r`n"
            }
        }
        finally {
            try {
                if (-not $script:PalworldSshClosing) {
                    if ($refreshAfter) {
                        & $script:PalworldSshRefreshServers
                    }
                    else {
                        & $script:PalworldSshRenderStatusNotice
                    }
                    if (($executed -or $script:PalworldSshPostActionApiSyncAfterFailure) -and
                        $script:PalworldSshPostActionApiSyncMode) {
                        try {
                            $apiServer = Resolve-PalworldPostActionApiServer `
                                -Configured ([string]$script:PalworldSshPostActionApiServer) `
                                -Refreshed ([string]$script:PalworldSshLastRefreshServer)
                            $apiSettings = Get-PalworldRemoteServerApiSettings `
                                -Connection $connection `
                                -Owner $script:PalworldSshOwner `
                                -Server $apiServer
                            # Setup/Import succeeded and the remote ENV was read.
                            # Show the operator its credentials and ports before
                            # touching the local connection store, so a storage
                            # or mapping failure cannot hide essential results.
                            if ($executed -and $definition.Id -in @("Setup", "Import")) {
                                $setupDetails = @(Get-PalworldSetupConnectionDetailLines `
                                    -Server $apiServer -Settings $apiSettings)
                                $postActionStatusLines += $setupDetails
                                Add-PalworldSshOutput ("`r`n" + ($setupDetails -join "`r`n") + "`r`n")
                            }
                            $apiSync = Set-PalworldManagedApiConnection `
                                -SshConnection $connection `
                                -Server $apiServer `
                                -Settings $apiSettings `
                                -Mode $script:PalworldSshPostActionApiSyncMode
                            $apiConnection = $apiSync.Connection
                            $registrationVerb = if ($apiSync.Created) { "registered" } else { "synchronized" }
                            $syncLevel = if ($executed) { "PASS" } else { "INFO" }
                            $syncSuffix = if ($executed) { "" } else { " after remote failure" }
                            $postActionStatusLines += "[$syncLevel] Server API ${registrationVerb}${syncSuffix}: $([string]$apiConnection.Name) · $apiServer"
                            if (-not $apiSettings.RestApiExposed) {
                                $postActionStatusLines += "[WARN] $apiServer REST_API_EXPOSE=false · the Server API is registered but is not reachable from Windows."
                            }
                            if ($script:PalworldSshPostActionShowToken) {
                                $tokenStatusLevel = if ($executed) { "PASS" } else { "INFO" }
                                $postActionStatusLines += "[$tokenStatusLevel] $apiServer API token: $([string]$apiSettings.AccessToken)"
                            }
                            Add-PalworldSshOutput "`r`n[$syncLevel] Server API ${registrationVerb}${syncSuffix}: $([string]$apiConnection.Name) · $apiServer`r`n"
                        }
                        catch {
                            $syncMessage = [string]$_.Exception.Message
                            $postActionStatusLines += "[WARN] Server API automatic synchronization failed: $syncMessage"
                            Add-PalworldSshOutput "`r`n[WARN] Server API automatic synchronization failed: $syncMessage`r`n"
                        }
                    }
                    if ($executed -and $script:PalworldSshPostActionApiRemoveServer) {
                        try {
                            $removeServer = if ($script:PalworldSshPostActionApiRemoveServer -eq "*") {
                                ""
                            }
                            else { [string]$script:PalworldSshPostActionApiRemoveServer }
                            $removedApiNames = @(
                                Remove-PalworldManagedApiConnections `
                                    -SshConnection $connection `
                                    -Server $removeServer
                            )
                            if ($removedApiNames.Count -gt 0) {
                                $postActionStatusLines += "[PASS] Removed stale Server API mapping(s): $($removedApiNames -join ', ')"
                            }
                        }
                        catch {
                            $removeMessage = [string]$_.Exception.Message
                            $postActionStatusLines += "[WARN] Removed server API mapping cleanup failed: $removeMessage"
                            Add-PalworldSshOutput "`r`n[WARN] Removed server API mapping cleanup failed: $removeMessage`r`n"
                        }
                    }
                    if ($executed -and $script:PalworldSshPostActionWorldOptionPreserved) {
                        $postActionStatusLines += "[INFO] WorldOption.sav was preserved with the imported world."
                    }
                    if ($postActionStatusLines.Count -gt 0) {
                        $script:PalworldSshLiveStatusLines = @($script:PalworldSshLiveStatusLines) + @($postActionStatusLines)
                        & $script:PalworldSshRenderStatusNotice
                    }
                }
            }
            finally {
                $script:PalworldSshPinnedConnectionId = ""
                if ($script:PalworldSshClosing) {
                    $script:PalworldSshOperationRunning = $false
                }
                else {
                    & $script:PalworldSshSetOperationState $false
                }
                if ($script:ResourceUsageRefreshContext) {
                    try { & $script:ResourceUsageRefreshContext } catch { }
                }
                $script:PalworldSshPreferNewServerAfterRefresh = $false
                $script:PalworldSshServersBeforeOperation = @()
                $script:PalworldSshPostActionApiSyncMode = ""
                $script:PalworldSshPostActionApiServer = ""
                $script:PalworldSshPostActionShowToken = $false
                $script:PalworldSshPostActionApiSyncAfterFailure = $false
                $script:PalworldSshPostActionApiRemoveServer = ""
                $script:PalworldSshPostActionWorldOptionPreserved = $false
                $script:PalworldSshNonCancelableTransaction = $false
                $script:PalworldSshLastRemoteOperationOutput = ""
                $script:PalworldSshLastRefreshServer = ""
                $script:PalworldSshCancelRequested = $false
            }
        }
    })
    $cancelOperationButton.Add_Click({
        if (-not $script:PalworldSshOperationRunning -or $script:PalworldSshCancelRequested) { return }
        $script:PalworldSshCancelRequested = $true
        $script:PalworldSshCancelOperationButton.Enabled = $false
        $script:PalworldSshCancelOperationButton.Text = Get-PalworldLocalizedText "Canceling..." "취소 중..."
        Add-PalworldSshOutput "`r`n[SSH] Cancellation requested...`r`n"
    })
    $script:PalworldSshTimer = New-Object System.Windows.Forms.Timer
    $script:PalworldSshTimer.Interval = 100
    $script:PalworldSshTerminalTick = {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Stop"
            if ($script:PalworldSshClosing) { return }
            if ($script:PalworldSshShell -and $script:PalworldSshShell.DataAvailable) {
                $readBatch = Read-PalworldSshAvailableUtf8 `
                    -Shell $script:PalworldSshShell `
                    -TotalByteLimit 65536 `
                    -PerReadByteLimit 16384 `
                    -MaximumReads 4
                if ($readBatch.Text) {
                    Add-PalworldSshTerminalOutput -Text ([string]$readBatch.Text) -TerminalStream
                }
                $promptTail = Get-PalworldSshOutputTail `
                    -Control $script:PalworldSshTerminalOutput `
                    -MaximumLength 500
                $promptSignature = Get-PalworldSshTerminalPasswordPromptSignature -Text $promptTail
                if ($promptSignature -and
                    $promptSignature -ne $script:PalworldSshTerminalHandledPasswordPromptSignature) {
                    Set-PalworldSshTerminalPasswordInputMode `
                        -Enabled $true `
                        -PromptSignature $promptSignature
                    $script:PalworldSshStatus.Text = Get-PalworldLocalizedText "Connected · terminal password input requested" "연결됨 · 터미널 비밀번호 입력 필요"
                    $script:PalworldSshStatus.ForeColor = [System.Drawing.Color]::DarkOrange
                    $script:PalworldSshTerminalInput.Focus()
                }
                elseif (-not $promptSignature) {
                    $script:PalworldSshTerminalHandledPasswordPromptSignature = ""
                    if ($script:PalworldSshTerminalPasswordMode) {
                        Set-PalworldSshTerminalPasswordInputMode -Enabled $false
                        $script:PalworldSshStatus.Text = Get-PalworldLocalizedText "Connected · management + terminal channels" "연결됨 · 관리 + 터미널 채널"
                        $script:PalworldSshStatus.ForeColor = [System.Drawing.Color]::DarkGreen
                    }
                }
            }
        }
        catch {
            Stop-PalworldSshTerminalAfterTransportFailure -Reason ([string]$_.Exception.Message)
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    }
    $script:PalworldSshTimer.Add_Tick({
        try { & $script:PalworldSshTerminalTick }
        catch {
            Stop-PalworldSshTerminalAfterTransportFailure -Reason ([string]$_.Exception.Message)
        }
    })
    $script:PalworldSshTimer.Start()
    $script:PalworldSshSendTerminal = { Send-PalworldSshTerminalInput }
    $sendTerminalButton.Add_Click({ & $script:PalworldSshSendTerminal })
    $terminalInput.Add_Enter({
        if ($script:PalworldSshOwner.AcceptButton -ne $script:PalworldSshTerminalSendButton) {
            $script:PalworldSshPreviousAcceptButton = $script:PalworldSshOwner.AcceptButton
            $script:PalworldSshOwner.AcceptButton = $script:PalworldSshTerminalSendButton
        }
    })
    $terminalInput.Add_Leave({
        if ($script:PalworldSshOwner.AcceptButton -eq $script:PalworldSshTerminalSendButton) {
            $script:PalworldSshOwner.AcceptButton = $script:PalworldSshPreviousAcceptButton
            $script:PalworldSshPreviousAcceptButton = $null
        }
    })
    $terminalInput.Add_KeyDown({
        param($sender, $eventArgs)
        if ($eventArgs.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $eventArgs.Handled = $true
            $eventArgs.SuppressKeyPress = $true
            & $script:PalworldSshSendTerminal
        }
    })
    $terminalInput.Add_KeyPress({
        param($sender, $eventArgs)
        if ([int][char]$eventArgs.KeyChar -eq 13) {
            $eventArgs.Handled = $true
            & $script:PalworldSshSendTerminal
        }
    })
    $clearTerminalButton.Add_Click({
        $script:PalworldSshTerminalOutput.Clear()
        if ($script:PalworldSshTerminalSanitizer) { $script:PalworldSshTerminalSanitizer.Reset() }
        Scroll-PalworldSshOutputToBottom -Control $script:PalworldSshTerminalOutput
    })
    $bottomTerminalButton.Add_Click({
        Scroll-PalworldSshOutputToBottom -Control $script:PalworldSshTerminalOutput
    })
    $terminalTabs.Add_SelectedIndexChanged({
        if ($terminalTabs.SelectedIndex -eq 0) {
            Scroll-PalworldSshOutputToBottom -Control $script:PalworldSshOutput
        }
        else {
            Scroll-PalworldSshOutputToBottom -Control $script:PalworldSshTerminalOutput
        }
    }.GetNewClosure())
    $Owner.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:PalworldSshNonCancelableTransaction -and
            $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            $eventArgs.Cancel = $true
            [void][System.Windows.Forms.MessageBox]::Show(
                $Owner,
                (Get-PalworldLocalizedText `
                    "The token apply/restart and recovery check is still running. Wait for it to finish before closing the program." `
                    "토큰 적용·재시작 및 복구 확인이 진행 중입니다. 완료될 때까지 기다린 후 프로그램을 닫아 주세요."),
                (Get-PalworldLocalizedText "Token operation in progress" "토큰 작업 진행 중"),
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            )
            return
        }
        Stop-PalworldSshUiForExit
    }.GetNewClosure())
    $Owner.Add_FormClosed({ [System.Windows.Forms.Application]::ExitThread() })
    & $script:PalworldSshRefreshConnections $script:AdminSelectedSshId
    if ($script:PalworldSshStatusHistoryLines.Count -eq 0) {
        & $script:PalworldSshBeginStatusOperation (
            Get-PalworldLocalizedText "SSH Management ready" "SSH 관리 준비"
        )
        $script:PalworldSshLiveStatusLines = @(
            (Get-PalworldLocalizedText `
                "[INFO] Select an SSH Connection, then Connect to inspect the host and managed servers." `
                "[INFO] SSH 연결을 선택한 뒤 Connect를 눌러 호스트와 관리 서버를 확인하세요.")
        )
        & $script:PalworldSshRenderStatusNotice
    }
    $categoryCombo.SelectedIndex = 0
    & $script:PalworldSshSetOperationState $false
    return $page
}

function Get-PalworldAdminWindowLayout {
    param([Parameter(Mandatory = $true)][System.Drawing.Rectangle]$WorkingArea)
    return [pscustomobject]@{
        ClientWidth = [Math]::Min(920, [Math]::Max(480, ($WorkingArea.Width - 32)))
        ClientHeight = [Math]::Min(1040, [Math]::Max(480, ($WorkingArea.Height - 40)))
        MinimumWidth = [Math]::Min(760, [Math]::Max(480, ($WorkingArea.Width - 16)))
        MinimumHeight = [Math]::Min(720, [Math]::Max(480, ($WorkingArea.Height - 32)))
    }
}

function Add-PalworldAdminTabs {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Form)
    $existing = @($Form.Controls)
    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Name = "AdminMainTabs"
    $tabs.Dock = "Fill"
    $apiPage = New-Object System.Windows.Forms.TabPage
    $apiPage.Text = "Server API"
    $apiPage.AutoScroll = $true
    $apiPage.AutoScrollMinSize = New-Object System.Drawing.Size(890, 850)
    foreach ($control in $existing) {
        $Form.Controls.Remove($control)
        $apiPage.Controls.Add($control)
    }
    $sshPage = New-PalworldSshManagementPage -Owner $Form
    $licensePage = New-PalworldThirdPartyPage
    [void]$tabs.TabPages.Add($apiPage)
    [void]$tabs.TabPages.Add($sshPage)
    [void]$tabs.TabPages.Add($licensePage)
    $tabs.Add_SelectedIndexChanged({
        try {
            if ($tabs.SelectedIndex -eq 0) {
                Sync-PalworldApiSelectionFromSsh
            }
            elseif ($tabs.SelectedIndex -eq 1) {
                Sync-PalworldSshSelectionFromApi
            }
            try { Save-AdminConnectionStore } catch { }
            if ($script:ResourceUsageRefreshContext) { & $script:ResourceUsageRefreshContext }
        }
        catch {
            if (-not $script:PalworldSshClosing) {
                try {
                    Add-PalworldSshOutput (
                        "`r`n[WARN] Tab selection synchronization was deferred: " +
                        [string]$_.Exception.Message + "`r`n"
                    )
                }
                catch { }
            }
        }
    }.GetNewClosure())
    $Form.Controls.Add($tabs)
    if ($null -eq (Get-SelectedAdminApiConnection)) {
        $initialSsh = Get-SelectedPalworldSshConnection
        if ($initialSsh) {
            $script:PalworldSshApiContextSshId = [string]$initialSsh.Id
        }
    }
    # The resource footer is outside the main tabs. Prefer enough initial
    # vertical room for the full SSH status area, but never force the window
    # below a small monitor/RDP work area. Both pages scroll only when the
    # available desktop is smaller than their design size.
    $workArea = [System.Windows.Forms.Screen]::FromControl($Form).WorkingArea
    $windowLayout = Get-PalworldAdminWindowLayout -WorkingArea $workArea
    # Lower the previous main-form minimum before applying a clamped client
    # size; otherwise WinForms can silently retain the old taller minimum.
    $Form.MinimumSize = New-Object System.Drawing.Size($windowLayout.MinimumWidth, $windowLayout.MinimumHeight)
    $Form.ClientSize = New-Object System.Drawing.Size($windowLayout.ClientWidth, $windowLayout.ClientHeight)
    return [pscustomobject]@{
        Tabs = $tabs
        ApiPage = $apiPage
        SshPage = $sshPage
        LicensePage = $licensePage
    }
}
