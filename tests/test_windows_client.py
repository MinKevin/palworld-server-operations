from __future__ import annotations

import struct
import subprocess
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
CLIENT_SOURCE = ROOT / "tools" / "windows-client" / "palworld-rest-client.ps1"
BUILD_SOURCE = ROOT / "tools" / "windows-client" / "build-exe.ps1"
BUILD_MANIFEST_SOURCE = (
    ROOT / "tools" / "windows-client" / "build-input-manifest.ps1"
)
BUILD_VERIFY_SOURCE = (
    ROOT / "tools" / "windows-client" / "verify-exe-build-inputs.ps1"
)
SSH_SOURCE = ROOT / "tools" / "windows-ssh-manager" / "palworld-ssh-management.ps1"
LAUNCHER_SOURCE = (
    ROOT / "tools" / "windows-client" / "source" / "PalworldServerOperationsLauncher.cs"
)
ICON_SOURCE = ROOT / "tools" / "windows-client" / "assets" / "palworld-server-operations.png"
ICON_FILE = ROOT / "tools" / "windows-client" / "assets" / "palworld-server-operations.ico"


class WindowsRestClientTests(unittest.TestCase):
    def test_main_windows_use_a_verified_fixed_layout(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn('$form.FormBorderStyle = "FixedSingle"', content)
        self.assertIn('$form.MaximizeBox = $false', content)
        self.assertIn("Get-PalworldAdminWindowLayout", SSH_SOURCE.read_text(encoding="utf-8"))

    def test_supported_official_rest_endpoints_are_available(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        for endpoint in (
            "info",
            "players",
            "settings",
            "metrics",
            "announce",
            "save",
            "kick",
            "ban",
            "unban",
            "shutdown",
            "stop",
        ):
            self.assertIn(f'Endpoint = "{endpoint}"', content)
        self.assertIn("(POST /v1/api/shutdown)", content)
        self.assertIn("(POST /v1/api/stop)", content)

    def test_optional_fields_and_direct_connection_are_present(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn("$playerIdText.Enabled = $definition.UserId", content)
        self.assertIn("$waitInput.Enabled = $definition.WaitTime", content)
        self.assertIn("$messageText.Enabled = $definition.Message", content)
        self.assertIn("$handler.UseProxy = $false", content)
        self.assertIn('$username = "admin"', content)
        self.assertIn("$port = 8212", content)
        self.assertIn("$dialogUsernameText.Text = $script:ConnectionSettings.Username", content)
        self.assertIn("$dialogPortText.Text = [string]$script:ConnectionSettings.Port", content)
        self.assertIn("$dialogPortText = New-Object System.Windows.Forms.TextBox", content)
        self.assertNotIn("$dialogPortText = New-Object System.Windows.Forms.NumericUpDown", content)
        self.assertIn('(GET /v1/api/info)', content)
        self.assertIn('(POST /v1/manager/start)', content)
        self.assertIn('(POST /v1/manager/restart)', content)
        self.assertIn('(POST /v1/manager/shutdown)', content)
        self.assertNotIn('(POST /v1/manager/stop)', content)
        self.assertIn('$apiRoot = if ($isManagerAction) { "/v1/manager" } else { "/v1/api" }', content)
        self.assertIn("-ServerAddress $serverHost", content)
        self.assertIn("-Port $apiPort", content)
        self.assertIn("-PathAndQuery $apiRoot", content)
        self.assertNotIn("ManagerPort", content)
        self.assertNotIn("Wait-WithUiEvents", content)
        self.assertIn("function Get-PalworldInnermostException", content)
        self.assertIn("function Get-PalworldHttpFailureDetail", content)
        self.assertIn("[System.Threading.Tasks.TaskCanceledException]", content)
        self.assertNotIn("[TaskCanceledException]", content)
        self.assertIn("Could not connect to the Server API", content)
        self.assertIn("Get-PalworldHttpFailureDetail -Exception $_.Exception", content)

    def test_command_labels_are_bilingual_text_followed_by_api_path(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn(
            'ServerInfo = Get-PalworldLocalizedText "Server information" "서버 정보 조회"',
            content,
        )
        self.assertIn('Display = "$($script:Text.ServerInfo) (GET /v1/api/info)"', content)
        expected = (
            'DirectShutdown = Get-PalworldLocalizedText "Shutdown - direct call (not recommended)" "Shutdown - 직접 호출 (권장하지 않음)"',
            'DirectStop = Get-PalworldLocalizedText "Stop - direct call (not recommended)" "Stop - 직접 호출 (권장하지 않음)"',
            'AdvancedStart = Get-PalworldLocalizedText "Advanced Start - start now and restore policy" "Advanced Start - 즉시 시작 및 운영 정책 복구"',
            'AdvancedRestart = Get-PalworldLocalizedText "Advanced Restart - safe restart and restore policy" "Advanced Restart - 안전 재시작 및 운영 정책 복구"',
            'AdvancedShutdown = Get-PalworldLocalizedText "Advanced Shutdown - stop until the next operating window" "Advanced Shutdown - 다음 운영 시작까지 안전 정지"',
        )
        for label_definition in expected:
            self.assertIn(label_definition, content)
        self.assertNotIn("ConvertFrom-Base64Text", content)
        self.assertNotIn("$categoryCombo", content)
        self.assertIn('$commandCombo.DrawMode = "OwnerDrawFixed"', content)
        self.assertIn("[System.Drawing.Color]::RoyalBlue", content)
        self.assertIn("[System.Drawing.Color]::Firebrick", content)
        self.assertIn("function Get-CommandDisplay", content)
        self.assertIn("if (-not $script:IsAdminEdition)", content)
        self.assertIn("(?:GET|POST) /v1/(?:api|manager)/", content)
        self.assertIn("(Get-CommandDisplay $definition)", content)

    def test_user_edition_keeps_private_single_connection_ui(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn('$script:ApplicationTitle = if ($script:IsAdminEdition)', content)
        self.assertIn('$form.Text = $script:ApplicationTitle', content)
        self.assertIn('$connectionButton.Text = "Connection Settings"', content)
        self.assertIn('function Show-ConnectionSettingsDialog', content)
        self.assertIn('[Environment]::GetFolderPath("ApplicationData")', content)
        self.assertIn("function ConvertTo-ProtectedText", content)
        self.assertIn("EncryptedServerHost = ConvertTo-ProtectedText $ServerHost", content)
        self.assertIn("EncryptedUsername = ConvertTo-ProtectedText $Username", content)
        self.assertIn("EncryptedPassword = ConvertTo-ProtectedText $Password", content)
        self.assertIn("EncryptedAccessToken = ConvertTo-ProtectedText $AccessToken", content)
        self.assertIn('$verifyConnectionButton.Text = "Verify Server"', content)
        self.assertIn("function Test-ManagedServerConnection", content)
        self.assertIn("/v1/manager/verify?challenge=", content)
        self.assertIn("palworld-docker-manager:1:$Challenge", content)
        self.assertIn("$commandGroup.Enabled = $Verified", content)
        self.assertIn("[hidden-url]", content)
        self.assertIn("[hidden-ip]", content)
        self.assertIn("[hidden-host]", content)
        self.assertIn("The request could not be completed. Check Connection Settings", content)
        self.assertIn('if (-not $Text -or $script:IsAdminEdition) { return $Text }', content)
        self.assertIn('if ($null -ne $worldRestoreButton) { throw "User edition must not expose World Restore" }', content)

    def test_admin_edition_has_portable_encrypted_multiple_connections(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn('"Palworld Server Operations - Admin.connections"', content)
        self.assertNotIn('"PalworldServerAdmin.connections"', content)
        self.assertNotIn("$script:LegacyAdminConnectionsFile", content)
        self.assertIn("public static class PalworldPortableConnectionCrypto", content)
        self.assertIn("private const int Iterations = 250000", content)
        self.assertIn("Rfc2898DeriveBytes", content)
        self.assertIn("Aes.Create()", content)
        self.assertIn("HMACSHA256", content)
        self.assertIn('Move-Item -LiteralPath $temporary -Destination $script:AdminConnectionsFile -Force', content)
        self.assertIn('$adminConnectionGroup.Text = "Connections - encrypted portable store"', content)
        self.assertIn('$connectionAddButton.Text = "Add"', content)
        self.assertIn('$connectionUpdateButton.Text = "Update"', content)
        self.assertIn('$connectionDeleteButton.Text = "Delete"', content)
        self.assertIn("function Show-AdminConnectionDialog", content)
        self.assertIn("$connectionHostText", content)
        self.assertIn("$passwordText", content)
        self.assertIn("$tokenText", content)
        self.assertIn("$connectionNameText.ReadOnly = $true", content)
        self.assertIn("$connectionHostText.ReadOnly = $true", content)
        self.assertIn("$connectionPortText.ReadOnly = $true", content)
        self.assertIn("No saved Connections. Select Add to create one.", content)
        self.assertIn('$script:AdminConnections = @()', content)
        self.assertNotIn("At least one Connection must remain", content)
        self.assertIn("leave blank only for ordinary Palworld REST servers", content)
        self.assertIn('$env:PALWORLD_CLIENT_TEST_MODE -eq "crypto"', content)
        self.assertIn("Portable connection encryption round-trip failed", content)
        self.assertIn("Version = 4", content)
        self.assertIn("SelectedSshId = $script:AdminSelectedSshId", content)
        self.assertIn("SshConnections = @($script:AdminSshConnections)", content)
        self.assertIn('SshConnectionId = if ($storeVersion -ge 2)', content)
        self.assertIn('LastUsedApiConnectionId = if ($storeVersion -ge 3)', content)
        self.assertIn("ManagedServerName", content)
        self.assertIn("function Get-AdminConnectionStorePayloadHash", content)
        self.assertIn('$script:AdminLastSavedStoreHash -eq $payloadHash', content)
        self.assertIn("An unchanged admin connection store performed encryption", content)
        self.assertIn('$script:AdminNoApiSelectionText = Get-PalworldLocalizedText', content)
        self.assertIn('"— No Server API selected —"', content)
        self.assertIn('$sshConnectionCombo.Items.Add(', content)
        self.assertIn('"— Not linked —"', content)
        self.assertIn('.v1.backup', content)

    def test_all_run_gateway_requests_carry_the_access_token_header(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn(
            '$request.Headers.TryAddWithoutValidation("X-Palworld-Manager-Token", $AccessToken)',
            content,
        )
        self.assertGreaterEqual(content.count("-AccessToken"), 9)

    def test_api_address_builder_supports_tls_without_disabling_validation(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("function Test-PalworldApiServerAddress", content)
        self.assertIn("function Get-PalworldApiUri", content)
        self.assertIn('PALWORLD_CLIENT_TEST_MODE -eq "api-uri"', content)
        self.assertIn('ServerAddress "https://gateway.example"', content)
        self.assertIn("A TLS Server API endpoint was not constructed correctly.", content)
        self.assertIn(
            "Full SSH synchronization overwrote a custom TLS Server API endpoint",
            content,
        )
        self.assertIn('"settings", "api-uri"', workflow)
        self.assertNotIn("ServerCertificateCustomValidationCallback", content)
        self.assertNotIn("DangerousAcceptAnyServerCertificateValidator", content)

    def test_http_task_failures_are_unwrapped_in_every_api_view(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn("function Get-PalworldHttpFailureDetail", content)
        self.assertGreaterEqual(
            content.count("Get-PalworldHttpFailureDetail -Exception $_.Exception"),
            6,
        )

    def test_admin_restore_and_runtime_log_tools_are_present(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn("function Show-WorldRestoreDialog", content)
        self.assertIn("function Add-PalworldBoundedRichTextLog", content)
        self.assertIn("-Control $restoreLog -Text", content)
        self.assertNotIn("$restoreLog.AppendText", content)
        self.assertIn("function Invoke-RestoreStream", content)
        self.assertIn('$worldRestoreButton.Text = "World Restore"', content)
        self.assertIn('/v1/manager/backups', content)
        self.assertIn('/v1/manager/restore', content)
        self.assertIn("HttpCompletionOption]::ResponseHeadersRead", content)
        self.assertIn("$reader.ReadLineAsync()", content)
        self.assertIn("$backupList.SelectedItems[0].Tag", content)
        self.assertIn("function Show-RuntimeLogDialog", content)
        self.assertIn('/v1/manager/logs?lines=', content)
        self.assertIn('source=', content)
        self.assertIn('$runtimeLogButton.Text = "Runtime Logs"', content)
        self.assertIn('$adminToolsGroup.Text = "Server Tools - selected Connection"', content)
        self.assertIn("$adminToolsGroup.Controls.Add($worldRestoreButton)", content)
        self.assertIn("$adminToolsGroup.Controls.Add($runtimeLogButton)", content)
        self.assertIn('if ($script:IsAdminEdition) {', content)
        self.assertIn("function Stop-PalworldHttpOperationsForExit", content)
        self.assertIn("function Wait-PalworldHttpTask", content)
        self.assertIn("-Operation $refreshOperation", content)
        self.assertIn("Stop-PalworldHttpOperation -Operation $restoreState.RefreshOperation", content)
        self.assertIn('foreach ($phase in @("Send", "Read", "Refresh"))', content)

    def test_simplified_result_and_message_behavior(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn('$statusLabel.Text = if ($result.Success) {', content)
        self.assertIn('Get-PalworldLocalizedText "Success" "성공"', content)
        self.assertIn('Get-PalworldLocalizedText "Fail" "실패"', content)
        self.assertIn('if ($result.Success) { $messageText.Clear() }', content)
        self.assertNotIn("Connection settings are auto-saved in AppData", content)

    def test_low_overhead_resource_footer_and_history_are_wired(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        self.assertIn('$panel.Name = "ResourceUsageFooter"', content)
        self.assertIn('/v1/manager/resources/current', content)
        self.assertIn('/v1/manager/resources/history?seconds=', content)
        self.assertIn('$script:ResourceUsageNextRequestUtc = [DateTime]::UtcNow.AddSeconds(1)', content)
        self.assertIn('$script:ResourceUsageTimer.Interval = 250', content)
        self.assertIn('$script:ResourceUsageTimerTick', content)
        self.assertIn('simulated resource timer failure', content)
        self.assertIn(
            'Get-PalworldLocalizedText "Temporary resource display error" "사용량 표시 일시 오류"',
            content,
        )
        self.assertIn('$script:ResourceUsagePending', content)
        self.assertIn('Show-ResourceUsageHistoryDialog -Owner $Owner -Scope Host', content)
        self.assertIn('Show-ResourceUsageHistoryDialog -Owner $Owner -Scope Container', content)
        self.assertIn('$script:ResourceUsageServerCombo', content)
        self.assertIn('Set-PalworldSshLastSelectedServer -Connection $ssh -Server $serverName', content)
        self.assertIn('$dialog.ClientSize.Height - 48', content)
        self.assertIn('$hostMetrics = $Payload.host', content)
        self.assertNotIn('$host = $Payload.host', content)
        self.assertIn('Set-ResourceUsagePayload -Payload $testCurrentPayload', content)
        self.assertIn('function Set-ResourceUsagePollingResult', content)
        self.assertIn('Set-ResourceUsagePollingResult -Kind Authentication', content)
        self.assertIn('$script:ResourceUsageNextRequestUtc = [DateTime]::MaxValue', content)
        self.assertIn("Monitoring paused during SSH management", content)
        self.assertIn("$sshOperationPaused", content)
        self.assertIn("$context.Ready) { 250 } else { 1000 }", content)
        self.assertIn("{ '준비 상태' } else { 'Preparation' }", content)
        self.assertIn("PalworldSshActionCombo.Items.Count -ne 2", content)
        self.assertIn('function ConvertTo-ResourceUsageSafeDiagnostic', content)
        self.assertIn('A pinned SSH operation redirected the Server API tab', content)
        self.assertIn('An ambiguous SSH/server resource mapping used an arbitrary API fallback', content)
        self.assertIn('Connect SSH to start monitoring', content)
        self.assertIn('$script:PalworldSshClient.IsConnected', content)
        self.assertIn('$sshSessionReady -and', content)
        self.assertNotIn('Docker socket', content)
        self.assertIn("$historyState.Operation = $operation", content)
        self.assertIn("$logState.Operation = $operation", content)
        self.assertIn(
            "Stop-PalworldHttpOperation -Operation $historyState.Operation", content
        )
        self.assertIn(
            "Stop-PalworldHttpOperation -Operation $logState.Operation", content
        )

    def test_icon_assets_and_window_icon_wiring_are_present(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        build = BUILD_SOURCE.read_text(encoding="utf-8")
        launcher = LAUNCHER_SOURCE.read_text(encoding="utf-8")
        self.assertTrue(ICON_SOURCE.is_file())
        self.assertTrue(ICON_FILE.is_file())
        data = ICON_FILE.read_bytes()
        reserved, icon_type, count = struct.unpack_from("<HHH", data, 0)
        self.assertEqual((reserved, icon_type), (0, 1))
        sizes = []
        for index in range(count):
            width, height = struct.unpack_from("BB", data, 6 + index * 16)
            sizes.append((256 if width == 0 else width, 256 if height == 0 else height))
        for size in (16, 32, 48, 128, 256):
            self.assertIn((size, size), sizes)
        self.assertIn('"/win32icon:$iconPath"', build)
        self.assertIn(
            '"/resource:$iconPath,PalworldServerOperations.Icon.ico"', build
        )
        self.assertIn('IconResourceName = "PalworldServerOperations.Icon.ico"', launcher)
        self.assertIn('"PALWORLD_CLIENT_ICON_PATH"', launcher)
        self.assertIn("$env:PALWORLD_CLIENT_ICON_PATH", content)
        self.assertIn("[System.Drawing.Icon]::ExtractAssociatedIcon", content)
        self.assertIn("Set-WindowIcon $form", content)
        self.assertGreaterEqual(content.count("Set-WindowIcon $dialog"), 4)
        self.assertIn("SetCurrentProcessExplicitAppUserModelID", content)
        self.assertIn('"MinKevin.PalworldServerOperations.Client"', content)
        self.assertIn('"MinKevin.PalworldServerOperations.Admin"', content)
        self.assertIn(
            "[PalworldServerOperations.WindowsShellIdentity]::Set($script:ApplicationUserModelId)",
            content,
        )
        self.assertIn(
            "$actualApplicationUserModelId -ne $script:ApplicationUserModelId",
            content,
        )

    def test_language_preference_and_menu_are_built_into_both_executables(self) -> None:
        content = CLIENT_SOURCE.read_text(encoding="utf-8")
        launcher = LAUNCHER_SOURCE.read_text(encoding="utf-8")
        self.assertIn('"preferences.json"', content)
        self.assertIn("function Get-PalworldApplicationLanguage", content)
        self.assertIn("function Save-PalworldApplicationLanguage", content)
        self.assertIn("function Get-PalworldLocalizedText", content)
        self.assertIn("function New-PalworldApplicationMenu", content)
        self.assertIn('ToolStripMenuItem("English")', content)
        self.assertIn('ToolStripMenuItem("한국어")', content)
        self.assertIn('ToolStripMenuItem("Language")', content)
        self.assertIn('ToolStripMenuItem("Project")', content)
        self.assertIn("[System.Windows.Forms.ToolStripItemAlignment]::Right", content)
        self.assertIn('Join-Path $applicationData "Palworld Server Operations"', content)
        self.assertNotIn('Join-Path $applicationData "PalworldServerManager"', content)
        self.assertNotIn("PALWORLD_CLIENT_TEST_LEGACY_SETTINGS_DIR", content)
        self.assertIn('$script:ApplicationRestartRequested = $true', content)
        self.assertIn("StartProcessWithEnvironment", launcher)
        self.assertNotIn("startInfo.EnvironmentVariables", launcher)
        self.assertIn('"PALWORLD_PROJECT_LICENSE_PATH"', launcher)
        self.assertIn("function Show-PalworldProjectLicense", content)
        self.assertIn("function Show-PalworldAboutDialog", content)
        self.assertIn("function Open-PalworldProjectUrl", content)
        self.assertIn('"https://github.com/MinKevin/palworld-server-operations"', content)
        self.assertIn('Name = "ApplicationProjectMenu"', content)
        self.assertIn('Name = "ProjectStatusStrip"', content)
        self.assertIn('$panel.Height = if ($script:IsAdminEdition) { 98 } else { 66 }', content)
        self.assertIn('$footerLayout.Controls.Add($projectStatus, 0, 1)', content)

    def test_two_single_file_exe_build_sources_are_present(self) -> None:
        build = BUILD_SOURCE.read_text(encoding="utf-8")
        launcher = LAUNCHER_SOURCE.read_text(encoding="utf-8")
        user_executable = ROOT / "windows" / "Palworld Server Operations - Client.exe"
        admin_executable = ROOT / "windows" / "Palworld Server Operations - Admin.exe"

        self.assertIn(r'Join-Path $repositoryRoot "windows\Palworld Server Operations - Client.exe"', build)
        self.assertIn(r'Join-Path $repositoryRoot "windows\Palworld Server Operations - Admin.exe"', build)
        self.assertIn('"/define:ADMIN"', build)
        self.assertIn('"/target:winexe"', build)
        self.assertIn('"/resource:$clientResource,PalworldServerOperations.Client.ps1"', build)
        self.assertIn('ResourceName = "PalworldServerOperations.Client.ps1"', launcher)
        self.assertIn('[assembly: AssemblyTitle("Palworld Server Operations - Client")]', launcher)
        self.assertIn('[assembly: AssemblyTitle("Palworld Server Operations - Admin")]', launcher)
        self.assertIn('[assembly: AssemblyCompany("MinKevin")]', launcher)
        self.assertIn('[assembly: AssemblyVersion("1.0.3.0")]', launcher)
        self.assertIn('[assembly: AssemblyFileVersion("1.0.3.0")]', launcher)
        self.assertIn("PalworldServerOperations.License.txt", build)
        self.assertIn('childEnvironment["PALWORLD_CLIENT_EDITION"]', launcher)
        self.assertIn("PalworldServerOperations.SshModule.ps1", launcher)
        self.assertIn("PalworldServerOperations.SshRuntime.", launcher)
        self.assertIn("PalworldServerOperations.SshPayload.", launcher)
        self.assertIn("DeleteTemporaryDirectory(temporarySshDirectory)", launcher)
        self.assertIn('"/resource:$sshModuleResource,PalworldServerOperations.SshModule.ps1"', build)
        self.assertIn('"/resource:$payload,PalworldServerOperations.SshPayload.$payloadName.tar.gz"', build)
        self.assertTrue(SSH_SOURCE.is_file())
        for executable in (user_executable, admin_executable):
            self.assertTrue(executable.is_file())
            self.assertEqual(executable.read_bytes()[:2], b"MZ")

    def test_executables_embed_and_verify_current_build_input_fingerprints(self) -> None:
        build = BUILD_SOURCE.read_text(encoding="utf-8")
        manifest = BUILD_MANIFEST_SOURCE.read_text(encoding="utf-8")
        verifier = BUILD_VERIFY_SOURCE.read_text(encoding="utf-8")
        workflow = (ROOT / ".github" / "workflows" / "ci.yml").read_text(
            encoding="utf-8"
        )

        self.assertIn("PalworldServerOperations.BuildInputs.json", manifest)
        self.assertIn("Get-PalworldWindowsBuildInputManifest", manifest)
        self.assertIn('mode = "text-utf8-lf"', manifest)
        self.assertIn('.Replace("`r`n", "`n").Replace("`r", "`n")', manifest)
        self.assertIn('"tools/windows-client/build-exe.ps1"', manifest)
        self.assertIn('"tools/windows-client/palworld-rest-client.ps1"', manifest)
        self.assertIn('"tools/windows-ssh-manager/generated/manifest.json"', manifest)
        self.assertIn("record.sources", manifest)
        self.assertIn("Write-PalworldWindowsBuildInputManifest", build)
        self.assertIn(
            '"/resource:$buildInputResource,$script:PalworldBuildInputResourceName"',
            build,
        )
        self.assertIn("& $buildInputVerifier", build)
        self.assertIn("GetManifestResourceStream", verifier)
        self.assertIn("Stale Windows executable", verifier)
        self.assertIn(
            "Verify committed Windows executables match current build inputs", workflow
        )
        self.assertEqual(workflow.count("verify-exe-build-inputs.ps1"), 2)

    def test_windows_distribution_contains_only_executables_and_runtime_store(self) -> None:
        tracked = subprocess.run(
            ["git", "-c", f"safe.directory={ROOT.as_posix()}", "ls-files", "--", "windows"],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        contents = sorted(Path(line).name for line in tracked.stdout.splitlines() if line)
        self.assertIn("Palworld Server Operations - Admin.exe", contents)
        self.assertIn("Palworld Server Operations - Client.exe", contents)
        allowed = {
            "Palworld Server Operations - Admin.exe",
            "Palworld Server Operations - Client.exe",
            "Palworld Server Operations - Admin.connections",
            "Palworld Server Operations - Admin.connections.v1.backup",
        }
        self.assertEqual(set(contents) - allowed, set())


if __name__ == "__main__":
    unittest.main()
