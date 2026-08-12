from __future__ import annotations

import hashlib
import json
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SSH_SOURCE = ROOT / "tools" / "windows-ssh-manager" / "palworld-ssh-management.ps1"
CLIENT_SOURCE = ROOT / "tools" / "windows-client" / "palworld-rest-client.ps1"
BUILD_SOURCE = ROOT / "tools" / "windows-client" / "build-exe.ps1"
LOCK_FILE = ROOT / "tools" / "windows-ssh-manager" / "vendor" / "packages.lock.json"
THIRD_PARTY_FILE = ROOT / "tools" / "windows-ssh-manager" / "vendor" / "THIRD_PARTY.txt"
FETCH_SOURCE = ROOT / "tools" / "windows-ssh-manager" / "fetch_sshnet.py"
GENERATED = ROOT / "tools" / "windows-ssh-manager" / "generated"


class WindowsSshManagerTests(unittest.TestCase):
    def test_sources_do_not_assign_to_powershell_automatic_variables(self) -> None:
        assignment = re.compile(
            r"(?im)^\s*\$(?:home|host|pid|pshome|psedition|psversiontable|"
            r"executioncontext|error|psculture|psuiculture|shellid|"
            r"consolefilename|matches|input|args|pwd|profile)\s*="
        )
        for path in (SSH_SOURCE, CLIENT_SOURCE):
            source = path.read_text("utf-8")
            self.assertIsNone(assignment.search(source), path)

    def test_admin_has_separate_api_and_ssh_management_tabs(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn('$apiPage.Text = "Server API"', source)
        self.assertIn('$page.Text = "SSH Management"', source)
        self.assertIn('$page.Text = "Licenses"', source)
        self.assertIn("function Add-PalworldAdminTabs", source)
        self.assertIn("function Sync-PalworldSshSelectionFromApi", source)
        self.assertIn("SshConnectionId", CLIENT_SOURCE.read_text("utf-8"))
        self.assertIn('PALWORLD_CLIENT_TEST_MODE -eq "ssh-add"', CLIENT_SOURCE.read_text("utf-8"))
        self.assertIn('PALWORLD_CLIENT_TEST_MODE -eq "ssh-model"', CLIENT_SOURCE.read_text("utf-8"))
        self.assertIn('PALWORLD_CLIENT_TEST_MODE -eq "ssh-runtime"', CLIENT_SOURCE.read_text("utf-8"))
        self.assertIn("SshConnectionAddButton", source)
        self.assertIn('$terminalTabs.Name = "SshChannelTabs"', source)
        self.assertIn('$managementOutputPage.Text = "SSH Management"', source)
        self.assertIn('$terminalPage.Text = "SSH Terminal"', source)
        self.assertIn("$script:PalworldSshRefreshConnections", source)
        self.assertIn("-Owner $script:PalworldSshOwner", source)
        self.assertIn("function Sync-PalworldApiSelectionFromSsh", source)
        self.assertIn("function Clear-PalworldSshApiSelectionContext", source)
        self.assertIn("$script:PalworldSshPinnedConnectionId", source)
        self.assertIn("$tabs.Add_SelectedIndexChanged", source)
        self.assertIn("[System.Windows.Forms.Screen]::FromControl($Form).WorkingArea", source)
        self.assertIn("function Get-PalworldAdminWindowLayout", source)
        self.assertIn("ClientHeight = [Math]::Min(1040", source)
        self.assertIn("MinimumHeight = [Math]::Min(720", source)
        self.assertIn('"— No SSH Connection selected —"', source)
        self.assertIn("LastUsedApiConnectionId", source)
        self.assertNotIn('"Pair with API"', source)
        self.assertNotIn('"Unpair API"', source)

    def test_management_actions_and_manual_terminal_use_separate_channels(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("function Connect-PalworldSshDualSession", source)
        self.assertIn("$client.KeepAliveInterval = [TimeSpan]::FromSeconds(30)", source)
        self.assertIn("$script:PalworldSshTerminalClient", source)
        self.assertIn("$script:PalworldSshTerminalOutput", source)
        self.assertIn("Add-PalworldSshTerminalOutput", source)
        self.assertIn("function Send-PalworldSshTerminalInput", source)
        self.assertIn("$script:PalworldSshShell.WriteLine($inputText)", source)
        self.assertIn('$script:PalworldSshOutput.WordWrap = $true', source)
        self.assertIn('$script:PalworldSshTerminalOutput.WordWrap = $true', source)
        self.assertIn('$script:PalworldSshOutput.ScrollBars = "ForcedVertical"', source)
        self.assertIn('$script:PalworldSshTerminalOutput.ScrollBars = "ForcedVertical"', source)
        self.assertIn('$bottomTerminalButton.Name = "SshTerminalBottomButton"', source)
        self.assertIn("function Scroll-PalworldSshOutputToBottom", source)
        self.assertIn("function Get-PalworldCompleteStreamPrefixLength", source)
        self.assertIn("class RichTextBoxScrollHelper", source)
        self.assertIn("$terminalTabs.Add_SelectedIndexChanged", source)
        self.assertIn("$eventArgs.Handled = $true", source)
        self.assertIn("$script:PalworldSshOwner.AcceptButton = $script:PalworldSshTerminalSendButton", source)
        self.assertIn("$terminalInput.Add_KeyPress", source)
        self.assertIn("UseSystemPasswordChar = $true", source)
        self.assertIn("TerminalPasswordMode", source)
        self.assertIn("function Stop-PalworldSshTerminalAfterTransportFailure", source)
        self.assertIn("The current SSH Management operation continues on its separate channel.", source)
        self.assertIn("simulated idle terminal transport failure", CLIENT_SOURCE.read_text("utf-8"))

    def test_terminal_preserves_split_lines_and_releases_password_masking(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("private bool pendingCarriageReturn = false;", source)
        self.assertIn('output.Append("\\r\\n");', source)
        self.assertIn("function Set-PalworldSshTerminalPasswordInputMode", source)
        self.assertIn("$script:PalworldSshTerminalInput.PasswordChar = [char]0", source)
        self.assertIn("finally {", source)
        self.assertIn("Set-PalworldSshTerminalPasswordInputMode -Enabled $false", source)
        self.assertIn("[SSH] Password submitted (hidden).", source)
        self.assertIn("[INPUT] $inputText", source)
        self.assertIn("Earlier $Channel output was trimmed", source)
        self.assertIn("$latestSafeCut", source)
        self.assertIn("$readCount -lt $MaximumReads", source)
        self.assertIn("-MaximumReads 4", source)
        self.assertIn("Get-PalworldSshTerminalPasswordPromptSignature", source)
        self.assertIn("function Get-PalworldSshOutputTail", source)
        self.assertIn("$Control.SelectedText = [string]::Empty", source)

    def test_automation_output_and_marker_scans_are_bounded(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        client = CLIENT_SOURCE.read_text("utf-8")
        self.assertIn("function Add-PalworldBoundedSshCommandOutput", source)
        self.assertIn("function Get-PalworldBoundedSshCommandOutput", source)
        self.assertIn("[int]$OutputLimitCharacters = 4194304", source)
        self.assertIn("[int]$MarkerWindowCharacters = 8192", source)
        self.assertIn("$maximumMarkerSegmentLength", source)
        self.assertIn("$markerBufferOffset", source)
        self.assertIn("OutputTruncated = $omittedResultLength -gt 0", source)
        self.assertNotIn("$all = New-Object Text.StringBuilder", source)
        self.assertNotIn("-Text $all.ToString()", source)
        self.assertIn("function Get-PalworldSshVisibleFlushPrefixLength", source)
        self.assertIn("[char]::IsHighSurrogate", source)
        self.assertIn("[int]$VisibleBufferLimitCharacters = 65536", source)
        self.assertIn("[int]$CancelGraceSeconds = 2", source)
        self.assertIn("Reset-PalworldAutomationShellStream", source)
        self.assertIn("Earlier SSH command output was truncated", client)
        self.assertIn("Bounded SSH output flush split a UTF-16 surrogate pair", client)
        self.assertIn("Canceled SSH automation did not reset only its stuck stream", client)

    def test_ssh_automation_is_serialized_and_plain_output_uses_fast_path(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("$script:PalworldSshAutomationCommandRunning = $false", source)
        self.assertIn("Another SSH management command is already running", source)
        self.assertIn("$script:PalworldSshAutomationCommandRunning = $true", source)
        self.assertIn("$script:PalworldSshAddButton.Enabled = $idle", source)
        self.assertGreaterEqual(
            source.count("& $script:PalworldSshSetOperationState $true"), 6
        )
        self.assertIn("if ($script:PalworldSshOperationRunning) { return }", source)
        self.assertIn("$requiresControlProcessing", source)
        self.assertIn("$Control.AppendText($clean)", source)

    def test_management_action_selection_is_hierarchical(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn('$script:PalworldSshCategoryCombo = $categoryCombo', source)
        for category in ("Setup", "Manage", "Test", "Remove"):
            self.assertIn(f'Category = "{category}"', source)
        self.assertIn("$script:PalworldSshVisibleActions", source)
        self.assertIn('Id = "EnvEdit"', source)
        self.assertIn('[only Windows] server.env 편집·적용', source)
        self.assertLess(source.index('Id = "TokenRotate"'), source.index('Id = "EnvEdit"'))

    def test_refresh_reconnect_and_non_blocking_network_status_are_wired(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn('$reconnectButton.Text = "Reconnect"', source)
        self.assertIn('$hostCheckButton.Text = Get-PalworldLocalizedText "Host Check"', source)
        self.assertIn('Get-PalworldLocalizedText "Prepare Work Dir"', source)
        self.assertIn('Get-PalworldLocalizedText "Review Common Settings"', source)
        self.assertIn('$script:PalworldSshWorkDirectoryStatus.Name = "SshWorkDirectoryStatus"', source)
        self.assertIn("function Set-PalworldSshWorkDirectoryStatus", source)
        self.assertIn("[ACTION REQUIRED] Select Prepare Work Dir", source)
        self.assertIn("function Test-PalworldSshHostReadiness", source)
        self.assertIn("function Initialize-PalworldSshWorkDirectory", source)
        self.assertIn("function Show-PalworldCommonSettingsEditor", source)
        self.assertIn("function Get-PalworldSshActionPrerequisites", source)
        self.assertNotIn("-CreateWorkDirectory", source)
        self.assertIn("Connect runs it automatically when preparation is already complete", source)
        self.assertIn("$script:PalworldSshRefreshServers", source)
        self.assertIn("& $script:PalworldSshRefreshServers", source)
        self.assertIn("function Get-PalworldNetworkNotice", source)
        network_notice = re.search(
            r"function Get-PalworldNetworkNotice \{(.*?)\n\}", source, flags=re.DOTALL
        )
        self.assertIsNotNone(network_notice)
        self.assertEqual(network_notice.group(1).count("__PALWORLD_SUDO__"), 1)
        self.assertIn("-TimeoutSeconds 15", network_notice.group(1))
        self.assertIn("Status history · commands, readiness, selected server and network", source)
        self.assertIn("$script:PalworldSshBeginStatusOperation", source)
        self.assertIn("$script:PalworldSshStatusHistoryLines", source)
        self.assertIn('"[{0}] COMMAND · {1}"', source)
        self.assertIn("('─' * 71)", source)
        self.assertIn("ScrollToCaret()", source)
        self.assertIn("[System.Drawing.Color]::DarkOrange", source)
        self.assertIn("[System.Drawing.Color]::DarkRed", source)
        self.assertIn("external path is not automatically verified", source)
        self.assertIn("router/NAT/cloud firewall forwarding", source)
        self.assertIn("[WARN] Live server details timed out", source)
        self.assertNotIn("[FAIL] Server status could not be completed", source)
        self.assertIn("27015/27016 TCP/UDP are advisory only", source)
        self.assertIn("function Get-PalworldSshConfiguredServerNames", source)
        self.assertIn('status = "config only"', source)
        self.assertIn("function Merge-PalworldSshServerInventory", source)

    def test_typed_confirmation_is_click_validated_and_event_safe(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("function Test-PalworldTypedConfirmationText", source)
        self.assertIn("function New-PalworldTypedConfirmationDialog", source)
        self.assertIn("[StringComparison]::Ordinal", source)
        self.assertIn('$ok.Enabled = $true', source)
        self.assertIn("입력 문구가 일치하지 않습니다", source)
        self.assertNotIn('$ok.Enabled = $input.Text -ceq $Expected', source)
        self.assertIn("}.GetNewClosure())", source)
        client = CLIENT_SOURCE.read_text("utf-8")
        self.assertIn('PALWORLD_CLIENT_TEST_MODE -eq "ssh-logic"', client)
        self.assertIn('PALWORLD_CLIENT_TEST_MODE -eq "ssh-dialog-events"', client)

    def test_operation_connection_stays_pinned_through_automatic_refresh(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("$script:PalworldSshOperationRunning", source)
        self.assertIn("$script:PalworldSshSetOperationState", source)
        finally_block = re.search(
            r"(?s)finally \{\s*try \{.*?if \(\$refreshAfter\) \{\s*& \$script:PalworldSshRefreshServers.*?"
            r"\$script:PalworldSshPinnedConnectionId = \"\".*?"
            r"& \$script:PalworldSshSetOperationState \$false",
            source,
        )
        self.assertIsNotNone(finally_block)

    def test_form_close_aborts_ui_work_and_disposes_ssh_in_background(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("class BackgroundDisposer", source)
        self.assertIn("function Stop-PalworldSshUiForExit", source)
        self.assertIn("$script:PalworldSshClosing = $true", source)
        self.assertIn("$script:PalworldSshCancelRequested = $true", source)
        self.assertIn("[Palworld.ServerManager.BackgroundDisposer]::Queue", source)
        self.assertIn("$Owner.Add_FormClosing({", source)
        self.assertIn("$script:PalworldSshNonCancelableTransaction", source)
        self.assertIn("[System.Windows.Forms.CloseReason]::UserClosing", source)
        self.assertIn("Stop-PalworldSshUiForExit", source)
        self.assertIn("[System.Windows.Forms.Application]::ExitThread()", source)
        client = CLIENT_SOURCE.read_text("utf-8")
        self.assertGreaterEqual(
            client.count("$script:PalworldSshNonCancelableTransaction"),
            2,
        )
        self.assertIn("if (-not $eventArgs.Cancel) { Stop-ResourceUsagePolling }", client)
        self.assertIn(
            "Stop-PalworldHttpOperationsForExit\n})",
            client,
        )
        self.assertIn("finally {\n    if ($script:IsAdminEdition) { Stop-PalworldSshUiForExit }", client)
        self.assertIn('PALWORLD_CLIENT_TEST_MODE -eq "ssh-close"', client)
        self.assertIn("Closing the Admin UI did not promptly abort", client)

    def test_command_and_sftp_io_are_async_cancelable_and_hard_bounded(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("function Wait-PalworldSshTask", source)
        self.assertIn("$sshCommand.ExecuteAsync($cancellation.Token)", source)
        self.assertIn("$sshCommand.CancelAsync($true, 100)", source)
        self.assertIn("$Sftp.ExistsAsync($RemotePath, $cancellation.Token)", source)
        self.assertIn("$Sftp.DownloadFileAsync($RemotePath, $Stream, $cancellation.Token)", source)
        self.assertIn("$Sftp.UploadFileAsync($Stream, $RemotePath, $cancellation.Token)", source)
        self.assertIn("class BoundedMemoryStream", source)
        self.assertIn("New-Object Palworld.ServerManager.BoundedMemoryStream(1048576)", source)
        self.assertIn("AsyncTaskCleanup]::ObserveAndDispose", source)
        self.assertNotIn("$sftp.Exists($RemotePath)", source)
        self.assertNotIn("$sftp.DownloadFile($RemotePath, $stream)", source)
        self.assertNotIn("$sftp.UploadFile(", source)

    def test_admin_env_editor_validates_backs_up_and_can_apply(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("function Show-PalworldServerEnvEditor", source)
        self.assertIn("function Test-PalworldServerEnvText", source)
        self.assertIn("function Save-PalworldRemoteServerEnv", source)
        self.assertIn('"SERVER_PORT"', source)
        self.assertIn('"PAL_SETTING_RESTAPIPort"', source)
        self.assertIn("PAL_ENV_BACKUP=", source)
        self.assertIn('$edited.Action -eq "Apply"', source)
        env_apply = source[
            source.index('        "EnvEdit" {') : source.index('        "Test" {')
        ]
        self.assertIn("-Action EnvApply", env_apply)
        self.assertIn("-EnvBackup ([string]$envBackup)", env_apply)
        self.assertIn("-Payload manage", env_apply)
        self.assertIn("New-PalworldManagerCommand", env_apply)
        self.assertNotIn("New-PalworldSetupCommand", env_apply)
        self.assertNotIn("-Mode update", env_apply)

    def test_ssh_connections_store_all_required_encrypted_fields(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn('[string]$SshHost = ""', source)
        self.assertNotIn('[string]$Host = ""', source)
        for field in (
            "Host",
            "Port",
            "Username",
            "AuthMode",
            "Password",
            "PrivateKeyPath",
            "PrivateKeyPassphrase",
            "SudoPassword",
            "WorkDirectory",
            "HostKeyFingerprint",
            "LastSelectedServer",
        ):
            self.assertIn(field, source)
        client = CLIENT_SOURCE.read_text("utf-8")
        self.assertIn("PalworldPortableConnectionCrypto]::Encrypt", client)
        self.assertIn("SshConnections = @($script:AdminSshConnections)", client)

    def test_private_key_file_authentication_is_validated_and_used(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("function Open-PalworldSshPrivateKeyFile", source)
        self.assertIn('[Renci.SshNet.PrivateKeyFile]::new($resolved, $Passphrase)', source)
        self.assertIn('[Renci.SshNet.PrivateKeyFile]::new($resolved)', source)
        self.assertIn('"Private Key File"', source)
        self.assertIn('AuthMode = $authMode', source)
        self.assertIn('if ([string]$Connection.AuthMode -eq "PrivateKey")', source)
        self.assertIn("Renci.SshNet.PrivateKeyAuthenticationMethod", source)
        self.assertIn("IPrivateKeySource", source)
        client = CLIENT_SOURCE.read_text("utf-8")
        self.assertIn('PALWORLD_CLIENT_TEST_MODE -eq "ssh-private-key-dialog"', client)
        self.assertIn("SSH private-key dialog settings were not used by the connection runtime.", client)

    def test_setup_and_token_actions_sync_the_managed_server_api_mapping(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        client = CLIENT_SOURCE.read_text("utf-8")
        self.assertIn("function Get-PalworldRemoteServerApiSettings", source)
        self.assertIn("function Set-PalworldManagedApiConnection", source)
        self.assertIn("function Remove-PalworldManagedApiConnections", source)
        self.assertIn('$apiName = "$([string]$SshConnection.Name) - $Server"', source)
        self.assertIn("PAL_SETTING_AdminPassword", source)
        self.assertIn("API_USERNAME", source)
        self.assertIn("API_ACCESS_TOKEN", source)
        self.assertIn('$script:PalworldSshPostActionApiSyncMode = "Full"', source)
        self.assertIn('$script:PalworldSshPostActionApiSyncMode = "Token"', source)
        self.assertIn('$script:PalworldSshPostActionApiSyncAfterFailure = $true', source)
        self.assertIn('$executed -or $script:PalworldSshPostActionApiSyncAfterFailure', source)
        self.assertIn('-Payload manage -TimeoutSeconds 3600', source)
        self.assertIn("safely restarted and verified", source)
        self.assertIn("Token apply and safe container recreation are in progress", source)
        self.assertIn("$script:PalworldSshCancelOperationButton.Enabled = $false", source)
        self.assertIn("$script:PalworldSshNonCancelableTransaction = $true", source)
        self.assertIn("$script:PalworldServerApiSetSshOperationState $Running", source)
        self.assertIn("current persistent operating policy", source)
        self.assertIn("PALWORLD_TOKEN_STATE=(rolled-back|indeterminate)", source)
        self.assertIn("Automatic Server API synchronization was stopped", source)
        self.assertIn("Token recovery was not confirmed", source)
        token_rotate_start = source.rindex('"TokenRotate" {')
        token_rotate = source[
            token_rotate_start : source.index('"RemoveServer" {', token_rotate_start)
        ]
        self.assertIn("apply any saved server.env changes", token_rotate)
        self.assertIn('$script:PalworldSshPostActionApiSyncMode = "Full"', token_rotate)
        self.assertNotIn('$script:PalworldSshPostActionApiSyncMode = "Token"', token_rotate)
        self.assertLess(
            token_rotate.index('-Expected "ROTATE $Server"'),
            token_rotate.index("$script:PalworldSshCancelOperationButton.Enabled = $false"),
        )
        self.assertIn("API token:", source)
        self.assertIn("PALWORLD_SETUP_SERVER=(server[1-9][0-9]*)", source)
        self.assertIn("$operationServer -match '^server[1-9][0-9]*$'", source)
        self.assertIn("function Get-PalworldSetupConnectionDetailLines", source)
        post_action = source[source.index("if (($executed -or $script:PalworldSshPostActionApiSyncAfterFailure)") :]
        self.assertLess(
            post_action.index("Get-PalworldSetupConnectionDetailLines"),
            post_action.index("$apiSync = Set-PalworldManagedApiConnection"),
        )
        self.assertIn('$executed -and $definition.Id -in @("Setup", "Import")', post_action)
        self.assertIn("ManagedServerName", client)
        self.assertIn("$managedServerText.ReadOnly = $true", client)
        self.assertIn("Setup-style Server API registration", client)
        self.assertIn("API token synchronization did not update only", client)
        self.assertIn("custom TLS Server API endpoint", client)

    def test_remote_failures_include_korean_diagnostics_and_token_close_is_guarded(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("오류:|치명적 경고:", source)
        self.assertIn("실패|충돌|사용 중|찾을 수|잘못", source)
        self.assertIn("$script:PalworldSshLastRemoteOperationOutput", source)
        self.assertIn("[System.Windows.Forms.CloseReason]::UserClosing", source)
        self.assertIn("token apply/restart and recovery check is still running", source)

    def test_host_key_and_work_directory_safety_are_enforced(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("FingerPrintSHA256", source)
        self.assertIn("class SshHostKeyVerifier", source)
        self.assertIn("class SshPasswordPromptResponder", source)
        self.assertIn("class TerminalStreamSanitizer", source)
        self.assertIn("$client.add_HostKeyReceived($hostKeyVerifier.Handler)", source)
        self.assertIn("$keyboardMethod.add_AuthenticationPrompt($promptResponder.Handler)", source)
        self.assertNotIn("$hostKeyBlock = {", source)
        self.assertNotIn("$promptBlock = {", source)
        self.assertIn('"dumb"', source)
        self.assertIn("TerminalModes]::ECHO", source)
        self.assertIn("SSH host key changed. Connection blocked.", source)
        self.assertIn("Verify this fingerprint with the server administrator", source)
        self.assertIn("function Test-PalworldWorkDirectory", source)
        self.assertIn("function ConvertTo-PalworldManagedWorkDirectory", source)
        self.assertIn('"$candidate/palworld-docker"', source)
        self.assertIn("readlink -m", source)
        self.assertIn('"/", "/bin", "/boot", "/dev", "/etc", "/home"', source)

    def test_shell_output_reads_are_byte_bounded_and_statefully_decoded(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        client = CLIENT_SOURCE.read_text("utf-8")
        self.assertIn("class BoundedUtf8ShellReader", source)
        self.assertIn("ConditionalWeakTable<Stream, DecoderState>", source)
        self.assertIn("GetDecoder()", source)
        self.assertIn("function Read-PalworldSshAvailableUtf8", source)
        self.assertIn("-TotalByteLimit 65536", source)
        self.assertIn("-PerReadByteLimit 16384", source)
        self.assertIn("-MaximumMilliseconds 1000", source)
        self.assertNotIn("$shell.Read()", source)
        self.assertNotIn("$script:PalworldSshShell.Read()", source)
        self.assertIn("Bounded SSH reads did not preserve split UTF-8 characters", client)
        self.assertIn("SSH Terminal did not render output through bounded byte reads", client)

    def test_sudo_password_is_sent_only_after_unique_prompt(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("__PALWORLD_SUDO_", source)
        self.assertIn("sudo -S -p", source)
        self.assertIn("function Expand-PalworldSudoPlaceholders", source)
        self.assertIn("function Write-PalworldShellSecretUtf8", source)
        self.assertIn("$encoding.GetBytes($Secret + \"`r\")", source)
        self.assertIn("$Shell.Write($bytes, 0, $bytes.Length)", source)
        self.assertIn("$Shell.Flush()", source)
        self.assertIn("$script:PalworldSshAutomationShell", source)
        self.assertIn("function ConvertTo-PalworldShellExecutionCommand", source)
        self.assertIn("( $expanded ); pal_rc=", source)
        self.assertNotIn("$shell.WriteLine([string]$Connection.SudoPassword)", source)
        wrapped_block = re.search(
            r'\$wrapped = .*?\n\s*\$shell =', source, flags=re.DOTALL
        )
        self.assertIsNotNone(wrapped_block)
        self.assertNotIn("SudoPassword", wrapped_block.group(0))
        self.assertIn('$clean = $clean.Replace($secret, "[hidden]")', source)
        self.assertIn("function Get-PalworldSudoPromptPattern", source)
        self.assertIn("$lastSudoPromptOffsets", source)
        self.assertIn("$sudoPromptsAnswered.ContainsKey($sudoMarker)", source)
        self.assertIn('-Command "__PALWORLD_SUDO__ -k true"', source)
        self.assertIn("sent unchanged as UTF-8 but sudo rejected it", source)

    def test_multiline_ssh_commands_are_normalized_to_unix_line_endings(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        normalization = re.search(
            r"function ConvertTo-PalworldUnixShellText \{(.*?)\n\}",
            source,
            flags=re.DOTALL,
        )
        conversion = re.search(
            r"function ConvertTo-PalworldShellExecutionCommand \{(.*?)\n\}",
            source,
            flags=re.DOTALL,
        )
        simple_command = re.search(
            r"function Invoke-PalworldSshSimpleCommand \{(.*?)\n\}",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(normalization)
        self.assertIsNotNone(conversion)
        self.assertIsNotNone(simple_command)
        self.assertIn(
            '$Command.Replace("`r`n", "`n").Replace("`r", "`n")',
            normalization.group(1),
        )
        self.assertIn(
            "ConvertTo-PalworldUnixShellText -Command $Command",
            conversion.group(1),
        )
        self.assertIn(
            "$encoding.GetBytes($normalizedCommand)",
            conversion.group(1),
        )
        self.assertNotIn("$encoding.GetBytes($Command)", conversion.group(1))
        self.assertIn(
            "ConvertTo-PalworldUnixShellText -Command $Command",
            simple_command.group(1),
        )
        self.assertIn(
            "$script:PalworldSshClient.CreateCommand($normalizedCommand)",
            simple_command.group(1),
        )
        self.assertNotIn(
            "$script:PalworldSshClient.CreateCommand($Command)",
            simple_command.group(1),
        )

    def test_host_check_directory_creation_and_setup_prerequisites_are_separated(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        host_check = re.search(
            r"function Test-PalworldSshHostReadiness \{(.*?)\n\}", source, flags=re.DOTALL
        )
        create_directory = re.search(
            r"function Initialize-PalworldSshWorkDirectory \{(.*?)\n\}",
            source,
            flags=re.DOTALL,
        )
        prerequisites = re.search(
            r"function Get-PalworldSshActionPrerequisites \{(.*?)\n\}",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(host_check)
        self.assertIsNotNone(create_directory)
        self.assertIsNotNone(prerequisites)
        self.assertNotIn("docker info", host_check.group(1))
        self.assertNotIn("docker compose version", host_check.group(1))
        self.assertIn("WorkDirectoryExists", host_check.group(1))
        self.assertIn("install -d -m 0755", create_directory.group(1))
        self.assertNotIn("chown", create_directory.group(1))
        self.assertIn("prepare-scaffold", create_directory.group(1))
        self.assertIn("Existing project directory ownership was preserved", create_directory.group(1))
        self.assertIn("docker compose version", prerequisites.group(1))
        self.assertIn("docker info", prerequisites.group(1))
        self.assertIn("PAL_SCAFFOLD", prerequisites.group(1))
        self.assertIn("$script:PalworldSshHostReadyForManagement", source)
        self.assertIn("Host preparation is incomplete", source)
        self.assertIn(
            "$script:PalworldSshHostReadyForManagement = [bool]$hostReadiness.ReadyForManagement",
            source,
        )
        self.assertRegex(
            source,
            r"elseif \(-not \$projectExists\) \{\s*\$script:PalworldSshHostReadyForManagement = \$false",
        )

        refresh_handler = re.search(
            r"\$refreshButton\.Add_Click\(\{(.*?)\n\s*\}\)", source, flags=re.DOTALL
        )
        self.assertIsNotNone(refresh_handler)
        self.assertNotIn("Initialize-PalworldSshWorkDirectory", refresh_handler.group(1))
        self.assertNotIn("Get-PalworldSshActionPrerequisites", refresh_handler.group(1))

        self.assertIn("function Test-PalworldSshActionNeedsRefresh", source)
        self.assertRegex(
            source,
            r"catch \{\s*\$refreshAfter = \$false\s*if \(\$script:PalworldSshClosing\)",
        )

    def test_connect_refreshes_and_ssh_remembers_last_server(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertGreaterEqual(source.count("& $script:PalworldSshRefreshServers"), 5)
        self.assertIn("Set-PalworldSshLastSelectedServer", source)
        self.assertIn("$connection.LastSelectedServer", source)
        client = CLIENT_SOURCE.read_text("utf-8")
        self.assertIn("LastSelectedServer = $lastSelectedServer", client)
        self.assertIn("The resource footer did not follow the SSH Connection's last selected server.", client)
        self.assertIn("The resource footer did not resolve the exact SSH/server API mapping.", client)
        self.assertIn("Changing the resource footer server did not synchronize", client)
        self.assertIn("$script:ResourceUsageRefreshContext", source)
        self.assertIn('PALWORLD_ENV_LANGUAGE=__ENV_LANGUAGE__', source)
        self.assertIn('Server connection details', source)
        self.assertIn('Game server port (UDP)', source)
        self.assertIn('External port forwarding was not automatically verified.', source)
        self.assertIn('REST_API_EXPOSE=true: also check REST API TCP', source)

    def test_existing_server_import_is_reviewed_and_atomic(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn('Id = "Import"', source)
        self.assertIn("function Show-PalworldImportSourceDialog", source)
        self.assertIn("[AllowEmptyCollection()][object[]]$Worlds", source)
        self.assertIn("Ports and management options are reviewed on the next screen.", source)
        self.assertIn("function Show-PalworldImportReviewDialog", source)
        self.assertIn("Items are ordered FAILED → BLOCKED → UNMAPPED → REVIEW → AUTO.", source)
        self.assertIn('Get-PalworldLocalizedText "Sync Value to ENV"', source)
        self.assertIn("ConvertTo-PalworldImportEnvValue", source)
        self.assertNotRegex(source, r"\breturn\s+if\s*\(")
        self.assertIn("Select-PalworldImportEditorKey", source)
        self.assertIn('"validate-ports"', source)
        self.assertIn("function Get-PalworldRemoteOperationFailureDetail", source)
        self.assertIn("PALWORLD_SERVER_TEMPLATE_SOURCE", source)
        self.assertIn('config/__TEMPLATE_LANGUAGE__/server.template.env', source)
        self.assertIn('$templateLanguage = if ($envLanguage -eq "ko") { "kr" }', source)
        self.assertIn("The source server's current listener is allowed.", source)
        self.assertRegex(
            source,
            r"(?s)function Set-PalworldEnvTextValue \{.*?\[AllowEmptyString\(\)\]\[string\]\$Value",
        )
        self.assertIn("function Invoke-PalworldExistingServerImport", source)
        self.assertIn("Copying and SHA-256 verifying the full Pal/Saved directory", source)
        self.assertIn("WorldOption.sav was preserved with the imported world", source)
        self.assertIn('"Setup", "Import"', source)
        setup_source = (ROOT / "install/setup.sh").read_text("utf-8")
        self.assertIn("게임 파일이 아직 없는 볼륨입니다", setup_source)
        self.assertIn("SteamCMD가 팰월드 서버 파일 전체를 설치", setup_source)
        self.assertIn("Docker 게임 파일 저장공간", setup_source)

    def test_server_selection_survives_refresh_and_setup_selects_new_server(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("function Get-PalworldPreferredServerName", source)
        self.assertIn("-Current $currentServer", source)
        self.assertIn("-PreferNew:$script:PalworldSshPreferNewServerAfterRefresh", source)
        self.assertRegex(
            source,
            r"(?s)if \(-not \$definition\.Server\) \{.*?SelectedIndex = -1",
        )
        self.assertIn("[string]$connection.LastSelectedServer", source)
        self.assertIn("function Resolve-PalworldPostActionApiServer", source)
        self.assertIn("$script:PalworldSshLastRefreshServer", source)
        self.assertIn("-Refreshed ([string]$script:PalworldSshLastRefreshServer)", source)
        client = CLIENT_SOURCE.read_text("utf-8")
        self.assertIn('-Current "server2" -Available @("server1", "server2")', client)
        self.assertIn('-Previous @("server1")', client)

    def test_operation_payloads_are_verified_and_always_cleaned(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        self.assertIn("sha256sum -c -", source)
        self.assertIn(".palworld-ssh-session", source)
        self.assertIn(
            "^/tmp/palworld-ssh-manager-[a-f0-9]{32}-(?:setup|test|manage)$",
            source,
        )
        self.assertIn("finally {", source)
        self.assertIn("Remove-PalworldSshTemporaryDirectory", source)
        self.assertNotIn("function New-PalworldRemoteArtifactCleanupCommand", source)
        self.assertIn("prepare-scaffold --scaffold", source)
        self.assertIn('$Mode -eq "update"', source)
        self.assertIn('" --refresh-server-template"', source)
        self.assertIn('Replace("__TEMPLATE_REFRESH__", $templateRefreshArgument)', source)
        self.assertIn("acquire_palworld_project_operation_lock", (ROOT / "install/lib.sh").read_text("utf-8"))
        self.assertIn("-mmin +60", source)
        self.assertIn("[a-f0-9]{32}-(setup|test|manage)", source)

    def test_all_requested_ssh_operations_are_wired(self) -> None:
        source = SSH_SOURCE.read_text("utf-8")
        for action in (
            "Setup",
            "Update",
            "EnvEdit",
            "Test",
            "Reset",
            "Restore",
            "TokenShow",
            "TokenRotate",
            "RemoveServer",
            "RemoveAll",
            "RemoveProject",
        ):
            self.assertIn(f'"{action}"', source)
        self.assertIn("--manual-start __MANUAL_START__", source)
        self.assertIn("YesNoCancel", source)
        self.assertIn('$manualStart = "yes"', source)
        self.assertIn('if ($Server -eq "all")', source)
        test_action = re.search(
            r'(?s)"Test" \{(.*?)\n\s*\}\n\s*"Reset" \{', source
        )
        self.assertIsNotNone(test_action)
        self.assertIn('if ($Server -eq "all")', test_action.group(1))
        self.assertIn("Temporary test start", test_action.group(1))
        self.assertIn('-Expected "RESTORE $Server"', source)
        self.assertNotIn('-Expected "RESTORE $Server $backup"', source)
        self.assertIn("function Assert-PalworldSshManagementActionTarget", source)
        self.assertIn("function New-PalworldManagerActionArguments", source)
        for cli_action in (
            "reset --server",
            "restore --server",
            "token --server",
            "remove --servers",
            "remove --all",
            "remove --project",
        ):
            self.assertIn(cli_action, source)

    def test_official_sshnet_runtime_is_pinned_and_hash_verified(self) -> None:
        lock = json.loads(LOCK_FILE.read_text("utf-8"))
        third_party = THIRD_PARTY_FILE.read_text("utf-8")
        self.assertEqual(lock["target"], "net462")
        root_package = lock["packages"][0]
        self.assertEqual((root_package["id"], root_package["version"]), ("SSH.NET", "2025.1.0"))
        self.assertTrue(root_package["source"].startswith("https://api.nuget.org/"))
        locked_assemblies: set[str] = set()
        for package in lock["packages"]:
            self.assertRegex(package["package_sha256"], r"^[a-f0-9]{64}$")
            self.assertTrue(package["authors"].strip())
            self.assertTrue(package["copyright"].strip())
            self.assertIn(package["copyright"], third_party)
            self.assertTrue(package["legal_documents"])
            for document in package["legal_documents"]:
                self.assertRegex(document["sha256"], r"^[a-f0-9]{64}$")
                self.assertIn(document["sha256"], third_party)
            for assembly in package["assemblies"]:
                locked_assemblies.add(assembly["file"])
                path = LOCK_FILE.parent / assembly["file"]
                self.assertTrue(path.is_file())
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), assembly["sha256"])
        self.assertEqual(
            locked_assemblies,
            {path.name for path in LOCK_FILE.parent.glob("*.dll")},
        )
        fetch_source = FETCH_SOURCE.read_text("utf-8")
        self.assertIn("PACKAGE_SHA256_PINS", fetch_source)
        for package in lock["packages"]:
            self.assertIn(package["package_sha256"], fetch_source)

        manifest = json.loads((GENERATED / "manifest.json").read_text("utf-8"))
        self.assertEqual(manifest["version"], 2)
        for payload_name, record in manifest["payloads"].items():
            self.assertEqual(len(record["entries"]), len(record["sources"]))
            payload = GENERATED / record["file"]
            self.assertEqual(hashlib.sha256(payload.read_bytes()).hexdigest(), record["sha256"])
            for source in record["sources"]:
                path = ROOT / source["path"]
                self.assertEqual(
                    hashlib.sha256(path.read_bytes()).hexdigest(), source["sha256"],
                    f"stale {payload_name} source: {source['path']}",
                )

    def test_admin_build_embeds_runtime_and_three_payloads(self) -> None:
        build = BUILD_SOURCE.read_text("utf-8")
        self.assertIn("Get-ChildItem -LiteralPath $sshVendor -Filter *.dll", build)
        self.assertIn("PalworldServerOperations.ThirdParty.txt", build)
        self.assertIn("function Assert-PalworldAdminBundleInputs", build)
        self.assertIn("Unpinned SSH runtime DLL is present", build)
        self.assertIn("SSH payload source", build)
        self.assertIn("function Copy-Utf8BomPowerShellResource", build)
        self.assertIn("New-Object Text.UTF8Encoding($true)", build)
        self.assertIn("New-PalworldThirdPartyPage", SSH_SOURCE.read_text("utf-8"))
        for operation in ("setup", "test", "manage"):
            self.assertTrue((GENERATED / f"{operation}.tar.gz").is_file())
            self.assertIn(f'@("setup", "test", "manage")', build)


if __name__ == "__main__":
    unittest.main()
