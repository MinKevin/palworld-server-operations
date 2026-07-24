#requires -Version 5.1

param(
    [string]$LauncherTestMode = ""
)

if ($LauncherTestMode) {
    $env:PALWORLD_CLIENT_TEST_MODE = $LauncherTestMode
}
if ($LauncherTestMode -eq "launcher-smoke") {
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Net.Http
Add-Type -AssemblyName System.Windows.Forms.DataVisualization

$script:IsAdminEdition = $env:PALWORLD_CLIENT_EDITION -eq "admin"
$script:ApplicationUserModelId = if ($script:IsAdminEdition) {
    "MinKevin.PalworldServerOperations.Admin"
}
else {
    "MinKevin.PalworldServerOperations.Client"
}
$script:ApplicationShellIdentityError = $null

if ($env:OS -eq "Windows_NT") {
    try {
        if (-not ("PalworldServerOperations.WindowsShellIdentity" -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace PalworldServerOperations
{
    public static class WindowsShellIdentity
    {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int SetCurrentProcessExplicitAppUserModelID(string appId);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = true)]
        private static extern int GetCurrentProcessExplicitAppUserModelID(out IntPtr appId);

        public static void Set(string appId)
        {
            int result = SetCurrentProcessExplicitAppUserModelID(appId);
            if (result < 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }
        }

        public static string Get()
        {
            IntPtr appId = IntPtr.Zero;
            int result = GetCurrentProcessExplicitAppUserModelID(out appId);
            if (result < 0)
            {
                Marshal.ThrowExceptionForHR(result);
            }
            try
            {
                return appId == IntPtr.Zero ? String.Empty : Marshal.PtrToStringUni(appId);
            }
            finally
            {
                if (appId != IntPtr.Zero)
                {
                    Marshal.FreeCoTaskMem(appId);
                }
            }
        }
    }
}
'@
        }
        [PalworldServerOperations.WindowsShellIdentity]::Set($script:ApplicationUserModelId)
    }
    catch {
        $script:ApplicationShellIdentityError = $_.Exception.Message
    }
}

[System.Windows.Forms.Application]::EnableVisualStyles()

$script:ApplicationTitle = if ($script:IsAdminEdition) {
    "Palworld Server Operations - Admin"
}
else {
    "Palworld Server Operations - Client"
}
$script:ProjectName = "Palworld Server Operations"
$script:ProjectRepositoryUrl = "https://github.com/MinKevin/palworld-server-operations"
$script:ProjectIssuesUrl = "$($script:ProjectRepositoryUrl)/issues"
$script:ProjectDiscussionsUrl = "$($script:ProjectRepositoryUrl)/discussions"
$script:MaintainerName = "MinKevin"
$script:MaintainerUrl = "https://github.com/MinKevin"
$script:ProjectLicensePath = [string]$env:PALWORLD_PROJECT_LICENSE_PATH
$script:ClientBaseDirectory = if ($env:PALWORLD_CLIENT_BASE_DIR) {
    [IO.Path]::GetFullPath($env:PALWORLD_CLIENT_BASE_DIR)
}
else {
    [AppDomain]::CurrentDomain.BaseDirectory
}
$applicationData = [Environment]::GetFolderPath("ApplicationData")
$script:ApplicationPreferencesDirectory = if ($env:PALWORLD_CLIENT_TEST_SETTINGS_DIR) {
    [IO.Path]::GetFullPath($env:PALWORLD_CLIENT_TEST_SETTINGS_DIR)
}
else {
    Join-Path $applicationData "Palworld Server Operations"
}
$script:ApplicationPreferencesFile = Join-Path $script:ApplicationPreferencesDirectory "preferences.json"
$script:ApplicationRestartRequested = $false

function Get-PalworldApplicationLanguage {
    $requested = [string]$env:PALWORLD_CLIENT_LANGUAGE
    if ($requested -in @("en", "ko")) { return $requested }
    if ($env:PALWORLD_CLIENT_TEST_MODE) { return "en" }
    if (Test-Path -LiteralPath $script:ApplicationPreferencesFile -PathType Leaf) {
        try {
            $saved = Get-Content -LiteralPath $script:ApplicationPreferencesFile -Raw -Encoding UTF8 |
                ConvertFrom-Json
            if ([string]$saved.Language -in @("en", "ko")) {
                return [string]$saved.Language
            }
        }
        catch { }
    }
    if ([Globalization.CultureInfo]::CurrentUICulture.TwoLetterISOLanguageName -eq "ko") {
        return "ko"
    }
    return "en"
}

function Save-PalworldApplicationLanguage {
    param([Parameter(Mandatory = $true)][ValidateSet("en", "ko")][string]$Language)
    if (-not (Test-Path -LiteralPath $script:ApplicationPreferencesDirectory)) {
        [void](New-Item -ItemType Directory -Path $script:ApplicationPreferencesDirectory -Force)
    }
    $temporary = "$($script:ApplicationPreferencesFile).tmp"
    [ordered]@{ Version = 1; Language = $Language } |
        ConvertTo-Json |
        Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination $script:ApplicationPreferencesFile -Force
}

$script:ApplicationLanguage = Get-PalworldApplicationLanguage

function Get-PalworldLocalizedText {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$English,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Korean
    )
    if ($script:ApplicationLanguage -eq "ko") { return $Korean }
    return $English
}

$script:EnglishToKoreanUiText = @{
    "Language" = "언어"
    "English" = "English"
    "Korean" = "한국어"
    "Confirm master password" = "마스터 비밀번호 확인"
    "Cancel" = "취소"
    "Continue" = "계속"
    "Save" = "저장"
    "Save only" = "저장만"
    "Save && Apply" = "저장 후 적용"
    "Add" = "추가"
    "Update" = "수정"
    "Delete" = "삭제"
    "Refresh" = "새로고침"
    "Select" = "선택"
    "Browse" = "찾아보기"
    "Connection Settings" = "연결 설정"
    "Server URL / host" = "서버 URL / 호스트"
    "API port" = "API 포트"
    "API username" = "API 사용자명"
    "API access token" = "API 액세스 토큰"
    "Show password and token" = "비밀번호와 토큰 표시"
    "Show passwords" = "비밀번호 표시"
    "Add Connection" = "연결 추가"
    "Update Connection" = "연결 수정"
    "Name" = "이름"
    "API URL / Host" = "API URL / 호스트"
    "Port" = "포트"
    "Username" = "사용자명"
    "AdminPassword" = "관리자 비밀번호"
    "API token" = "API 토큰"
    "SSH Connection" = "SSH 연결"
    "Managed Server" = "관리 서버"
    "Type" = "유형"
    "Files" = "파일 수"
    "Size" = "크기"
    "Validate" = "검사"
    "Connection" = "연결"
    "Connections - encrypted portable store" = "연결 - 암호화 휴대용 저장소"
    "Connection details are read-only. Select Update to edit." = "연결 요약은 읽기 전용입니다. 수정하려면 Update를 누르세요."
    "Managed" = "관리 서버"
    "Not linked" = "연결 안 됨"
    "Not mapped" = "매핑 안 됨"
    "Server Tools - selected Connection" = "서버 도구 - 선택한 연결"
    "Backup recovery and recent server-side runtime log viewer" = "백업 복원과 최근 서버 runtime 로그 확인"
    "World Restore" = "월드 복원"
    "Runtime Logs" = "런타임 로그"
    "Basic API" = "기본 API"
    "Direct Shutdown / Stop" = "직접 Shutdown / Stop"
    "Verify Server" = "서버 검증"
    "Request" = "요청"
    "Response" = "응답"
    "Player userId" = "플레이어 userId"
    "Wait time (sec)" = "대기 시간(초)"
    "Message" = "메시지"
    "Message (required)" = "메시지(필수)"
    "Send request" = "요청 전송"
    "Ready" = "준비"
    "Sending..." = "전송 중..."
    "Success" = "성공"
    "Fail" = "실패"
    "Source" = "출처"
    "Recent lines" = "최근 줄 수"
    "Loading..." = "불러오는 중..."
    "Server runtime logs" = "서버 런타임 로그"
    "CPU" = "CPU"
    "Memory" = "메모리"
    "Network" = "네트워크"
    "Range" = "기간"
    "Refresh history" = "동향 새로고침"
    "Host trend" = "호스트 동향"
    "Container trend" = "컨테이너 동향"
    "Recent trend" = "최근 동향"
    "Host" = "호스트"
    "Server" = "서버"
    "Palworld" = "팰월드"
    "Server API" = "서버 API"
    "SSH Management" = "SSH 관리"
    "SSH Terminal" = "SSH 터미널"
    "Licenses" = "라이선스"
    "SSH Connections - encrypted portable store" = "SSH 연결 - 암호화 휴대용 저장소"
    "SSH Connections · encrypted portable store" = "SSH 연결 · 암호화된 휴대용 저장소"
    "SSH Session" = "SSH 세션"
    "Connect" = "연결"
    "Disconnect" = "연결 해제"
    "Reconnect" = "다시 연결"
    "Host Check" = "호스트 검사"
    "Create Work Dir" = "작업 디렉터리 생성"
    "Refresh Servers" = "서버 목록 새로고침"
    "Run" = "실행"
    "Send" = "전송"
    "Bottom" = "맨 아래"
    "Clear" = "지우기"
    "Disconnected" = "연결 끊김"
    "Automated Management - operation payload is removed immediately after each action" = "자동 관리 - 작업 payload는 실행 직후 제거됩니다"
    "Automated Management · temporary files are removed after each action" = "자동 관리 · 작업용 임시 파일은 실행이 끝나면 제거됩니다"
    "Status - last action, readiness, selected server and network" = "상태 - 마지막 작업, 준비 상태, 선택 서버와 네트워크"
    "Status · last action, readiness, selected server and network" = "상태 · 마지막 작업, 준비 상태, 선택 서버와 네트워크"
    "Third-party licenses" = "제3자 라이선스"
}
$script:KoreanToEnglishUiText = @{}
foreach ($entry in $script:EnglishToKoreanUiText.GetEnumerator()) {
    if (-not $script:KoreanToEnglishUiText.ContainsKey([string]$entry.Value)) {
        $script:KoreanToEnglishUiText[[string]$entry.Value] = [string]$entry.Key
    }
}

function ConvertTo-PalworldLocalizedLiteral {
    param([AllowEmptyString()][string]$Text)
    if (-not $Text) { return $Text }
    if ($script:ApplicationLanguage -eq "ko" -and $script:EnglishToKoreanUiText.ContainsKey($Text)) {
        return [string]$script:EnglishToKoreanUiText[$Text]
    }
    if ($script:ApplicationLanguage -eq "en" -and $script:KoreanToEnglishUiText.ContainsKey($Text)) {
        return [string]$script:KoreanToEnglishUiText[$Text]
    }
    return $Text
}

function Set-PalworldLocalizedControlTree {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Control]$Control)
    if (
        $Control -is [System.Windows.Forms.Form] -or
        $Control -is [System.Windows.Forms.Label] -or
        $Control -is [System.Windows.Forms.ButtonBase] -or
        $Control -is [System.Windows.Forms.GroupBox] -or
        $Control -is [System.Windows.Forms.TabPage]
    ) {
        $Control.Text = ConvertTo-PalworldLocalizedLiteral ([string]$Control.Text)
    }
    foreach ($child in @($Control.Controls)) {
        Set-PalworldLocalizedControlTree -Control $child
    }
}

function Set-PalworldApplicationLanguageFromUi {
    param(
        [Parameter(Mandatory = $true)][ValidateSet("en", "ko")][string]$Language,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    if ($Language -eq $script:ApplicationLanguage) { return }
    try {
        Save-PalworldApplicationLanguage -Language $Language
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            (Get-PalworldLocalizedText `
                "The language preference could not be saved.`r`n`r`n$($_.Exception.Message)" `
                "언어 설정을 저장하지 못했습니다.`r`n`r`n$($_.Exception.Message)"),
            $script:ApplicationTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        return
    }
    $script:ApplicationLanguage = $Language
    if ($env:PALWORLD_CLIENT_EXE_PATH -and
        (Test-Path -LiteralPath $env:PALWORLD_CLIENT_EXE_PATH -PathType Leaf)) {
        $script:ApplicationRestartRequested = $true
        $Owner.Close()
        return
    }
    [void][System.Windows.Forms.MessageBox]::Show(
        (Get-PalworldLocalizedText `
            "Language saved. Restart the application to apply it everywhere." `
            "언어를 저장했습니다. 프로그램을 다시 실행하면 전체 화면에 적용됩니다."),
        $script:ApplicationTitle,
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

function Open-PalworldProjectUrl {
    param(
        [Parameter(Mandatory = $true)][string]$Url,
        [Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner
    )
    try {
        Start-Process $Url
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            (Get-PalworldLocalizedText `
                "Could not open the link.`r`n`r`n$Url`r`n`r`n$($_.Exception.Message)" `
                "링크를 열지 못했습니다.`r`n`r`n$Url`r`n`r`n$($_.Exception.Message)"),
            $script:ApplicationTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}

function Show-PalworldProjectLicense {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = Get-PalworldLocalizedText "Project license" "프로젝트 라이선스"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(760, 600)
    $dialog.MinimumSize = New-Object System.Drawing.Size(620, 460)
    $dialog.Font = $Owner.Font
    Set-WindowIcon $dialog

    $licenseText = New-Object System.Windows.Forms.RichTextBox
    $licenseText.Dock = "Fill"
    $licenseText.ReadOnly = $true
    $licenseText.WordWrap = $false
    $licenseText.BackColor = [System.Drawing.SystemColors]::Window
    $licenseText.Font = New-Object System.Drawing.Font("Consolas", 9)
    if ($script:ProjectLicensePath -and
        (Test-Path -LiteralPath $script:ProjectLicensePath -PathType Leaf)) {
        $licenseText.Text = [IO.File]::ReadAllText($script:ProjectLicensePath, [Text.Encoding]::UTF8)
    }
    else {
        $licenseText.Text = Get-PalworldLocalizedText `
            "The embedded GPL-3.0 license is unavailable. Rebuild the application." `
            "내장된 GPL-3.0 라이선스를 찾을 수 없습니다. 프로그램을 다시 빌드하세요."
    }
    $dialog.Controls.Add($licenseText)
    try { [void]$dialog.ShowDialog($Owner) }
    finally { $dialog.Dispose() }
}

function Show-PalworldAboutDialog {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner)
    $version = "development"
    if ($env:PALWORLD_CLIENT_EXE_PATH -and
        (Test-Path -LiteralPath $env:PALWORLD_CLIENT_EXE_PATH -PathType Leaf)) {
        try {
            $version = [Diagnostics.FileVersionInfo]::GetVersionInfo(
                $env:PALWORLD_CLIENT_EXE_PATH
            ).FileVersion
        }
        catch { }
    }
    $edition = if ($script:IsAdminEdition) { "Admin" } else { "Client" }
    $message = Get-PalworldLocalizedText `
        "$($script:ProjectName) - $edition`r`nVersion $version`r`n`r`nDeveloped and maintained by $($script:MaintainerName).`r`nLicensed under GPL-3.0-only.`r`n`r`nUnofficial Palworld community project.`r`n$($script:ProjectRepositoryUrl)" `
        "$($script:ProjectName) - $edition`r`n버전 $version`r`n`r`n$($script:MaintainerName)이 개발하고 유지관리합니다.`r`nGPL-3.0-only 라이선스로 제공합니다.`r`n`r`n비공식 Palworld 커뮤니티 프로젝트입니다.`r`n$($script:ProjectRepositoryUrl)"
    [void][System.Windows.Forms.MessageBox]::Show(
        $Owner,
        $message,
        (Get-PalworldLocalizedText "About" "정보"),
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Information
    )
}

function New-PalworldApplicationMenu {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner)
    $existingControls = @($Owner.Controls)
    $menu = New-Object System.Windows.Forms.MenuStrip
    $menu.Name = "ApplicationMenuStrip"
    $menu.Dock = "Top"
    $languageMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Language")
    $languageMenu.Name = "ApplicationLanguageMenu"
    $languageMenu.Alignment = [System.Windows.Forms.ToolStripItemAlignment]::Right
    $englishItem = New-Object System.Windows.Forms.ToolStripMenuItem("English")
    $englishItem.Name = "ApplicationLanguageEnglish"
    $englishItem.Checked = $script:ApplicationLanguage -eq "en"
    $koreanItem = New-Object System.Windows.Forms.ToolStripMenuItem("한국어")
    $koreanItem.Name = "ApplicationLanguageKorean"
    $koreanItem.Checked = $script:ApplicationLanguage -eq "ko"
    $englishItem.Add_Click({
        Set-PalworldApplicationLanguageFromUi -Language "en" -Owner $Owner
    }.GetNewClosure())
    $koreanItem.Add_Click({
        Set-PalworldApplicationLanguageFromUi -Language "ko" -Owner $Owner
    }.GetNewClosure())
    [void]$languageMenu.DropDownItems.Add($englishItem)
    [void]$languageMenu.DropDownItems.Add($koreanItem)
    $projectMenu = New-Object System.Windows.Forms.ToolStripMenuItem("Project")
    $projectMenu.Name = "ApplicationProjectMenu"
    $projectMenu.Alignment = [System.Windows.Forms.ToolStripItemAlignment]::Right
    $repositoryItem = New-Object System.Windows.Forms.ToolStripMenuItem("Official repository")
    $repositoryItem.Add_Click({
        Open-PalworldProjectUrl -Url $script:ProjectRepositoryUrl -Owner $Owner
    }.GetNewClosure())
    $issueItem = New-Object System.Windows.Forms.ToolStripMenuItem("Report an issue")
    $issueItem.Add_Click({
        Open-PalworldProjectUrl -Url $script:ProjectIssuesUrl -Owner $Owner
    }.GetNewClosure())
    $discussionItem = New-Object System.Windows.Forms.ToolStripMenuItem("Contact and discussions")
    $discussionItem.Add_Click({
        Open-PalworldProjectUrl -Url $script:ProjectDiscussionsUrl -Owner $Owner
    }.GetNewClosure())
    $licenseItem = New-Object System.Windows.Forms.ToolStripMenuItem("Project license")
    $licenseItem.Add_Click({ Show-PalworldProjectLicense -Owner $Owner }.GetNewClosure())
    $aboutItem = New-Object System.Windows.Forms.ToolStripMenuItem("About")
    $aboutItem.Add_Click({ Show-PalworldAboutDialog -Owner $Owner }.GetNewClosure())
    foreach ($item in @($repositoryItem, $issueItem, $discussionItem)) {
        [void]$projectMenu.DropDownItems.Add($item)
    }
    [void]$projectMenu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$projectMenu.DropDownItems.Add($licenseItem)
    [void]$projectMenu.DropDownItems.Add($aboutItem)
    $adminNavigationItems = @()
    if ($script:IsAdminEdition -and $script:AdminTabLayout) {
        $adminTabs = $script:AdminTabLayout.Tabs
        $navigationLabels = @(
            (Get-PalworldLocalizedText "Server API" "서버 API"),
            (Get-PalworldLocalizedText "SSH Management" "SSH 관리"),
            (Get-PalworldLocalizedText "Licenses" "라이선스")
        )
        for ($tabIndex = 0; $tabIndex -lt $navigationLabels.Count; $tabIndex++) {
            $capturedIndex = $tabIndex
            $navigationItem = New-Object System.Windows.Forms.ToolStripMenuItem($navigationLabels[$tabIndex])
            $navigationItem.Name = "ApplicationAdminTab$tabIndex"
            $navigationItem.Add_Click({
                $adminTabs.SelectedIndex = $capturedIndex
            }.GetNewClosure())
            $adminNavigationItems += $navigationItem
            [void]$menu.Items.Add($navigationItem)
        }
    }
    if ($script:IsAdminEdition -and $script:AdminTabLayout) {
        $languageMenu.Alignment = [System.Windows.Forms.ToolStripItemAlignment]::Left
        $projectMenu.Alignment = [System.Windows.Forms.ToolStripItemAlignment]::Left
        [void]$menu.Items.Add($languageMenu)
        [void]$menu.Items.Add($projectMenu)
    }
    else {
        # Right-aligned items are laid out from the right edge. Add Project first
        # so the Client edition reads Language, then Project.
        [void]$menu.Items.Add($projectMenu)
        [void]$menu.Items.Add($languageMenu)
    }
    $Owner.MainMenuStrip = $menu
    $Owner.Controls.Add($menu)

    $menuHeight = [Math]::Max(24, $menu.PreferredSize.Height)
    if ($script:IsAdminEdition -and $script:AdminTabLayout) {
        # Admin navigation and global controls share one row. The native tab
        # headers are collapsed; the left menu items select the same TabPages.
        $script:AdminTabLayout.Tabs.Appearance = "FlatButtons"
        $script:AdminTabLayout.Tabs.SizeMode = "Fixed"
        $script:AdminTabLayout.Tabs.ItemSize = New-Object System.Drawing.Size(0, 1)
        $script:AdminTabLayout.Tabs.Location = New-Object System.Drawing.Point(0, $menuHeight)
        $script:AdminTabLayout.Tabs.Size = New-Object System.Drawing.Size(
            $Owner.ClientSize.Width,
            [Math]::Max(120, ($script:ResourceUsageFooter.Top - $menuHeight))
        )
    }
    else {
        $topFlag = [int][System.Windows.Forms.AnchorStyles]::Top
        $bottomFlag = [int][System.Windows.Forms.AnchorStyles]::Bottom
        foreach ($control in $existingControls) {
            if ($control -eq $script:ResourceUsageFooter -or $control.Dock -ne "None") { continue }
            $anchor = [int]$control.Anchor
            $hasTop = ($anchor -band $topFlag) -ne 0
            $hasBottom = ($anchor -band $bottomFlag) -ne 0
            if (-not $hasTop) { continue }
            $control.Top += $menuHeight
            if ($hasBottom) {
                $control.Height = [Math]::Max(24, ($control.Height - $menuHeight))
            }
        }
    }
    $menu.BringToFront()
    $script:ApplicationMenuStrip = $menu
    $script:ApplicationLanguageMenu = $languageMenu
    $script:ApplicationEnglishLanguageItem = $englishItem
    $script:ApplicationKoreanLanguageItem = $koreanItem
    $script:ApplicationProjectMenu = $projectMenu
    return $menu
}

$script:ApplicationIcon = $null
$script:PalworldApplicationClosing = $false
$script:PalworldActiveHttpOperations = New-Object 'System.Collections.Generic.List[object]'
if ($env:PALWORLD_CLIENT_ICON_PATH -and (Test-Path -LiteralPath $env:PALWORLD_CLIENT_ICON_PATH)) {
    try {
        $script:ApplicationIcon = New-Object System.Drawing.Icon -ArgumentList (
            [IO.Path]::GetFullPath($env:PALWORLD_CLIENT_ICON_PATH)
        )
    }
    catch {
        $script:ApplicationIcon = $null
    }
}
elseif ($env:PALWORLD_CLIENT_EXE_PATH -and (Test-Path -LiteralPath $env:PALWORLD_CLIENT_EXE_PATH)) {
    try {
        $script:ApplicationIcon = [System.Drawing.Icon]::ExtractAssociatedIcon(
            [IO.Path]::GetFullPath($env:PALWORLD_CLIENT_EXE_PATH)
        )
    }
    catch {
        $script:ApplicationIcon = $null
    }
}

function Set-WindowIcon {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Window)
    if ($script:ApplicationIcon) {
        $Window.Icon = $script:ApplicationIcon
    }
    $windowToLocalize = $Window
    $Window.Add_Shown({
        Set-PalworldLocalizedControlTree -Control $windowToLocalize
    }.GetNewClosure())
}

$script:Text = @{
    ServerInfo = Get-PalworldLocalizedText "Server information" "서버 정보 조회"
    Players = Get-PalworldLocalizedText "Connected players" "접속 플레이어 조회"
    Settings = Get-PalworldLocalizedText "Server settings" "서버 설정 조회"
    Metrics = Get-PalworldLocalizedText "Server metrics" "서버 지표 조회"
    Announce = Get-PalworldLocalizedText "Broadcast announcement" "전체 공지 전송"
    Save = Get-PalworldLocalizedText "Save world now" "월드 즉시 저장"
    Kick = Get-PalworldLocalizedText "Kick player" "플레이어 추방"
    Ban = Get-PalworldLocalizedText "Ban player" "플레이어 차단"
    Unban = Get-PalworldLocalizedText "Unban player" "플레이어 차단 해제"
    CategorySelection = Get-PalworldLocalizedText "Category" "카테고리"
    OfficialCategory = "Palworld REST API"
    DirectCategory = Get-PalworldLocalizedText "Direct termination API (not recommended)" "직접 종료 API (권장하지 않음)"
    AdvancedCategory = Get-PalworldLocalizedText "Advanced Management" "고급 관리"
    DirectShutdown = Get-PalworldLocalizedText "Shutdown - direct call (not recommended)" "Shutdown - 직접 호출 (권장하지 않음)"
    DirectStop = Get-PalworldLocalizedText "Stop - direct call (not recommended)" "Stop - 직접 호출 (권장하지 않음)"
    AdvancedStart = Get-PalworldLocalizedText "Advanced Start - start now and restore policy" "Advanced Start - 즉시 시작 및 운영 정책 복구"
    AdvancedRestart = Get-PalworldLocalizedText "Advanced Restart - safe restart and restore policy" "Advanced Restart - 안전 재시작 및 운영 정책 복구"
    AdvancedShutdown = Get-PalworldLocalizedText "Advanced Shutdown - stop until the next operating window" "Advanced Shutdown - 다음 운영 시작까지 안전 정지"
    DirectWarningTitle = Get-PalworldLocalizedText "Direct termination API warning" "직접 종료 API 경고"
    DirectWarning = Get-PalworldLocalizedText `
        "This API calls the Palworld server directly and bypasses the Linux supervisor's execution state. The server can start again automatically. Use Advanced Shutdown for a safe stop. Continue?" `
        "이 API는 팰월드 서버에 직접 전달되며 Linux 감독기의 실행 상태를 변경하지 않습니다. 서버가 자동으로 다시 시작될 수 있습니다. 안전한 종료는 Advanced Shutdown을 사용하세요. 계속하시겠습니까?"
    CommandSelection = Get-PalworldLocalizedText "Command" "명령 선택"
    WorldRestore = Get-PalworldLocalizedText "World backup restore" "월드 백업 복원"
    RefreshBackups = Get-PalworldLocalizedText "Refresh backup list" "백업 목록 새로고침"
    RestoreSelected = Get-PalworldLocalizedText "Restore selected backup" "선택 백업 복원"
    AvailableBackups = Get-PalworldLocalizedText "Available backups" "복원 가능한 백업"
    RestoreWarning = Get-PalworldLocalizedText `
        "Before restoring, the current world is moved to a deleted_ backup. The server stops safely and restarts according to its operating policy after the restore. Continue?" `
        "복원 전 현재 월드를 deleted_ 백업으로 이동합니다. 서버가 안전 종료되고 복원 후 운영 정책에 따라 다시 시작됩니다. 계속하시겠습니까?"
    AutomaticBackup = Get-PalworldLocalizedText "Automatic backup" "자동 백업"
    PreRestoreBackup = Get-PalworldLocalizedText "Pre-restore backup" "복원 전 보존본"
    WorldGuid = Get-PalworldLocalizedText "World GUID" "월드 GUID"
    RestoreWait = Get-PalworldLocalizedText "Shutdown notice (sec)" "종료 안내 시간(초)"
    RestoreProgress = Get-PalworldLocalizedText "Restore progress log" "복원 진행 로그"
}

$script:ApiDefinitions = @(
    [pscustomobject]@{ Category = $script:Text.OfficialCategory; Display = "$($script:Text.ServerInfo) (GET /v1/api/info)"; Method = "GET"; Endpoint = "info"; UserId = $false; WaitTime = $false; Message = $false; MessageRequired = $false; Dangerous = $false }
    [pscustomobject]@{ Category = $script:Text.OfficialCategory; Display = "$($script:Text.Players) (GET /v1/api/players)"; Method = "GET"; Endpoint = "players"; UserId = $false; WaitTime = $false; Message = $false; MessageRequired = $false; Dangerous = $false }
    [pscustomobject]@{ Category = $script:Text.OfficialCategory; Display = "$($script:Text.Settings) (GET /v1/api/settings)"; Method = "GET"; Endpoint = "settings"; UserId = $false; WaitTime = $false; Message = $false; MessageRequired = $false; Dangerous = $false }
    [pscustomobject]@{ Category = $script:Text.OfficialCategory; Display = "$($script:Text.Metrics) (GET /v1/api/metrics)"; Method = "GET"; Endpoint = "metrics"; UserId = $false; WaitTime = $false; Message = $false; MessageRequired = $false; Dangerous = $false }
    [pscustomobject]@{ Category = $script:Text.OfficialCategory; Display = "$($script:Text.Announce) (POST /v1/api/announce)"; Method = "POST"; Endpoint = "announce"; UserId = $false; WaitTime = $false; Message = $true; MessageRequired = $true; Dangerous = $false }
    [pscustomobject]@{ Category = $script:Text.OfficialCategory; Display = "$($script:Text.Save) (POST /v1/api/save)"; Method = "POST"; Endpoint = "save"; UserId = $false; WaitTime = $false; Message = $false; MessageRequired = $false; Dangerous = $false }
    [pscustomobject]@{ Category = $script:Text.OfficialCategory; Display = "$($script:Text.Kick) (POST /v1/api/kick)"; Method = "POST"; Endpoint = "kick"; UserId = $true; WaitTime = $false; Message = $true; MessageRequired = $false; Dangerous = $true }
    [pscustomobject]@{ Category = $script:Text.OfficialCategory; Display = "$($script:Text.Ban) (POST /v1/api/ban)"; Method = "POST"; Endpoint = "ban"; UserId = $true; WaitTime = $false; Message = $true; MessageRequired = $false; Dangerous = $true }
    [pscustomobject]@{ Category = $script:Text.OfficialCategory; Display = "$($script:Text.Unban) (POST /v1/api/unban)"; Method = "POST"; Endpoint = "unban"; UserId = $true; WaitTime = $false; Message = $false; MessageRequired = $false; Dangerous = $true }
    [pscustomobject]@{ Category = $script:Text.DirectCategory; Display = "$($script:Text.DirectShutdown) (POST /v1/api/shutdown)"; Method = "POST"; Endpoint = "shutdown"; UserId = $false; WaitTime = $true; Message = $true; MessageRequired = $true; Dangerous = $true; DirectControl = $true }
    [pscustomobject]@{ Category = $script:Text.DirectCategory; Display = "$($script:Text.DirectStop) (POST /v1/api/stop)"; Method = "POST"; Endpoint = "stop"; UserId = $false; WaitTime = $false; Message = $false; MessageRequired = $false; Dangerous = $true; DirectControl = $true }
    [pscustomobject]@{ Category = $script:Text.AdvancedCategory; Display = "$($script:Text.AdvancedStart) (POST /v1/manager/start)"; Method = "POST"; Endpoint = "start"; UserId = $false; WaitTime = $false; Message = $false; MessageRequired = $false; Dangerous = $true; ManagerAction = $true }
    [pscustomobject]@{ Category = $script:Text.AdvancedCategory; Display = "$($script:Text.AdvancedRestart) (POST /v1/manager/restart)"; Method = "POST"; Endpoint = "restart"; UserId = $false; WaitTime = $true; Message = $false; MessageRequired = $false; Dangerous = $true; ManagerAction = $true }
    [pscustomobject]@{ Category = $script:Text.AdvancedCategory; Display = "$($script:Text.AdvancedShutdown) (POST /v1/manager/shutdown)"; Method = "POST"; Endpoint = "shutdown"; UserId = $false; WaitTime = $true; Message = $false; MessageRequired = $false; Dangerous = $true; ManagerAction = $true }
)

function Get-CommandDisplay {
    param([Parameter(Mandatory = $true)]$Definition)
    $display = [string]$Definition.Display
    if (-not $script:IsAdminEdition) {
        return $display -replace '\s+\((?:GET|POST) /v1/(?:api|manager)/[^)]+\)$', ''
    }
    return $display
}

function New-PalworldHttpOperation {
    return [pscustomobject]@{
        Cancellation = New-Object Threading.CancellationTokenSource
        Client = $null
        Response = $null
        StopRequested = $false
    }
}

function Get-PalworldInnermostException {
    param([Parameter(Mandatory = $true)][Exception]$Exception)
    $cursor = $Exception
    while ($cursor.InnerException -and $cursor.InnerException -ne $cursor) {
        $cursor = $cursor.InnerException
    }
    return $cursor
}

function Get-PalworldHttpFailureDetail {
    param([Parameter(Mandatory = $true)][Exception]$Exception)
    $cursor = $Exception
    $isCanceled = $false
    $isConnection = $false
    while ($cursor) {
        if ($cursor -is [OperationCanceledException] -or
            $cursor -is [System.Threading.Tasks.TaskCanceledException]) {
            $isCanceled = $true
        }
        if ($cursor -is [System.Net.Http.HttpRequestException] -or
            $cursor -is [System.Net.Sockets.SocketException]) {
            $isConnection = $true
        }
        $cursor = $cursor.InnerException
    }
    $innermost = Get-PalworldInnermostException -Exception $Exception
    $detail = [string]$innermost.Message
    if ($isCanceled) {
        return Get-PalworldLocalizedText `
            "The Server API request timed out or was canceled. The server may still be restarting." `
            "Server API 요청 시간이 초과되었거나 취소되었습니다. 서버가 아직 재시작 중일 수 있습니다."
    }
    if ($isConnection) {
        $summary = Get-PalworldLocalizedText `
            "Could not connect to the Server API. The server may be stopped or restarting; check the API TCP port and retry." `
            "Server API에 연결할 수 없습니다. 서버가 정지 또는 재시작 중인지, API TCP 포트가 열려 있는지 확인한 후 다시 시도하세요."
        if ($detail) {
            $detailLabel = Get-PalworldLocalizedText "Detail" "상세"
            return "$summary`r`n${detailLabel}: $detail"
        }
        return $summary
    }
    if ($detail) { return $detail }
    return Get-PalworldLocalizedText `
        "The Server API request could not be completed." `
        "Server API 요청을 완료하지 못했습니다."
}

function Add-PalworldBoundedRichTextLog {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.RichTextBox]$Control,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text,
        [ValidateRange(65536, 4000000)][int]$MaximumCharacters = 1000000,
        [ValidateRange(32768, 3000000)][int]$RetainedCharacters = 800000
    )
    if ($Control.IsDisposed -or -not $Text) { return }
    if ($RetainedCharacters -ge $MaximumCharacters) {
        throw "RetainedCharacters must be smaller than MaximumCharacters."
    }
    $Control.AppendText($Text)
    if ($Control.TextLength -gt $MaximumCharacters) {
        $removeLength = $Control.TextLength - $RetainedCharacters
        # Drop complete old lines when possible. This bounds a long restore
        # stream without repeatedly copying the entire control during normal use.
        $newline = $Control.Text.IndexOf("`n", $removeLength)
        if ($newline -ge 0) { $removeLength = $newline + 1 }
        $Control.Select(0, $removeLength)
        $Control.SelectedText = ""
    }
    $Control.SelectionStart = $Control.TextLength
    $Control.ScrollToCaret()
}

function Stop-PalworldHttpOperation {
    param([Parameter(Mandatory = $true)]$Operation)
    $Operation.StopRequested = $true
    try { $Operation.Cancellation.Cancel() } catch { }
    if ($Operation.Client) {
        try { $Operation.Client.CancelPendingRequests() } catch { }
    }
    if ($Operation.Response) {
        try { $Operation.Response.Dispose() } catch { }
        $Operation.Response = $null
    }
}

function Wait-PalworldHttpTask {
    param(
        [Parameter(Mandatory = $true)][Threading.Tasks.Task]$Task,
        [Parameter(Mandatory = $true)]$Operation
    )
    while (-not $Task.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:PalworldApplicationClosing -or
            $Operation.StopRequested -or
            $Operation.Cancellation.IsCancellationRequested) {
            Stop-PalworldHttpOperation -Operation $Operation
            throw [OperationCanceledException]::new("HTTP request was canceled while its window was closing.")
        }
        Start-Sleep -Milliseconds 25
    }
    if ($script:PalworldApplicationClosing -or
        $Operation.StopRequested -or
        $Operation.Cancellation.IsCancellationRequested) {
        Stop-PalworldHttpOperation -Operation $Operation
        throw [OperationCanceledException]::new("HTTP request was canceled while its window was closing.")
    }
    return $Task.GetAwaiter().GetResult()
}

function Stop-PalworldHttpOperationsForExit {
    if ($script:PalworldApplicationClosing) { return }
    $script:PalworldApplicationClosing = $true
    foreach ($operation in @($script:PalworldActiveHttpOperations.ToArray())) {
        Stop-PalworldHttpOperation -Operation $operation
    }
}

function Invoke-PalworldRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [AllowEmptyString()][string]$AccessToken = "",
        [string]$BodyJson,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 15,
        $Operation = $null
    )

    if ($script:PalworldApplicationClosing) {
        throw [OperationCanceledException]::new("Palworld Server Operations is closing.")
    }
    $ownsOperation = $null -eq $Operation
    if ($ownsOperation) { $Operation = New-PalworldHttpOperation }
    if ($Operation.StopRequested -or $Operation.Cancellation.IsCancellationRequested) {
        if ($ownsOperation) { $Operation.Cancellation.Dispose() }
        throw [OperationCanceledException]::new("HTTP request was canceled before it started.")
    }
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $request = $null
    $response = $null
    try {
        $Operation.Client = $client
        [void]$script:PalworldActiveHttpOperations.Add($Operation)
        $httpMethod = New-Object System.Net.Http.HttpMethod($Method)
        $request = New-Object System.Net.Http.HttpRequestMessage($httpMethod, $Uri)
        $credentials = [Text.Encoding]::UTF8.GetBytes("${Username}:${Password}")
        $token = [Convert]::ToBase64String($credentials)
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $token)
        if ($AccessToken) {
            [void]$request.Headers.TryAddWithoutValidation("X-Palworld-Manager-Token", $AccessToken)
        }
        $request.Headers.Accept.Add((New-Object System.Net.Http.Headers.MediaTypeWithQualityHeaderValue("application/json")))
        if ($BodyJson) {
            $request.Content = New-Object System.Net.Http.StringContent(
                $BodyJson,
                [Text.Encoding]::UTF8,
                "application/json"
            )
        }

        $sendTask = $client.SendAsync($request, $Operation.Cancellation.Token)
        $response = Wait-PalworldHttpTask -Task $sendTask -Operation $Operation
        $Operation.Response = $response
        $readTask = $response.Content.ReadAsStringAsync()
        $responseBody = Wait-PalworldHttpTask -Task $readTask -Operation $Operation
        return [pscustomobject]@{
            Success = $response.IsSuccessStatusCode
            StatusCode = [int]$response.StatusCode
            Reason = $response.ReasonPhrase
            Body = $responseBody
        }
    }
    finally {
        [void]$script:PalworldActiveHttpOperations.Remove($Operation)
        $Operation.Response = $null
        $Operation.Client = $null
        if ($response) { $response.Dispose() }
        if ($request) { $request.Dispose() }
        $client.Dispose()
        $handler.Dispose()
        if ($ownsOperation) { $Operation.Cancellation.Dispose() }
    }
}

function New-PalworldRestoreSubscription {
    return [pscustomobject]@{
        Cancellation = New-Object Threading.CancellationTokenSource
        Client = $null
        Stream = $null
        Reader = $null
        StopRequested = $false
    }
}

function Stop-PalworldRestoreSubscription {
    param([Parameter(Mandatory = $true)]$Subscription)
    $Subscription.StopRequested = $true
    try { $Subscription.Cancellation.Cancel() } catch { }
    if ($Subscription.Client) {
        try { $Subscription.Client.CancelPendingRequests() } catch { }
    }
    if ($Subscription.Reader) {
        try { $Subscription.Reader.Dispose() } catch { }
        $Subscription.Reader = $null
    }
    if ($Subscription.Stream) {
        try { $Subscription.Stream.Dispose() } catch { }
        $Subscription.Stream = $null
    }
}

function Wait-PalworldRestoreTask {
    param(
        [Parameter(Mandatory = $true)][Threading.Tasks.Task]$Task,
        [Parameter(Mandatory = $true)]$Subscription
    )
    while (-not $Task.IsCompleted) {
        if ($Subscription.Cancellation.IsCancellationRequested) {
            Stop-PalworldRestoreSubscription -Subscription $Subscription
            throw [OperationCanceledException]::new(
                "Restore progress subscription stopped. The server-side restore was not canceled and may still be running."
            )
        }
        [System.Windows.Forms.Application]::DoEvents()
        if ($Subscription.Cancellation.IsCancellationRequested) {
            Stop-PalworldRestoreSubscription -Subscription $Subscription
            throw [OperationCanceledException]::new(
                "Restore progress subscription stopped. The server-side restore was not canceled and may still be running."
            )
        }
        Start-Sleep -Milliseconds 25
    }
    if ($Subscription.Cancellation.IsCancellationRequested) {
        Stop-PalworldRestoreSubscription -Subscription $Subscription
        throw [OperationCanceledException]::new(
            "Restore progress subscription stopped. The server-side restore was not canceled and may still be running."
        )
    }
    return $Task.GetAwaiter().GetResult()
}

function Invoke-RestoreStream {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [Parameter(Mandatory = $true)][string]$Username,
        [Parameter(Mandatory = $true)][string]$Password,
        [AllowEmptyString()][string]$AccessToken = "",
        [Parameter(Mandatory = $true)][string]$BodyJson,
        [Parameter(Mandatory = $true)][scriptblock]$OnEvent,
        [Parameter(Mandatory = $true)]$Subscription
    )

    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromHours(1)
    $request = $null
    $response = $null
    $stream = $null
    $reader = $null
    $finalResult = $null
    try {
        $Subscription.Client = $client
        $httpMethod = [System.Net.Http.HttpMethod]::Post
        $request = New-Object System.Net.Http.HttpRequestMessage($httpMethod, $Uri)
        $credentials = [Text.Encoding]::UTF8.GetBytes("${Username}:${Password}")
        $token = [Convert]::ToBase64String($credentials)
        $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $token)
        if ($AccessToken) {
            [void]$request.Headers.TryAddWithoutValidation("X-Palworld-Manager-Token", $AccessToken)
        }
        $request.Headers.Accept.Add((New-Object System.Net.Http.Headers.MediaTypeWithQualityHeaderValue("application/x-ndjson")))
        $request.Content = New-Object System.Net.Http.StringContent(
            $BodyJson,
            [Text.Encoding]::UTF8,
            "application/json"
        )
        $sendTask = $client.SendAsync(
            $request,
            [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead,
            $Subscription.Cancellation.Token
        )
        $response = Wait-PalworldRestoreTask -Task $sendTask -Subscription $Subscription
        if (-not $response.IsSuccessStatusCode) {
            $errorTask = $response.Content.ReadAsStringAsync()
            $errorBody = Wait-PalworldRestoreTask -Task $errorTask -Subscription $Subscription
            $detail = "HTTP $([int]$response.StatusCode) $($response.ReasonPhrase)"
            try {
                $errorPayload = $errorBody | ConvertFrom-Json
                if ([string]$errorPayload.error) {
                    $detail = "$detail - $([string]$errorPayload.error)"
                }
            }
            catch {
                # Preserve the status-only message when the response is not JSON.
            }
            throw "The restore request was rejected: $detail"
        }
        $streamTask = $response.Content.ReadAsStreamAsync()
        $stream = Wait-PalworldRestoreTask -Task $streamTask -Subscription $Subscription
        $Subscription.Stream = $stream
        $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8)
        $Subscription.Reader = $reader
        while ($true) {
            $readTask = $reader.ReadLineAsync()
            $line = Wait-PalworldRestoreTask -Task $readTask -Subscription $Subscription
            if ($null -eq $line) { break }
            if (-not $line.Trim()) { continue }
            try {
                $event = $line | ConvertFrom-Json
            }
            catch {
                continue
            }
            & $OnEvent $event
            if ([string]$event.type -eq "result") { $finalResult = $event }
        }
        if ($null -eq $finalResult) {
            throw "The restore stream ended without a final result. Check runtime.log."
        }
        return $finalResult
    }
    finally {
        if ($reader) { try { $reader.Dispose() } catch { } }
        elseif ($stream) { try { $stream.Dispose() } catch { } }
        $Subscription.Reader = $null
        $Subscription.Stream = $null
        if ($response) { try { $response.Dispose() } catch { } }
        if ($request) { try { $request.Dispose() } catch { } }
        try { $client.Dispose() } catch { }
        $Subscription.Client = $null
        try { $handler.Dispose() } catch { }
    }
}

function Protect-DisplayText {
    param(
        [AllowEmptyString()][string]$Text,
        [AllowEmptyString()][string]$ServerHost
    )
    if (-not $Text -or $script:IsAdminEdition) { return $Text }
    $protected = $Text
    $protected = [Text.RegularExpressions.Regex]::Replace(
        $protected,
        '(?i)https?://[^\s"''<>]+',
        '[hidden-url]'
    )
    $protected = [Text.RegularExpressions.Regex]::Replace(
        $protected,
        '(?<![\d.])(?:25[0-5]|2[0-4]\d|1?\d?\d)(?:\.(?:25[0-5]|2[0-4]\d|1?\d?\d)){3}(?![\d.])',
        '[hidden-ip]'
    )
    $protected = [Text.RegularExpressions.Regex]::Replace(
        $protected,
        '(?i)(?<![0-9a-f:])(?:[0-9a-f]{1,4}:){2,}[0-9a-f:]{1,4}(?![0-9a-f:])',
        '[hidden-ip]'
    )
    if ($ServerHost) {
        $protected = [Text.RegularExpressions.Regex]::Replace(
            $protected,
            [Text.RegularExpressions.Regex]::Escape($ServerHost),
            '[hidden-host]',
            [Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    }
    return $protected
}

function Format-ResponseBody {
    param(
        [string]$Body,
        [AllowEmptyString()][string]$ServerHost
    )
    if (-not $Body) { return "(empty response body)" }
    try {
        $formatted = $Body | ConvertFrom-Json | ConvertTo-Json -Depth 20
    }
    catch {
        $formatted = $Body
    }
    return Protect-DisplayText -Text $formatted -ServerHost $ServerHost
}

function ConvertTo-ApiPort {
    param([Parameter(Mandatory = $true)][string]$Text)
    $port = 0
    if (-not [int]::TryParse($Text.Trim(), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "API port must be an integer between 1 and 65535."
    }
    return $port
}

function Test-PalworldApiServerAddress {
    param([AllowEmptyString()][string]$Address)
    if (-not $Address) { return $false }
    $candidate = $Address.Trim()
    if ($candidate -notmatch '^(?i)https?://') {
        $candidate = "http://$candidate"
    }
    if ($candidate -match '^(?i)https?://(?:\[[^\]]+\]|[^/:?#]+):\d+/?$') {
        return $false
    }
    $parsed = $null
    if (-not [Uri]::TryCreate($candidate, [UriKind]::Absolute, [ref]$parsed)) {
        return $false
    }
    return (
        $parsed.Scheme -in @("http", "https") -and
        [string]$parsed.Host -and
        -not $parsed.UserInfo -and
        $parsed.AbsolutePath -eq "/" -and
        -not $parsed.Query -and
        -not $parsed.Fragment
    )
}

function Get-PalworldApiUri {
    param(
        [Parameter(Mandatory = $true)][string]$ServerAddress,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$PathAndQuery
    )
    if (-not (Test-PalworldApiServerAddress -Address $ServerAddress)) {
        throw "Server API address must be a host/IP or an http:// or https:// URL without a path or port."
    }
    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "API port must be an integer between 1 and 65535."
    }
    if (-not $PathAndQuery.StartsWith("/")) {
        throw "Server API endpoint path must start with /."
    }
    $candidate = $ServerAddress.Trim()
    if ($candidate -notmatch '^(?i)https?://') {
        $candidate = "http://$candidate"
    }
    $address = [Uri]$candidate
    $builder = New-Object UriBuilder($address.Scheme, $address.Host, $Port)
    return ([Uri]::new($builder.Uri, $PathAndQuery)).AbsoluteUri
}

if ($env:PALWORLD_CLIENT_TEST_MODE -eq "api-uri") {
    $plainUri = [Uri](Get-PalworldApiUri `
        -ServerAddress "192.0.2.10" -Port 39472 -PathAndQuery "/v1/api/info")
    if ($plainUri.Scheme -ne "http" -or $plainUri.Host -ne "192.0.2.10" -or
        $plainUri.Port -ne 39472 -or $plainUri.AbsolutePath -ne "/v1/api/info") {
        throw "A plain Server API host did not retain the backward-compatible HTTP endpoint."
    }
    $tlsUri = [Uri](Get-PalworldApiUri `
        -ServerAddress "https://gateway.example" `
        -Port 8443 `
        -PathAndQuery "/v1/manager/resources/history?seconds=60&points=10")
    if ($tlsUri.Scheme -ne "https" -or $tlsUri.Host -ne "gateway.example" -or
        $tlsUri.Port -ne 8443 -or $tlsUri.AbsolutePath -ne "/v1/manager/resources/history" -or
        $tlsUri.Query -ne "?seconds=60&points=10") {
        throw "A TLS Server API endpoint was not constructed correctly."
    }
    foreach ($invalidAddress in @(
        "https://gateway.example:443",
        "https://gateway.example/api",
        "https://user@gateway.example",
        "ftp://gateway.example"
    )) {
        if (Test-PalworldApiServerAddress -Address $invalidAddress) {
            throw "An invalid Server API address was accepted: $invalidAddress"
        }
    }
    $invalidPathRejected = $false
    try {
        [void](Get-PalworldApiUri `
            -ServerAddress "https://gateway.example" -Port 443 -PathAndQuery "v1/api/info")
    }
    catch { $invalidPathRejected = $true }
    if (-not $invalidPathRejected) {
        throw "A Server API endpoint path without a leading slash was accepted."
    }
    return
}

if ($script:IsAdminEdition) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;

public static class PalworldPortableConnectionCrypto
{
    private static readonly byte[] Magic = Encoding.ASCII.GetBytes("PWCONN01");
    private const int Iterations = 250000;

    private static byte[] RandomBytes(int count)
    {
        byte[] value = new byte[count];
        using (RandomNumberGenerator random = RandomNumberGenerator.Create())
        {
            random.GetBytes(value);
        }
        return value;
    }

    private static byte[] Derive(string password, byte[] salt)
    {
        using (Rfc2898DeriveBytes derive = new Rfc2898DeriveBytes(password, salt, Iterations))
        {
            return derive.GetBytes(64);
        }
    }

    private static bool Equal(byte[] left, byte[] right)
    {
        if (left == null || right == null || left.Length != right.Length) return false;
        int difference = 0;
        for (int index = 0; index < left.Length; index++) difference |= left[index] ^ right[index];
        return difference == 0;
    }

    public static byte[] Encrypt(string plaintext, string password)
    {
        if (String.IsNullOrEmpty(password)) throw new ArgumentException("Master password is required.");
        byte[] salt = RandomBytes(16);
        byte[] iv = RandomBytes(16);
        byte[] keys = Derive(password, salt);
        byte[] cipher;
        using (Aes aes = Aes.Create())
        {
            aes.KeySize = 256;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;
            byte[] encryptionKey = new byte[32];
            Array.Copy(keys, 0, encryptionKey, 0, 32);
            aes.Key = encryptionKey;
            aes.IV = iv;
            using (MemoryStream output = new MemoryStream())
            using (CryptoStream crypto = new CryptoStream(output, aes.CreateEncryptor(), CryptoStreamMode.Write))
            {
                byte[] plain = Encoding.UTF8.GetBytes(plaintext);
                crypto.Write(plain, 0, plain.Length);
                crypto.FlushFinalBlock();
                cipher = output.ToArray();
            }
        }

        byte[] authenticated = new byte[Magic.Length + salt.Length + iv.Length + cipher.Length];
        int offset = 0;
        Array.Copy(Magic, 0, authenticated, offset, Magic.Length); offset += Magic.Length;
        Array.Copy(salt, 0, authenticated, offset, salt.Length); offset += salt.Length;
        Array.Copy(iv, 0, authenticated, offset, iv.Length); offset += iv.Length;
        Array.Copy(cipher, 0, authenticated, offset, cipher.Length);
        byte[] authenticationKey = new byte[32];
        Array.Copy(keys, 32, authenticationKey, 0, 32);
        byte[] tag;
        using (HMACSHA256 hmac = new HMACSHA256(authenticationKey))
        {
            tag = hmac.ComputeHash(authenticated);
        }
        byte[] result = new byte[authenticated.Length + tag.Length];
        Array.Copy(authenticated, result, authenticated.Length);
        Array.Copy(tag, 0, result, authenticated.Length, tag.Length);
        Array.Clear(keys, 0, keys.Length);
        return result;
    }

    public static string Decrypt(byte[] value, string password)
    {
        if (value == null || value.Length < 88) throw new CryptographicException("Invalid connection store.");
        byte[] magic = new byte[Magic.Length];
        Array.Copy(value, 0, magic, 0, magic.Length);
        if (!Equal(magic, Magic)) throw new CryptographicException("Invalid connection store.");
        byte[] salt = new byte[16];
        byte[] iv = new byte[16];
        Array.Copy(value, Magic.Length, salt, 0, 16);
        Array.Copy(value, Magic.Length + 16, iv, 0, 16);
        int cipherLength = value.Length - Magic.Length - 16 - 16 - 32;
        byte[] cipher = new byte[cipherLength];
        Array.Copy(value, Magic.Length + 32, cipher, 0, cipherLength);
        byte[] suppliedTag = new byte[32];
        Array.Copy(value, value.Length - 32, suppliedTag, 0, 32);
        byte[] keys = Derive(password, salt);
        byte[] authenticationKey = new byte[32];
        Array.Copy(keys, 32, authenticationKey, 0, 32);
        byte[] expectedTag;
        using (HMACSHA256 hmac = new HMACSHA256(authenticationKey))
        {
            expectedTag = hmac.ComputeHash(value, 0, value.Length - 32);
        }
        if (!Equal(suppliedTag, expectedTag))
        {
            Array.Clear(keys, 0, keys.Length);
            throw new CryptographicException("Incorrect master password or damaged connection store.");
        }
        byte[] plain;
        using (Aes aes = Aes.Create())
        {
            aes.KeySize = 256;
            aes.Mode = CipherMode.CBC;
            aes.Padding = PaddingMode.PKCS7;
            byte[] encryptionKey = new byte[32];
            Array.Copy(keys, 0, encryptionKey, 0, 32);
            aes.Key = encryptionKey;
            aes.IV = iv;
            using (MemoryStream input = new MemoryStream(cipher))
            using (CryptoStream crypto = new CryptoStream(input, aes.CreateDecryptor(), CryptoStreamMode.Read))
            using (MemoryStream output = new MemoryStream())
            {
                crypto.CopyTo(output);
                plain = output.ToArray();
            }
        }
        Array.Clear(keys, 0, keys.Length);
        return Encoding.UTF8.GetString(plain);
    }
}
'@
}

$script:AdminConnectionsDisplayName = "Palworld Server Operations - Admin.connections"
$script:AdminConnectionsFile = if ($env:PALWORLD_CLIENT_TEST_CONNECTIONS_FILE) {
    [IO.Path]::GetFullPath($env:PALWORLD_CLIENT_TEST_CONNECTIONS_FILE)
}
else {
    Join-Path `
        $script:ClientBaseDirectory `
        $script:AdminConnectionsDisplayName
}
$script:AdminConnections = @()
$script:AdminSelectedId = ""
$script:AdminSshConnections = @()
$script:AdminSelectedSshId = ""
$script:AdminSelectionSyncing = $false
$script:AdminNoApiSelectionText = Get-PalworldLocalizedText `
    "— No Server API selected —" `
    "— Server API 선택 없음 —"
$script:AdminApiCombo = $null
$script:AdminSelectApiConnection = $null
$script:AdminRefreshApiConnections = $null
$script:AdminMasterPassword = ""
$script:AdminPersistenceEnabled = $true
$script:AdminLastSavedStoreHash = ""
$script:AdminStoreWriteCount = 0
$script:ResourceUsageFooter = $null
$script:ProjectStatusStrip = $null
$script:ProjectRepositoryLink = $null
$script:ProjectLicenseLink = $null
$script:ProjectMaintainerLink = $null
$script:ResourceUsageServerCombo = $null
$script:ResourceUsageServerChanging = $false
$script:ResourceUsageHostCpu = $null
$script:ResourceUsageHostMemory = $null
$script:ResourceUsageHostReceive = $null
$script:ResourceUsageHostTransmit = $null
$script:ResourceUsageContainerCpu = $null
$script:ResourceUsageContainerMemory = $null
$script:ResourceUsageContainerReceive = $null
$script:ResourceUsageContainerTransmit = $null
$script:ResourceUsageHostHistoryButton = $null
$script:ResourceUsageContainerHistoryButton = $null
$script:ResourceUsageRefreshContext = $null
$script:ResourceUsageTimer = $null
$script:ResourceUsagePollTick = $null
$script:ResourceUsageTimerTick = $null
$script:ResourceUsageClient = $null
$script:ResourceUsagePending = $null
$script:PalworldServerApiSetSshOperationState = $null
$script:ResourceUsageContextGeneration = 0
$script:ResourceUsageClosing = $false
$script:ResourceUsageNextRequestUtc = [DateTime]::MinValue
$script:ResourceUsageFailureCount = 0
$script:ResourceUsageBlockedContextKey = ""
$script:ResourceUsageToolTip = $null

function New-AdminConnection {
    param(
        [string]$Name = "",
        [string]$ServerHost = "",
        [int]$Port = 8212,
        [string]$Username = "admin",
        [string]$Password = "",
        [string]$AccessToken = "",
        [string]$SshConnectionId = "",
        [string]$ManagedServerName = ""
    )
    return [pscustomobject]@{
        Id = [Guid]::NewGuid().ToString("N")
        Name = $Name
        ServerHost = $ServerHost
        Port = $Port
        Username = $Username
        Password = $Password
        AccessToken = $AccessToken
        SshConnectionId = $SshConnectionId
        ManagedServerName = $ManagedServerName
    }
}

function Set-ActiveAdminConnection {
    param([AllowNull()]$Connection)
    if ($null -eq $Connection) {
        $script:AdminSelectedId = ""
        $script:ConnectionSettings = [pscustomobject]@{
            ServerHost = ""
            Port = 8212
            Username = "admin"
            Password = ""
            AccessToken = ""
        }
        return
    }
    $script:AdminSelectedId = [string]$Connection.Id
    $script:ConnectionSettings = [pscustomobject]@{
        ServerHost = [string]$Connection.ServerHost
        Port = [int]$Connection.Port
        Username = [string]$Connection.Username
        Password = [string]$Connection.Password
        AccessToken = [string]$Connection.AccessToken
    }
}

if ($script:IsAdminEdition) {
    $sshModulePath = if ($env:PALWORLD_SSH_MODULE_PATH) {
        [IO.Path]::GetFullPath($env:PALWORLD_SSH_MODULE_PATH)
    }
    else {
        [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\windows-ssh-manager\palworld-ssh-management.ps1"))
    }
    if (-not (Test-Path -LiteralPath $sshModulePath -PathType Leaf)) {
        throw "SSH Management module is missing. Rebuild Palworld Server Operations - Admin.exe."
    }
    . $sshModulePath
}

function Get-AdminConnectionStorePayload {
    return [ordered]@{
        Version = 4
        SelectedId = $script:AdminSelectedId
        Connections = @($script:AdminConnections)
        SelectedSshId = $script:AdminSelectedSshId
        SshConnections = @($script:AdminSshConnections)
    } | ConvertTo-Json -Depth 8 -Compress
}

function Get-AdminConnectionStorePayloadHash {
    param([Parameter(Mandatory = $true)][string]$Payload)
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Payload)
        return [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace("-", "")
    }
    finally { $sha.Dispose() }
}

function Save-AdminConnectionStore {
    param([switch]$Force)
    if (-not $script:AdminPersistenceEnabled) { return }
    $payload = Get-AdminConnectionStorePayload
    $payloadHash = Get-AdminConnectionStorePayloadHash $payload
    if (-not $Force -and $script:AdminLastSavedStoreHash -eq $payloadHash) { return }
    $encrypted = [PalworldPortableConnectionCrypto]::Encrypt(
        $payload,
        $script:AdminMasterPassword
    )
    $temporary = "$($script:AdminConnectionsFile).tmp"
    [IO.File]::WriteAllBytes($temporary, $encrypted)
    Move-Item -LiteralPath $temporary -Destination $script:AdminConnectionsFile -Force
    $script:AdminLastSavedStoreHash = $payloadHash
    $script:AdminStoreWriteCount++
}

function Load-AdminConnectionStore {
    $encrypted = [IO.File]::ReadAllBytes($script:AdminConnectionsFile)
    $plaintext = [PalworldPortableConnectionCrypto]::Decrypt(
        $encrypted,
        $script:AdminMasterPassword
    )
    $saved = $plaintext | ConvertFrom-Json
    $storeVersion = [int]$saved.Version
    if ($storeVersion -notin @(1, 2, 3, 4)) { throw "Unsupported connection store version." }
    $storeNeedsSave = $storeVersion -ne 4
    $loaded = @()
    foreach ($item in @($saved.Connections)) {
        $port = ConvertTo-ApiPort ([string]$item.Port)
        $loaded += [pscustomobject]@{
            Id = if ([string]$item.Id) { [string]$item.Id } else { [Guid]::NewGuid().ToString("N") }
            Name = [string]$item.Name
            ServerHost = [string]$item.ServerHost
            Port = $port
            Username = [string]$item.Username
            Password = [string]$item.Password
            AccessToken = [string]$item.AccessToken
            SshConnectionId = if ($storeVersion -ge 2) { [string]$item.SshConnectionId } else { "" }
            ManagedServerName = if ($storeVersion -ge 4 -and
                [string]$item.ManagedServerName -match '^server[1-9][0-9]*$') {
                [string]$item.ManagedServerName
            }
            else { "" }
        }
    }
    $script:AdminConnections = @(
        $loaded | Where-Object {
            -not (
                $_.Name -eq "Default" -and
                $_.ServerHost -eq "127.0.0.1" -and
                $_.Port -eq 8212 -and
                $_.Username -eq "admin" -and
                -not $_.Password -and
                -not $_.AccessToken
            )
        }
    )
    $script:AdminSelectedId = [string]$saved.SelectedId
    $script:AdminSshConnections = @()
    if ($storeVersion -ge 2) {
        foreach ($item in @($saved.SshConnections)) {
            $sshPort = 0
            if (
                -not [int]::TryParse([string]$item.Port, [ref]$sshPort) -or
                $sshPort -lt 1 -or
                $sshPort -gt 65535
            ) {
                throw "SSH port must be an integer between 1 and 65535."
            }
            $authMode = [string]$item.AuthMode
            if ($authMode -notin @("Password", "PrivateKey")) { $authMode = "Password" }
            $workDirectory = [string]$item.WorkDirectory
            if (-not $workDirectory) { $workDirectory = "~/palworld-docker" }
            $lastSelectedServer = [string]$item.LastSelectedServer
            if ($lastSelectedServer -notmatch '^server[1-9][0-9]*$') { $lastSelectedServer = "" }
            if ($item.PSObject.Properties.Name -notcontains "LastSelectedServer") {
                $storeNeedsSave = $true
            }
            $script:AdminSshConnections += [pscustomobject]@{
                Id = if ([string]$item.Id) { [string]$item.Id } else { [Guid]::NewGuid().ToString("N") }
                Name = [string]$item.Name
                Host = [string]$item.Host
                Port = $sshPort
                Username = [string]$item.Username
                AuthMode = $authMode
                Password = [string]$item.Password
                PrivateKeyPath = [string]$item.PrivateKeyPath
                PrivateKeyPassphrase = [string]$item.PrivateKeyPassphrase
                SudoPassword = [string]$item.SudoPassword
                WorkDirectory = $workDirectory
                HostKeyFingerprint = [string]$item.HostKeyFingerprint
                LastUsedApiConnectionId = if ($storeVersion -ge 3) {
                    [string]$item.LastUsedApiConnectionId
                }
                else { "" }
                LastSelectedServer = $lastSelectedServer
            }
        }
        $script:AdminSelectedSshId = [string]$saved.SelectedSshId
    }
    $sshIds = @{}
    foreach ($ssh in $script:AdminSshConnections) { $sshIds[[string]$ssh.Id] = $true }
    foreach ($api in $script:AdminConnections) {
        if ([string]$api.SshConnectionId -and -not $sshIds.ContainsKey([string]$api.SshConnectionId)) {
            $api.SshConnectionId = ""
            $storeNeedsSave = $true
        }
    }
    foreach ($ssh in $script:AdminSshConnections) {
        $linkedApis = @(
            $script:AdminConnections | Where-Object {
                [string]$_.SshConnectionId -eq [string]$ssh.Id
            }
        )
        $recent = $linkedApis | Where-Object {
            [string]$_.Id -eq [string]$ssh.LastUsedApiConnectionId
        } | Select-Object -First 1
        if ($null -eq $recent) {
            $selectedLinked = $linkedApis | Where-Object {
                [string]$_.Id -eq [string]$script:AdminSelectedId
            } | Select-Object -First 1
            $replacement = if ($selectedLinked) { $selectedLinked } elseif ($linkedApis.Count) { $linkedApis[0] } else { $null }
            $replacementId = if ($replacement) { [string]$replacement.Id } else { "" }
            if ([string]$ssh.LastUsedApiConnectionId -ne $replacementId) {
                $ssh.LastUsedApiConnectionId = $replacementId
                $storeNeedsSave = $true
            }
        }
    }
    $selected = $script:AdminConnections |
        Where-Object { $_.Id -eq $script:AdminSelectedId } |
        Select-Object -First 1
    if ($null -eq $selected -and $storeVersion -lt 3 -and $script:AdminConnections.Count -gt 0) {
        $selected = $script:AdminConnections[0]
        $script:AdminSelectedId = [string]$selected.Id
        $storeNeedsSave = $true
    }
    elseif ($null -eq $selected) {
        if ($script:AdminSelectedId) { $storeNeedsSave = $true }
        $script:AdminSelectedId = ""
    }
    $savedSelectedSshId = [string]$script:AdminSelectedSshId
    $selectedSsh = $script:AdminSshConnections |
        Where-Object { $_.Id -eq $script:AdminSelectedSshId } |
        Select-Object -First 1
    $selectedSshWasInvalid = [bool]$savedSelectedSshId -and $null -eq $selectedSsh
    if ($null -eq $selectedSsh) {
        if ($script:AdminSelectedSshId) { $storeNeedsSave = $true }
        $script:AdminSelectedSshId = ""
    }
    if ($selected -and ($storeVersion -lt 3 -or $script:AdminSelectedSshId -or $selectedSshWasInvalid)) {
        $linkedSsh = $script:AdminSshConnections |
            Where-Object { $_.Id -eq [string]$selected.SshConnectionId } |
            Select-Object -First 1
        $coherentSshId = if ($linkedSsh) { [string]$linkedSsh.Id } else { "" }
        if ($script:AdminSelectedSshId -ne $coherentSshId) {
            $script:AdminSelectedSshId = $coherentSshId
            $storeNeedsSave = $true
        }
    }
    Set-ActiveAdminConnection $selected
    if ($storeVersion -eq 1) {
        $backupPath = "$($script:AdminConnectionsFile).v1.backup"
        if (-not (Test-Path -LiteralPath $backupPath)) {
            Copy-Item -LiteralPath $script:AdminConnectionsFile -Destination $backupPath
        }
    }
    if ($storeNeedsSave -or $loaded.Count -ne $script:AdminConnections.Count) {
        Save-AdminConnectionStore -Force
    }
    else {
        $script:AdminLastSavedStoreHash = Get-AdminConnectionStorePayloadHash `
            (Get-AdminConnectionStorePayload)
    }
}

function Show-MasterPasswordDialog {
    param([bool]$CreateNew)
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = if ($CreateNew) {
        Get-PalworldLocalizedText "Create admin master password" "관리자 마스터 비밀번호 생성"
    }
    else {
        Get-PalworldLocalizedText "Unlock admin connections" "관리자 연결 잠금 해제"
    }
    $dialog.StartPosition = "CenterScreen"
    $dialog.ClientSize = New-Object System.Drawing.Size(460, $(if ($CreateNew) { 205 } else { 155 }))
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog

    $description = New-Object System.Windows.Forms.Label
    $description.Text = if ($CreateNew) {
        Get-PalworldLocalizedText `
            "This password encrypts $($script:AdminConnectionsDisplayName).`r`nUse the same password after copying it to another PC." `
            "이 비밀번호는 $($script:AdminConnectionsDisplayName) 파일을 암호화합니다.`r`n다른 PC로 복사한 뒤에도 같은 비밀번호를 사용하세요."
    }
    else {
        Get-PalworldLocalizedText `
            "Enter the master password for $($script:AdminConnectionsDisplayName)." `
            "$($script:AdminConnectionsDisplayName)의 마스터 비밀번호를 입력하세요."
    }
    $description.Location = New-Object System.Drawing.Point(16, 14)
    $description.Size = New-Object System.Drawing.Size(425, 42)
    $dialog.Controls.Add($description)

    $password = New-Object System.Windows.Forms.TextBox
    $password.Location = New-Object System.Drawing.Point(16, 61)
    $password.Size = New-Object System.Drawing.Size(425, 23)
    $password.UseSystemPasswordChar = $true
    $dialog.Controls.Add($password)

    $confirm = $null
    if ($CreateNew) {
        $confirmLabel = New-Object System.Windows.Forms.Label
        $confirmLabel.Text = "Confirm master password"
        $confirmLabel.Location = New-Object System.Drawing.Point(16, 93)
        $confirmLabel.AutoSize = $true
        $dialog.Controls.Add($confirmLabel)
        $confirm = New-Object System.Windows.Forms.TextBox
        $confirm.Location = New-Object System.Drawing.Point(16, 116)
        $confirm.Size = New-Object System.Drawing.Size(425, 23)
        $confirm.UseSystemPasswordChar = $true
        $dialog.Controls.Add($confirm)
    }

    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = "Cancel"
    $cancel.Location = New-Object System.Drawing.Point(261, $(if ($CreateNew) { 158 } else { 108 }))
    $cancel.Size = New-Object System.Drawing.Size(85, 30)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancel)

    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = if ($CreateNew) {
        Get-PalworldLocalizedText "Create" "생성"
    }
    else {
        Get-PalworldLocalizedText "Unlock" "잠금 해제"
    }
    $ok.Location = New-Object System.Drawing.Point(356, $(if ($CreateNew) { 158 } else { 108 }))
    $ok.Size = New-Object System.Drawing.Size(85, 30)
    $ok.Add_Click({
        if ($password.Text.Length -lt 8) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "Use a master password with at least 8 characters." `
                    "마스터 비밀번호는 8자 이상으로 입력하세요."),
                (Get-PalworldLocalizedText "Master password" "마스터 비밀번호")
            )
            return
        }
        if ($CreateNew -and $password.Text -ne $confirm.Text) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "The master passwords do not match." `
                    "마스터 비밀번호가 서로 일치하지 않습니다."),
                (Get-PalworldLocalizedText "Master password" "마스터 비밀번호")
            )
            return
        }
        $dialog.Tag = $password.Text
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $dialog.Controls.Add($ok)
    $dialog.AcceptButton = $ok
    $dialog.CancelButton = $cancel
    try {
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return [string]$dialog.Tag
        }
        return $null
    }
    finally {
        $dialog.Dispose()
    }
}

function Initialize-AdminConnectionStore {
    if ($env:PALWORLD_CLIENT_TEST_MODE) {
        $script:AdminPersistenceEnabled = $false
        $script:AdminMasterPassword = "test-master-password"
        if ($env:PALWORLD_CLIENT_TEST_MODE -eq "admin-empty") {
            $script:AdminConnections = @()
            $script:AdminSshConnections = @()
            Set-ActiveAdminConnection $null
        }
        else {
            $script:AdminConnections = @(
                New-AdminConnection -Name "Test server" -Password "test-password"
            )
            $script:AdminSshConnections = @()
            Set-ActiveAdminConnection $script:AdminConnections[0]
        }
        return
    }

    if (Test-Path -LiteralPath $script:AdminConnectionsFile) {
        while ($true) {
            $entered = Show-MasterPasswordDialog -CreateNew $false
            if ($null -eq $entered) { exit 0 }
            $script:AdminMasterPassword = $entered
            try {
                Load-AdminConnectionStore
                return
            }
            catch {
                [void][System.Windows.Forms.MessageBox]::Show(
                    (Get-PalworldLocalizedText `
                        "The master password is incorrect or the connections file is damaged." `
                        "마스터 비밀번호가 틀렸거나 연결 파일이 손상되었습니다."),
                    (Get-PalworldLocalizedText "Connection store error" "연결 저장소 오류"),
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error
                )
            }
        }
    }

    $entered = Show-MasterPasswordDialog -CreateNew $true
    if ($null -eq $entered) { exit 0 }
    $script:AdminMasterPassword = $entered
    $script:AdminConnections = @()
    $script:AdminSshConnections = @()
    Set-ActiveAdminConnection $null
    try {
        Save-AdminConnectionStore
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            (Get-PalworldLocalizedText `
                ("The encrypted connections file could not be created next to the EXE. " +
                    "Move the program to a writable folder and try again.`r`n`r`n$($_.Exception.Message)") `
                ("EXE 옆에 암호화 연결 파일을 생성하지 못했습니다. " +
                    "프로그램을 쓰기 가능한 폴더로 옮긴 뒤 다시 시도하세요.`r`n`r`n$($_.Exception.Message)")),
            (Get-PalworldLocalizedText "Connection store error" "연결 저장소 오류"),
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
        exit 1
    }
}

$script:SettingsDirectory = $script:ApplicationPreferencesDirectory
$script:SettingsFile = Join-Path $script:SettingsDirectory "settings.json"
$script:SettingsLoadWarning = $null
$script:SettingsNeedsMigration = $false

function ConvertTo-PlainText {
    param([Parameter(Mandatory = $true)][Security.SecureString]$SecureValue)
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

function ConvertTo-ProtectedText {
    param([AllowEmptyString()][string]$Value)
    if (-not $Value) { return "" }
    $secureValue = ConvertTo-SecureString $Value -AsPlainText -Force
    return ConvertFrom-SecureString $secureValue
}

function ConvertFrom-ProtectedText {
    param([Parameter(Mandatory = $true)][string]$Value)
    $secureValue = ConvertTo-SecureString $Value -ErrorAction Stop
    return ConvertTo-PlainText $secureValue
}

function Get-ClientSettings {
    $serverHost = "127.0.0.1"
    $port = 8212
    $username = "admin"
    $password = ""
    $accessToken = ""
    if (-not (Test-Path -LiteralPath $script:SettingsFile)) {
        return [pscustomobject]@{
            ServerHost = $serverHost; Port = $port; Username = $username
            Password = $password; AccessToken = $accessToken
        }
    }

    try {
        $saved = Get-Content -LiteralPath $script:SettingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$saved.EncryptedServerHost) {
            $serverHost = ConvertFrom-ProtectedText ([string]$saved.EncryptedServerHost)
        }
        elseif ([string]$saved.ServerHost) {
            $serverHost = [string]$saved.ServerHost
            $script:SettingsNeedsMigration = $true
        }
        if ([string]$saved.EncryptedUsername) {
            $username = ConvertFrom-ProtectedText ([string]$saved.EncryptedUsername)
        }
        elseif ([string]$saved.Username) {
            $username = [string]$saved.Username
            $script:SettingsNeedsMigration = $true
        }
        $loadedPort = 0
        if (
            [int]::TryParse([string]$saved.Port, [ref]$loadedPort) -and
            $loadedPort -ge 1 -and
            $loadedPort -le 65535
        ) {
            $port = $loadedPort
        }
        if ([string]$saved.EncryptedPassword) {
            try {
                $password = ConvertFrom-ProtectedText ([string]$saved.EncryptedPassword)
            }
            catch {
                $script:SettingsLoadWarning = "The saved password belongs to another Windows user or cannot be decrypted. Enter it again."
            }
        }
        if ([string]$saved.EncryptedAccessToken) {
            try {
                $accessToken = ConvertFrom-ProtectedText ([string]$saved.EncryptedAccessToken)
            }
            catch {
                $script:SettingsLoadWarning = "The saved API token belongs to another Windows user or cannot be decrypted. Enter it again."
            }
        }
    }
    catch {
        $script:SettingsLoadWarning = "Saved settings could not be read. First-run defaults were loaded."
    }
    return [pscustomobject]@{
        ServerHost = $serverHost; Port = $port; Username = $username
        Password = $password; AccessToken = $accessToken
    }
}

function Save-ClientSettings {
    param(
        [Parameter(Mandatory = $true)][string]$ServerHost,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Username,
        [AllowEmptyString()][string]$Password,
        [AllowEmptyString()][string]$AccessToken
    )
    if (-not (Test-Path -LiteralPath $script:SettingsDirectory)) {
        [void](New-Item -ItemType Directory -Path $script:SettingsDirectory -Force)
    }
    $settings = [ordered]@{
        EncryptedServerHost = ConvertTo-ProtectedText $ServerHost
        Port = $Port
        EncryptedUsername = ConvertTo-ProtectedText $Username
        EncryptedPassword = ConvertTo-ProtectedText $Password
        EncryptedAccessToken = ConvertTo-ProtectedText $AccessToken
    }
    $temporaryFile = "$($script:SettingsFile).tmp"
    $settings | ConvertTo-Json | Set-Content -LiteralPath $temporaryFile -Encoding UTF8
    Move-Item -LiteralPath $temporaryFile -Destination $script:SettingsFile -Force
}

if ($script:IsAdminEdition) {
    Initialize-AdminConnectionStore
    if ($env:PALWORLD_CLIENT_TEST_MODE -eq "crypto") {
        $testPayload = '{"host":"203.0.113.10","password":"portable-test"}'
        $testPassword = "test-master-password"
        $encrypted = [PalworldPortableConnectionCrypto]::Encrypt($testPayload, $testPassword)
        $decrypted = [PalworldPortableConnectionCrypto]::Decrypt($encrypted, $testPassword)
        if ($decrypted -ne $testPayload) { throw "Portable connection encryption round-trip failed" }
        $rejected = $false
        try {
            [void][PalworldPortableConnectionCrypto]::Decrypt($encrypted, "incorrect-password")
        }
        catch {
            $rejected = $true
        }
        if (-not $rejected) { throw "Portable connection encryption accepted an incorrect password" }
        $script:AdminPersistenceEnabled = $true
        $script:AdminLastSavedStoreHash = Get-AdminConnectionStorePayloadHash `
            (Get-AdminConnectionStorePayload)
        $writesBeforeNoOp = $script:AdminStoreWriteCount
        Save-AdminConnectionStore
        if ($script:AdminStoreWriteCount -ne $writesBeforeNoOp) {
            throw "An unchanged admin connection store performed encryption or a file write"
        }
        $script:AdminPersistenceEnabled = $false
        return
    }
}
else {
    $loadedSettings = Get-ClientSettings
    if ($script:SettingsNeedsMigration) {
        try {
            Save-ClientSettings `
                -ServerHost $loadedSettings.ServerHost `
                -Port $loadedSettings.Port `
                -Username $loadedSettings.Username `
                -Password $loadedSettings.Password `
                -AccessToken $loadedSettings.AccessToken
        }
        catch {
            $script:SettingsLoadWarning = "Legacy connection settings were loaded but could not be protected. Open Connection Settings and save again."
        }
    }
    $script:ConnectionSettings = [pscustomobject]@{
        ServerHost = [string]$loadedSettings.ServerHost
        Port = [int]$loadedSettings.Port
        Username = [string]$loadedSettings.Username
        Password = [string]$loadedSettings.Password
        AccessToken = [string]$loadedSettings.AccessToken
    }
}

$script:UserConnectionVerified = $script:IsAdminEdition
$script:VerifiedInstance = ""

function New-VerificationChallenge {
    $bytes = New-Object byte[] 32
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $random.GetBytes($bytes)
    }
    finally {
        $random.Dispose()
    }
    return [BitConverter]::ToString($bytes).Replace("-", "").ToLowerInvariant()
}

function Get-VerificationProof {
    param(
        [Parameter(Mandatory = $true)][string]$AccessToken,
        [Parameter(Mandatory = $true)][string]$Challenge
    )
    $message = "palworld-docker-manager:1:$Challenge"
    $hmac = New-Object Security.Cryptography.HMACSHA256
    try {
        $hmac.Key = [Text.Encoding]::UTF8.GetBytes($AccessToken)
        $proof = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($message))
        return [BitConverter]::ToString($proof).Replace("-", "").ToLowerInvariant()
    }
    finally {
        $hmac.Dispose()
    }
}

function Test-ManagedServerConnection {
    $settings = $script:ConnectionSettings
    if (
        -not $settings.ServerHost -or
        -not $settings.Username -or
        -not $settings.Password -or
        [string]$settings.AccessToken -notmatch '^[A-Za-z0-9_-]{32,128}$'
    ) {
        return [pscustomobject]@{
            Success = $false
            Message = Get-PalworldLocalizedText `
                "Enter the AdminPassword and API token in Connection Settings." `
                "Connection Settings에 관리자 비밀번호와 API access token을 입력하세요."
            Instance = ""
        }
    }
    $challenge = New-VerificationChallenge
    $uri = Get-PalworldApiUri `
        -ServerAddress ([string]$settings.ServerHost) `
        -Port ([int]$settings.Port) `
        -PathAndQuery "/v1/manager/verify?challenge=$challenge"
    try {
        $result = Invoke-PalworldRequest `
            -Uri $uri `
            -Method "GET" `
            -Username $settings.Username `
            -Password $settings.Password `
            -AccessToken $settings.AccessToken `
            -TimeoutSeconds 15
        if (-not $result.Success) {
            $message = switch ($result.StatusCode) {
                401 { Get-PalworldLocalizedText "Admin account or password verification failed" "관리자 계정 또는 비밀번호 검증 실패" }
                403 { Get-PalworldLocalizedText "API token verification failed" "API access token 검증 실패" }
                default {
                    Get-PalworldLocalizedText `
                        "This is not a verified project server, or its verification API is unavailable." `
                        "검증된 .run 서버가 아니거나 검증 API를 사용할 수 없습니다."
                }
            }
            return [pscustomobject]@{ Success = $false; Message = $message; Instance = "" }
        }
        $payload = $result.Body | ConvertFrom-Json
        $expectedProof = Get-VerificationProof `
            -AccessToken $settings.AccessToken `
            -Challenge $challenge
        $valid = (
            [string]$payload.product -eq "palworld-docker-manager" -and
            [int]$payload.protocol -eq 1 -and
            $payload.token_verified -eq $true -and
            [string]$payload.challenge -eq $challenge -and
            [string]$payload.proof -ceq $expectedProof
        )
        if (-not $valid) {
            return [pscustomobject]@{
                Success = $false
                Message = Get-PalworldLocalizedText `
                    "Server and token challenge verification failed" `
                    "서버·토큰 challenge 응답 검증 실패"
                Instance = ""
            }
        }
        return [pscustomobject]@{
            Success = $true
            Message = Get-PalworldLocalizedText "Verification complete" "검증 완료"
            Instance = [string]$payload.instance
        }
    }
    catch {
        return [pscustomobject]@{
            Success = $false
            Message = Get-PalworldLocalizedText `
                "Could not connect to a verified project server." `
                "검증된 .run 서버에 연결할 수 없습니다."
            Instance = ""
        }
    }
}

function Show-ConnectionSettingsDialog {
    param([System.Windows.Forms.IWin32Window]$Owner)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = "Connection Settings"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(520, 310)
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog

    $dialogHostLabel = New-Object System.Windows.Forms.Label
    $dialogHostLabel.Text = "Server URL / host"
    $dialogHostLabel.Location = New-Object System.Drawing.Point(18, 29)
    $dialogHostLabel.AutoSize = $true
    $dialog.Controls.Add($dialogHostLabel)

    $dialogHostText = New-Object System.Windows.Forms.TextBox
    $dialogHostText.Location = New-Object System.Drawing.Point(145, 25)
    $dialogHostText.Size = New-Object System.Drawing.Size(350, 23)
    $dialogHostText.Text = $script:ConnectionSettings.ServerHost
    $dialog.Controls.Add($dialogHostText)

    $dialogPortLabel = New-Object System.Windows.Forms.Label
    $dialogPortLabel.Text = "API port"
    $dialogPortLabel.Location = New-Object System.Drawing.Point(18, 69)
    $dialogPortLabel.AutoSize = $true
    $dialog.Controls.Add($dialogPortLabel)

    $dialogPortText = New-Object System.Windows.Forms.TextBox
    $dialogPortText.Location = New-Object System.Drawing.Point(145, 65)
    $dialogPortText.Size = New-Object System.Drawing.Size(120, 23)
    $dialogPortText.Text = [string]$script:ConnectionSettings.Port
    $dialog.Controls.Add($dialogPortText)

    $dialogUsernameLabel = New-Object System.Windows.Forms.Label
    $dialogUsernameLabel.Text = "API username"
    $dialogUsernameLabel.Location = New-Object System.Drawing.Point(18, 109)
    $dialogUsernameLabel.AutoSize = $true
    $dialog.Controls.Add($dialogUsernameLabel)

    $dialogUsernameText = New-Object System.Windows.Forms.TextBox
    $dialogUsernameText.Location = New-Object System.Drawing.Point(145, 105)
    $dialogUsernameText.Size = New-Object System.Drawing.Size(350, 23)
    $dialogUsernameText.Text = $script:ConnectionSettings.Username
    $dialog.Controls.Add($dialogUsernameText)

    $dialogPasswordLabel = New-Object System.Windows.Forms.Label
    $dialogPasswordLabel.Text = "AdminPassword"
    $dialogPasswordLabel.Location = New-Object System.Drawing.Point(18, 149)
    $dialogPasswordLabel.AutoSize = $true
    $dialog.Controls.Add($dialogPasswordLabel)

    $dialogPasswordText = New-Object System.Windows.Forms.TextBox
    $dialogPasswordText.Location = New-Object System.Drawing.Point(145, 145)
    $dialogPasswordText.Size = New-Object System.Drawing.Size(350, 23)
    $dialogPasswordText.UseSystemPasswordChar = $true
    $dialogPasswordText.Text = $script:ConnectionSettings.Password
    $dialog.Controls.Add($dialogPasswordText)

    $dialogTokenLabel = New-Object System.Windows.Forms.Label
    $dialogTokenLabel.Text = "API access token"
    $dialogTokenLabel.Location = New-Object System.Drawing.Point(18, 189)
    $dialogTokenLabel.AutoSize = $true
    $dialog.Controls.Add($dialogTokenLabel)

    $dialogTokenText = New-Object System.Windows.Forms.TextBox
    $dialogTokenText.Location = New-Object System.Drawing.Point(145, 185)
    $dialogTokenText.Size = New-Object System.Drawing.Size(350, 23)
    $dialogTokenText.UseSystemPasswordChar = $true
    $dialogTokenText.Text = $script:ConnectionSettings.AccessToken
    $dialog.Controls.Add($dialogTokenText)

    $dialogShowPassword = New-Object System.Windows.Forms.CheckBox
    $dialogShowPassword.Text = "Show password and token"
    $dialogShowPassword.Location = New-Object System.Drawing.Point(145, 216)
    $dialogShowPassword.AutoSize = $true
    $dialogShowPassword.Add_CheckedChanged({
        $dialogPasswordText.UseSystemPasswordChar = -not $dialogShowPassword.Checked
        $dialogTokenText.UseSystemPasswordChar = -not $dialogShowPassword.Checked
    })
    $dialog.Controls.Add($dialogShowPassword)

    $dialogCancelButton = New-Object System.Windows.Forms.Button
    $dialogCancelButton.Text = "Cancel"
    $dialogCancelButton.Location = New-Object System.Drawing.Point(315, 260)
    $dialogCancelButton.Size = New-Object System.Drawing.Size(85, 30)
    $dialogCancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($dialogCancelButton)

    $dialogSaveButton = New-Object System.Windows.Forms.Button
    $dialogSaveButton.Text = "Save"
    $dialogSaveButton.Location = New-Object System.Drawing.Point(410, 260)
    $dialogSaveButton.Size = New-Object System.Drawing.Size(85, 30)
    $dialog.Controls.Add($dialogSaveButton)

    $dialogSaveButton.Add_Click({
        $serverHost = $dialogHostText.Text.Trim()
        $username = $dialogUsernameText.Text.Trim()
        $password = $dialogPasswordText.Text
        $accessToken = $dialogTokenText.Text.Trim()
        if (-not $serverHost) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText "Enter a server IP address or hostname." "서버 IP 또는 호스트 주소를 입력해 주세요."),
                (Get-PalworldLocalizedText "Input required" "입력 안내")
            )
            return
        }
        if (-not (Test-PalworldApiServerAddress -Address $serverHost)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "Enter a host/IP, or an http:// or https:// URL without a path. The API port is entered separately." `
                    "호스트/IP 또는 경로가 없는 http://·https:// URL을 입력하세요. API 포트는 별도로 입력합니다."),
                (Get-PalworldLocalizedText "Input required" "입력 안내")
            )
            return
        }
        if (-not $username -or -not $password) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "Enter the API username and AdminPassword." `
                    "API 사용자 이름과 관리자 비밀번호를 입력해 주세요."),
                (Get-PalworldLocalizedText "Input required" "입력 안내")
            )
            return
        }
        if ($accessToken -notmatch '^[A-Za-z0-9_-]{32,128}$') {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "Enter the 32-128 character API token from config/serverN.env." `
                    "config/serverN.env에 설정된 API 접근 토큰(32~128자)을 입력해 주세요."),
                (Get-PalworldLocalizedText "Input required" "입력 안내")
            )
            return
        }
        try {
            $apiPort = ConvertTo-ApiPort $dialogPortText.Text
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                (Get-PalworldLocalizedText "Check port" "포트 확인")
            )
            return
        }
        try {
            Save-ClientSettings `
                -ServerHost $serverHost `
                -Port $apiPort `
                -Username $username `
                -Password $password `
                -AccessToken $accessToken
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "Connection settings could not be saved. Try again." `
                    "연결 설정을 저장하지 못했습니다. 다시 시도해 주세요."),
                (Get-PalworldLocalizedText "Save error" "저장 오류"),
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
            return
        }
        $script:ConnectionSettings = [pscustomobject]@{
            ServerHost = $serverHost
            Port = $apiPort
            Username = $username
            Password = $password
            AccessToken = $accessToken
        }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })

    $dialog.AcceptButton = $dialogSaveButton
    $dialog.CancelButton = $dialogCancelButton
    Set-PalworldLocalizedControlTree -Control $dialog
    if ($env:PALWORLD_CLIENT_TEST_MODE -eq "settings") {
        $bitmap = New-Object System.Drawing.Bitmap(520, 310)
        try {
            $dialog.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, 520, 310)))
        }
        finally {
            $bitmap.Dispose()
            $dialog.Dispose()
        }
        return [System.Windows.Forms.DialogResult]::Cancel
    }
    try {
        return $dialog.ShowDialog($Owner)
    }
    finally {
        $dialog.Dispose()
    }
}

function Show-AdminConnectionDialog {
    param(
        [System.Windows.Forms.IWin32Window]$Owner,
        [ValidateSet("Add", "Update")][string]$Mode,
        [AllowNull()]$Connection
    )

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = if ($Mode -eq "Add") {
        Get-PalworldLocalizedText "Add Connection" "연결 추가"
    }
    else {
        Get-PalworldLocalizedText "Update Connection" "연결 수정"
    }
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(560, 495)
    $dialog.FormBorderStyle = "FixedDialog"
    $dialog.MaximizeBox = $false
    $dialog.MinimizeBox = $false
    $dialog.ShowInTaskbar = $false
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog

    $fields = @(
        @{ Label = (Get-PalworldLocalizedText "Name" "이름"); Y = 29 },
        @{ Label = (Get-PalworldLocalizedText "API URL / Host" "API URL / 호스트"); Y = 69 },
        @{ Label = (Get-PalworldLocalizedText "Port" "포트"); Y = 109 },
        @{ Label = (Get-PalworldLocalizedText "Username" "사용자명"); Y = 149 },
        @{ Label = (Get-PalworldLocalizedText "AdminPassword" "관리자 비밀번호"); Y = 189 },
        @{ Label = (Get-PalworldLocalizedText "API token" "API 토큰"); Y = 229 },
        @{ Label = (Get-PalworldLocalizedText "SSH Connection" "SSH 연결"); Y = 269 },
        @{ Label = (Get-PalworldLocalizedText "Managed Server" "관리 서버"); Y = 309 }
    )
    foreach ($field in $fields) {
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $field.Label
        $label.Location = New-Object System.Drawing.Point(18, $field.Y)
        $label.AutoSize = $true
        $dialog.Controls.Add($label)
    }

    $nameText = New-Object System.Windows.Forms.TextBox
    $nameText.Location = New-Object System.Drawing.Point(150, 25)
    $nameText.Size = New-Object System.Drawing.Size(385, 23)
    $dialog.Controls.Add($nameText)

    $hostText = New-Object System.Windows.Forms.TextBox
    $hostText.Location = New-Object System.Drawing.Point(150, 65)
    $hostText.Size = New-Object System.Drawing.Size(385, 23)
    $dialog.Controls.Add($hostText)

    $portText = New-Object System.Windows.Forms.TextBox
    $portText.Location = New-Object System.Drawing.Point(150, 105)
    $portText.Size = New-Object System.Drawing.Size(130, 23)
    $dialog.Controls.Add($portText)

    $usernameText = New-Object System.Windows.Forms.TextBox
    $usernameText.Location = New-Object System.Drawing.Point(150, 145)
    $usernameText.Size = New-Object System.Drawing.Size(385, 23)
    $dialog.Controls.Add($usernameText)

    $passwordText = New-Object System.Windows.Forms.TextBox
    $passwordText.Location = New-Object System.Drawing.Point(150, 185)
    $passwordText.Size = New-Object System.Drawing.Size(385, 23)
    $passwordText.UseSystemPasswordChar = $true
    $dialog.Controls.Add($passwordText)

    $tokenText = New-Object System.Windows.Forms.TextBox
    $tokenText.Location = New-Object System.Drawing.Point(150, 225)
    $tokenText.Size = New-Object System.Drawing.Size(385, 23)
    $tokenText.UseSystemPasswordChar = $true
    $dialog.Controls.Add($tokenText)

    $sshConnectionCombo = New-Object System.Windows.Forms.ComboBox
    $sshConnectionCombo.Name = "AdminApiSshConnectionCombo"
    $sshConnectionCombo.Location = New-Object System.Drawing.Point(150, 265)
    $sshConnectionCombo.Size = New-Object System.Drawing.Size(385, 23)
    $sshConnectionCombo.DropDownStyle = "DropDownList"
    [string[]]$sshConnectionIds = @()
    $sshConnectionIds += ""
    [void]$sshConnectionCombo.Items.Add(
        (Get-PalworldLocalizedText "— Not linked —" "— 연결 안 됨 —")
    )
    foreach ($sshConnection in @($script:AdminSshConnections)) {
        [void]$sshConnectionCombo.Items.Add([string]$sshConnection.Name)
        $sshConnectionIds += [string]$sshConnection.Id
    }
    $sshConnectionCombo.SelectedIndex = 0
    $dialog.Controls.Add($sshConnectionCombo)

    $managedServerText = New-Object System.Windows.Forms.TextBox
    $managedServerText.Location = New-Object System.Drawing.Point(150, 305)
    $managedServerText.Size = New-Object System.Drawing.Size(385, 23)
    $managedServerText.ReadOnly = $true
    $managedServerText.Text = if ($Connection -and [string]$Connection.ManagedServerName) {
        [string]$Connection.ManagedServerName
    }
    else { Get-PalworldLocalizedText "— Not mapped —" "— 매핑 안 됨 —" }
    $dialog.Controls.Add($managedServerText)

    $showSecrets = New-Object System.Windows.Forms.CheckBox
    $showSecrets.Text = "Show password and token"
    $showSecrets.Location = New-Object System.Drawing.Point(150, 340)
    $showSecrets.AutoSize = $true
    $showSecrets.Add_CheckedChanged({
        $passwordText.UseSystemPasswordChar = -not $showSecrets.Checked
        $tokenText.UseSystemPasswordChar = -not $showSecrets.Checked
    })
    $dialog.Controls.Add($showSecrets)

    $hint = New-Object System.Windows.Forms.Label
    $hint.Text = Get-PalworldLocalizedText `
        "API token: required for project-managed servers; leave blank only for ordinary Palworld REST servers." `
        "API 토큰: 이 프로젝트가 관리하는 서버에는 필수입니다. 일반 Palworld REST 서버만 비워 둘 수 있습니다."
    $hint.Location = New-Object System.Drawing.Point(18, 374)
    $hint.Size = New-Object System.Drawing.Size(517, 42)
    $dialog.Controls.Add($hint)

    if ($null -ne $Connection) {
        $nameText.Text = [string]$Connection.Name
        $hostText.Text = [string]$Connection.ServerHost
        $portText.Text = [string]$Connection.Port
        $usernameText.Text = [string]$Connection.Username
        $passwordText.Text = [string]$Connection.Password
        $tokenText.Text = [string]$Connection.AccessToken
        for ($sshIndex = 1; $sshIndex -lt $sshConnectionIds.Count; $sshIndex++) {
            if ($sshConnectionIds[$sshIndex] -eq [string]$Connection.SshConnectionId) {
                $sshConnectionCombo.SelectedIndex = $sshIndex
                break
            }
        }
    }
    else {
        $portText.Text = "8212"
        $usernameText.Text = "admin"
    }

    $cancelButton = New-Object System.Windows.Forms.Button
    $cancelButton.Text = "Cancel"
    $cancelButton.Location = New-Object System.Drawing.Point(355, 444)
    $cancelButton.Size = New-Object System.Drawing.Size(85, 30)
    $cancelButton.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $dialog.Controls.Add($cancelButton)

    $saveButton = New-Object System.Windows.Forms.Button
    $saveButton.Text = if ($Mode -eq "Add") { "Add" } else { "Update" }
    $saveButton.Location = New-Object System.Drawing.Point(450, 444)
    $saveButton.Size = New-Object System.Drawing.Size(85, 30)
    $saveButton.Add_Click({
        $name = $nameText.Text.Trim()
        $hostValue = $hostText.Text.Trim()
        $username = $usernameText.Text.Trim()
        $password = $passwordText.Text
        $accessToken = $tokenText.Text.Trim()
        if (-not $name) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText "Enter a Connection name." "연결 이름을 입력하세요."),
                (Get-PalworldLocalizedText "Missing setting" "설정 누락")
            )
            return
        }
        if (-not (Test-PalworldApiServerAddress -Address $hostValue)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "Enter a host/IP, or an http:// or https:// URL without a path. Enter the API port separately." `
                    "호스트/IP 또는 경로가 없는 http://·https:// URL을 입력하세요. API 포트는 별도로 입력합니다."),
                (Get-PalworldLocalizedText "Invalid server" "잘못된 서버 주소")
            )
            return
        }
        if (-not $username -or -not $password) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "Enter the API username and AdminPassword." `
                    "API 사용자명과 AdminPassword를 입력하세요."),
                (Get-PalworldLocalizedText "Missing credentials" "인증 정보 누락")
            )
            return
        }
        if ($accessToken -and $accessToken -notmatch '^[A-Za-z0-9_-]{32,128}$') {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "API token must contain 32-128 letters, numbers, underscores, or hyphens." `
                    "API 토큰은 영문자, 숫자, 밑줄, 하이픈으로 된 32~128자여야 합니다."),
                (Get-PalworldLocalizedText "Invalid API token" "잘못된 API 토큰")
            )
            return
        }
        try {
            $port = ConvertTo-ApiPort $portText.Text
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                $_.Exception.Message,
                (Get-PalworldLocalizedText "Invalid API port" "잘못된 API 포트")
            )
            return
        }
        $selectedSshConnectionId = [string]$sshConnectionIds[$sshConnectionCombo.SelectedIndex]
        $managedServerName = if ($Connection) { [string]$Connection.ManagedServerName } else { "" }
        if ($managedServerName) {
            if (-not $selectedSshConnectionId) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    (Get-PalworldLocalizedText `
                        "A managed Server API must remain linked to an SSH Connection." `
                        "관리 서버 API는 SSH 연결과 계속 연결되어 있어야 합니다."),
                    (Get-PalworldLocalizedText "Managed Server mapping" "관리 서버 매핑")
                )
                return
            }
            $mappedSsh = Get-PalworldSshConnectionById $selectedSshConnectionId
            if ($null -eq $mappedSsh) {
                [void][System.Windows.Forms.MessageBox]::Show(
                    (Get-PalworldLocalizedText `
                        "The mapped SSH Connection no longer exists." `
                        "매핑된 SSH 연결이 더 이상 존재하지 않습니다."),
                    (Get-PalworldLocalizedText "Managed Server mapping" "관리 서버 매핑")
                )
                return
            }
        }
        $dialog.Tag = [pscustomobject]@{
            Name = $name
            ServerHost = $hostValue
            Port = $port
            Username = $username
            Password = $password
            AccessToken = $accessToken
            SshConnectionId = $selectedSshConnectionId
            ManagedServerName = $managedServerName
        }
        $dialog.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dialog.Close()
    })
    $dialog.Controls.Add($saveButton)
    $dialog.AcceptButton = $saveButton
    $dialog.CancelButton = $cancelButton

    if ($env:PALWORLD_CLIENT_TEST_MODE -eq "admin-connection") {
        $bitmap = New-Object System.Drawing.Bitmap(560, 495)
        try {
            $dialog.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, 560, 495)))
        }
        finally {
            $bitmap.Dispose()
            $dialog.Dispose()
        }
        return $null
    }
    try {
        if ($dialog.ShowDialog($Owner) -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.Tag
        }
        return $null
    }
    finally {
        $dialog.Dispose()
    }
}

function Format-ByteSize {
    param([long]$Value)
    if ($Value -ge 1GB) { return "{0:N2} GiB" -f ($Value / 1GB) }
    if ($Value -ge 1MB) { return "{0:N1} MiB" -f ($Value / 1MB) }
    if ($Value -ge 1KB) { return "{0:N1} KiB" -f ($Value / 1KB) }
    return "$Value B"
}

function Format-ResourceCpu {
    param([AllowNull()]$Value)
    if ($null -eq $Value) { return "CPU —" }
    return "CPU {0:N1}%" -f [double]$Value
}

function Format-ResourceMemory {
    param(
        [AllowNull()]$Used,
        [AllowNull()]$Total,
        [switch]$Container
    )
    $label = Get-PalworldLocalizedText "Memory" "메모리"
    if ($null -eq $Used) { return "$label —" }
    $usedGb = [double]$Used / 1GB
    if ($Container -or $null -eq $Total) {
        return "$label {0:N1} GB" -f $usedGb
    }
    return "$label {0:N1} / {1:N1} GB" -f $usedGb, ([double]$Total / 1GB)
}

function Format-ResourceNetworkRate {
    param(
        [AllowNull()]$BytesPerSecond,
        [Parameter(Mandatory = $true)][ValidateSet("Receive", "Transmit")][string]$Direction
    )
    $prefix = if ($Direction -eq "Receive") { "↓" } else { "↑" }
    if ($null -eq $BytesPerSecond) { return "$prefix —" }
    $megabits = [double]$BytesPerSecond * 8.0 / 1000000.0
    $formatted = if ($megabits -lt 1.0) { "{0:N2}" -f $megabits } else { "{0:N1}" -f $megabits }
    return "$prefix $formatted Mbps"
}

function Get-ResourceUsageSelectedServerName {
    if (-not $script:IsAdminEdition) { return [string]$script:VerifiedInstance }
    $selectedApi = Get-SelectedAdminApiConnection
    $selectedTab = if ($script:AdminTabLayout -and $script:AdminTabLayout.Tabs) {
        [int]$script:AdminTabLayout.Tabs.SelectedIndex
    }
    else { -1 }
    # The visible Server API selection owns the context on the Server API tab.
    # In particular, an SSH operation pin must not silently redirect its requests.
    if ($selectedTab -eq 0) {
        if ($selectedApi -and [string]$selectedApi.ManagedServerName -match '^server[1-9][0-9]*$') {
            return [string]$selectedApi.ManagedServerName
        }
        return ""
    }
    $selectedSsh = Get-PalworldSshSynchronizationConnection
    if ($selectedSsh -and [string]$selectedSsh.LastSelectedServer -match '^server[1-9][0-9]*$') {
        return [string]$selectedSsh.LastSelectedServer
    }
    if ($selectedApi -and
        ((-not $selectedSsh) -or [string]$selectedApi.SshConnectionId -eq [string]$selectedSsh.Id) -and
        [string]$selectedApi.ManagedServerName -match '^server[1-9][0-9]*$') {
        return [string]$selectedApi.ManagedServerName
    }
    if ($script:ResourceUsageServerCombo -and
        $script:ResourceUsageServerCombo.SelectedIndex -ge 0 -and
        [string]$script:ResourceUsageServerCombo.SelectedItem -match '^server[1-9][0-9]*$') {
        return [string]$script:ResourceUsageServerCombo.SelectedItem
    }
    return ""
}

function Get-ResourceUsageApiContext {
    if (-not $script:IsAdminEdition) {
        $settings = $script:ConnectionSettings
        $ready = (
            $script:UserConnectionVerified -and
            [string]$settings.ServerHost -and
            [int]$settings.Port -ge 1 -and
            [string]$settings.Username -and
            [string]$settings.Password -and
            [string]$settings.AccessToken -match '^[A-Za-z0-9_-]{32,128}$'
        )
        $userTarget = "$([string]$settings.ServerHost):$([int]$settings.Port)"
        if ($script:VerifiedInstance) { $userTarget += " · $([string]$script:VerifiedInstance)" }
        return [pscustomobject]@{
            Ready = $ready
            Message = if ($ready) { "" } else {
                Get-PalworldLocalizedText "Available after server verification" "서버 검증 후 표시"
            }
            ContextKey = "user|$([string]$settings.ServerHost)|$([int]$settings.Port)|$([string]$script:VerifiedInstance)"
            ServerHost = [string]$settings.ServerHost
            Port = [int]$settings.Port
            Username = [string]$settings.Username
            Password = [string]$settings.Password
            AccessToken = [string]$settings.AccessToken
            ServerName = [string]$script:VerifiedInstance
            ContainerMatches = $true
            ApiConnectionId = "user"
            ApiConnectionName = "user"
            Authority = "api"
            SshConnectionId = ""
            MappingCount = 1
            TargetDescription = $userTarget
        }
    }

    $selectedApi = Get-SelectedAdminApiConnection
    $selectedTab = if ($script:AdminTabLayout -and $script:AdminTabLayout.Tabs) {
        [int]$script:AdminTabLayout.Tabs.SelectedIndex
    }
    else { -1 }
    $apiIsAuthoritative = $selectedTab -eq 0 -or ($selectedTab -ne 1 -and $null -ne $selectedApi)
    $selectedSsh = if ($apiIsAuthoritative) {
        if ($selectedApi) { Get-LinkedSshConnection $selectedApi } else { $null }
    }
    else { Get-PalworldSshSynchronizationConnection }
    $sshId = if ($selectedSsh) { [string]$selectedSsh.Id } else { "" }
    $sshSessionReady = (
        $apiIsAuthoritative -or (
            $null -ne $selectedSsh -and
            $null -ne $script:PalworldSshCurrentConnection -and
            [string]$script:PalworldSshCurrentConnection.Id -eq $sshId -and
            $null -ne $script:PalworldSshClient -and
            [bool]$script:PalworldSshClient.IsConnected
        )
    )
    $sshOperationPaused = [bool]$script:PalworldSshOperationRunning
    $serverName = Get-ResourceUsageSelectedServerName
    $exactApis = @()
    $api = $null
    $mappingMessage = ""
    if ($apiIsAuthoritative) {
        $api = $selectedApi
        if ($api -and $serverName -and [string]$api.ManagedServerName -ne $serverName) {
            $mappingMessage = Get-PalworldLocalizedText `
                "$serverName API mapping mismatch" `
                "$serverName API 매핑 불일치"
        }
    }
    elseif ($selectedSsh -and $serverName) {
        $exactApis = @(
            $script:AdminConnections | Where-Object {
                [string]$_.ManagedServerName -eq $serverName -and
                [string]$_.SshConnectionId -eq $sshId
            }
        )
        $selectedExactApi = $exactApis | Where-Object {
            $selectedApi -and [string]$_.Id -eq [string]$selectedApi.Id
        } | Select-Object -First 1
        if ($selectedExactApi) {
            # A user-visible selection is deterministic even if legacy data contains duplicates.
            $api = $selectedExactApi
        }
        elseif ($exactApis.Count -eq 1) {
            $api = $exactApis[0]
        }
        elseif ($exactApis.Count -gt 1) {
            $mappingMessage = Get-PalworldLocalizedText `
                "$serverName has duplicate API mappings" `
                "$serverName API 매핑 중복"
        }
    }
    $ready = (
        (-not $sshOperationPaused) -and $sshSessionReady -and
        $null -ne $api -and
        [string]$api.ServerHost -and
        [int]$api.Port -ge 1 -and
        [string]$api.Username -and
        [string]$api.Password -and
        [string]$api.AccessToken -match '^[A-Za-z0-9_-]{32,128}$'
    )
    $message = if ($sshOperationPaused) {
        Get-PalworldLocalizedText `
            "Monitoring paused during SSH management" `
            "SSH 관리 작업 중 모니터링 일시 중지"
    }
    elseif (-not $sshSessionReady) {
        Get-PalworldLocalizedText "Connect SSH to start monitoring" "모니터링을 시작하려면 SSH를 연결하세요"
    }
    elseif ($mappingMessage) {
        $mappingMessage
    }
    elseif ($null -eq $api) {
        Get-PalworldLocalizedText "No API" "API 없음"
    }
    elseif (-not $ready) {
        Get-PalworldLocalizedText "Check API authentication" "API 인증 확인 필요"
    }
    else { "" }
    if (-not $mappingMessage -and $null -eq $api -and $serverName) {
        $message = Get-PalworldLocalizedText "$serverName has no API" "$serverName API 없음"
    }
    $containerMatches = (
        $null -ne $api -and
        $serverName -and
        [string]$api.ManagedServerName -eq $serverName
    )
    $authority = if ($apiIsAuthoritative) { "api" } else { "ssh" }
    $targetDescription = if ($api) {
        $apiName = if ([string]$api.Name) { [string]$api.Name } else { "Server API" }
        $serverSuffix = if ($serverName) { " · $serverName" } else { "" }
        "$apiName · $([string]$api.ServerHost):$([int]$api.Port)$serverSuffix"
    }
    elseif ($selectedSsh) {
        $serverSuffix = if ($serverName) { " · $serverName" } else { "" }
        "$([string]$selectedSsh.Name)$serverSuffix"
    }
    else { Get-PalworldLocalizedText "No selection" "선택 없음" }
    return [pscustomobject]@{
        Ready = $ready
        Message = $message
        ContextKey = if ($api) { "admin|$authority|$sshId|$sshSessionReady|$sshOperationPaused|$([string]$api.Id)|$serverName" } else { "admin|$authority|$sshId|$sshSessionReady|$sshOperationPaused|none|$serverName" }
        ServerHost = if ($api) { [string]$api.ServerHost } else { "" }
        Port = if ($api) { [int]$api.Port } else { 0 }
        Username = if ($api) { [string]$api.Username } else { "" }
        Password = if ($api) { [string]$api.Password } else { "" }
        AccessToken = if ($api) { [string]$api.AccessToken } else { "" }
        ServerName = $serverName
        ContainerMatches = $containerMatches
        ApiConnectionId = if ($api) { [string]$api.Id } else { "" }
        ApiConnectionName = if ($api) { [string]$api.Name } else { "" }
        Authority = $authority
        SshConnectionId = $sshId
        MappingCount = $exactApis.Count
        TargetDescription = $targetDescription
    }
}

function Get-ResourceUsageAdminServerNames {
    if (-not $script:IsAdminEdition) { return @() }
    $selectedApi = Get-SelectedAdminApiConnection
    $selectedTab = if ($script:AdminTabLayout -and $script:AdminTabLayout.Tabs) {
        [int]$script:AdminTabLayout.Tabs.SelectedIndex
    }
    else { -1 }
    $apiIsAuthoritative = $selectedTab -eq 0 -or ($selectedTab -ne 1 -and $null -ne $selectedApi)
    $selectedSsh = if ($apiIsAuthoritative) {
        if ($selectedApi) { Get-LinkedSshConnection $selectedApi } else { $null }
    }
    else { Get-PalworldSshSynchronizationConnection }
    $sshId = if ($selectedSsh) { [string]$selectedSsh.Id } else { "" }
    $names = @(
        $script:AdminConnections | Where-Object {
            [string]$_.ManagedServerName -match '^server[1-9][0-9]*$' -and
            ($sshId -and [string]$_.SshConnectionId -eq $sshId)
        } | ForEach-Object { [string]$_.ManagedServerName }
    )
    if ($apiIsAuthoritative -and $selectedApi -and
        [string]$selectedApi.ManagedServerName -match '^server[1-9][0-9]*$') {
        $names += [string]$selectedApi.ManagedServerName
    }
    if ($selectedSsh -and [string]$selectedSsh.LastSelectedServer -match '^server[1-9][0-9]*$') {
        $names += [string]$selectedSsh.LastSelectedServer
    }
    if (-not $apiIsAuthoritative -and $selectedSsh -and $script:PalworldSshServerCombo) {
        $names += @(
            $script:PalworldSshServerCombo.Items | ForEach-Object { [string]$_ } |
                Where-Object { $_ -match '^server[1-9][0-9]*$' }
        )
    }
    return @(
        $names | Sort-Object -Property { [int]([string]$_ -replace '^server', '') } -Unique
    )
}

function ConvertTo-ResourceUsageSafeDiagnostic {
    param(
        [AllowEmptyString()][string]$Text,
        [AllowNull()]$Context,
        [ValidateRange(40, 2000)][int]$MaximumLength = 500
    )
    if (-not $Text) { return "" }
    $safe = $Text
    if ($Context) {
        foreach ($secret in @([string]$Context.Password, [string]$Context.AccessToken)) {
            if ($secret) { $safe = $safe -replace [regex]::Escape($secret), "[redacted]" }
        }
    }
    $safe = $safe -replace '(?i)(Authorization\s*[:=]\s*(?:Basic|Bearer)\s+)\S+', '$1[redacted]'
    $safe = $safe -replace '(?i)(X-Palworld-Manager-Token\s*[:=]\s*)\S+', '$1[redacted]'
    $safe = $safe -replace '(?i)("?(?:password|access[_ -]?token)"?\s*[:=]\s*"?)[^",\s}\]]+', '$1[redacted]'
    $safe = ($safe -replace '[\r\n\t]+', ' ' -replace '\s{2,}', ' ').Trim()
    if ($safe.Length -gt $MaximumLength) { return $safe.Substring(0, $MaximumLength - 1) + "…" }
    return $safe
}

function Set-ResourceUsageDiagnostic {
    param(
        [AllowEmptyString()][string]$Summary,
        [AllowEmptyString()][string]$Detail = ""
    )
    $parts = @()
    if ($Summary) { $parts += $Summary }
    if ($Detail) { $parts += $Detail }
    $text = $parts -join "`r`n"
    if ($script:ResourceUsageFooter) { $script:ResourceUsageFooter.Tag = $text }
    if (-not $script:ResourceUsageToolTip) { return }
    foreach ($control in @(
        $script:ResourceUsageFooter,
        $script:ResourceUsageHostCpu, $script:ResourceUsageHostMemory,
        $script:ResourceUsageHostReceive, $script:ResourceUsageHostTransmit,
        $script:ResourceUsageContainerCpu, $script:ResourceUsageContainerMemory,
        $script:ResourceUsageContainerReceive, $script:ResourceUsageContainerTransmit,
        $script:ResourceUsageHostHistoryButton, $script:ResourceUsageContainerHistoryButton
    )) {
        if ($control) { $script:ResourceUsageToolTip.SetToolTip($control, $text) }
    }
}

function Get-ResourceUsageHttpStatusMessage {
    param([int]$StatusCode)
    $message = switch ($StatusCode) {
        401 { Get-PalworldLocalizedText "Check the Server API account" "Server API 계정 확인 필요" }
        403 { Get-PalworldLocalizedText "Check the API token" "API token 확인 필요" }
        404 { Get-PalworldLocalizedText "Update the server with Manage" "서버 Manage 갱신 필요" }
        408 { Get-PalworldLocalizedText "Resource request timed out" "사용량 요청 시간 초과" }
        429 { Get-PalworldLocalizedText "Resource requests are rate-limited" "사용량 요청 제한됨" }
        503 { Get-PalworldLocalizedText "Resource collection is starting" "사용량 수집 준비 중" }
        default {
            if ($StatusCode -ge 500) {
                Get-PalworldLocalizedText "Resource server error (HTTP $StatusCode)" "사용량 서버 오류 (HTTP $StatusCode)"
            }
            else {
                Get-PalworldLocalizedText "Resource request failed (HTTP $StatusCode)" "사용량 요청 실패 (HTTP $StatusCode)"
            }
        }
    }
    return $message
}

function Get-ResourceUsageRetryDelaySeconds {
    param(
        [ValidateSet("Transient", "NotFound", "Busy")][string]$Kind,
        [ValidateRange(1, 1000)][int]$FailureCount
    )
    if ($Kind -eq "NotFound") { return 30 }
    if ($Kind -eq "Busy") { return [Math]::Min(30, [Math]::Max(5, $FailureCount * 5)) }
    return [Math]::Min(30, [Math]::Pow(2, [Math]::Min(5, $FailureCount - 1)))
}

function Reset-ResourceUsagePollingBackoff {
    $script:ResourceUsageFailureCount = 0
    $script:ResourceUsageBlockedContextKey = ""
    $script:ResourceUsageNextRequestUtc = [DateTime]::UtcNow
}

function Set-ResourceUsagePollingResult {
    param(
        [ValidateSet("Success", "Authentication", "Transient", "NotFound", "Busy")][string]$Kind,
        [AllowEmptyString()][string]$ContextKey = ""
    )
    if ($Kind -eq "Success") {
        $script:ResourceUsageFailureCount = 0
        $script:ResourceUsageBlockedContextKey = ""
        $script:ResourceUsageNextRequestUtc = [DateTime]::UtcNow.AddSeconds(1)
        return
    }
    if ($Kind -eq "Authentication") {
        # Invalid saved credentials do not heal by retrying. Resume as soon as selection/settings change.
        $script:ResourceUsageBlockedContextKey = $ContextKey
        $script:ResourceUsageNextRequestUtc = [DateTime]::MaxValue
        return
    }
    $script:ResourceUsageFailureCount++
    $delay = Get-ResourceUsageRetryDelaySeconds -Kind $Kind -FailureCount $script:ResourceUsageFailureCount
    $script:ResourceUsageNextRequestUtc = [DateTime]::UtcNow.AddSeconds($delay)
}

function Set-ResourceUsageUnavailable {
    param(
        [AllowEmptyString()][string]$Message,
        [AllowEmptyString()][string]$Detail = ""
    )
    if ($script:ResourceUsageHostCpu) {
        $script:ResourceUsageHostCpu.Text = "CPU —"
        $script:ResourceUsageHostMemory.Text = if ($Message) {
            $Message
        }
        else {
            Get-PalworldLocalizedText "Memory —" "메모리 —"
        }
        $script:ResourceUsageHostReceive.Text = "↓ —"
        $script:ResourceUsageHostTransmit.Text = "↑ —"
    }
    if ($script:IsAdminEdition -and $script:ResourceUsageContainerCpu) {
        $script:ResourceUsageContainerCpu.Text = "CPU —"
        $script:ResourceUsageContainerMemory.Text = if ($Message) {
            $Message
        }
        else {
            Get-PalworldLocalizedText "Memory —" "메모리 —"
        }
        $script:ResourceUsageContainerReceive.Text = "↓ —"
        $script:ResourceUsageContainerTransmit.Text = "↑ —"
    }
    Set-ResourceUsageDiagnostic -Summary $Message -Detail $Detail
}

function Set-ResourceUsagePayload {
    param(
        [Parameter(Mandatory = $true)]$Payload,
        [Parameter(Mandatory = $true)]$Context
    )
    $hostMetrics = $Payload.host
    if ($null -eq $hostMetrics) { throw "Resource usage response does not contain host metrics." }
    $script:ResourceUsageHostCpu.Text = Format-ResourceCpu $hostMetrics.cpu_percent
    $script:ResourceUsageHostMemory.Text = Format-ResourceMemory $hostMetrics.memory_used_bytes $hostMetrics.memory_total_bytes
    $script:ResourceUsageHostReceive.Text = Format-ResourceNetworkRate $hostMetrics.network_receive_bytes_per_second Receive
    $script:ResourceUsageHostTransmit.Text = Format-ResourceNetworkRate $hostMetrics.network_transmit_bytes_per_second Transmit
    if ($script:IsAdminEdition) {
        $container = $Payload.container
        $containerMatchesSelection = (
            $Context.ContainerMatches -and
            [string]$container.instance -eq [string]$Context.ServerName
        )
        if ($containerMatchesSelection) {
            $script:ResourceUsageContainerCpu.Text = Format-ResourceCpu $container.cpu_percent
            $script:ResourceUsageContainerMemory.Text = Format-ResourceMemory $container.memory_used_bytes $null -Container
            $script:ResourceUsageContainerReceive.Text = Format-ResourceNetworkRate $container.network_receive_bytes_per_second Receive
            $script:ResourceUsageContainerTransmit.Text = Format-ResourceNetworkRate $container.network_transmit_bytes_per_second Transmit
        }
        else {
            $script:ResourceUsageContainerCpu.Text = "CPU —"
            $script:ResourceUsageContainerMemory.Text = if ($Context.ServerName) {
                Get-PalworldLocalizedText `
                    "$($Context.ServerName) has no API mapping" `
                    "$($Context.ServerName) API 매핑 없음"
            }
            else {
                Get-PalworldLocalizedText "Select a server" "서버 선택 필요"
            }
            $script:ResourceUsageContainerReceive.Text = "↓ —"
            $script:ResourceUsageContainerTransmit.Text = "↑ —"
        }
    }
    if ($script:ResourceUsageFooter) {
        $sampleTime = try {
            [DateTimeOffset]::FromUnixTimeSeconds([long][double]$Payload.sampled_at).ToLocalTime().ToString("yyyy-MM-dd HH:mm:ss")
        }
        catch { Get-PalworldLocalizedText "Time unavailable" "시간 정보 없음" }
        $errorText = @($Payload.errors | ForEach-Object {
            ConvertTo-ResourceUsageSafeDiagnostic -Text ([string]$_) -Context $Context -MaximumLength 300
        }) -join "`r`n"
        $target = if ($Context.PSObject.Properties.Name -contains "TargetDescription") {
            [string]$Context.TargetDescription
        }
        else { "" }
        $targetLabel = Get-PalworldLocalizedText "Target" "대상"
        $detail = @($(if ($target) { "${targetLabel}: $target" }), $(if ($errorText) { $errorText })) -join "`r`n"
        $recentLabel = Get-PalworldLocalizedText "Last sample" "최근 수집"
        Set-ResourceUsageDiagnostic -Summary "${recentLabel}: $sampleTime" -Detail $detail
    }
}

function New-ResourceHistoryChart {
    param(
        [Parameter(Mandatory = $true)][string]$YAxisTitle,
        [switch]$Percent
    )
    $chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
    $chart.Dock = "Fill"
    $chart.BackColor = [System.Drawing.Color]::White
    $area = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea("Usage")
    $area.AxisX.LabelStyle.Format = "MM-dd HH:mm"
    $area.AxisX.LabelStyle.Angle = -30
    $area.AxisX.MajorGrid.LineColor = [System.Drawing.Color]::Gainsboro
    $area.AxisY.MajorGrid.LineColor = [System.Drawing.Color]::Gainsboro
    $area.AxisY.Title = $YAxisTitle
    $area.AxisY.Minimum = 0
    if ($Percent) { $area.AxisY.Maximum = 100 }
    [void]$chart.ChartAreas.Add($area)
    $legend = New-Object System.Windows.Forms.DataVisualization.Charting.Legend("Legend")
    $legend.Docking = [System.Windows.Forms.DataVisualization.Charting.Docking]::Top
    [void]$chart.Legends.Add($legend)
    return $chart
}

function Add-ResourceHistorySeries {
    param(
        [Parameter(Mandatory = $true)]$Chart,
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][System.Drawing.Color]$Color,
        [Parameter(Mandatory = $true)]$Points,
        [Parameter(Mandatory = $true)][scriptblock]$Value
    )
    $series = New-Object System.Windows.Forms.DataVisualization.Charting.Series($Name)
    $series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $series.XValueType = [System.Windows.Forms.DataVisualization.Charting.ChartValueType]::DateTime
    $series.YValueType = [System.Windows.Forms.DataVisualization.Charting.ChartValueType]::Double
    $series.BorderWidth = 2
    $series.Color = $Color
    foreach ($point in @($Points)) {
        $valueResult = & $Value $point
        if ($null -eq $valueResult) { continue }
        $timestamp = [DateTimeOffset]::FromUnixTimeSeconds([long][double]$point.sampled_at).LocalDateTime
        [void]$series.Points.AddXY($timestamp.ToOADate(), [double]$valueResult)
    }
    [void]$Chart.Series.Add($series)
}

function Set-ResourceHistoryCharts {
    param(
        [Parameter(Mandatory = $true)]$CpuChart,
        [Parameter(Mandatory = $true)]$MemoryChart,
        [Parameter(Mandatory = $true)]$NetworkChart,
        [Parameter(Mandatory = $true)]$Payload,
        [Parameter(Mandatory = $true)][ValidateSet("Host", "Container")][string]$Scope
    )
    $CpuChart.Series.Clear()
    $MemoryChart.Series.Clear()
    $NetworkChart.Series.Clear()
    $points = @($Payload.points)
    $scopeName = $Scope.ToLowerInvariant()
    Add-ResourceHistorySeries -Chart $CpuChart -Name "CPU" -Color ([System.Drawing.Color]::RoyalBlue) -Points $points -Value {
        param($point)
        $value = if ($scopeName -eq "host") { $point.host.cpu_percent } else { $point.container.cpu_percent }
        if ($null -eq $value) { return $null }
        return [double]$value
    }.GetNewClosure()
    Add-ResourceHistorySeries -Chart $MemoryChart -Name (Get-PalworldLocalizedText "Used" "사용") -Color ([System.Drawing.Color]::DarkOrange) -Points $points -Value {
        param($point)
        $value = if ($scopeName -eq "host") { $point.host.memory_used_bytes } else { $point.container.memory_used_bytes }
        if ($null -eq $value) { return $null }
        return [double]$value / 1GB
    }.GetNewClosure()
    if ($scopeName -eq "host") {
        Add-ResourceHistorySeries -Chart $MemoryChart -Name (Get-PalworldLocalizedText "Total" "전체") -Color ([System.Drawing.Color]::DimGray) -Points $points -Value {
            param($point)
            if ($null -eq $point.host.memory_total_bytes) { return $null }
            return [double]$point.host.memory_total_bytes / 1GB
        }
    }
    Add-ResourceHistorySeries -Chart $NetworkChart -Name (Get-PalworldLocalizedText "Download" "다운로드") -Color ([System.Drawing.Color]::SeaGreen) -Points $points -Value {
        param($point)
        $value = if ($scopeName -eq "host") { $point.host.network_receive_bytes_per_second } else { $point.container.network_receive_bytes_per_second }
        if ($null -eq $value) { return $null }
        return [double]$value * 8.0 / 1000000.0
    }.GetNewClosure()
    Add-ResourceHistorySeries -Chart $NetworkChart -Name (Get-PalworldLocalizedText "Upload" "업로드") -Color ([System.Drawing.Color]::Firebrick) -Points $points -Value {
        param($point)
        $value = if ($scopeName -eq "host") { $point.host.network_transmit_bytes_per_second } else { $point.container.network_transmit_bytes_per_second }
        if ($null -eq $value) { return $null }
        return [double]$value * 8.0 / 1000000.0
    }.GetNewClosure()
}

function Show-ResourceUsageHistoryDialog {
    param(
        [Parameter(Mandatory = $true)][System.Windows.Forms.IWin32Window]$Owner,
        [Parameter(Mandatory = $true)][ValidateSet("Host", "Container")][string]$Scope
    )
    $context = Get-ResourceUsageApiContext
    if (-not $context.Ready -or ($Scope -eq "Container" -and -not $context.ContainerMatches)) {
        $requiredMessage = if ($context.Message) {
            [string]$context.Message
        }
        else {
            Get-PalworldLocalizedText `
                "The selected server needs a Server API connection." `
                "선택한 서버의 Server API 연결이 필요합니다."
        }
        [void][System.Windows.Forms.MessageBox]::Show(
            $requiredMessage,
            (Get-PalworldLocalizedText "Recent trend" "최근 동향")
        )
        return
    }
    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = if ($Scope -eq "Host") {
        Get-PalworldLocalizedText "Recent host resource trend" "호스트 최근 사용량 동향"
    }
    else {
        Get-PalworldLocalizedText `
            "$($context.ServerName) recent container resource trend" `
            "$($context.ServerName) 컨테이너 최근 사용량 동향"
    }
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(980, 680)
    $dialog.MinimumSize = New-Object System.Drawing.Size(820, 560)
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog

    $toolbar = New-Object System.Windows.Forms.Panel
    $toolbar.Location = New-Object System.Drawing.Point(0, 0)
    $toolbar.Size = New-Object System.Drawing.Size($dialog.ClientSize.Width, 48)
    $toolbar.Anchor = "Top,Left,Right"
    $dialog.Controls.Add($toolbar)
    $rangeLabel = New-Object System.Windows.Forms.Label
    $rangeLabel.Text = Get-PalworldLocalizedText "Range" "기간"
    $rangeLabel.Location = New-Object System.Drawing.Point(12, 16)
    $rangeLabel.AutoSize = $true
    $toolbar.Controls.Add($rangeLabel)
    $range = New-Object System.Windows.Forms.ComboBox
    $range.Location = New-Object System.Drawing.Point(55, 12)
    $range.Size = New-Object System.Drawing.Size(125, 23)
    $range.DropDownStyle = "DropDownList"
    $rangeItems = if ($script:ApplicationLanguage -eq "ko") {
        @("최근 1시간", "최근 24시간", "최근 7일")
    }
    else {
        @("Last hour", "Last 24 hours", "Last 7 days")
    }
    foreach ($label in $rangeItems) { [void]$range.Items.Add($label) }
    $range.SelectedIndex = 2
    $toolbar.Controls.Add($range)
    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = Get-PalworldLocalizedText "Refresh" "새로고침"
    $refresh.Location = New-Object System.Drawing.Point(190, 9)
    $refresh.Size = New-Object System.Drawing.Size(95, 30)
    $toolbar.Controls.Add($refresh)
    $historyStatus = New-Object System.Windows.Forms.Label
    $historyStatus.Location = New-Object System.Drawing.Point(300, 15)
    $historyStatus.Size = New-Object System.Drawing.Size(650, 22)
    $historyStatus.ForeColor = [System.Drawing.Color]::DimGray
    $historyStatus.AutoEllipsis = $true
    $toolbar.Controls.Add($historyStatus)
    $historyToolTip = New-Object System.Windows.Forms.ToolTip
    $historyToolTip.AutoPopDelay = 20000
    $historyState = [pscustomobject]@{
        Closing = $false
        Operation = $null
    }

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(0, 48)
    $tabs.Size = New-Object System.Drawing.Size($dialog.ClientSize.Width, ($dialog.ClientSize.Height - 48))
    $tabs.Anchor = "Top,Bottom,Left,Right"
    $dialog.Controls.Add($tabs)
    $cpuPage = New-Object System.Windows.Forms.TabPage
    $cpuPage.Text = "CPU"
    $memoryPage = New-Object System.Windows.Forms.TabPage
    $memoryPage.Text = Get-PalworldLocalizedText "Memory" "메모리"
    $networkPage = New-Object System.Windows.Forms.TabPage
    $networkPage.Text = Get-PalworldLocalizedText "Network" "네트워크"
    [void]$tabs.TabPages.Add($cpuPage)
    [void]$tabs.TabPages.Add($memoryPage)
    [void]$tabs.TabPages.Add($networkPage)
    $cpuChart = New-ResourceHistoryChart -YAxisTitle "CPU (%)" -Percent
    $memoryChart = New-ResourceHistoryChart -YAxisTitle (Get-PalworldLocalizedText "Memory (GB)" "메모리 (GB)")
    $networkChart = New-ResourceHistoryChart -YAxisTitle (Get-PalworldLocalizedText "Rate (Mbps)" "속도 (Mbps)")
    $cpuPage.Controls.Add($cpuChart)
    $memoryPage.Controls.Add($memoryChart)
    $networkPage.Controls.Add($networkChart)

    $loadHistory = {
        if ($historyState.Closing -or $dialog.IsDisposed) { return }
        $seconds = @(3600, 86400, 604800)[$range.SelectedIndex]
        $refresh.Enabled = $false
        $range.Enabled = $false
        $historyStatus.Text = Get-PalworldLocalizedText "Loading history..." "이력 불러오는 중..."
        $dialog.UseWaitCursor = $true
        $operation = New-PalworldHttpOperation
        $historyState.Operation = $operation
        try {
            $uri = Get-PalworldApiUri `
                -ServerAddress ([string]$context.ServerHost) `
                -Port ([int]$context.Port) `
                -PathAndQuery "/v1/manager/resources/history?seconds=$seconds&points=600"
            $result = Invoke-PalworldRequest `
                -Uri $uri -Method GET `
                -Username $context.Username -Password $context.Password `
                -AccessToken $context.AccessToken -TimeoutSeconds 10 `
                -Operation $operation
            if (-not $result.Success) {
                $summary = Get-ResourceUsageHttpStatusMessage -StatusCode ([int]$result.StatusCode)
                $responseDetail = ConvertTo-ResourceUsageSafeDiagnostic `
                    -Text ([string]$result.Body) -Context $context -MaximumLength 400
                $responseSuffix = if ($responseDetail) { ": $responseDetail" } else { "" }
                throw "$summary$responseSuffix"
            }
            $payload = $result.Body | ConvertFrom-Json
            Set-ResourceHistoryCharts `
                -CpuChart $cpuChart -MemoryChart $memoryChart -NetworkChart $networkChart `
                -Payload $payload -Scope $Scope
            $historyStatus.Text = if (@($payload.points).Count -gt 0) {
                Get-PalworldLocalizedText `
                    "15-second samples · $(@($payload.points).Count) graph points · automatic 7-day retention" `
                    "수집 간격 15초 · 그래프 점 $(@($payload.points).Count)개 · 7일 자동 보관"
            }
            else {
                Get-PalworldLocalizedText `
                    "No history has been stored yet. Recording begins within 15 seconds after installation or update." `
                    "저장된 이력이 아직 없습니다. 설치·갱신 후 최대 15초 뒤부터 기록됩니다."
            }
            $historyStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            $historyToolTip.SetToolTip($historyStatus, $historyStatus.Text)
        }
        catch {
            if ($historyState.Closing -or $dialog.IsDisposed) { return }
            $failureDetail = ConvertTo-ResourceUsageSafeDiagnostic `
                -Text (Get-PalworldHttpFailureDetail -Exception $_.Exception) `
                -Context $context -MaximumLength 500
            $historyStatus.Text = Get-PalworldLocalizedText `
                "History request failed · hover for details" `
                "동향 조회 실패 · 자세한 내용은 마우스를 올려 확인"
            $historyStatus.ForeColor = [System.Drawing.Color]::DarkRed
            $historyToolTip.SetToolTip($historyStatus, $failureDetail)
        }
        finally {
            if ($historyState.Operation -eq $operation) { $historyState.Operation = $null }
            try { $operation.Cancellation.Dispose() } catch { }
            if (-not $historyState.Closing -and -not $dialog.IsDisposed) {
                $dialog.UseWaitCursor = $false
                $refresh.Enabled = $true
                $range.Enabled = $true
            }
        }
    }.GetNewClosure()
    $refresh.Add_Click({ & $loadHistory }.GetNewClosure())
    $range.Add_SelectedIndexChanged({ if ($dialog.Visible) { & $loadHistory } }.GetNewClosure())
    $dialog.Add_Shown({ & $loadHistory }.GetNewClosure())
    $dialog.Add_FormClosing({
        $historyState.Closing = $true
        if ($historyState.Operation) {
            Stop-PalworldHttpOperation -Operation $historyState.Operation
        }
    }.GetNewClosure())
    try { [void]$dialog.ShowDialog($Owner) }
    finally {
        if ($historyState.Operation) {
            Stop-PalworldHttpOperation -Operation $historyState.Operation
        }
        $historyToolTip.Dispose()
        $dialog.Dispose()
    }
}

function Show-WorldRestoreDialog {
    param([System.Windows.Forms.IWin32Window]$Owner)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = $script:Text.WorldRestore
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(780, 640)
    $dialog.MinimumSize = New-Object System.Drawing.Size(796, 679)
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog

    $worldGuidLabel = New-Object System.Windows.Forms.Label
    $worldGuidLabel.Text = "$($script:Text.WorldGuid): -"
    $worldGuidLabel.Location = New-Object System.Drawing.Point(16, 17)
    $worldGuidLabel.Size = New-Object System.Drawing.Size(748, 22)
    $dialog.Controls.Add($worldGuidLabel)

    $backupList = New-Object System.Windows.Forms.ListView
    $backupList.Location = New-Object System.Drawing.Point(16, 44)
    $backupList.Size = New-Object System.Drawing.Size(748, 242)
    $backupList.Anchor = "Top,Left,Right"
    $backupList.View = "Details"
    $backupList.FullRowSelect = $true
    $backupList.MultiSelect = $false
    $backupList.HideSelection = $false
    [void]$backupList.Columns.Add($script:Text.AvailableBackups, 270)
    [void]$backupList.Columns.Add((Get-PalworldLocalizedText "Type" "유형"), 150)
    [void]$backupList.Columns.Add((Get-PalworldLocalizedText "Files" "파일 수"), 90)
    [void]$backupList.Columns.Add((Get-PalworldLocalizedText "Size" "크기"), 120)
    $dialog.Controls.Add($backupList)

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = $script:Text.RefreshBackups
    $refreshButton.Location = New-Object System.Drawing.Point(16, 298)
    $refreshButton.Size = New-Object System.Drawing.Size(160, 32)
    $dialog.Controls.Add($refreshButton)

    $restoreWaitLabel = New-Object System.Windows.Forms.Label
    $restoreWaitLabel.Text = $script:Text.RestoreWait
    $restoreWaitLabel.Location = New-Object System.Drawing.Point(285, 306)
    $restoreWaitLabel.AutoSize = $true
    $dialog.Controls.Add($restoreWaitLabel)

    $restoreWaitInput = New-Object System.Windows.Forms.NumericUpDown
    $restoreWaitInput.Location = New-Object System.Drawing.Point(430, 302)
    $restoreWaitInput.Size = New-Object System.Drawing.Size(90, 23)
    $restoreWaitInput.Minimum = 0
    $restoreWaitInput.Maximum = 3600
    $restoreWaitInput.Value = 60
    $dialog.Controls.Add($restoreWaitInput)

    $restoreButton = New-Object System.Windows.Forms.Button
    $restoreButton.Text = $script:Text.RestoreSelected
    $restoreButton.Location = New-Object System.Drawing.Point(594, 298)
    $restoreButton.Size = New-Object System.Drawing.Size(170, 32)
    $restoreButton.Anchor = "Top,Right"
    $dialog.Controls.Add($restoreButton)

    $restoreProgressLabel = New-Object System.Windows.Forms.Label
    $restoreProgressLabel.Text = $script:Text.RestoreProgress
    $restoreProgressLabel.Location = New-Object System.Drawing.Point(16, 344)
    $restoreProgressLabel.AutoSize = $true
    $dialog.Controls.Add($restoreProgressLabel)

    $restoreLog = New-Object System.Windows.Forms.RichTextBox
    $restoreLog.Location = New-Object System.Drawing.Point(16, 370)
    $restoreLog.Size = New-Object System.Drawing.Size(748, 222)
    $restoreLog.Anchor = "Top,Bottom,Left,Right"
    $restoreLog.ReadOnly = $true
    $restoreLog.WordWrap = $false
    $restoreLog.Font = New-Object System.Drawing.Font("Consolas", 9)
    $dialog.Controls.Add($restoreLog)

    $restoreStatus = New-Object System.Windows.Forms.Label
    $restoreStatus.Text = Get-PalworldLocalizedText "Ready" "준비"
    $restoreStatus.Location = New-Object System.Drawing.Point(16, 604)
    $restoreStatus.Size = New-Object System.Drawing.Size(748, 23)
    $restoreStatus.Anchor = "Bottom,Left,Right"
    $dialog.Controls.Add($restoreStatus)

    $script:RestoreInProgress = $false
    $restoreState = [pscustomobject]@{
        InProgress = $false
        Closing = $false
        Subscription = $null
        RefreshOperation = $null
    }

    $validateConnection = {
        $settings = $script:ConnectionSettings
        return (
            [string]$settings.ServerHost -and
            [int]$settings.Port -ge 1 -and
            [int]$settings.Port -le 65535 -and
            [string]$settings.Username -and
            [string]$settings.Password
        )
    }

    $refreshBackups = {
        if ($restoreState.Closing -or $dialog.IsDisposed) { return }
        if (-not (& $validateConnection)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "Open Connection Settings on the main window and enter valid connection information." `
                    "메인 화면의 연결 설정을 열고 올바른 연결 정보를 입력하세요."),
                (Get-PalworldLocalizedText "Connection settings required" "연결 설정 필요")
            )
            return
        }
        $refreshButton.Enabled = $false
        $restoreStatus.Text = Get-PalworldLocalizedText "Loading backups..." "백업 목록 불러오는 중..."
        $restoreStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        $backupList.Items.Clear()
        $worldGuidLabel.Text = "$($script:Text.WorldGuid): -"
        $restoreLog.Clear()
        $refreshOperation = New-PalworldHttpOperation
        $restoreState.RefreshOperation = $refreshOperation
        try {
            $settings = $script:ConnectionSettings
            $uri = Get-PalworldApiUri `
                -ServerAddress ([string]$settings.ServerHost) `
                -Port ([int]$settings.Port) `
                -PathAndQuery "/v1/manager/backups"
            $result = Invoke-PalworldRequest `
                -Uri $uri `
                -Method "GET" `
                -Username $settings.Username `
                -Password $settings.Password `
                -AccessToken $settings.AccessToken `
                -TimeoutSeconds 60 `
                -Operation $refreshOperation
            if ($restoreState.Closing -or $dialog.IsDisposed) { return }
            if (-not $result.Success) {
                $detail = "HTTP $($result.StatusCode) $($result.Reason)"
                try {
                    $errorPayload = $result.Body | ConvertFrom-Json
                    if ([string]$errorPayload.error) {
                        $detail = "$detail - $([string]$errorPayload.error)"
                    }
                }
                catch {
                    # Preserve the status-only message when the response is not JSON.
                }
                throw (Get-PalworldLocalizedText `
                    "Backup list request failed: $detail" `
                    "백업 목록 요청 실패: $detail")
            }
            $payload = $result.Body | ConvertFrom-Json
            $worldGuidLabel.Text = "$($script:Text.WorldGuid): $([string]$payload.world_guid)"
            foreach ($backup in @($payload.backups)) {
                $item = New-Object System.Windows.Forms.ListViewItem([string]$backup.name)
                $kind = if ([string]$backup.kind -eq "pre-restore") {
                    $script:Text.PreRestoreBackup
                }
                else {
                    $script:Text.AutomaticBackup
                }
                [void]$item.SubItems.Add($kind)
                [void]$item.SubItems.Add([string]$backup.file_count)
                [void]$item.SubItems.Add((Format-ByteSize ([long]$backup.size_bytes)))
                $item.Tag = [string]$backup.name
                [void]$backupList.Items.Add($item)
            }
            $restoreStatus.Text = Get-PalworldLocalizedText `
                "Success - $($backupList.Items.Count) backup(s)" `
                "성공 - 백업 $($backupList.Items.Count)개"
            $restoreStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            if ($backupList.Items.Count -eq 0) {
                $restoreLog.Text = Get-PalworldLocalizedText `
                    "No complete backups are available yet. Wait for a Palworld automatic backup, then refresh." `
                    "아직 완전한 백업이 없습니다. Palworld 자동 백업을 기다린 뒤 새로고침하세요."
            }
        }
        catch {
            if (-not $restoreState.Closing -and -not $dialog.IsDisposed) {
                $restoreStatus.Text = Get-PalworldLocalizedText "Fail" "실패"
                $restoreStatus.ForeColor = [System.Drawing.Color]::DarkRed
                $safeDetail = Protect-DisplayText `
                    -Text (Get-PalworldHttpFailureDetail -Exception $_.Exception) `
                    -ServerHost ([string]$script:ConnectionSettings.ServerHost)
                $restoreLog.Text = (Get-PalworldLocalizedText `
                    "Backup list could not be loaded. Check Connection Settings, server state, and runtime.log.`r`n$safeDetail" `
                    "백업 목록을 불러오지 못했습니다. 연결 설정, 서버 상태와 runtime.log를 확인하세요.`r`n$safeDetail")
            }
        }
        finally {
            $restoreState.RefreshOperation = $null
            try { $refreshOperation.Cancellation.Dispose() } catch { }
            if (-not $restoreState.Closing -and -not $dialog.IsDisposed) {
                $refreshButton.Enabled = $true
            }
        }
    }

    $refreshButton.Add_Click({ & $refreshBackups })
    $restoreButton.Add_Click({
        if ($backupList.SelectedItems.Count -ne 1) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText "Select one backup to restore." "복원할 백업 하나를 선택하세요."),
                (Get-PalworldLocalizedText "Backup selection required" "백업 선택 필요")
            )
            return
        }
        if (-not (& $validateConnection)) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText `
                    "Open Connection Settings on the main window and enter valid connection information." `
                    "메인 화면의 연결 설정을 열고 올바른 연결 정보를 입력하세요."),
                (Get-PalworldLocalizedText "Connection settings required" "연결 설정 필요")
            )
            return
        }
        $backupName = [string]$backupList.SelectedItems[0].Tag
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "$($script:Text.RestoreWarning)`r`n`r`nBackup: $backupName",
            $script:Text.WorldRestore,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

        $settings = $script:ConnectionSettings
        $uri = Get-PalworldApiUri `
            -ServerAddress ([string]$settings.ServerHost) `
            -Port ([int]$settings.Port) `
            -PathAndQuery "/v1/manager/restore"
        $bodyJson = [ordered]@{
            backup = $backupName
            waittime = [int]$restoreWaitInput.Value
        } | ConvertTo-Json -Compress
        $subscription = New-PalworldRestoreSubscription
        $restoreState.Subscription = $subscription
        $restoreState.InProgress = $true
        $script:RestoreInProgress = $true
        $refreshButton.Enabled = $false
        $restoreButton.Enabled = $false
        $backupList.Enabled = $false
        $restoreWaitInput.Enabled = $false
        $restoreLog.Clear()
        $restoreStatus.Text = Get-PalworldLocalizedText "Restore in progress..." "복원 진행 중..."
        $restoreStatus.ForeColor = [System.Drawing.Color]::DarkOrange
        $restoreResult = $null
        try {
            $restoreResult = Invoke-RestoreStream `
                -Uri $uri `
                -Username $settings.Username `
                -Password $settings.Password `
                -AccessToken $settings.AccessToken `
                -BodyJson $bodyJson `
                -Subscription $subscription `
                -OnEvent {
                    param($event)
                    if ([string]$event.type -eq "log") {
                        $level = if ([string]$event.level) { ([string]$event.level).ToUpperInvariant() } else { "INFO" }
                        $line = "[$([string]$event.timestamp)] [$level] $([string]$event.message)"
                        Add-PalworldBoundedRichTextLog `
                            -Control $restoreLog -Text ($line + "`r`n")
                    }
                    [System.Windows.Forms.Application]::DoEvents()
                }
            if ([bool]$restoreResult.success) {
                $restoreStatus.Text = Get-PalworldLocalizedText `
                    "Success - $([string]$restoreResult.message)" `
                    "성공 - $([string]$restoreResult.message)"
                $restoreStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            }
            else {
                $restoreStatus.Text = Get-PalworldLocalizedText `
                    "Fail - $([string]$restoreResult.message)" `
                    "실패 - $([string]$restoreResult.message)"
                $restoreStatus.ForeColor = [System.Drawing.Color]::DarkRed
            }
        }
        catch {
            if ($subscription.Cancellation.IsCancellationRequested) {
                if (-not $restoreState.Closing -and -not $dialog.IsDisposed) {
                    $restoreStatus.Text = Get-PalworldLocalizedText `
                        "Progress view stopped - server restore continues" `
                        "진행 화면 중지 - 서버 복원은 계속됩니다"
                    $restoreStatus.ForeColor = [System.Drawing.Color]::DarkOrange
                    Add-PalworldBoundedRichTextLog -Control $restoreLog -Text (Get-PalworldLocalizedText `
                        "Only this Windows progress subscription was stopped. The Linux server-side restore was not canceled and continues independently.`r`n" `
                        "Windows 진행 표시만 중지했습니다. Linux 서버의 복원 작업은 취소되지 않았고 독립적으로 계속됩니다.`r`n")
                }
            }
            elseif (-not $restoreState.Closing -and -not $dialog.IsDisposed) {
                $restoreStatus.Text = Get-PalworldLocalizedText "Fail" "실패"
                $restoreStatus.ForeColor = [System.Drawing.Color]::DarkRed
                $safeDetail = Protect-DisplayText `
                    -Text (Get-PalworldHttpFailureDetail -Exception $_.Exception) `
                    -ServerHost ([string]$script:ConnectionSettings.ServerHost)
                Add-PalworldBoundedRichTextLog -Control $restoreLog -Text (Get-PalworldLocalizedText `
                    "The restore connection ended unexpectedly. The server-side operation may still be running; inspect data/serverN/logs/runtime.log.`r`n$safeDetail`r`n" `
                    "복원 연결이 예기치 않게 종료되었습니다. 서버 작업은 계속 실행 중일 수 있으므로 data/serverN/logs/runtime.log를 확인하세요.`r`n$safeDetail`r`n")
            }
        }
        finally {
            $restoreState.InProgress = $false
            $script:RestoreInProgress = $false
            $restoreState.Subscription = $null
            try { $subscription.Cancellation.Dispose() } catch { }
            if (-not $restoreState.Closing -and -not $dialog.IsDisposed) {
                $refreshButton.Enabled = $true
                $restoreButton.Enabled = $true
                $backupList.Enabled = $true
                $restoreWaitInput.Enabled = $true
            }
        }
        if (-not $restoreState.Closing -and -not $dialog.IsDisposed -and
            $null -ne $restoreResult -and [bool]$restoreResult.success) {
            $completedStatus = $restoreStatus.Text
            & $refreshBackups
            $restoreStatus.Text = $completedStatus
            $restoreStatus.ForeColor = [System.Drawing.Color]::DarkGreen
        }
    })

    $dialog.Add_FormClosing({
        param($sender, $eventArgs)
        $restoreState.Closing = $true
        if ($restoreState.RefreshOperation) {
            Stop-PalworldHttpOperation -Operation $restoreState.RefreshOperation
        }
        if ($restoreState.InProgress) {
            $restoreStatus.Text = Get-PalworldLocalizedText `
                "Closing progress view - server restore continues" `
                "진행 화면 닫는 중 - 서버 복원은 계속됩니다"
            $restoreStatus.ForeColor = [System.Drawing.Color]::DarkOrange
            if ($restoreState.Subscription) {
                Stop-PalworldRestoreSubscription -Subscription $restoreState.Subscription
            }
        }
        # Closing detaches only the HTTP progress subscriber. Linux intentionally
        # continues the already accepted restore after the client disconnects.
        $eventArgs.Cancel = $false
    }.GetNewClosure())
    $dialog.Add_FormClosed({
        if ($restoreState.RefreshOperation) {
            Stop-PalworldHttpOperation -Operation $restoreState.RefreshOperation
        }
        if ($restoreState.Subscription) {
            Stop-PalworldRestoreSubscription -Subscription $restoreState.Subscription
        }
    }.GetNewClosure())
    if ($env:PALWORLD_CLIENT_TEST_MODE -eq "restore-close") {
        $phase = [string]$env:PALWORLD_RESTORE_CLOSE_TEST_PHASE
        if ($phase -notin @("Send", "Read", "Refresh")) {
            throw "Restore close test phase is invalid."
        }
        if ($phase -eq "Refresh") {
            $operation = New-PalworldHttpOperation
            $fakeClient = New-Object psobject -Property @{ CancelCalled = $false }
            $fakeClient | Add-Member -MemberType ScriptMethod -Name CancelPendingRequests -Value {
                $this.CancelCalled = $true
            }
            $fakeResponse = New-Object psobject -Property @{ Disposed = $false }
            $fakeResponse | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
                $this.Disposed = $true
            }
            $operation.Client = $fakeClient
            $operation.Response = $fakeResponse
            $restoreState.RefreshOperation = $operation
            $stuck = New-Object 'Threading.Tasks.TaskCompletionSource[object]'
            $closeTimer = New-Object System.Windows.Forms.Timer
            $closeTimer.Interval = 75
            $closeTimer.Add_Tick({
                $closeTimer.Stop()
                $dialog.Close()
            }.GetNewClosure())
            $canceled = $false
            $startedAt = [DateTime]::UtcNow
            try {
                $dialog.Show()
                $closeTimer.Start()
                [void](Wait-PalworldHttpTask -Task $stuck.Task -Operation $operation)
            }
            catch [OperationCanceledException] { $canceled = $true }
            finally {
                $closeTimer.Stop()
                $closeTimer.Dispose()
                $restoreState.RefreshOperation = $null
            }
            if (-not $canceled -or -not $operation.Cancellation.IsCancellationRequested -or
                -not $restoreState.Closing -or -not $fakeClient.CancelCalled -or
                -not $fakeResponse.Disposed -or
                ([DateTime]::UtcNow - $startedAt).TotalSeconds -ge 2) {
                throw "A stuck backup refresh prevented the restore dialog from closing promptly."
            }
            $operation.Cancellation.Dispose()
            if (-not $dialog.IsDisposed) { $dialog.Dispose() }
            return
        }
        $subscription = New-PalworldRestoreSubscription
        $fakeResource = New-Object psobject -Property @{
            CancelCalled = $false
            Disposed = $false
        }
        $fakeResource | Add-Member -MemberType ScriptMethod -Name CancelPendingRequests -Value {
            $this.CancelCalled = $true
        }
        $fakeResource | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
            $this.Disposed = $true
        }
        if ($phase -eq "Send") { $subscription.Client = $fakeResource }
        else { $subscription.Reader = $fakeResource }
        $restoreState.Subscription = $subscription
        $restoreState.InProgress = $true
        $script:RestoreInProgress = $true
        $stuck = New-Object 'Threading.Tasks.TaskCompletionSource[object]'
        $closeTimer = New-Object System.Windows.Forms.Timer
        $closeTimer.Interval = 75
        $closeTimer.Add_Tick({
            $closeTimer.Stop()
            $dialog.Close()
        }.GetNewClosure())
        $canceled = $false
        $startedAt = [DateTime]::UtcNow
        try {
            $dialog.Show()
            $closeTimer.Start()
            [void](Wait-PalworldRestoreTask `
                -Task $stuck.Task `
                -Subscription $subscription)
        }
        catch [OperationCanceledException] {
            $canceled = $true
        }
        finally {
            $closeTimer.Stop()
            $closeTimer.Dispose()
            $restoreState.InProgress = $false
            $script:RestoreInProgress = $false
        }
        $resourceStopped = if ($phase -eq "Send") {
            [bool]$fakeResource.CancelCalled
        }
        else { [bool]$fakeResource.Disposed }
        if (-not $canceled -or -not $subscription.Cancellation.IsCancellationRequested -or
            -not $restoreState.Closing -or -not $resourceStopped -or
            ([DateTime]::UtcNow - $startedAt).TotalSeconds -ge 2) {
            throw "A stuck restore $phase subscription prevented the dialog from closing promptly."
        }
        $subscription.Cancellation.Dispose()
        if (-not $dialog.IsDisposed) { $dialog.Dispose() }
        return
    }
    if ($env:PALWORLD_CLIENT_TEST_MODE -eq "restore") {
        $bitmap = New-Object System.Drawing.Bitmap(780, 640)
        try {
            $dialog.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, 780, 640)))
        }
        finally {
            $bitmap.Dispose()
            $dialog.Dispose()
        }
        return
    }
    $dialog.Add_Shown({ & $refreshBackups })
    $ownerClosingHandler = $null
    if ($Owner -is [System.Windows.Forms.Form]) {
        $ownerClosingHandler = {
            $restoreState.Closing = $true
            if ($restoreState.RefreshOperation) {
                Stop-PalworldHttpOperation -Operation $restoreState.RefreshOperation
            }
            if ($restoreState.Subscription) {
                Stop-PalworldRestoreSubscription -Subscription $restoreState.Subscription
            }
            if (-not $dialog.IsDisposed) { $dialog.Close() }
        }.GetNewClosure()
        $Owner.Add_FormClosing($ownerClosingHandler)
    }
    try {
        [void]$dialog.ShowDialog($Owner)
    }
    finally {
        if ($ownerClosingHandler -and $Owner -is [System.Windows.Forms.Form]) {
            try { $Owner.Remove_FormClosing($ownerClosingHandler) } catch { }
        }
        $dialog.Dispose()
    }
}

function Show-RuntimeLogDialog {
    param([System.Windows.Forms.IWin32Window]$Owner)

    $dialog = New-Object System.Windows.Forms.Form
    $dialog.Text = Get-PalworldLocalizedText "Server runtime logs" "서버 런타임 로그"
    $dialog.StartPosition = "CenterParent"
    $dialog.ClientSize = New-Object System.Drawing.Size(900, 650)
    $dialog.MinimumSize = New-Object System.Drawing.Size(760, 500)
    $dialog.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    Set-WindowIcon $dialog

    $sourceLabel = New-Object System.Windows.Forms.Label
    $sourceLabel.Text = Get-PalworldLocalizedText "Source" "출처"
    $sourceLabel.Location = New-Object System.Drawing.Point(14, 18)
    $sourceLabel.AutoSize = $true
    $dialog.Controls.Add($sourceLabel)

    $sourceCombo = New-Object System.Windows.Forms.ComboBox
    $sourceCombo.Location = New-Object System.Drawing.Point(70, 14)
    $sourceCombo.Size = New-Object System.Drawing.Size(150, 23)
    $sourceCombo.DropDownStyle = "DropDownList"
    foreach ($source in @("all", "game", "manager", "api", "update", "restore")) {
        [void]$sourceCombo.Items.Add($source)
    }
    $sourceCombo.SelectedIndex = 0
    $dialog.Controls.Add($sourceCombo)

    $linesLabel = New-Object System.Windows.Forms.Label
    $linesLabel.Text = Get-PalworldLocalizedText "Recent lines" "최근 줄 수"
    $linesLabel.Location = New-Object System.Drawing.Point(240, 18)
    $linesLabel.AutoSize = $true
    $dialog.Controls.Add($linesLabel)

    $linesInput = New-Object System.Windows.Forms.NumericUpDown
    $linesInput.Location = New-Object System.Drawing.Point(325, 14)
    $linesInput.Size = New-Object System.Drawing.Size(100, 23)
    $linesInput.Minimum = 1
    $linesInput.Maximum = 5000
    $linesInput.Value = 500
    $dialog.Controls.Add($linesInput)

    $refresh = New-Object System.Windows.Forms.Button
    $refresh.Text = Get-PalworldLocalizedText "Refresh" "새로고침"
    $refresh.Location = New-Object System.Drawing.Point(445, 10)
    $refresh.Size = New-Object System.Drawing.Size(100, 31)
    $dialog.Controls.Add($refresh)

    $status = New-Object System.Windows.Forms.Label
    $status.Text = Get-PalworldLocalizedText "Ready" "준비"
    $status.Location = New-Object System.Drawing.Point(565, 18)
    $status.Size = New-Object System.Drawing.Size(320, 22)
    $status.Anchor = "Top,Left,Right"
    $dialog.Controls.Add($status)

    $logText = New-Object System.Windows.Forms.RichTextBox
    $logText.Location = New-Object System.Drawing.Point(12, 52)
    $logText.Size = New-Object System.Drawing.Size(876, 585)
    $logText.Anchor = "Top,Bottom,Left,Right"
    $logText.ReadOnly = $true
    $logText.WordWrap = $false
    $logText.Font = New-Object System.Drawing.Font("Consolas", 9)
    $dialog.Controls.Add($logText)
    $logState = [pscustomobject]@{
        Closing = $false
        Operation = $null
    }

    $loadLogs = {
        if ($logState.Closing -or $dialog.IsDisposed) { return }
        $settings = $script:ConnectionSettings
        if (-not $settings.ServerHost -or -not $settings.Password) {
            [void][System.Windows.Forms.MessageBox]::Show(
                (Get-PalworldLocalizedText "Select a valid Connection first." "먼저 올바른 연결을 선택하세요."),
                (Get-PalworldLocalizedText "Connection required" "연결 필요")
            )
            return
        }
        $refresh.Enabled = $false
        $status.Text = Get-PalworldLocalizedText "Loading..." "불러오는 중..."
        $status.ForeColor = [System.Drawing.Color]::DarkOrange
        $operation = New-PalworldHttpOperation
        $logState.Operation = $operation
        try {
            $source = [string]$sourceCombo.SelectedItem
            $uri = Get-PalworldApiUri `
                -ServerAddress ([string]$settings.ServerHost) `
                -Port ([int]$settings.Port) `
                -PathAndQuery "/v1/manager/logs?lines=$([int]$linesInput.Value)&source=$source"
            $result = Invoke-PalworldRequest `
                -Uri $uri `
                -Method "GET" `
                -Username $settings.Username `
                -Password $settings.Password `
                -AccessToken $settings.AccessToken `
                -TimeoutSeconds 60 `
                -Operation $operation
            if (-not $result.Success) {
                throw "HTTP $($result.StatusCode) $($result.Reason): $($result.Body)"
            }
            $payload = $result.Body | ConvertFrom-Json
            $fileLabel = Get-PalworldLocalizedText "File" "파일"
            $sourceHeaderLabel = Get-PalworldLocalizedText "Source" "출처"
            $returnedLabel = Get-PalworldLocalizedText "returned" "반환 줄 수"
            $header = "${fileLabel}: $([string]$payload.log_file)`r`n" +
                "${sourceHeaderLabel}: $([string]$payload.source), ${returnedLabel}: $([int]$payload.returned_lines)`r`n" +
                ("-" * 90) + "`r`n"
            $logText.Text = $header + ((@($payload.lines) | ForEach-Object { [string]$_ }) -join "`r`n")
            $logText.SelectionStart = $logText.TextLength
            $logText.ScrollToCaret()
            $status.Text = Get-PalworldLocalizedText "Success" "성공"
            $status.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        catch {
            if ($logState.Closing -or $dialog.IsDisposed) { return }
            $status.Text = Get-PalworldLocalizedText "Fail" "실패"
            $status.ForeColor = [System.Drawing.Color]::DarkRed
            $logText.Text = Get-PalworldHttpFailureDetail -Exception $_.Exception
        }
        finally {
            if ($logState.Operation -eq $operation) { $logState.Operation = $null }
            try { $operation.Cancellation.Dispose() } catch { }
            if (-not $logState.Closing -and -not $dialog.IsDisposed) {
                $refresh.Enabled = $true
            }
        }
    }
    $refresh.Add_Click({ & $loadLogs })

    if ($env:PALWORLD_CLIENT_TEST_MODE -eq "logs") {
        $bitmap = New-Object System.Drawing.Bitmap(900, 650)
        try {
            $dialog.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, 900, 650)))
        }
        finally {
            $bitmap.Dispose()
            $dialog.Dispose()
        }
        return
    }
    $dialog.Add_Shown({ & $loadLogs })
    $dialog.Add_FormClosing({
        $logState.Closing = $true
        if ($logState.Operation) {
            Stop-PalworldHttpOperation -Operation $logState.Operation
        }
    }.GetNewClosure())
    try {
        [void]$dialog.ShowDialog($Owner)
    }
    finally {
        if ($logState.Operation) {
            Stop-PalworldHttpOperation -Operation $logState.Operation
        }
        $dialog.Dispose()
    }
}

function New-ResourceUsageFooter {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner)
    $panel = New-Object System.Windows.Forms.Panel
    $panel.Name = "ResourceUsageFooter"
    $panel.Dock = "Bottom"
    $panel.Height = if ($script:IsAdminEdition) { 98 } else { 66 }
    $panel.BorderStyle = "FixedSingle"
    $panel.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 250)
    $panel.AutoScroll = $false
    $script:ResourceUsageFooter = $panel
    $script:ResourceUsageToolTip = New-Object System.Windows.Forms.ToolTip
    $script:ResourceUsageToolTip.AutoPopDelay = 20000
    $script:ResourceUsageToolTip.InitialDelay = 350
    $script:ResourceUsageToolTip.ReshowDelay = 100

    $footerLayout = New-Object System.Windows.Forms.TableLayoutPanel
    $footerLayout.Dock = "Fill"
    $footerLayout.Margin = New-Object System.Windows.Forms.Padding(0)
    $footerLayout.Padding = New-Object System.Windows.Forms.Padding(0)
    $footerLayout.RowCount = 2
    $footerLayout.ColumnCount = 1
    [void]$footerLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$footerLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    [void]$footerLayout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 24)))
    $panel.Controls.Add($footerLayout)

    $layout = New-Object System.Windows.Forms.TableLayoutPanel
    $layout.Dock = "Fill"
    $layout.Margin = New-Object System.Windows.Forms.Padding(0)
    $layout.Padding = New-Object System.Windows.Forms.Padding(6, 3, 6, 3)
    $layout.RowCount = if ($script:IsAdminEdition) { 2 } else { 1 }
    $layout.ColumnCount = if ($script:IsAdminEdition) { 7 } else { 6 }
    $layout.AutoScroll = $false
    $footerLayout.Controls.Add($layout, 0, 0)

    $projectStatus = New-Object System.Windows.Forms.StatusStrip
    $projectStatus.Name = "ProjectStatusStrip"
    $projectStatus.Dock = "Fill"
    $projectStatus.SizingGrip = $false
    $projectStatus.BackColor = [System.Drawing.Color]::FromArgb(242, 243, 245)
    $projectStatus.Padding = New-Object System.Windows.Forms.Padding(4, 0, 4, 0)
    $projectLink = New-Object System.Windows.Forms.ToolStripStatusLabel($script:ProjectName)
    $projectLink.IsLink = $true
    $projectLink.ToolTipText = $script:ProjectRepositoryUrl
    $projectLink.Add_Click({
        Open-PalworldProjectUrl -Url $script:ProjectRepositoryUrl -Owner $Owner
    }.GetNewClosure())
    $projectSpacer = New-Object System.Windows.Forms.ToolStripStatusLabel
    $projectSpacer.Spring = $true
    $licenseLink = New-Object System.Windows.Forms.ToolStripStatusLabel("GPL-3.0")
    $licenseLink.IsLink = $true
    $licenseLink.Add_Click({ Show-PalworldProjectLicense -Owner $Owner }.GetNewClosure())
    $maintainerPrefix = New-Object System.Windows.Forms.ToolStripStatusLabel("by")
    $maintainerLink = New-Object System.Windows.Forms.ToolStripStatusLabel($script:MaintainerName)
    $maintainerLink.IsLink = $true
    $maintainerLink.ToolTipText = $script:MaintainerUrl
    $maintainerLink.Add_Click({
        Open-PalworldProjectUrl -Url $script:MaintainerUrl -Owner $Owner
    }.GetNewClosure())
    foreach ($item in @($projectLink, $projectSpacer, $licenseLink, $maintainerPrefix, $maintainerLink)) {
        [void]$projectStatus.Items.Add($item)
    }
    $footerLayout.Controls.Add($projectStatus, 0, 1)
    $script:ProjectStatusStrip = $projectStatus
    $script:ProjectRepositoryLink = $projectLink
    $script:ProjectLicenseLink = $licenseLink
    $script:ProjectMaintainerLink = $maintainerLink

    if ($script:IsAdminEdition) {
        foreach ($width in @(72, 103, 94, 178, 128, 100)) {
            [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, $width)))
        }
        [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
        [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))
        [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 50)))
    }
    else {
        foreach ($width in @(58, 95, 178, 128, 105)) {
            [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Absolute, $width)))
        }
        [void]$layout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 100)))
        [void]$layout.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
    }

    $newLabel = {
        param([string]$Text, [string]$Name = "")
        $label = New-Object System.Windows.Forms.Label
        $label.Text = $Text
        $label.Name = $Name
        $label.Dock = "Fill"
        $label.TextAlign = "MiddleLeft"
        $label.AutoEllipsis = $true
        $label.Margin = New-Object System.Windows.Forms.Padding(4, 1, 2, 1)
        return $label
    }
    if ($script:IsAdminEdition) {
        $hostTitle = & $newLabel (Get-PalworldLocalizedText "Host" "호스트") "ResourceUsageHostTitle"
        $hostTitle.Font = New-Object System.Drawing.Font($Owner.Font, [System.Drawing.FontStyle]::Bold)
        $layout.Controls.Add($hostTitle, 0, 0)
        $layout.SetColumnSpan($hostTitle, 2)
        $script:ResourceUsageHostCpu = & $newLabel "CPU —" "ResourceUsageHostCpu"
        $script:ResourceUsageHostMemory = & $newLabel (Get-PalworldLocalizedText "Memory —" "메모리 —") "ResourceUsageHostMemory"
        $script:ResourceUsageHostReceive = & $newLabel "↓ —" "ResourceUsageHostReceive"
        $script:ResourceUsageHostTransmit = & $newLabel "↑ —" "ResourceUsageHostTransmit"
        $layout.Controls.Add($script:ResourceUsageHostCpu, 2, 0)
        $layout.Controls.Add($script:ResourceUsageHostMemory, 3, 0)
        $layout.Controls.Add($script:ResourceUsageHostReceive, 4, 0)
        $layout.Controls.Add($script:ResourceUsageHostTransmit, 5, 0)
        $script:ResourceUsageHostHistoryButton = New-Object System.Windows.Forms.Button
        $script:ResourceUsageHostHistoryButton.Name = "ResourceUsageHostHistoryButton"
        $script:ResourceUsageHostHistoryButton.Text = Get-PalworldLocalizedText "Host trend" "호스트 동향"
        $script:ResourceUsageHostHistoryButton.Dock = "Right"
        $script:ResourceUsageHostHistoryButton.Width = 105
        $script:ResourceUsageHostHistoryButton.Margin = New-Object System.Windows.Forms.Padding(2, 1, 1, 1)
        $layout.Controls.Add($script:ResourceUsageHostHistoryButton, 6, 0)

        $containerTitle = & $newLabel (Get-PalworldLocalizedText "Palworld" "팰월드") "ResourceUsageContainerTitle"
        $containerTitle.Font = New-Object System.Drawing.Font($Owner.Font, [System.Drawing.FontStyle]::Bold)
        $layout.Controls.Add($containerTitle, 0, 1)
        $script:ResourceUsageServerCombo = New-Object System.Windows.Forms.ComboBox
        $script:ResourceUsageServerCombo.Name = "ResourceUsageServerCombo"
        $script:ResourceUsageServerCombo.Dock = "Fill"
        $script:ResourceUsageServerCombo.DropDownStyle = "DropDownList"
        $script:ResourceUsageServerCombo.Margin = New-Object System.Windows.Forms.Padding(2, 3, 5, 2)
        $script:ResourceUsageServerCombo.Enabled = $false
        $layout.Controls.Add($script:ResourceUsageServerCombo, 1, 1)
        $script:ResourceUsageContainerCpu = & $newLabel "CPU —" "ResourceUsageContainerCpu"
        $script:ResourceUsageContainerMemory = & $newLabel (Get-PalworldLocalizedText "Memory —" "메모리 —") "ResourceUsageContainerMemory"
        $script:ResourceUsageContainerReceive = & $newLabel "↓ —" "ResourceUsageContainerReceive"
        $script:ResourceUsageContainerTransmit = & $newLabel "↑ —" "ResourceUsageContainerTransmit"
        $layout.Controls.Add($script:ResourceUsageContainerCpu, 2, 1)
        $layout.Controls.Add($script:ResourceUsageContainerMemory, 3, 1)
        $layout.Controls.Add($script:ResourceUsageContainerReceive, 4, 1)
        $layout.Controls.Add($script:ResourceUsageContainerTransmit, 5, 1)
        $script:ResourceUsageContainerHistoryButton = New-Object System.Windows.Forms.Button
        $script:ResourceUsageContainerHistoryButton.Name = "ResourceUsageContainerHistoryButton"
        $script:ResourceUsageContainerHistoryButton.Text = Get-PalworldLocalizedText "Container trend" "컨테이너 동향"
        $script:ResourceUsageContainerHistoryButton.Dock = "Right"
        $script:ResourceUsageContainerHistoryButton.Width = 105
        $script:ResourceUsageContainerHistoryButton.Margin = New-Object System.Windows.Forms.Padding(2, 1, 1, 1)
        $layout.Controls.Add($script:ResourceUsageContainerHistoryButton, 6, 1)
    }
    else {
        $hostTitle = & $newLabel (Get-PalworldLocalizedText "Server" "서버") "ResourceUsageHostTitle"
        $hostTitle.Font = New-Object System.Drawing.Font($Owner.Font, [System.Drawing.FontStyle]::Bold)
        $script:ResourceUsageHostCpu = & $newLabel "CPU —" "ResourceUsageHostCpu"
        $script:ResourceUsageHostMemory = & $newLabel (Get-PalworldLocalizedText "Memory —" "메모리 —") "ResourceUsageHostMemory"
        $script:ResourceUsageHostReceive = & $newLabel "↓ —" "ResourceUsageHostReceive"
        $script:ResourceUsageHostTransmit = & $newLabel "↑ —" "ResourceUsageHostTransmit"
        $layout.Controls.Add($hostTitle, 0, 0)
        $layout.Controls.Add($script:ResourceUsageHostCpu, 1, 0)
        $layout.Controls.Add($script:ResourceUsageHostMemory, 2, 0)
        $layout.Controls.Add($script:ResourceUsageHostReceive, 3, 0)
        $layout.Controls.Add($script:ResourceUsageHostTransmit, 4, 0)
        $script:ResourceUsageHostHistoryButton = New-Object System.Windows.Forms.Button
        $script:ResourceUsageHostHistoryButton.Name = "ResourceUsageHostHistoryButton"
        $script:ResourceUsageHostHistoryButton.Text = Get-PalworldLocalizedText "Recent trend" "최근 동향"
        $script:ResourceUsageHostHistoryButton.Dock = "Right"
        $script:ResourceUsageHostHistoryButton.Width = 105
        $script:ResourceUsageHostHistoryButton.Margin = New-Object System.Windows.Forms.Padding(2, 1, 1, 1)
        $layout.Controls.Add($script:ResourceUsageHostHistoryButton, 5, 0)
    }
    $script:ResourceUsageHostHistoryButton.Add_Click({ Show-ResourceUsageHistoryDialog -Owner $Owner -Scope Host }.GetNewClosure())
    if ($script:IsAdminEdition) {
        $script:ResourceUsageContainerHistoryButton.Add_Click({ Show-ResourceUsageHistoryDialog -Owner $Owner -Scope Container }.GetNewClosure())
    }
    $Owner.Controls.Add($panel)
    $panel.Dock = "None"
    $panel.Location = New-Object System.Drawing.Point(0, ($Owner.ClientSize.Height - $panel.Height))
    $panel.Size = New-Object System.Drawing.Size($Owner.ClientSize.Width, $panel.Height)
    $panel.Anchor = "Bottom,Left,Right"
    if ($script:IsAdminEdition -and $script:AdminTabLayout) {
        $script:AdminTabLayout.Tabs.Dock = "None"
        $script:AdminTabLayout.Tabs.Location = New-Object System.Drawing.Point(0, 0)
        $script:AdminTabLayout.Tabs.Size = New-Object System.Drawing.Size(
            $Owner.ClientSize.Width,
            ($Owner.ClientSize.Height - $panel.Height)
        )
        $script:AdminTabLayout.Tabs.Anchor = "Top,Bottom,Left,Right"
    }
    $panel.BringToFront()
    return $panel
}

function Stop-ResourceUsagePolling {
    if ($script:ResourceUsageClosing) { return }
    $script:ResourceUsageClosing = $true
    if ($script:ResourceUsageTimer) {
        $script:ResourceUsageTimer.Stop()
        $script:ResourceUsageTimer.Dispose()
        $script:ResourceUsageTimer = $null
    }
    $pending = $script:ResourceUsagePending
    $script:ResourceUsagePending = $null
    if ($script:ResourceUsageClient) {
        try { $script:ResourceUsageClient.CancelPendingRequests() } catch { }
        $script:ResourceUsageClient.Dispose()
        $script:ResourceUsageClient = $null
    }
    if ($pending -and $pending.Request) {
        try { $pending.Request.Dispose() } catch { }
    }
    if ($script:ResourceUsageToolTip) {
        $script:ResourceUsageToolTip.Dispose()
        $script:ResourceUsageToolTip = $null
    }
}

function Initialize-ResourceUsagePolling {
    param([Parameter(Mandatory = $true)][System.Windows.Forms.Form]$Owner)
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $script:ResourceUsageClient = New-Object System.Net.Http.HttpClient($handler, $true)
    $script:ResourceUsageClient.Timeout = [TimeSpan]::FromSeconds(3)
    $script:ResourceUsageClosing = $false

    $script:ResourceUsageRefreshContext = {
        if ($script:ResourceUsageClosing -or $script:ResourceUsageServerChanging) { return }
        $desiredServer = Get-ResourceUsageSelectedServerName
        if ($script:IsAdminEdition -and $script:ResourceUsageServerCombo) {
            $serverNames = @(Get-ResourceUsageAdminServerNames)
            $script:ResourceUsageServerChanging = $true
            try {
                $script:ResourceUsageServerCombo.Items.Clear()
                foreach ($serverName in $serverNames) {
                    [void]$script:ResourceUsageServerCombo.Items.Add($serverName)
                }
                $selectedIndex = if ($desiredServer) {
                    $script:ResourceUsageServerCombo.Items.IndexOf($desiredServer)
                }
                else { -1 }
                if ($selectedIndex -lt 0 -and $script:ResourceUsageServerCombo.Items.Count -gt 0) {
                    $selectedIndex = 0
                }
                $script:ResourceUsageServerCombo.SelectedIndex = $selectedIndex
            }
            finally { $script:ResourceUsageServerChanging = $false }
        }
        $script:ResourceUsageContextGeneration++
        Reset-ResourceUsagePollingBackoff
        try { $script:ResourceUsageClient.CancelPendingRequests() } catch { }
        $context = Get-ResourceUsageApiContext
        if ($script:ResourceUsageTimer) {
            $script:ResourceUsageTimer.Interval = if ($context.Ready) { 250 } else { 1000 }
        }
        $targetLabel = Get-PalworldLocalizedText "Target" "대상"
        Set-ResourceUsageUnavailable $context.Message "${targetLabel}: $([string]$context.TargetDescription)"
        $script:ResourceUsageHostHistoryButton.Enabled = [bool]$context.Ready
        if ($script:IsAdminEdition) {
            $selectedTab = if ($script:AdminTabLayout -and $script:AdminTabLayout.Tabs) {
                [int]$script:AdminTabLayout.Tabs.SelectedIndex
            } else { -1 }
            $script:ResourceUsageServerCombo.Visible = ($selectedTab -eq 1)
            $script:ResourceUsageServerCombo.Enabled = $false
            $script:ResourceUsageContainerHistoryButton.Enabled = (
                $context.Ready -and $context.ContainerMatches
            )
        }
    }

    if ($script:IsAdminEdition -and $script:ResourceUsageServerCombo) {
        $script:ResourceUsageServerCombo.Add_SelectedIndexChanged({
            if ($script:ResourceUsageServerChanging -or $script:ResourceUsageServerCombo.SelectedIndex -lt 0) { return }
            $serverName = [string]$script:ResourceUsageServerCombo.SelectedItem
            if ($serverName -notmatch '^server[1-9][0-9]*$') { return }
            $script:ResourceUsageServerChanging = $true
            try {
                $selectedApi = Get-SelectedAdminApiConnection
                $selectedTab = if ($script:AdminTabLayout -and $script:AdminTabLayout.Tabs) {
                    [int]$script:AdminTabLayout.Tabs.SelectedIndex
                }
                else { -1 }
                $ssh = if ($selectedTab -eq 0 -and $selectedApi) {
                    Get-LinkedSshConnection $selectedApi
                }
                else { Get-PalworldSshSynchronizationConnection }
                if ($ssh) {
                    Set-PalworldSshLastSelectedServer -Connection $ssh -Server $serverName
                    if ($script:PalworldSshServerCombo -and $script:PalworldSshServerCombo.Items.Contains($serverName)) {
                        $script:PalworldSshServerCombo.SelectedIndex = $script:PalworldSshServerCombo.Items.IndexOf($serverName)
                    }
                }
                $sshId = if ($ssh) { [string]$ssh.Id } else { "" }
                $matchingApis = @($script:AdminConnections | Where-Object {
                    [string]$_.ManagedServerName -eq $serverName -and
                    ((-not $sshId) -or [string]$_.SshConnectionId -eq $sshId)
                })
                $api = $matchingApis | Where-Object {
                    $selectedApi -and [string]$_.Id -eq [string]$selectedApi.Id
                } | Select-Object -First 1
                if (-not $api -and $matchingApis.Count -eq 1) { $api = $matchingApis[0] }
                if ($api -and -not $script:PalworldSshOperationRunning -and $script:AdminSelectApiConnection) {
                    $previousSync = $script:AdminSelectionSyncing
                    $script:AdminSelectionSyncing = $true
                    try { & $script:AdminSelectApiConnection ([string]$api.Id) }
                    finally { $script:AdminSelectionSyncing = $previousSync }
                }
                try { Save-AdminConnectionStore } catch { }
            }
            finally { $script:ResourceUsageServerChanging = $false }
            & $script:ResourceUsageRefreshContext
        })
    }

    $script:ResourceUsageTimer = New-Object System.Windows.Forms.Timer
    $script:ResourceUsageTimer.Interval = 250
    $script:ResourceUsagePollTick = {
        if ($script:ResourceUsageClosing) { return }
        if ($script:ResourceUsagePending) {
            if ($script:ResourceUsageTimer.Interval -ne 250) {
                $script:ResourceUsageTimer.Interval = 250
            }
            if (-not $script:ResourceUsagePending.Task.IsCompleted) { return }
            $pending = $script:ResourceUsagePending
            $script:ResourceUsagePending = $null
            $response = $null
            try {
                $response = $pending.Task.GetAwaiter().GetResult()
                $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
                $currentContext = Get-ResourceUsageApiContext
                if ($pending.Generation -ne $script:ResourceUsageContextGeneration -or
                    [string]$pending.ContextKey -ne [string]$currentContext.ContextKey) {
                    return
                }
                if ($response.IsSuccessStatusCode) {
                    try { $payload = $body | ConvertFrom-Json }
                    catch { throw [FormatException]::new("Resource usage API returned invalid JSON.", $_.Exception) }
                    Set-ResourceUsagePayload -Payload $payload -Context $currentContext
                    Set-ResourceUsagePollingResult -Kind Success -ContextKey ([string]$currentContext.ContextKey)
                }
                else {
                    $statusCode = [int]$response.StatusCode
                    $message = Get-ResourceUsageHttpStatusMessage -StatusCode $statusCode
                    $responseDetail = ConvertTo-ResourceUsageSafeDiagnostic `
                        -Text $body -Context $currentContext -MaximumLength 400
                    $targetLabel = Get-PalworldLocalizedText "Target" "대상"
                    $detail = "HTTP $statusCode $([string]$response.ReasonPhrase) · ${targetLabel}: $([string]$currentContext.TargetDescription)"
                    if ($responseDetail) { $detail += " · $responseDetail" }
                    if ($statusCode -in @(401, 403)) {
                        $detail += Get-PalworldLocalizedText `
                            " · Retrying resumes when the selected connection or credentials change." `
                            " · 연결 선택 또는 인증 설정을 변경하면 다시 시도합니다."
                        Set-ResourceUsagePollingResult -Kind Authentication -ContextKey ([string]$currentContext.ContextKey)
                    }
                    elseif ($statusCode -eq 404) {
                        Set-ResourceUsagePollingResult -Kind NotFound -ContextKey ([string]$currentContext.ContextKey)
                    }
                    elseif ($statusCode -in @(429, 503)) {
                        Set-ResourceUsagePollingResult -Kind Busy -ContextKey ([string]$currentContext.ContextKey)
                    }
                    else {
                        Set-ResourceUsagePollingResult -Kind Transient -ContextKey ([string]$currentContext.ContextKey)
                    }
                    Set-ResourceUsageUnavailable $message $detail
                }
            }
            catch {
                if (-not $script:ResourceUsageClosing -and
                    $pending.Generation -eq $script:ResourceUsageContextGeneration) {
                    $exception = $_.Exception
                    $cursor = $exception
                    $isCanceled = $false
                    $isFormat = $false
                    $isHttp = $false
                    while ($cursor) {
                        if ($cursor -is [OperationCanceledException] -or
                            $cursor -is [System.Threading.Tasks.TaskCanceledException]) { $isCanceled = $true }
                        if ($cursor -is [FormatException]) { $isFormat = $true }
                        if ($cursor -is [System.Net.Http.HttpRequestException]) { $isHttp = $true }
                        $cursor = $cursor.InnerException
                    }
                    $message = if ($isCanceled) {
                        Get-PalworldLocalizedText "Resource request timed out" "사용량 요청 시간 초과"
                    }
                    elseif ($isFormat) {
                        Get-PalworldLocalizedText "Invalid resource response" "사용량 응답 형식 오류"
                    }
                    elseif ($isHttp) {
                        Get-PalworldLocalizedText "Resource server connection failed" "사용량 서버 연결 실패"
                    }
                    else {
                        Get-PalworldLocalizedText "Resource display error" "사용량 표시 오류"
                    }
                    $innermost = Get-PalworldInnermostException -Exception $exception
                    $failureDetail = ConvertTo-ResourceUsageSafeDiagnostic `
                        -Text ("{0}: {1}" -f $innermost.GetType().Name, $innermost.Message) `
                        -Context (Get-ResourceUsageApiContext) -MaximumLength 500
                    Set-ResourceUsagePollingResult -Kind Transient -ContextKey ([string]$pending.ContextKey)
                    Set-ResourceUsageUnavailable $message $failureDetail
                }
            }
            finally {
                if ($response) { $response.Dispose() }
                if ($pending.Request) {
                    try { $pending.Request.Dispose() } catch { }
                }
            }
            return
        }
        if ($script:ResourceUsageBlockedContextKey) {
            $blockedContext = Get-ResourceUsageApiContext
            if ([string]$blockedContext.ContextKey -ne [string]$script:ResourceUsageBlockedContextKey) {
                Reset-ResourceUsagePollingBackoff
            }
        }
        if ([DateTime]::UtcNow -lt $script:ResourceUsageNextRequestUtc) { return }
        $context = Get-ResourceUsageApiContext
        if (-not $context.Ready) {
            if ($script:ResourceUsageTimer.Interval -ne 1000) {
                $script:ResourceUsageTimer.Interval = 1000
            }
            $targetLabel = Get-PalworldLocalizedText "Target" "대상"
            Set-ResourceUsageUnavailable $context.Message "${targetLabel}: $([string]$context.TargetDescription)"
            $script:ResourceUsageNextRequestUtc = [DateTime]::UtcNow.AddSeconds(1)
            return
        }
        if ($script:ResourceUsageTimer.Interval -ne 250) {
            $script:ResourceUsageTimer.Interval = 250
        }
        $request = $null
        try {
            $uri = Get-PalworldApiUri `
                -ServerAddress ([string]$context.ServerHost) `
                -Port ([int]$context.Port) `
                -PathAndQuery "/v1/manager/resources/current"
            $request = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $uri)
            $credentials = [Text.Encoding]::UTF8.GetBytes("$($context.Username):$($context.Password)")
            $basicToken = [Convert]::ToBase64String($credentials)
            $request.Headers.Authorization = New-Object System.Net.Http.Headers.AuthenticationHeaderValue("Basic", $basicToken)
            [void]$request.Headers.TryAddWithoutValidation("X-Palworld-Manager-Token", [string]$context.AccessToken)
            $request.Headers.Accept.Add((New-Object System.Net.Http.Headers.MediaTypeWithQualityHeaderValue("application/json")))
            $task = $script:ResourceUsageClient.SendAsync($request)
            $script:ResourceUsagePending = [pscustomobject]@{
                Task = $task
                Request = $request
                ContextKey = [string]$context.ContextKey
                Generation = $script:ResourceUsageContextGeneration
            }
        }
        catch {
            if ($request) { $request.Dispose() }
            $failureDetail = ConvertTo-ResourceUsageSafeDiagnostic `
                -Text (Get-PalworldHttpFailureDetail -Exception $_.Exception) `
                -Context $context -MaximumLength 500
            Set-ResourceUsagePollingResult -Kind Transient -ContextKey ([string]$context.ContextKey)
            Set-ResourceUsageUnavailable `
                (Get-PalworldLocalizedText "Could not start the resource request" "사용량 요청 시작 실패") `
                $failureDetail
        }
        if ($script:ResourceUsagePending) {
            $script:ResourceUsageNextRequestUtc = [DateTime]::UtcNow.AddSeconds(1)
        }
    }
    $script:ResourceUsageTimerTick = {
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = "Stop"
            & $script:ResourceUsagePollTick
        }
        catch {
            # This timer is dispatched by Application.DoEvents during long SSH
            # Setup/Manage commands.  A transient polling/UI race must remain a
            # footer diagnostic, never a WinForms unhandled-exception dialog.
            try {
                $failedPending = $script:ResourceUsagePending
                $script:ResourceUsagePending = $null
                if ($failedPending -and $failedPending.Request) {
                    try { $failedPending.Request.Dispose() } catch { }
                }
                if (-not $script:ResourceUsageClosing) {
                    $context = Get-ResourceUsageApiContext
                    $innermost = Get-PalworldInnermostException -Exception $_.Exception
                    $failureDetail = ConvertTo-ResourceUsageSafeDiagnostic `
                        -Text ("{0}: {1}" -f $innermost.GetType().Name, $innermost.Message) `
                        -Context $context -MaximumLength 500
                    Set-ResourceUsagePollingResult -Kind Transient -ContextKey ([string]$context.ContextKey)
                    Set-ResourceUsageUnavailable `
                        (Get-PalworldLocalizedText "Temporary resource display error" "사용량 표시 일시 오류") `
                        $failureDetail
                    $script:ResourceUsageNextRequestUtc = [DateTime]::UtcNow.AddSeconds(5)
                }
            }
            catch { }
        }
        finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
    }
    $script:ResourceUsageTimer.Add_Tick({
        try { & $script:ResourceUsageTimerTick } catch { }
    })
    & $script:ResourceUsageRefreshContext
    if (-not $env:PALWORLD_CLIENT_TEST_MODE) { $script:ResourceUsageTimer.Start() }
    $Owner.Add_FormClosing({
        param($sender, $eventArgs)
        if ($script:IsAdminEdition -and
            $script:PalworldSshNonCancelableTransaction -and
            $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
            return
        }
        if (-not $eventArgs.Cancel) { Stop-ResourceUsagePolling }
    })
    $Owner.Add_Disposed({ Stop-ResourceUsagePolling })
}

$form = New-Object System.Windows.Forms.Form
$form.Text = $script:ApplicationTitle
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedSingle"
$form.MaximizeBox = $false
$form.ClientSize = if ($script:IsAdminEdition) {
    New-Object System.Drawing.Size(900, 944)
}
else {
    New-Object System.Drawing.Size(780, 760)
}
$form.MinimumSize = if ($script:IsAdminEdition) {
    New-Object System.Drawing.Size(916, 759)
}
else {
    New-Object System.Drawing.Size(796, 739)
}
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
Set-WindowIcon $form
$form.Add_FormClosing({
    param($sender, $eventArgs)
    # SSH Management owns the user-facing close guard for an in-flight token
    # rotation. Do not tear down shared HTTP state before that later handler
    # cancels the close request.
    if ($script:IsAdminEdition -and
        $script:PalworldSshNonCancelableTransaction -and
        $eventArgs.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        return
    }
    Stop-PalworldHttpOperationsForExit
})

$connectionButton = $null
$verifyConnectionButton = $null
$verificationLabel = $null
$worldRestoreButton = $null
$runtimeLogButton = $null
$adminConnectionGroup = $null
$adminToolsGroup = $null
$connectionCombo = $null
$connectionNameText = $null
$connectionHostText = $null
$connectionPortText = $null
$connectionSummaryLabel = $null
$connectionSshText = $null
$connectionManagedText = $null
$connectionAddButton = $null
$connectionUpdateButton = $null
$connectionDeleteButton = $null

if ($script:IsAdminEdition) {
    $adminConnectionGroup = New-Object System.Windows.Forms.GroupBox
    $adminConnectionGroup.Text = "Connections - encrypted portable store"
    $adminConnectionGroup.Location = New-Object System.Drawing.Point(12, 10)
    $adminConnectionGroup.Size = New-Object System.Drawing.Size(876, 175)
    $adminConnectionGroup.Anchor = "Top,Left,Right"
    $form.Controls.Add($adminConnectionGroup)

    $connectionSelectLabel = New-Object System.Windows.Forms.Label
    $connectionSelectLabel.Text = "Connection"
    $connectionSelectLabel.Location = New-Object System.Drawing.Point(16, 31)
    $connectionSelectLabel.AutoSize = $true
    $adminConnectionGroup.Controls.Add($connectionSelectLabel)

    $connectionCombo = New-Object System.Windows.Forms.ComboBox
    $connectionCombo.Name = "AdminApiConnectionCombo"
    $connectionCombo.Location = New-Object System.Drawing.Point(105, 27)
    $connectionCombo.Size = New-Object System.Drawing.Size(440, 23)
    $connectionCombo.DropDownStyle = "DropDownList"
    $adminConnectionGroup.Controls.Add($connectionCombo)

    $connectionAddButton = New-Object System.Windows.Forms.Button
    $connectionAddButton.Text = "Add"
    $connectionAddButton.Location = New-Object System.Drawing.Point(570, 24)
    $connectionAddButton.Size = New-Object System.Drawing.Size(85, 29)
    $adminConnectionGroup.Controls.Add($connectionAddButton)

    $connectionUpdateButton = New-Object System.Windows.Forms.Button
    $connectionUpdateButton.Text = "Update"
    $connectionUpdateButton.Location = New-Object System.Drawing.Point(663, 24)
    $connectionUpdateButton.Size = New-Object System.Drawing.Size(90, 29)
    $adminConnectionGroup.Controls.Add($connectionUpdateButton)

    $connectionDeleteButton = New-Object System.Windows.Forms.Button
    $connectionDeleteButton.Text = "Delete"
    $connectionDeleteButton.Location = New-Object System.Drawing.Point(761, 24)
    $connectionDeleteButton.Size = New-Object System.Drawing.Size(90, 29)
    $adminConnectionGroup.Controls.Add($connectionDeleteButton)

    $connectionSummaryLabel = New-Object System.Windows.Forms.Label
    $connectionSummaryLabel.Text = ""
    $connectionSummaryLabel.Location = New-Object System.Drawing.Point(105, 145)
    $connectionSummaryLabel.Size = New-Object System.Drawing.Size(746, 20)
    $connectionSummaryLabel.ForeColor = [System.Drawing.Color]::DimGray
    $adminConnectionGroup.Controls.Add($connectionSummaryLabel)

    $nameLabel = New-Object System.Windows.Forms.Label
    $nameLabel.Text = "Name"
    $nameLabel.Location = New-Object System.Drawing.Point(16, 64)
    $nameLabel.AutoSize = $true
    $adminConnectionGroup.Controls.Add($nameLabel)

    $connectionNameText = New-Object System.Windows.Forms.TextBox
    $connectionNameText.Location = New-Object System.Drawing.Point(70, 60)
    $connectionNameText.Size = New-Object System.Drawing.Size(200, 23)
    $connectionNameText.ReadOnly = $true
    $connectionNameText.BackColor = [System.Drawing.SystemColors]::Window
    $adminConnectionGroup.Controls.Add($connectionNameText)

    $hostLabel = New-Object System.Windows.Forms.Label
    $hostLabel.Text = "API URL / Host"
    $hostLabel.Location = New-Object System.Drawing.Point(290, 64)
    $hostLabel.AutoSize = $true
    $adminConnectionGroup.Controls.Add($hostLabel)

    $connectionHostText = New-Object System.Windows.Forms.TextBox
    $connectionHostText.Location = New-Object System.Drawing.Point(355, 60)
    $connectionHostText.Size = New-Object System.Drawing.Size(325, 23)
    $connectionHostText.ReadOnly = $true
    $connectionHostText.BackColor = [System.Drawing.SystemColors]::Window
    $adminConnectionGroup.Controls.Add($connectionHostText)

    $portLabel = New-Object System.Windows.Forms.Label
    $portLabel.Text = "Port"
    $portLabel.Location = New-Object System.Drawing.Point(700, 64)
    $portLabel.AutoSize = $true
    $adminConnectionGroup.Controls.Add($portLabel)

    $connectionPortText = New-Object System.Windows.Forms.TextBox
    $connectionPortText.Location = New-Object System.Drawing.Point(742, 60)
    $connectionPortText.Size = New-Object System.Drawing.Size(109, 23)
    $connectionPortText.ReadOnly = $true
    $connectionPortText.BackColor = [System.Drawing.SystemColors]::Window
    $adminConnectionGroup.Controls.Add($connectionPortText)

    $sshLabel = New-Object System.Windows.Forms.Label
    $sshLabel.Text = "SSH"
    $sshLabel.Location = New-Object System.Drawing.Point(16, 91)
    $sshLabel.AutoSize = $true
    $adminConnectionGroup.Controls.Add($sshLabel)

    $connectionSshText = New-Object System.Windows.Forms.TextBox
    $connectionSshText.Name = "AdminApiSshConnectionField"
    $connectionSshText.Location = New-Object System.Drawing.Point(70, 87)
    $connectionSshText.Size = New-Object System.Drawing.Size(200, 23)
    $connectionSshText.ReadOnly = $true
    $connectionSshText.BackColor = [System.Drawing.SystemColors]::Window
    $adminConnectionGroup.Controls.Add($connectionSshText)

    $managedLabel = New-Object System.Windows.Forms.Label
    $managedLabel.Text = "Managed"
    $managedLabel.Location = New-Object System.Drawing.Point(290, 91)
    $managedLabel.AutoSize = $true
    $adminConnectionGroup.Controls.Add($managedLabel)

    $connectionManagedText = New-Object System.Windows.Forms.TextBox
    $connectionManagedText.Name = "AdminApiManagedServerField"
    $connectionManagedText.Location = New-Object System.Drawing.Point(355, 87)
    $connectionManagedText.Size = New-Object System.Drawing.Size(200, 23)
    $connectionManagedText.ReadOnly = $true
    $connectionManagedText.BackColor = [System.Drawing.SystemColors]::Window
    $adminConnectionGroup.Controls.Add($connectionManagedText)

    $adminToolsGroup = New-Object System.Windows.Forms.GroupBox
    $adminToolsGroup.Text = "Server Tools - selected Connection"
    $adminToolsGroup.Location = New-Object System.Drawing.Point(12, 195)
    $adminToolsGroup.Size = New-Object System.Drawing.Size(876, 65)
    $adminToolsGroup.Anchor = "Top,Left,Right"
    $form.Controls.Add($adminToolsGroup)

    $toolsHint = New-Object System.Windows.Forms.Label
    $toolsHint.Text = "Backup recovery and recent server-side runtime log viewer"
    $toolsHint.Location = New-Object System.Drawing.Point(16, 30)
    $toolsHint.Size = New-Object System.Drawing.Size(500, 23)
    $adminToolsGroup.Controls.Add($toolsHint)

    $worldRestoreButton = New-Object System.Windows.Forms.Button
    $worldRestoreButton.Text = "World Restore"
    $worldRestoreButton.Location = New-Object System.Drawing.Point(600, 22)
    $worldRestoreButton.Size = New-Object System.Drawing.Size(120, 32)
    $adminToolsGroup.Controls.Add($worldRestoreButton)

    $runtimeLogButton = New-Object System.Windows.Forms.Button
    $runtimeLogButton.Text = "Runtime Logs"
    $runtimeLogButton.Location = New-Object System.Drawing.Point(728, 22)
    $runtimeLogButton.Size = New-Object System.Drawing.Size(123, 32)
    $adminToolsGroup.Controls.Add($runtimeLogButton)
}
else {
    $verificationLabel = New-Object System.Windows.Forms.Label
    $verificationLabel.Text = Get-PalworldLocalizedText "Waiting for server verification" "서버 검증 대기"
    $verificationLabel.Location = New-Object System.Drawing.Point(12, 18)
    $verificationLabel.Size = New-Object System.Drawing.Size(390, 22)
    $verificationLabel.ForeColor = [System.Drawing.Color]::DarkOrange
    $form.Controls.Add($verificationLabel)

    $verifyConnectionButton = New-Object System.Windows.Forms.Button
    $verifyConnectionButton.Text = "Verify Server"
    $verifyConnectionButton.Location = New-Object System.Drawing.Point(410, 10)
    $verifyConnectionButton.Size = New-Object System.Drawing.Size(165, 32)
    $form.Controls.Add($verifyConnectionButton)

    $connectionButton = New-Object System.Windows.Forms.Button
    $connectionButton.Text = "Connection Settings"
    $connectionButton.Location = New-Object System.Drawing.Point(588, 10)
    $connectionButton.Size = New-Object System.Drawing.Size(180, 32)
    $connectionButton.Anchor = "Top,Right"
    $form.Controls.Add($connectionButton)
}

$commandTop = if ($script:IsAdminEdition) { 240 } else { 50 }
$contentWidth = if ($script:IsAdminEdition) { 876 } else { 756 }
$commandInputWidth = $contentWidth - 152
$resourceUsageFooterHeight = if ($script:IsAdminEdition) { 98 } else { 66 }

$commandGroup = New-Object System.Windows.Forms.GroupBox
$commandGroup.Text = "Request"
$commandGroup.Location = New-Object System.Drawing.Point(12, $commandTop)
$commandGroup.Size = New-Object System.Drawing.Size($contentWidth, 280)
$commandGroup.Anchor = "Top,Left,Right"
$form.Controls.Add($commandGroup)

$commandLabel = New-Object System.Windows.Forms.Label
$commandLabel.Text = $script:Text.CommandSelection
$commandLabel.Location = New-Object System.Drawing.Point(16, 31)
$commandLabel.AutoSize = $true
$commandGroup.Controls.Add($commandLabel)

$commandCombo = New-Object System.Windows.Forms.ComboBox
$commandCombo.Location = New-Object System.Drawing.Point(126, 27)
$commandCombo.Size = New-Object System.Drawing.Size($commandInputWidth, 23)
$commandCombo.DropDownStyle = "DropDownList"
$commandCombo.DrawMode = "OwnerDrawFixed"
$commandGroup.Controls.Add($commandCombo)

$basicLegend = New-Object System.Windows.Forms.Label
$basicLegend.Text = "Basic API"
$basicLegend.Location = New-Object System.Drawing.Point(126, 56)
$basicLegend.AutoSize = $true
$basicLegend.ForeColor = [System.Drawing.Color]::Black
$commandGroup.Controls.Add($basicLegend)

$advancedLegend = New-Object System.Windows.Forms.Label
$advancedLegend.Text = $script:Text.AdvancedCategory
$advancedLegend.Location = New-Object System.Drawing.Point(220, 56)
$advancedLegend.AutoSize = $true
$advancedLegend.ForeColor = [System.Drawing.Color]::RoyalBlue
$commandGroup.Controls.Add($advancedLegend)

$directLegend = New-Object System.Windows.Forms.Label
$directLegend.Text = "Direct Shutdown / Stop"
$directLegend.Location = New-Object System.Drawing.Point(390, 56)
$directLegend.AutoSize = $true
$directLegend.ForeColor = [System.Drawing.Color]::Firebrick
$commandGroup.Controls.Add($directLegend)

$playerIdLabel = New-Object System.Windows.Forms.Label
$playerIdLabel.Text = "Player userId"
$playerIdLabel.Location = New-Object System.Drawing.Point(16, 87)
$playerIdLabel.AutoSize = $true
$commandGroup.Controls.Add($playerIdLabel)

$playerIdText = New-Object System.Windows.Forms.TextBox
$playerIdText.Location = New-Object System.Drawing.Point(126, 83)
$playerIdText.Size = New-Object System.Drawing.Size($commandInputWidth, 23)
$commandGroup.Controls.Add($playerIdText)

$waitLabel = New-Object System.Windows.Forms.Label
$waitLabel.Text = "Wait time (sec)"
$waitLabel.Location = New-Object System.Drawing.Point(16, 127)
$waitLabel.AutoSize = $true
$commandGroup.Controls.Add($waitLabel)

$waitInput = New-Object System.Windows.Forms.NumericUpDown
$waitInput.Location = New-Object System.Drawing.Point(126, 123)
$waitInput.Size = New-Object System.Drawing.Size(120, 23)
$waitInput.Minimum = 0
$waitInput.Maximum = 3600
$waitInput.Value = 60
$commandGroup.Controls.Add($waitInput)

$messageLabel = New-Object System.Windows.Forms.Label
$messageLabel.Text = "Message"
$messageLabel.Location = New-Object System.Drawing.Point(16, 167)
$messageLabel.AutoSize = $true
$commandGroup.Controls.Add($messageLabel)

$messageText = New-Object System.Windows.Forms.TextBox
$messageText.Location = New-Object System.Drawing.Point(126, 163)
$messageText.Size = New-Object System.Drawing.Size($commandInputWidth, 55)
$messageText.Multiline = $true
$messageText.ScrollBars = "Vertical"
$commandGroup.Controls.Add($messageText)

$sendButton = New-Object System.Windows.Forms.Button
$sendButton.Text = "Send request"
$sendButton.Location = New-Object System.Drawing.Point(($contentWidth - 166), 232)
$sendButton.Size = New-Object System.Drawing.Size(140, 32)
$commandGroup.Controls.Add($sendButton)

$statusLabel = New-Object System.Windows.Forms.Label
$statusLabel.Text = if ($script:SettingsLoadWarning) { $script:SettingsLoadWarning } else { "Ready" }
$statusLabel.Location = New-Object System.Drawing.Point(126, 240)
$statusLabel.Size = New-Object System.Drawing.Size(($contentWidth - 332), 23)
$statusLabel.TextAlign = "MiddleLeft"
$statusLabel.ForeColor = if ($script:SettingsLoadWarning) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.Color]::Black }
$commandGroup.Controls.Add($statusLabel)

$responseGroup = New-Object System.Windows.Forms.GroupBox
$responseGroup.Text = "Response"
$responseTop = $commandTop + 288
$responseHeight = $form.ClientSize.Height - $responseTop - $resourceUsageFooterHeight - 12
$responseGroup.Location = New-Object System.Drawing.Point(12, $responseTop)
$responseGroup.Size = New-Object System.Drawing.Size($contentWidth, $responseHeight)
$responseGroup.Anchor = "Top,Bottom,Left,Right"
$form.Controls.Add($responseGroup)

$responseText = New-Object System.Windows.Forms.RichTextBox
$responseText.Location = New-Object System.Drawing.Point(12, 24)
$responseText.Size = New-Object System.Drawing.Size(($contentWidth - 24), ($responseHeight - 36))
$responseText.Anchor = "Top,Bottom,Left,Right"
$responseText.ReadOnly = $true
$responseText.WordWrap = $false
$responseText.Font = New-Object System.Drawing.Font("Consolas", 9)
$responseGroup.Controls.Add($responseText)

$script:VisibleDefinitions = @($script:ApiDefinitions)
foreach ($definition in $script:VisibleDefinitions) {
    [void]$commandCombo.Items.Add((Get-CommandDisplay $definition))
}

$commandCombo.Add_DrawItem({
    param($sender, $eventArgs)
    $eventArgs.DrawBackground()
    if ($eventArgs.Index -ge 0 -and $eventArgs.Index -lt $script:VisibleDefinitions.Count) {
        $definition = $script:VisibleDefinitions[$eventArgs.Index]
        $isSelected = ($eventArgs.State -band [System.Windows.Forms.DrawItemState]::Selected) -ne 0
        $isManagerAction = $null -ne $definition.PSObject.Properties["ManagerAction"]
        $isDirectControl = $null -ne $definition.PSObject.Properties["DirectControl"]
        $color = if ($isSelected) {
            [System.Drawing.SystemColors]::HighlightText
        }
        elseif ($isDirectControl) {
            [System.Drawing.Color]::Firebrick
        }
        elseif ($isManagerAction) {
            [System.Drawing.Color]::RoyalBlue
        }
        else {
            [System.Drawing.SystemColors]::WindowText
        }
        $brush = New-Object System.Drawing.SolidBrush($color)
        try {
            $eventArgs.Graphics.DrawString(
                [string]$sender.Items[$eventArgs.Index],
                $eventArgs.Font,
                $brush,
                [single]$eventArgs.Bounds.X,
                [single]$eventArgs.Bounds.Y
            )
        }
        finally {
            $brush.Dispose()
        }
    }
    $eventArgs.DrawFocusRectangle()
})

$updateFields = {
    if ($commandCombo.SelectedIndex -lt 0 -or $commandCombo.SelectedIndex -ge $script:VisibleDefinitions.Count) {
        return
    }
    $definition = $script:VisibleDefinitions[$commandCombo.SelectedIndex]
    $playerIdText.Enabled = $definition.UserId
    $waitInput.Enabled = $definition.WaitTime
    $messageText.Enabled = $definition.Message
    $playerIdLabel.Enabled = $definition.UserId
    $waitLabel.Enabled = $definition.WaitTime
    $messageLabel.Enabled = $definition.Message
    $messageLabel.Text = if ($definition.MessageRequired) {
        Get-PalworldLocalizedText "Message (required)" "메시지(필수)"
    }
    else {
        Get-PalworldLocalizedText "Message" "메시지"
    }
    $isDirectControl = $null -ne $definition.PSObject.Properties["DirectControl"]
    $minimumWait = if ($isDirectControl -and $definition.Endpoint -eq "shutdown") { 1 } else { 0 }
    if ($waitInput.Value -lt $minimumWait) { $waitInput.Value = $minimumWait }
    $waitInput.Minimum = $minimumWait
}

$commandCombo.Add_SelectedIndexChanged($updateFields)
$commandCombo.SelectedIndex = 0
& $updateFields

$setUserVerificationState = {
    param([bool]$Verified, [string]$Message, [string]$Instance = "")
    if ($script:IsAdminEdition) { return }
    $script:UserConnectionVerified = $Verified
    $script:VerifiedInstance = if ($Verified) { $Instance } else { "" }
    $commandGroup.Enabled = $Verified
    $sendButton.Enabled = $Verified
    $verificationLabel.Text = if ($Verified -and $Instance) {
        Get-PalworldLocalizedText "Verified project server: $Instance" "검증된 프로젝트 서버: $Instance"
    }
    else {
        $Message
    }
    $verificationLabel.ForeColor = if ($Verified) {
        [System.Drawing.Color]::DarkGreen
    }
    else {
        [System.Drawing.Color]::DarkRed
    }
    if ($script:ResourceUsageRefreshContext) { & $script:ResourceUsageRefreshContext }
}

$verifyUserConnection = {
    if ($script:IsAdminEdition) { return }
    & $setUserVerificationState $false (
        Get-PalworldLocalizedText `
            "Verifying server, password, and token..." `
            "서버·비밀번호·토큰 검증 중..."
    )
    $verifyConnectionButton.Enabled = $false
    $form.UseWaitCursor = $true
    try {
        $verification = Test-ManagedServerConnection
        & $setUserVerificationState `
            ([bool]$verification.Success) `
            ([string]$verification.Message) `
            ([string]$verification.Instance)
    }
    finally {
        $form.UseWaitCursor = $false
        $verifyConnectionButton.Enabled = $true
    }
}

if (-not $script:IsAdminEdition) {
    & $setUserVerificationState $false (
        Get-PalworldLocalizedText "Server verification required" "서버 검증 필요"
    )
}

if ($script:IsAdminEdition) {
    $script:RefreshingAdminConnections = $false

    $setAdminConnectionAvailability = {
        param([bool]$Available)
        $connectionUpdateButton.Enabled = $Available
        $connectionDeleteButton.Enabled = $Available
        $worldRestoreButton.Enabled = $Available
        $runtimeLogButton.Enabled = $Available
        $commandGroup.Enabled = $Available
        $sendButton.Enabled = $Available
    }

    $showAdminConnection = {
        param($connection)
        if ($null -eq $connection) {
            $connectionNameText.Clear()
            $connectionHostText.Clear()
            $connectionPortText.Clear()
            $connectionSshText.Clear()
            $connectionManagedText.Clear()
            $connectionSummaryLabel.Text = if ($script:AdminConnections.Count -gt 0) {
                Get-PalworldLocalizedText `
                    "No Server API selected. Select a Connection or Add a new one." `
                    "선택한 Server API가 없습니다. 연결을 선택하거나 새로 추가하세요."
            }
            else {
                Get-PalworldLocalizedText `
                    "No saved Connections. Select Add to create one." `
                    "저장된 연결이 없습니다. Add를 눌러 생성하세요."
            }
            Set-ActiveAdminConnection $null
            & $setAdminConnectionAvailability $false
            if ($script:ResourceUsageRefreshContext) { & $script:ResourceUsageRefreshContext }
            return
        }
        $connectionNameText.Text = [string]$connection.Name
        $connectionHostText.Text = [string]$connection.ServerHost
        $connectionPortText.Text = [string]$connection.Port
        $linkedSsh = Get-LinkedSshConnection $connection
        $sshSummary = if ($linkedSsh) {
            [string]$linkedSsh.Name
        }
        else {
            Get-PalworldLocalizedText "Not linked" "연결 안 됨"
        }
        $managedServer = if ([string]$connection.ManagedServerName) {
            [string]$connection.ManagedServerName
        }
        else { Get-PalworldLocalizedText "Not mapped" "매핑 안 됨" }
        $connectionSshText.Text = $sshSummary
        $connectionManagedText.Text = $managedServer
        $connectionSummaryLabel.Text = Get-PalworldLocalizedText `
            "Connection details are read-only. Select Update to edit." `
            "연결 요약은 읽기 전용입니다. 수정하려면 Update를 누르세요."
        Set-ActiveAdminConnection $connection
        & $setAdminConnectionAvailability $true
        if ($script:ResourceUsageRefreshContext) { & $script:ResourceUsageRefreshContext }
    }

    $refreshAdminConnectionList = {
        param([string]$SelectedId)
        $script:RefreshingAdminConnections = $true
        try {
            $connectionCombo.Items.Clear()
            [void]$connectionCombo.Items.Add($script:AdminNoApiSelectionText)
            $selectedIndex = 0
            for ($index = 0; $index -lt $script:AdminConnections.Count; $index++) {
                [void]$connectionCombo.Items.Add([string]$script:AdminConnections[$index].Name)
                if ($script:AdminConnections[$index].Id -eq $SelectedId) {
                    $selectedIndex = $index + 1
                }
            }
            $connectionCombo.SelectedIndex = $selectedIndex
            if ($selectedIndex -gt 0) {
                & $showAdminConnection $script:AdminConnections[$selectedIndex - 1]
            }
            else {
                & $showAdminConnection $null
            }
        }
        finally {
            $script:RefreshingAdminConnections = $false
        }
    }

    $script:AdminApiCombo = $connectionCombo
    $script:AdminRefreshApiConnections = $refreshAdminConnectionList
    $script:AdminSelectApiConnection = {
        param([string]$ConnectionId)
        $targetIndex = 0
        for ($index = 0; $index -lt $script:AdminConnections.Count; $index++) {
            if ([string]$script:AdminConnections[$index].Id -eq $ConnectionId) {
                $targetIndex = $index + 1
                break
            }
        }
        $previousIndex = $connectionCombo.SelectedIndex
        $connectionCombo.SelectedIndex = $targetIndex
        if ($previousIndex -eq $targetIndex) {
            if ($targetIndex -gt 0) {
                & $showAdminConnection $script:AdminConnections[$targetIndex - 1]
            }
            else {
                & $showAdminConnection $null
            }
        }
    }

    $connectionCombo.Add_SelectedIndexChanged({
        if ($script:RefreshingAdminConnections -or $connectionCombo.SelectedIndex -lt 0) { return }
        if ($connectionCombo.SelectedIndex -eq 0) {
            & $showAdminConnection $null
        }
        else {
            $selected = $script:AdminConnections[$connectionCombo.SelectedIndex - 1]
            & $showAdminConnection $selected
        }
        if ($script:AdminSelectionSyncing) { return }
        try {
            Clear-PalworldSshApiSelectionContext
            Sync-PalworldSshSelectionFromApi
            Save-AdminConnectionStore
        }
        catch {
            $statusLabel.Text = Get-PalworldLocalizedText `
                "Connection selection could not be saved" `
                "연결 선택을 저장하지 못했습니다"
            $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
        }
    })

    $connectionAddButton.Add_Click({
        try {
            $values = Show-AdminConnectionDialog -Owner $form -Mode Add -Connection $null
            if ($null -eq $values) { return }
            if ($script:AdminConnections | Where-Object { $_.Name -ieq $values.Name }) {
                throw (Get-PalworldLocalizedText `
                    "A Connection with that name already exists." `
                    "같은 이름의 연결이 이미 있습니다.")
            }
            $created = New-AdminConnection `
                -Name $values.Name `
                -ServerHost $values.ServerHost `
                -Port $values.Port `
                -Username $values.Username `
                -Password $values.Password `
                -AccessToken $values.AccessToken `
                -ManagedServerName $values.ManagedServerName
            $script:AdminConnections = @($script:AdminConnections) + @($created)
            Set-PalworldApiSshLink -ApiConnection $created -SshConnectionId $values.SshConnectionId
            Set-ActiveAdminConnection $created
            & $refreshAdminConnectionList $created.Id
            Sync-PalworldSshSelectionFromApi
            Save-AdminConnectionStore
            $statusLabel.Text = Get-PalworldLocalizedText "Connection added" "연결을 추가했습니다"
            $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                [string]$_.Exception.Message,
                (Get-PalworldLocalizedText "Connection add error" "연결 추가 오류"),
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })

    $connectionUpdateButton.Add_Click({
        if ($connectionCombo.SelectedIndex -le 0) { return }
        try {
            $selected = $script:AdminConnections[$connectionCombo.SelectedIndex - 1]
            $values = Show-AdminConnectionDialog -Owner $form -Mode Update -Connection $selected
            if ($null -eq $values) { return }
            if ($script:AdminConnections | Where-Object {
                $_.Id -ne $selected.Id -and $_.Name -ieq $values.Name
            }) {
                throw (Get-PalworldLocalizedText `
                    "A Connection with that name already exists." `
                    "같은 이름의 연결이 이미 있습니다.")
            }
            if ($values.ManagedServerName -and $script:AdminConnections | Where-Object {
                $_.Id -ne $selected.Id -and
                [string]$_.SshConnectionId -eq [string]$values.SshConnectionId -and
                [string]$_.ManagedServerName -eq [string]$values.ManagedServerName
            }) {
                throw (Get-PalworldLocalizedText `
                    "That SSH Connection already has a Server API mapped to $($values.ManagedServerName)." `
                    "해당 SSH 연결에는 이미 $($values.ManagedServerName) Server API가 매핑되어 있습니다.")
            }
            $selected.Name = $values.Name
            $selected.ServerHost = $values.ServerHost
            $selected.Port = $values.Port
            $selected.Username = $values.Username
            $selected.Password = $values.Password
            $selected.AccessToken = $values.AccessToken
            $selected.ManagedServerName = $values.ManagedServerName
            Set-PalworldApiSshLink -ApiConnection $selected -SshConnectionId $values.SshConnectionId
            Set-ActiveAdminConnection $selected
            & $refreshAdminConnectionList $selected.Id
            Sync-PalworldSshSelectionFromApi
            Save-AdminConnectionStore
            $statusLabel.Text = Get-PalworldLocalizedText "Connection updated" "연결을 수정했습니다"
            $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                [string]$_.Exception.Message,
                (Get-PalworldLocalizedText "Connection update error" "연결 수정 오류"),
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })

    $connectionDeleteButton.Add_Click({
        if ($connectionCombo.SelectedIndex -le 0) { return }
        $selected = $script:AdminConnections[$connectionCombo.SelectedIndex - 1]
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (Get-PalworldLocalizedText `
                "Delete Connection '$($selected.Name)'?" `
                "'$($selected.Name)' 연결을 삭제하시겠습니까?"),
            (Get-PalworldLocalizedText "Connection delete" "연결 삭제"),
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        try {
            $script:AdminConnections = @(
                $script:AdminConnections | Where-Object { $_.Id -ne $selected.Id }
            )
            foreach ($ssh in $script:AdminSshConnections) {
                if ([string]$ssh.LastUsedApiConnectionId -eq [string]$selected.Id) {
                    $replacement = Get-PalworldPreferredApiConnectionForSsh $ssh
                    $ssh.LastUsedApiConnectionId = if ($replacement) { [string]$replacement.Id } else { "" }
                }
            }
            Set-ActiveAdminConnection $null
            & $refreshAdminConnectionList ""
            Save-AdminConnectionStore
            $statusLabel.Text = Get-PalworldLocalizedText "Connection deleted" "연결을 삭제했습니다"
            $statusLabel.ForeColor = [System.Drawing.Color]::DarkGreen
        }
        catch {
            [void][System.Windows.Forms.MessageBox]::Show(
                [string]$_.Exception.Message,
                (Get-PalworldLocalizedText "Connection delete error" "연결 삭제 오류"),
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            )
        }
    })

    $worldRestoreButton.Add_Click({ Show-WorldRestoreDialog -Owner $form })
    $runtimeLogButton.Add_Click({ Show-RuntimeLogDialog -Owner $form })
    & $refreshAdminConnectionList $script:AdminSelectedId
}
else {
    $verifyConnectionButton.Add_Click({ & $verifyUserConnection })
    $connectionButton.Add_Click({
        $result = Show-ConnectionSettingsDialog -Owner $form
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $statusLabel.Text = Get-PalworldLocalizedText `
                "Connection settings saved; verifying server" `
                "연결 설정 저장 완료 · 서버 검증 중"
            $statusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
            & $verifyUserConnection
        }
    })
}

$sendButton.Add_Click({
    if ($commandCombo.SelectedIndex -lt 0 -or $commandCombo.SelectedIndex -ge $script:VisibleDefinitions.Count) {
        return
    }
    $definition = $script:VisibleDefinitions[$commandCombo.SelectedIndex]
    $serverHost = [string]$script:ConnectionSettings.ServerHost
    $apiPort = [int]$script:ConnectionSettings.Port
    $username = [string]$script:ConnectionSettings.Username
    $password = [string]$script:ConnectionSettings.Password
    $accessToken = [string]$script:ConnectionSettings.AccessToken
    if (-not $script:IsAdminEdition -and -not $script:UserConnectionVerified) {
        [void][System.Windows.Forms.MessageBox]::Show(
            (Get-PalworldLocalizedText `
                "Verify the server first. Check the address, password, and API token in Connection Settings." `
                "먼저 서버 연결을 확인해 주세요. Connection Settings에서 서버 주소, 비밀번호, API 토큰이 올바른지 확인할 수 있습니다."),
            (Get-PalworldLocalizedText "Server verification required" "서버 확인 필요")
        )
        return
    }
    if (
        -not (Test-PalworldApiServerAddress -Address $serverHost) -or
        $apiPort -lt 1 -or
        $apiPort -gt 65535 -or
        -not $username -or
        -not $password -or
        (-not $script:IsAdminEdition -and $accessToken -notmatch '^[A-Za-z0-9_-]{32,128}$')
    ) {
        [void][System.Windows.Forms.MessageBox]::Show(
            (Get-PalworldLocalizedText `
                "Open Connection Settings and enter valid server connection information." `
                "Connection Settings를 열고 서버 연결 정보를 올바르게 입력해 주세요."),
            (Get-PalworldLocalizedText "Connection information required" "연결 정보 필요")
        )
        return
    }
    if ($definition.UserId -and -not $playerIdText.Text.Trim()) {
        [void][System.Windows.Forms.MessageBox]::Show(
            (Get-PalworldLocalizedText `
                "Enter a player userId returned by GET /players." `
                "GET /players에서 조회한 플레이어 userId를 입력해 주세요."),
            (Get-PalworldLocalizedText "Input required" "입력 안내")
        )
        return
    }
    if ($definition.MessageRequired -and -not $messageText.Text.Trim()) {
        [void][System.Windows.Forms.MessageBox]::Show(
            (Get-PalworldLocalizedText "Enter a message." "메시지를 입력해 주세요."),
            (Get-PalworldLocalizedText "Input required" "입력 안내")
        )
        return
    }
    $isManagerAction = $null -ne $definition.PSObject.Properties["ManagerAction"]
    $isDirectControl = $null -ne $definition.PSObject.Properties["DirectControl"]
    if ($isDirectControl) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            $script:Text.DirectWarning,
            $script:Text.DirectWarningTitle,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }
    elseif ($definition.Dangerous) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            (Get-PalworldLocalizedText `
                "$(Get-CommandDisplay $definition)`n`nSend this request?" `
                "$(Get-CommandDisplay $definition)`n`n이 요청을 보내시겠습니까?"),
            (Get-PalworldLocalizedText "Confirm request" "요청 확인"),
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        )
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    $body = [ordered]@{}
    if ($definition.UserId) { $body.userid = $playerIdText.Text.Trim() }
    if ($definition.WaitTime) { $body.waittime = [int]$waitInput.Value }
    if ($definition.Message -and $messageText.Text.Trim()) { $body.message = $messageText.Text.Trim() }
    $bodyJson = if ($body.Count -gt 0) { $body | ConvertTo-Json -Compress } else { $null }
    $apiRoot = if ($isManagerAction) { "/v1/manager" } else { "/v1/api" }
    $baseUri = Get-PalworldApiUri `
        -ServerAddress $serverHost `
        -Port $apiPort `
        -PathAndQuery $apiRoot
    $uri = "$baseUri/$($definition.Endpoint)"

    $sendButton.Enabled = $false
    $form.UseWaitCursor = $true
    $statusLabel.Text = Get-PalworldLocalizedText "Sending..." "전송 중..."
    $statusLabel.ForeColor = [System.Drawing.Color]::DarkOrange
    $responseText.Text = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]`r`n"
    if ($script:IsAdminEdition) {
        $responseText.AppendText("$($definition.Method) $uri`r`n")
    }
    $responseText.AppendText((Get-PalworldLocalizedText "Request sent`r`n" "요청 전송 완료`r`n"))
    try {
        $result = Invoke-PalworldRequest `
            -Uri $uri `
            -Method $definition.Method `
            -Username $username `
            -Password $password `
            -AccessToken $accessToken `
            -BodyJson $bodyJson
        $statusLabel.Text = if ($result.Success) {
            Get-PalworldLocalizedText "Success" "성공"
        }
        else {
            Get-PalworldLocalizedText "Fail" "실패"
        }
        $statusLabel.ForeColor = if ($result.Success) { [System.Drawing.Color]::DarkGreen } else { [System.Drawing.Color]::DarkRed }
        $responseText.AppendText("HTTP $($result.StatusCode)`r`n`r`n")
        if ($isManagerAction -and $result.Success) {
            $responseText.AppendText((Get-PalworldLocalizedText `
                "Accepted by the Linux supervisor. The countdown continues even if this client closes.`r`n`r`n" `
                "Linux supervisor가 요청을 수락했습니다. 이 프로그램을 닫아도 countdown은 계속됩니다.`r`n`r`n"))
        }
        $responseText.AppendText((Format-ResponseBody -Body $result.Body -ServerHost $serverHost))
        if ($result.Success) { $messageText.Clear() }
        elseif (-not $script:IsAdminEdition -and $result.StatusCode -in @(401, 403)) {
            & $setUserVerificationState $false (
                Get-PalworldLocalizedText `
                    "The password or API token changed. Verify the server again." `
                    "비밀번호 또는 API access token이 변경되었습니다. 다시 검증하세요."
            )
        }
    }
    catch {
        $statusLabel.Text = Get-PalworldLocalizedText "Fail" "실패"
        $statusLabel.ForeColor = [System.Drawing.Color]::DarkRed
        if ($script:IsAdminEdition) {
            $responseText.AppendText(
                "ERROR`r`n$(Get-PalworldHttpFailureDetail -Exception $_.Exception)"
            )
        }
        else {
            $responseText.AppendText(
                "ERROR`r`nThe request could not be completed. Check Connection Settings, REST API exposure, firewall, and server state."
            )
        }
    }
    finally {
        $form.UseWaitCursor = $false
        $sendButton.Enabled = if ($script:IsAdminEdition) {
            [bool]$script:ConnectionSettings.ServerHost
        }
        else {
            $script:UserConnectionVerified
        }
    }
})

$script:AdminTabLayout = $null
if ($script:IsAdminEdition) {
    $script:PalworldServerApiSetSshOperationState = {
        param([bool]$Running)
        foreach ($control in @($adminConnectionGroup, $adminToolsGroup, $commandGroup)) {
            if ($control -and -not $control.IsDisposed) {
                $control.Enabled = -not $Running
            }
        }
    }.GetNewClosure()
    $script:AdminTabLayout = Add-PalworldAdminTabs -Form $form
}
[void](New-ResourceUsageFooter -Owner $form)
[void](New-PalworldApplicationMenu -Owner $form)
Set-PalworldLocalizedControlTree -Control $form
Initialize-ResourceUsagePolling -Owner $form

$form.AcceptButton = $sendButton
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-import-source-ui") {
    $syntheticWorld = [pscustomobject]@{
        active = $true
        server_name = "Existing Palworld Server"
        pal_directory = "/home/kevin/palworld/Pal"
        saved_directory = "/home/kevin/palworld/Pal/Saved"
        world_guid = "0123456789ABCDEF0123456789ABCDEF"
        level_modified_at = "2026-07-23T14:35:00+09:00"
        level_size_bytes = 188743680
        player_count = 12
        game_port = 39471
        rest_api_port = 39472
        running = $true
        source_type = "systemd"
        control_id = "palworld.service"
        world_option_present = $true
        processes = @([pscustomobject]@{ community_server = $false })
    }
    [void](Show-PalworldImportSourceDialog `
        -Owner $form -Worlds @($syntheticWorld) -SearchRoot "/home/kevin")
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-import-review-ui") {
    $syntheticInspection = [pscustomobject]@{
        server = "server2"
        source_ini = "[/Script/Pal.PalGameWorldSettings]`r`nOptionSettings=(ServerName=`"Existing Server`",AdminPassword=`"example-password`",ExpRate=2.500000,RESTAPIEnabled=True,RESTAPIPort=39472,FutureServerSetting=60)"
        target_env = "ACTIVE_WINDOW=always`r`nRESTART_TIMES=04:00`r`nSERVER_PORT=`r`nCOMMUNITY_SERVER=false`r`nPAL_SETTING_PublicPort=`r`nPAL_SETTING_AdminPassword=example-password`r`nPAL_SETTING_ExpRate=2.500000`r`nPAL_SETTING_RESTAPIEnabled=True`r`nPAL_SETTING_RESTAPIPort=39472`r`nREST_API_EXPOSE=true`r`nAPI_ACCESS_TOKEN=example_generated_token_0123456789`r`n`r`n# ==================== Imported settings not in this template ====================`r`nPAL_SETTING_FutureServerSetting=60"
        review = @(
            [pscustomobject]@{ id = "game-port"; status = "BLOCKED"; source_key = "-port / PublicPort"; env_keys = @("SERVER_PORT", "PAL_SETTING_PublicPort"); value = ""; value_type = "text"; editable = $true; required = $true; scope = "server.env"; description = "Enter the existing game UDP port because the source process was not running."; reserved_values = @("39461") },
            [pscustomobject]@{ id = "rest-port"; status = "REVIEW"; source_key = "RESTAPIPort"; env_keys = @("PAL_SETTING_RESTAPIPort"); value = "39472"; value_type = "text"; editable = $true; required = $true; scope = "server.env"; description = "Confirm the detected REST API TCP port."; reserved_values = @("18080", "39462") },
            [pscustomobject]@{ id = "rest-exposure"; status = "REVIEW"; source_key = "REST API external access"; env_keys = @("REST_API_EXPOSE"); value = "True"; value_type = "boolean"; editable = $true; required = $false; scope = "server.env"; description = "External access is recommended for the Windows apps. Protect it with a firewall, VPN, or TLS gateway." },
            [pscustomobject]@{ id = "community-server"; status = "REVIEW"; source_key = "-publiclobby"; env_keys = @("COMMUNITY_SERVER"); value = "False"; value_type = "boolean"; editable = $true; required = $false; scope = "server.env"; description = "Confirm whether the source used the community-server launch option." },
            [pscustomobject]@{ id = "active-window"; status = "REVIEW"; source_key = ""; env_keys = @("ACTIVE_WINDOW"); value = "always"; value_type = "text"; editable = $true; required = $false; scope = "server.env"; description = "Runs 24/7. Overnight ranges such as 14:00-02:00 are supported." },
            [pscustomobject]@{ id = "pal-setting-FutureServerSetting"; status = "UNMAPPED"; source_key = "FutureServerSetting"; env_keys = @("PAL_SETTING_FutureServerSetting"); value = "60"; value_type = "text"; editable = $true; required = $false; scope = "server.env"; description = "Preserved in the imported-settings fallback section because the current template does not document it." },
            [pscustomobject]@{ id = "pal-setting-ExpRate"; status = "AUTO"; source_key = "ExpRate"; env_keys = @("PAL_SETTING_ExpRate"); value = "2.500000"; value_type = "text"; editable = $true; required = $false; scope = "server.env"; description = "Imported from PalWorldSettings.ini." },
            [pscustomobject]@{ id = "world-guid"; status = "AUTO"; source_key = "DedicatedServerName"; env_keys = @(); value = "0123456789ABCDEF0123456789ABCDEF"; value_type = "text"; editable = $false; required = $false; scope = "GameUserSettings.ini"; description = "The existing world identity is preserved." }
        )
    }
    [void](Show-PalworldImportReviewDialog -Owner $form -Inspection $syntheticInspection)
    $form.Dispose()
    return
}
if (-not $script:IsAdminEdition -and -not $env:PALWORLD_CLIENT_TEST_MODE) {
    $form.Add_Shown({ & $verifyUserConnection })
}
if (-not $script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "settings") {
    [void](Show-ConnectionSettingsDialog -Owner $form)
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "admin-connection") {
    [void](Show-AdminConnectionDialog -Owner $form -Mode Add -Connection $null)
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-model") {
    $smallWindow = Get-PalworldAdminWindowLayout -WorkingArea (New-Object System.Drawing.Rectangle(0, 0, 1366, 728))
    $largeWindow = Get-PalworldAdminWindowLayout -WorkingArea (New-Object System.Drawing.Rectangle(0, 0, 1920, 1040))
    if ($smallWindow.ClientHeight -ne 688 -or $smallWindow.MinimumHeight -ne 696 -or
        $largeWindow.ClientHeight -ne 1000 -or $largeWindow.MinimumHeight -ne 720) {
        throw "Admin window sizing did not respect the monitor working area."
    }
    $model = New-AdminSshConnection `
        -Name "Regression Test" `
        -SshHost "example.invalid" `
        -Port 22 `
        -Username "guest" `
        -Password "secret" `
        -SudoPassword "secret"
    if ([string]$model.Host -ne "example.invalid") {
        throw "SSH Connection Host was not stored correctly."
    }
    Disconnect-PalworldSshSession
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-runtime") {
    Initialize-PalworldSshRuntime
    $hostKeyVerifier = New-Object Palworld.ServerManager.SshHostKeyVerifier("")
    $promptResponder = New-Object Palworld.ServerManager.SshPasswordPromptResponder("secret")
    $sanitizer = New-Object Palworld.ServerManager.TerminalStreamSanitizer
    if ($hostKeyVerifier.Handler.Method.DeclaringType.FullName -ne "Palworld.ServerManager.SshHostKeyVerifier") {
        throw "SSH host-key callback is not a managed event handler."
    }
    if ($promptResponder.Handler.Method.DeclaringType.FullName -ne "Palworld.ServerManager.SshPasswordPromptResponder") {
        throw "SSH password callback is not a managed event handler."
    }
    $escape = [string][char]27
    $bell = [string][char]7
    $first = $sanitizer.Filter("before${escape}]3008;start=session")
    $second = $sanitizer.Filter(";type=shell${bell}after${escape}[31mred${escape}[0m")
    if ($first -ne "before" -or $second -ne "afterred") {
        throw "Streaming SSH terminal control sequences were not normalized."
    }
    $splitCarriageReturn = $sanitizer.Filter("printf split-regression`r")
    $splitLineFeed = $sanitizer.Filter("`ncommand-output")
    if ($splitCarriageReturn -ne "printf split-regression" -or
        $splitLineFeed -ne "`r`ncommand-output") {
        throw "SSH terminal split CRLF handling did not preserve the command line."
    }
    $utf8Text = "A한글B"
    $utf8Bytes = [Text.Encoding]::UTF8.GetBytes($utf8Text)
    $utf8Stream = New-Object IO.MemoryStream -ArgumentList (,$utf8Bytes)
    $decodedUtf8 = New-Object Text.StringBuilder
    try {
        while ($utf8Stream.Position -lt $utf8Stream.Length) {
            $utf8Read = Read-PalworldSshShellUtf8 -Shell $utf8Stream -MaximumBytes 2
            if ($utf8Read.BytesRead -le 0) { throw "Bounded UTF-8 reader stopped early." }
            [void]$decodedUtf8.Append([string]$utf8Read.Text)
        }
        if ($decodedUtf8.ToString() -ne $utf8Text) {
            throw "Bounded SSH reads did not preserve split UTF-8 characters."
        }
    }
    finally {
        Reset-PalworldSshShellUtf8Decoder -Shell $utf8Stream
        $utf8Stream.Dispose()
        [Array]::Clear($utf8Bytes, 0, $utf8Bytes.Length)
    }

    function Enable-PalworldBoundedAsciiTestRead {
        param([Parameter(Mandatory = $true)]$Shell)
        $Shell | Add-Member -MemberType NoteProperty -Name PendingRead -Value ""
        $Shell | Add-Member -MemberType NoteProperty -Name MaximumRequestedBytes -Value 0
        $Shell | Add-Member -MemberType NoteProperty -Name BytesReadBeforeWrite -Value 0
        $Shell | Add-Member -MemberType NoteProperty -Name CommandWritten -Value $false
        $Shell | Add-Member -MemberType ScriptMethod -Name ReadPalworldBoundedUtf8 -Value {
            param($maximumBytes)
            $requested = [int]$maximumBytes
            if ($requested -gt $this.MaximumRequestedBytes) {
                $this.MaximumRequestedBytes = $requested
            }
            if (-not $this.PendingRead -and $this.Chunks.Count -gt 0) {
                $this.PendingRead = [string]$this.Chunks.Dequeue()
            }
            if (-not $this.PendingRead) {
                return [pscustomobject]@{ BytesRead = 0; Text = "" }
            }
            # Test protocol chunks are ASCII. Keeping the fake explicitly
            # byte-bounded prevents a regression from hiding behind Read().
            $take = [Math]::Min($requested, $this.PendingRead.Length)
            $text = $this.PendingRead.Substring(0, $take)
            $this.PendingRead = $this.PendingRead.Substring($take)
            if (-not $this.CommandWritten) {
                $this.BytesReadBeforeWrite += $take
            }
            return [pscustomobject]@{ BytesRead = $take; Text = $text }
        }
    }
    $missingPrivateKeyRejected = $false
    try {
        [void](Open-PalworldSshPrivateKeyFile `
            -Path (Join-Path ([IO.Path]::GetTempPath()) "palworld-missing-private-key"))
    }
    catch {
        $missingPrivateKeyRejected = [string]$_.Exception.Message -match "private key file was not found"
    }
    if (-not $missingPrivateKeyRejected) {
        throw "SSH private-key authentication did not validate the selected key file."
    }
    $fakeClient = New-Object psobject -Property @{ IsConnected = $true }
    $fakeClient | Add-Member -MemberType ScriptMethod -Name Disconnect -Value {
        $this.IsConnected = $false
    }
    $fakeClient | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
    $boundedShell = New-Object psobject -Property @{
        CanRead = $true
        CanWrite = $true
        LastCommand = ""
        Chunks = New-Object 'System.Collections.Generic.Queue[string]'
        Disposed = $false
    }
    Enable-PalworldBoundedAsciiTestRead -Shell $boundedShell
    $boundedShell | Add-Member -MemberType ScriptProperty -Name DataAvailable -Value {
        return [bool]$this.PendingRead -or $this.Chunks.Count -gt 0
    }
    $boundedShell | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
        param($value)
        $this.CommandWritten = $true
        $this.LastCommand = [string]$value
        $markerMatch = [Text.RegularExpressions.Regex]::Match(
            $this.LastCommand,
            '__PALWORLD_DONE_[0-9a-f]{32}__'
        )
        if (-not $markerMatch.Success) { throw "Automation completion marker was not framed." }
        $marker = $markerMatch.Value
        $splitAt = $marker.Length - 7
        $this.Chunks.Enqueue("discard-me:" + "".PadLeft(70000, [char]'x'))
        $this.Chunks.Enqueue("`r`nretained-tail`r`n" + $marker.Substring(0, $splitAt))
        $this.Chunks.Enqueue($marker.Substring($splitAt) + ":7`r`n")
    }
    $boundedShell | Add-Member -MemberType ScriptMethod -Name Write -Value { param($value) }
    $boundedShell | Add-Member -MemberType ScriptMethod -Name Flush -Value { }
    $boundedShell | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposed = $true
    }
    $script:PalworldSshClient = $fakeClient
    $script:PalworldSshAutomationShell = $boundedShell
    $script:PalworldSshPinnedConnectionId = ""
    $script:PalworldSshClosing = $false
    $boundedShell.Chunks.Enqueue("".PadLeft(70000, [char]'i'))
    $boundedConnection = New-AdminSshConnection -Name "Bounded Output Test"
    $boundedResult = Invoke-PalworldSshCommand `
        -Connection $boundedConnection `
        -Owner $form `
        -Command "printf bounded" `
        -TimeoutSeconds 3 `
        -OutputLimitCharacters 2048 `
        -MarkerWindowCharacters 256 `
        -VisibleBufferLimitCharacters 1024
    if ($boundedResult.ExitCode -ne 7 -or -not $boundedResult.OutputTruncated -or
        $boundedResult.OmittedCharacters -le 0 -or
        $boundedResult.Output -notmatch 'Earlier SSH command output was truncated' -or
        $boundedResult.Output -notmatch 'retained-tail' -or
        $boundedResult.Output -match 'discard-me' -or
        $script:PalworldSshOutput.Text -notmatch 'retained-tail' -or
        $boundedShell.MaximumRequestedBytes -gt 16384 -or
        $boundedShell.BytesReadBeforeWrite -gt 65536) {
        throw "Long SSH automation output was not bounded while retaining its tail and completion marker."
    }
    $highSurrogate = [char]0xD83D
    $lowSurrogate = [char]0xDE00
    $unicodeLine = "".PadLeft(1100, [char]'a') + $highSurrogate + $lowSurrogate + "z"
    $unicodeFlushLength = Get-PalworldSshVisibleFlushPrefixLength `
        -Text $unicodeLine -HoldLength 2 -MaximumBufferedLength 1024
    if ($unicodeFlushLength -ne 1100) {
        throw "Bounded SSH output flush split a UTF-16 surrogate pair."
    }
    Reset-PalworldAutomationShellStream
    if (-not $boundedShell.Disposed) {
        throw "Completed automation test stream did not dispose on explicit reset."
    }

    $sudoShell = New-Object psobject -Property @{
        CanRead = $true
        CanWrite = $true
        Chunks = New-Object 'System.Collections.Generic.Queue[string]'
        DoneMarker = ""
        SudoMarker = ""
        SecretWrites = 0
        LastSecretBase64 = ""
        Disposed = $false
    }
    Enable-PalworldBoundedAsciiTestRead -Shell $sudoShell
    $sudoShell | Add-Member -MemberType ScriptProperty -Name DataAvailable -Value {
        return [bool]$this.PendingRead -or $this.Chunks.Count -gt 0
    }
    $sudoShell | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
        param($value)
        $this.CommandWritten = $true
        $commandText = [string]$value
        $this.DoneMarker = [Text.RegularExpressions.Regex]::Match(
            $commandText,
            '__PALWORLD_DONE_[0-9a-f]{32}__'
        ).Value
        $this.SudoMarker = [Text.RegularExpressions.Regex]::Match(
            $commandText,
            '__PALWORLD_SUDO_[0-9a-f]{32}__'
        ).Value
        if (-not $this.DoneMarker -or -not $this.SudoMarker) {
            throw "Sudo automation markers were not framed."
        }
        $splitAt = 11
        $this.Chunks.Enqueue(
            "".PadLeft(400, [char]'x') + "`r`n[sudo: " +
                $this.SudoMarker.Substring(0, $splitAt)
        )
        $this.Chunks.Enqueue(
            $this.SudoMarker.Substring($splitAt) + "] Password: "
        )
    }
    $sudoShell | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param($buffer, $offset, $count)
        if ($buffer -is [byte[]]) {
            $copy = New-Object byte[] $count
            [Array]::Copy($buffer, $offset, $copy, 0, $count)
            $this.LastSecretBase64 = [Convert]::ToBase64String($copy)
            $this.SecretWrites++
            $splitAt = $this.DoneMarker.Length - 5
            $this.Chunks.Enqueue("`r`n" + $this.DoneMarker.Substring(0, $splitAt))
            $this.Chunks.Enqueue($this.DoneMarker.Substring($splitAt) + ":0`r`n")
        }
    }
    $sudoShell | Add-Member -MemberType ScriptMethod -Name Flush -Value { }
    $sudoShell | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposed = $true
    }
    $script:PalworldSshAutomationShell = $sudoShell
    $sudoPassword = 'Az9!한글'
    $sudoConnection = New-AdminSshConnection `
        -Name "Rolling Sudo Prompt Test" -SudoPassword $sudoPassword
    $sudoResult = Invoke-PalworldSshCommand `
        -Connection $sudoConnection `
        -Owner $form `
        -Command "__PALWORLD_SUDO__ -k true" `
        -TimeoutSeconds 3 `
        -MarkerWindowCharacters 256 `
        -Quiet
    $expectedSudoSecret = [Convert]::ToBase64String(
        [Text.Encoding]::UTF8.GetBytes($sudoPassword + "`r")
    )
    if ($sudoResult.ExitCode -ne 0 -or $sudoShell.SecretWrites -ne 1 -or
        $sudoShell.LastSecretBase64 -ne $expectedSudoSecret) {
        throw "Rolling SSH marker detection did not answer one split sudo prompt with exact UTF-8 bytes."
    }
    Reset-PalworldAutomationShellStream
    if (-not $sudoShell.Disposed) {
        throw "Completed sudo automation test stream did not dispose on explicit reset."
    }

    $cancelShell = New-Object psobject -Property @{
        CanRead = $true
        CanWrite = $true
        LastCommand = ""
        ControlCCount = 0
        Disposed = $false
    }
    $cancelShell | Add-Member -MemberType ScriptProperty -Name DataAvailable -Value { return $false }
    $cancelShell | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
        param($value)
        $this.LastCommand = [string]$value
    }
    $cancelShell | Add-Member -MemberType ScriptMethod -Name Read -Value { return "" }
    $cancelShell | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param($value)
        if ([string]$value -eq [string][char]3) { $this.ControlCCount++ }
    }
    $cancelShell | Add-Member -MemberType ScriptMethod -Name Flush -Value { }
    $cancelShell | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
        $this.Disposed = $true
    }
    $script:PalworldSshAutomationShell = $cancelShell
    $script:PalworldSshCancelRequested = $false
    $cancelTimer = New-Object System.Windows.Forms.Timer
    $cancelTimer.Interval = 100
    $cancelTimer.Add_Tick({
        $script:PalworldSshCancelRequested = $true
    })
    $cancelled = $false
    $cancelStartedAt = [DateTime]::UtcNow
    try {
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $cancelTimer.Start()
        [void](Invoke-PalworldSshCommand `
            -Connection $boundedConnection `
            -Owner $form `
            -Command "printf waiting" `
            -TimeoutSeconds 5 `
            -CancelGraceSeconds 1 `
            -Quiet)
    }
    catch {
        if ([string]$_.Exception.Message -match 'was canceled') { $cancelled = $true }
        else { throw }
    }
    finally {
        $cancelTimer.Stop()
        $cancelTimer.Dispose()
    }
    if (-not $cancelled -or $cancelShell.ControlCCount -ne 1 -or
        -not $cancelShell.Disposed -or $script:PalworldSshAutomationShell -or
        ([DateTime]::UtcNow - $cancelStartedAt).TotalSeconds -ge 3) {
        throw "Canceled SSH automation did not reset only its stuck stream after the grace period."
    }
    Disconnect-PalworldSshSession
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-close") {
    $fakeShell = New-Object psobject -Property @{
        CanRead = $true
        CanWrite = $true
        DataAvailable = $false
        LastCommand = ""
    }
    $fakeShell | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
        param($value)
        $this.LastCommand = [string]$value
    }
    $fakeShell | Add-Member -MemberType ScriptMethod -Name Read -Value { return "" }
    $fakeShell | Add-Member -MemberType ScriptMethod -Name Write -Value { param($value) }
    $fakeShell | Add-Member -MemberType ScriptMethod -Name Flush -Value { }
    $fakeClient = New-Object psobject -Property @{ IsConnected = $true }
    $script:PalworldSshAutomationShell = $fakeShell
    $script:PalworldSshClient = $fakeClient
    $connection = New-AdminSshConnection -Name "Close Test"
    $closeTimer = New-Object System.Windows.Forms.Timer
    $closeTimer.Interval = 100
    $closeTimer.Add_Tick({
        $closeTimer.Stop()
        $form.Close()
    }.GetNewClosure())
    $startedAt = [DateTime]::UtcNow
    $abortedForClose = $false
    try {
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $closeTimer.Start()
        [void](Invoke-PalworldSshCommand `
            -Connection $connection -Owner $form -Command "printf waiting" -TimeoutSeconds 5)
    }
    catch {
        if ([string]$_.Exception.Message -match 'closing') { $abortedForClose = $true }
        else { throw }
    }
    finally {
        $closeTimer.Stop()
        $closeTimer.Dispose()
    }
    if (-not $abortedForClose -or ([DateTime]::UtcNow - $startedAt).TotalSeconds -ge 2) {
        throw "Closing the Admin UI did not promptly abort an active SSH command loop."
    }
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-add") {
    $buttons = @($script:AdminTabLayout.SshPage.Controls.Find("SshConnectionAddButton", $true))
    if ($buttons.Count -ne 1) { throw "SSH Add button was not found." }
    $script:PalworldSshAddDialogOpened = $false
    $script:AdminTabLayout.Tabs.SelectedIndex = 1
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    $buttons[0].PerformClick()
    [System.Windows.Forms.Application]::DoEvents()
    if (-not $script:PalworldSshAddDialogOpened) {
        throw "SSH Add button did not open the Connection dialog."
    }
    Disconnect-PalworldSshSession
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-dialog") {
    [void](Show-PalworldSshConnectionDialog `
        -Owner $form `
        -Mode Add `
        -Connection $null `
        -ApiConnection (Get-SelectedAdminApiConnection))
    Disconnect-PalworldSshSession
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-dialog-events") {
    $sshDialogResult = Show-PalworldSshConnectionDialog `
        -Owner $form `
        -Mode Add `
        -Connection $null `
        -ApiConnection $null
    if ($null -eq $sshDialogResult -or [string]$sshDialogResult.Host -ne "example.invalid" -or
        [string]$sshDialogResult.WorkDirectory -ne "/home/guest/palworld-docker") {
        throw "SSH Connection dialog event validation failed."
    }
    $envContent = @'
SERVER_PORT=8211
REST_API_EXPOSE=true
PAL_SETTING_RESTAPIEnabled=True
PAL_SETTING_RESTAPIPort=8212
PAL_SETTING_AdminPassword=secret
API_ACCESS_TOKEN=abcdefghijklmnopqrstuvwxyz123456
'@
    $envDialogResult = Show-PalworldServerEnvEditor `
        -Owner $form -Server "server1" -Content $envContent
    if ($null -eq $envDialogResult -or [string]$envDialogResult.Action -ne "Save") {
        throw "server.env editor button events failed."
    }
    $backupDialogResult = Show-PalworldSshBackupDialog `
        -Owner $form `
        -Payload ([pscustomobject]@{
            world_guid = "REGRESSION"
            backups = @([pscustomobject]@{
                name = "2026.07.18-01.00.00"
                kind = "automatic"
                file_count = 3
                size_bytes = 1024
            })
        })
    if ($backupDialogResult -ne "2026.07.18-01.00.00") {
        throw "SSH backup selection dialog events failed."
    }
    Disconnect-PalworldSshSession
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-private-key-dialog") {
    $sshDialogResult = Show-PalworldSshConnectionDialog `
        -Owner $form `
        -Mode Add `
        -Connection $null `
        -ApiConnection $null
    $expectedKeyPath = [IO.Path]::GetFullPath([string]$env:PALWORLD_SSH_PRIVATE_KEY_TEST_PATH)
    if ($null -eq $sshDialogResult -or
        [string]$sshDialogResult.AuthMode -ne "PrivateKey" -or
        [IO.Path]::GetFullPath([string]$sshDialogResult.PrivateKeyPath) -ne $expectedKeyPath) {
        throw "SSH private-key dialog did not return the selected authentication settings."
    }
    $privateKeyConnection = New-AdminSshConnection `
        -Name $sshDialogResult.Name `
        -SshHost $sshDialogResult.Host `
        -Port $sshDialogResult.Port `
        -Username $sshDialogResult.Username `
        -AuthMode $sshDialogResult.AuthMode `
        -PrivateKeyPath $sshDialogResult.PrivateKeyPath `
        -PrivateKeyPassphrase $sshDialogResult.PrivateKeyPassphrase `
        -SudoPassword $sshDialogResult.SudoPassword `
        -WorkDirectory $sshDialogResult.WorkDirectory
    $privateKeyInfo = New-PalworldSshConnectionInfo -Connection $privateKeyConnection
    if ($privateKeyInfo.AuthenticationMethods.Count -ne 1 -or
        $privateKeyInfo.AuthenticationMethods[0].GetType().FullName -ne
            "Renci.SshNet.PrivateKeyAuthenticationMethod") {
        throw "SSH private-key dialog settings were not used by the connection runtime."
    }
    Disconnect-PalworldSshSession
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-logic") {
    $parsedInventory = @(
        Get-PalworldJsonFromSshOutput (
            "remote trace`n" +
            '[{"name":"server1","state":"running"},{"name":"server3","state":"exited"}]'
        )
    )
    if ($parsedInventory.Count -ne 2 -or [string]$parsedInventory[0].name -ne "server1" -or
        [string]$parsedInventory[1].name -ne "server3") {
        throw "SSH JSON array output was not enumerated into individual server records."
    }
    $promptedInventory = @(
        Get-PalworldJsonFromSshOutput (
            'guest@testhost:~$ ' +
            '[{"name":"server1","state":"running"},{"name":"server2","state":"running"}]'
        )
    )
    if ($promptedInventory.Count -ne 2 -or [string]$promptedInventory[1].name -ne "server2") {
        throw "PTY-prefixed SSH JSON output was not parsed."
    }
    $installed = [pscustomobject]@{
        name = "server1"
        container = "palworld-server1"
        image = "local/palworld-dedicated-server:latest"
        state = "running"
        status = "Up"
    }
    $inventory = @(
        Merge-PalworldSshServerInventory `
            -Installed @($installed) `
            -ConfiguredNames @("server1", "server2")
    )
    if ($inventory.Count -ne 2 -or [string]$inventory[0].state -ne "running" -or
        [string]$inventory[1].state -ne "configured") {
        throw "SSH Docker/config inventory merge is incorrect."
    }
    $promptMarker = "__PALWORLD_TEST_PROMPT__"
    $promptPattern = Get-PalworldSudoPromptPattern -Marker $promptMarker
    $echoedPromptCommand = "guest@host:~`$ sudo -S -p '$promptMarker' id"
    if ([Text.RegularExpressions.Regex]::Matches($echoedPromptCommand, $promptPattern).Count -ne 0) {
        throw "An echoed sudo command was mistaken for a password prompt."
    }
    $rawPromptOutput = "guest@host:~`$ command`r`n$promptMarker"
    if ([Text.RegularExpressions.Regex]::Matches($rawPromptOutput, $promptPattern).Count -ne 1) {
        throw "A raw sudo password prompt was not detected."
    }
    $ubuntuPromptOutput = "[sudo: $promptMarker] Password: `r`nsudo: Authentication failed, try again.`r`n$promptMarker"
    if ([Text.RegularExpressions.Regex]::Matches($ubuntuPromptOutput, $promptPattern).Count -ne 2) {
        throw "Sudo prompt retry detection is incorrect."
    }
    $multiLineCommand = "printf 'one\n'`nprintf 'two\n'"
    $singleLineExecution = ConvertTo-PalworldShellExecutionCommand -Command $multiLineCommand
    if ($singleLineExecution -match '[\r\n]' -or $singleLineExecution.Contains($multiLineCommand)) {
        throw "Multi-line SSH automation command was not framed as one terminal line."
    }
    $encodedMatch = [Text.RegularExpressions.Regex]::Match(
        $singleLineExecution,
        "printf %s '([^']+)'"
    )
    if (-not $encodedMatch.Success) { throw "Encoded SSH automation command is malformed." }
    $decodedCommand = [Text.Encoding]::UTF8.GetString(
        [Convert]::FromBase64String($encodedMatch.Groups[1].Value)
    )
    if ($decodedCommand -cne $multiLineCommand) {
        throw "Encoded SSH automation command did not round-trip."
    }
    $partialStatus = "[PASS] first line`r`n[PASS] host timezone: Asia/S"
    $firstLineLength = $partialStatus.IndexOf("[PASS] host timezone", [StringComparison]::Ordinal)
    if ((Get-PalworldCompleteStreamPrefixLength `
            -Text $partialStatus -SafeLength $partialStatus.Length) -ne $firstLineLength) {
        throw "SSH Management streaming exposed an incomplete final line."
    }
    $completedStatus = $partialStatus + "eoul`r`n"
    if ((Get-PalworldCompleteStreamPrefixLength `
            -Text $completedStatus -SafeLength $completedStatus.Length) -ne $completedStatus.Length) {
        throw "SSH Management streaming did not release a completed line."
    }
    $sudoExpansion = Expand-PalworldSudoPlaceholders `
        -Command "__PALWORLD_SUDO__ -n true; __PALWORLD_SUDO__ id"
    if ($sudoExpansion.Markers.Count -ne 2 -or
        [string]$sudoExpansion.Markers[0] -eq [string]$sudoExpansion.Markers[1] -or
        [string]$sudoExpansion.Command -match '__PALWORLD_SUDO__') {
        throw "Each sudo invocation must receive a unique authentication prompt marker."
    }
    $sudoSecret = 'Az9!@#$한글'
    $secretStream = New-Object psobject -Property @{
        Buffer = New-Object System.IO.MemoryStream
        FlushCount = 0
    }
    $secretStream | Add-Member -MemberType ScriptMethod -Name Write -Value {
        param([byte[]]$buffer, [int]$offset, [int]$count)
        $this.Buffer.Write($buffer, $offset, $count)
    }
    $secretStream | Add-Member -MemberType ScriptMethod -Name Flush -Value {
        $this.FlushCount++
    }
    try {
        Write-PalworldShellSecretUtf8 -Shell $secretStream -Secret $sudoSecret
        $actualSecretBytes = $secretStream.Buffer.ToArray()
        $expectedSecretBytes = [Text.Encoding]::UTF8.GetBytes($sudoSecret + "`r")
        if ([Convert]::ToBase64String($actualSecretBytes) -ne
            [Convert]::ToBase64String($expectedSecretBytes)) {
            throw "Sudo Password was not written as exact UTF-8 bytes followed by PTY CR."
        }
        if ($secretStream.FlushCount -ne 1) { throw "Sudo Password write was not flushed immediately." }
    }
    finally { $secretStream.Buffer.Dispose() }
    $readyManagement = ConvertFrom-PalworldActionPrerequisitesOutput -Project "/home/test/palworld-docker" -Output @'
PAL_WORK_EXISTS=yes
PAL_WORK_WRITABLE=yes
PAL_CURL=yes
PAL_PYTHON=yes
PAL_DOCKER=yes
PAL_COMPOSE=yes
PAL_DAEMON=yes
PAL_SCAFFOLD=yes
'@
    if (-not $readyManagement.Ready -or -not $readyManagement.Exists -or
        -not $readyManagement.Writable) {
        throw "Complete SSH management readiness output was not accepted."
    }
    $incompleteManagement = ConvertFrom-PalworldActionPrerequisitesOutput -Project "/home/test/palworld-docker" -Output @'
PAL_WORK_EXISTS=yes
PAL_WORK_WRITABLE=yes
PAL_CURL=yes
PAL_PYTHON=yes
PAL_DOCKER=no
PAL_COMPOSE=no
PAL_DAEMON=no
PAL_SCAFFOLD=no
'@
    if ($incompleteManagement.Ready -or -not $incompleteManagement.Exists -or $incompleteManagement.Docker) {
        throw "Incomplete SSH management readiness output was not rejected."
    }
    foreach ($action in @(
        "Setup", "Update", "EnvEdit", "Test", "Reset", "Restore", "TokenRotate",
        "RemoveServer", "RemoveAll", "RemoveProject"
    )) {
        if (-not (Test-PalworldSshActionNeedsRefresh -Action $action)) {
            throw "SSH action refresh policy is missing: $action"
        }
    }
    foreach ($action in @("TokenShow", "Unknown")) {
        if (Test-PalworldSshActionNeedsRefresh -Action $action) {
            throw "Read-only SSH action should not force a server refresh: $action"
        }
    }
    $promptedManagement = ConvertFrom-PalworldActionPrerequisitesOutput -Project "/home/guest/palworld-docker" -Output @'
guest@testhost:~$ PAL_WORK_EXISTS=yes
guest@testhost:~$ PAL_WORK_WRITABLE=yes
guest@testhost:~$ PAL_CURL=yes
guest@testhost:~$ PAL_PYTHON=yes
> > PAL_DOCKER=yes
PAL_COMPOSE=yes
PAL_DAEMON=yes
guest@testhost:~$ > PAL_SCAFFOLD=yes
'@
    if (-not $promptedManagement.Ready -or -not $promptedManagement.Exists -or
        -not $promptedManagement.Docker -or -not $promptedManagement.Scaffold) {
        throw "PTY-prefixed SSH management readiness output was parsed incorrectly."
    }
    $savedApis = $script:AdminConnections
    $savedSshConnections = $script:AdminSshConnections
    try {
        $sshA = New-AdminSshConnection -Name "SSH A"
        $sshB = New-AdminSshConnection -Name "SSH B"
        Set-PalworldSshLastSelectedServer -Connection $sshA -Server "server2"
        Set-PalworldSshLastSelectedServer -Connection $sshA -Server "all"
        if ([string]$sshA.LastSelectedServer -ne "server2") {
            throw "SSH last selected server was not retained safely."
        }
        $apiA1 = New-AdminConnection -Name "API A1"
        $apiA2 = New-AdminConnection -Name "API A2"
        $script:AdminConnections = @($apiA1, $apiA2)
        $script:AdminSshConnections = @($sshA, $sshB)
        Set-PalworldApiSshLink -ApiConnection $apiA1 -SshConnectionId $sshA.Id
        Set-PalworldApiSshLink -ApiConnection $apiA2 -SshConnectionId $sshA.Id
        if ((Get-PalworldPreferredApiConnectionForSsh $sshA).Id -ne $apiA2.Id) {
            throw "SSH recent Server API selection was not retained."
        }
        Set-PalworldApiSshLink -ApiConnection $apiA2 -SshConnectionId $sshB.Id
        if ((Get-PalworldPreferredApiConnectionForSsh $sshA).Id -ne $apiA1.Id -or
            (Get-PalworldPreferredApiConnectionForSsh $sshB).Id -ne $apiA2.Id) {
            throw "Moving a Server API did not repair both SSH recent selections."
        }
    }
    finally {
        $script:AdminConnections = $savedApis
        $script:AdminSshConnections = $savedSshConnections
    }
    $keptServer = Get-PalworldPreferredServerName `
        -Current "server2" -Available @("server1", "server2")
    if ($keptServer -ne "server2") {
        throw "SSH refresh did not preserve the selected server."
    }
    $newServer = Get-PalworldPreferredServerName `
        -Current "server1" `
        -Available @("server1", "server2") `
        -Previous @("server1") `
        -PreferNew
    if ($newServer -ne "server2") {
        throw "SSH Setup refresh did not select the newly created server."
    }
    if ((Resolve-PalworldPostActionApiServer -Configured "server4" -Refreshed "") -ne "server4" -or
        (Resolve-PalworldPostActionApiServer -Configured "" -Refreshed "server2") -ne "server2") {
        throw "Post-Setup Server API synchronization did not resolve an explicit or refreshed serverN."
    }
    $missingPostSetupServerRejected = $false
    try { [void](Resolve-PalworldPostActionApiServer -Configured "" -Refreshed "") }
    catch { $missingPostSetupServerRejected = $_.Exception.Message -match "could not be identified" }
    if (-not $missingPostSetupServerRejected) {
        throw "Post-Setup Server API synchronization accepted an empty server name."
    }
    $artifactCleanup = New-PalworldRemoteArtifactCleanupCommand `
        -Project "/home/guest/palworld-docker"
    if ($artifactCleanup -notmatch 'README\.md' -or
        $artifactCleanup -notmatch 'PalworldServerInstaller\.run' -or
        $artifactCleanup -match '[*?]') {
        throw "Remote release-artifact cleanup is incomplete or uses an unsafe wildcard."
    }
    if (-not (Test-PalworldTypedConfirmationText -Actual "DELETE server1" -Expected "DELETE server1") -or
        (Test-PalworldTypedConfirmationText -Actual "delete server1" -Expected "DELETE server1")) {
        throw "Typed confirmation must use an exact ordinal comparison."
    }
    $confirmation = New-PalworldTypedConfirmationDialog `
        -Title "Regression" `
        -Message "Regression confirmation" `
        -Expected "DELETE server1"
    try {
        if (-not $confirmation.ContinueButton.Enabled) {
            throw "Typed confirmation Continue button must remain enabled."
        }
        $confirmation.Form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $confirmation.Input.Text = "wrong"
        $confirmation.ContinueButton.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        if ($confirmation.Form.DialogResult -eq [System.Windows.Forms.DialogResult]::OK -or
            -not $confirmation.ValidationLabel.Text) {
            throw "An incorrect typed confirmation was accepted."
        }
        $confirmation.Input.Text = "DELETE server1"
        $confirmation.ContinueButton.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        if ($confirmation.Form.DialogResult -ne [System.Windows.Forms.DialogResult]::OK) {
            throw "A correct typed confirmation was not accepted."
        }
    }
    finally { $confirmation.Form.Dispose() }
    $setupCommand = New-PalworldSetupCommand `
        -Project "/home/guest/palworld-docker" `
        -Tools "/tmp/tools" `
        -Server "server2" `
        -Mode update
    $manageCommand = New-PalworldManagerCommand `
        -Project "/home/guest/palworld-docker" `
        -Tools "/tmp/tools" `
        -Arguments "list --format json"
    $testCommand = New-PalworldTestCommand `
        -Project "/home/guest/palworld-docker" `
        -Tools "/tmp/tools" `
        -Server "all" `
        -ManualStart "yes"
    if ($setupCommand -notmatch 'manager.*update.*--server.*server2' -or
        $manageCommand -notmatch 'manager.*list --format json' -or
        $testCommand -notmatch 'install/test.*--server.*all.*--manual-start.*yes') {
        throw "SSH packaged operation command construction is incorrect."
    }
    $managerActionArguments = [ordered]@{
        Reset = "reset --server 'server2'"
        RestoreList = "restore --server 'server2' --list-json"
        Restore = "restore --server 'server2' --backup '2026.07.18-01.00.00' --yes"
        TokenShow = "token --server 'server2' --show"
        TokenRotate = "token --server 'server2' --rotate"
        RemoveServer = "remove --servers 'server2'"
        RemoveAll = "remove --all"
        RemoveProject = "remove --project"
    }
    foreach ($managerAction in $managerActionArguments.Keys) {
        $arguments = if ($managerAction -eq "Restore") {
            New-PalworldManagerActionArguments `
                -Action $managerAction -Server "server2" -Backup "2026.07.18-01.00.00"
        }
        elseif ($managerAction -in @("RemoveAll", "RemoveProject")) {
            New-PalworldManagerActionArguments -Action $managerAction
        }
        else {
            New-PalworldManagerActionArguments -Action $managerAction -Server "server2"
        }
        if ($arguments -cne [string]$managerActionArguments[$managerAction]) {
            throw "SSH manager action arguments are incorrect: $managerAction"
        }
    }
    $invalidActionTargetRejected = $false
    try { Assert-PalworldSshManagementActionTarget -Action "Update" -Server "all" }
    catch { $invalidActionTargetRejected = $true }
    if (-not $invalidActionTargetRejected) {
        throw "A non-Test SSH action accepted the all-servers target."
    }
    Assert-PalworldSshManagementActionTarget -Action "Test" -Server "all"
    if (-not (Test-PalworldWorkDirectory "/home/guest/palworld-docker") -or
        (Test-PalworldWorkDirectory "/home")) {
        throw "SSH project directory safety rules are incorrect."
    }
    if ((ConvertTo-PalworldManagedWorkDirectory "~") -ne "~/palworld-docker" -or
        (ConvertTo-PalworldManagedWorkDirectory "/srv") -ne "/srv/palworld-docker" -or
        (ConvertTo-PalworldManagedWorkDirectory "/srv/palworld-docker") -ne "/srv/palworld-docker") {
        throw "SSH Management parent/project directory normalization is incorrect."
    }
    Disconnect-PalworldSshSession
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "connection-sync") {
    $sshA = New-AdminSshConnection -Name "SSH A"
    $sshB = New-AdminSshConnection -Name "SSH B"
    $apiA1 = New-AdminConnection -Name "API A1" -ServerHost "192.0.2.10" -Port 8212 `
        -Username "admin" -Password "password" -AccessToken ("A" * 32) `
        -SshConnectionId $sshA.Id -ManagedServerName "server1"
    $apiA2 = New-AdminConnection -Name "API A2" -ServerHost "192.0.2.10" -Port 8222 `
        -Username "admin" -Password "password" -AccessToken ("B" * 32) `
        -SshConnectionId $sshA.Id -ManagedServerName "server2"
    $apiB1 = New-AdminConnection -Name "API B1" -SshConnectionId $sshB.Id
    $apiOnly = New-AdminConnection -Name "API only"
    $sshA.LastUsedApiConnectionId = $apiA2.Id
    $sshA.LastSelectedServer = "server2"
    $sshB.LastUsedApiConnectionId = "deleted-api"
    $script:AdminConnections = @($apiA1, $apiA2, $apiB1, $apiOnly)
    $script:AdminSshConnections = @($sshA, $sshB)
    & $refreshAdminConnectionList ""
    & $script:PalworldSshRefreshConnections ""
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()

    $connectionCombo.SelectedIndex = 2
    if ((Get-SelectedPalworldSshConnection).Id -ne $sshA.Id -or
        [string]$sshA.LastUsedApiConnectionId -ne [string]$apiA2.Id) {
        throw "Selecting a Server API did not select and update its linked SSH Connection."
    }
    $script:PalworldSshConnectionCombo.SelectedIndex = 2
    if ((Get-SelectedAdminApiConnection).Id -ne $apiB1.Id -or
        [string]$sshB.LastUsedApiConnectionId -ne [string]$apiB1.Id) {
        throw "Selecting an SSH Connection did not use its safe Server API fallback."
    }

    $connectionCombo.SelectedIndex = 1
    $script:PalworldSshConnectionCombo.SelectedIndex = 0
    if ($null -ne (Get-SelectedAdminApiConnection) -or
        $null -ne (Get-SelectedPalworldSshConnection)) {
        throw "No SSH Connection and Server API selections diverged."
    }
    $script:PalworldSshConnectionCombo.SelectedIndex = 1
    $connectionCombo.SelectedIndex = 0
    if ($null -ne (Get-SelectedAdminApiConnection) -or
        $null -ne (Get-SelectedPalworldSshConnection)) {
        throw "An explicit No Server API selection did not clear the SSH selection."
    }

    $connectionCombo.SelectedIndex = 4
    if ((Get-SelectedAdminApiConnection).Id -ne $apiOnly.Id -or
        $null -ne (Get-SelectedPalworldSshConnection)) {
        throw "An unlinked Server API must select No SSH Connection."
    }
    Set-PalworldApiSshLink -ApiConnection $apiB1 -SshConnectionId ""
    $script:PalworldSshConnectionCombo.SelectedIndex = 2
    Sync-PalworldSshSelectionFromApi
    if ($null -ne (Get-SelectedAdminApiConnection) -or
        (Get-SelectedPalworldSshConnection).Id -ne $sshB.Id) {
        throw "No Server API did not retain the SSH context that produced it."
    }

    Set-PalworldApiSshLink -ApiConnection $apiB1 -SshConnectionId $sshB.Id
    $connectionCombo.SelectedIndex = 2
    $script:PalworldSshPinnedConnectionId = $sshA.Id
    $connectionCombo.SelectedIndex = 3
    $script:AdminTabLayout.Tabs.SelectedIndex = 1
    [System.Windows.Forms.Application]::DoEvents()
    if ((Get-SelectedPalworldSshConnection).Id -ne $sshA.Id -or
        (Get-SelectedAdminApiConnection).Id -ne $apiB1.Id) {
        throw "Changing Server API during a pinned SSH operation changed the SSH Connection."
    }
    $script:AdminTabLayout.Tabs.SelectedIndex = 0
    [System.Windows.Forms.Application]::DoEvents()
    if ((Get-SelectedPalworldSshConnection).Id -ne $sshA.Id -or
        (Get-SelectedAdminApiConnection).Id -ne $apiA2.Id) {
        $actualSsh = Get-SelectedPalworldSshConnection
        $actualApi = Get-SelectedAdminApiConnection
        throw "Returning to Server API did not restore the pinned SSH Connection's recent API. SSH=$([string]$actualSsh.Name), API=$([string]$actualApi.Name), recent=$([string]$sshA.LastUsedApiConnectionId)"
    }
    $script:PalworldSshPinnedConnectionId = ""

    & $script:ResourceUsageRefreshContext
    if ($script:ResourceUsageServerCombo.Items.Count -ne 2 -or
        [string]$script:ResourceUsageServerCombo.SelectedItem -ne "server2") {
        throw "The resource footer did not follow the SSH Connection's last selected server."
    }
    $resourceContext = Get-ResourceUsageApiContext
    if (-not $resourceContext.Ready -or
        -not $resourceContext.ContainerMatches -or
        [string]$resourceContext.ApiConnectionId -ne [string]$apiA2.Id) {
        throw "The resource footer did not resolve the exact SSH/server API mapping."
    }
    $script:PalworldSshPinnedConnectionId = $sshB.Id
    $apiAuthoritativeContext = Get-ResourceUsageApiContext
    if ([string]$apiAuthoritativeContext.Authority -ne "api" -or
        [string]$apiAuthoritativeContext.ApiConnectionId -ne [string]$apiA2.Id -or
        [string]$apiAuthoritativeContext.SshConnectionId -ne [string]$sshA.Id) {
        throw "A pinned SSH operation redirected the Server API tab's resource context."
    }
    $script:PalworldSshPinnedConnectionId = ""
    $script:ResourceUsageServerCombo.SelectedIndex = $script:ResourceUsageServerCombo.Items.IndexOf("server1")
    [System.Windows.Forms.Application]::DoEvents()
    if ([string]$sshA.LastSelectedServer -ne "server1" -or
        [string](Get-SelectedAdminApiConnection).Id -ne [string]$apiA1.Id) {
        throw "Changing the resource footer server did not synchronize SSH LastSelectedServer and Server API."
    }

    $duplicateA1 = New-AdminConnection -Name "API A1 duplicate" -ServerHost "192.0.2.10" -Port 8212 `
        -Username "admin" -Password "password" -AccessToken ("D" * 32) `
        -SshConnectionId $sshA.Id -ManagedServerName "server1"
    $script:AdminConnections = @($script:AdminConnections) + @($duplicateA1)
    $script:AdminTabLayout.Tabs.SelectedIndex = 1
    $script:AdminSelectedId = [string]$apiA2.Id
    $script:PalworldSshCurrentConnection = $null
    $script:PalworldSshClient = $null
    $disconnectedSshResourceContext = Get-ResourceUsageApiContext
    $sshRequiredMessage = Get-PalworldLocalizedText `
        "Connect SSH to start monitoring" `
        "모니터링을 시작하려면 SSH를 연결하세요"
    if ($disconnectedSshResourceContext.Ready -or
        [string]$disconnectedSshResourceContext.Message -ne $sshRequiredMessage) {
        throw "The SSH resource footer became ready without a connected SSH session."
    }
    $script:PalworldSshCurrentConnection = $sshA
    $script:PalworldSshClient = [pscustomobject]@{ IsConnected = $true }
    $ambiguousContext = Get-ResourceUsageApiContext
    $duplicateMappingPattern = if ($script:ApplicationLanguage -eq "ko") { '중복' } else { 'duplicate' }
    if ($ambiguousContext.Ready -or
        [string]$ambiguousContext.ApiConnectionId -or
        [string]$ambiguousContext.Message -notmatch $duplicateMappingPattern) {
        throw "An ambiguous SSH/server resource mapping used an arbitrary API fallback."
    }
    $script:PalworldSshPinnedConnectionId = $sshB.Id
    $script:PalworldSshCurrentConnection = $sshB
    $sshB.LastSelectedServer = "server2"
    $script:AdminSelectedId = [string]$apiB1.Id
    $incorrectFallbackContext = Get-ResourceUsageApiContext
    $missingServerApiMessage = Get-PalworldLocalizedText "server2 has no API" "server2 API 없음"
    if ($incorrectFallbackContext.Ready -or
        [string]$incorrectFallbackContext.ApiConnectionId -or
        [string]$incorrectFallbackContext.Message -ne $missingServerApiMessage) {
        throw "The SSH resource context fell back to an API mapped to the wrong server."
    }
    $script:PalworldSshPinnedConnectionId = ""
    $script:PalworldSshCurrentConnection = $null
    $script:PalworldSshClient = $null
    $script:AdminConnections = @($script:AdminConnections | Where-Object {
        [string]$_.Id -ne [string]$duplicateA1.Id
    })
    $script:AdminSelectedId = [string]$apiA1.Id
    $script:AdminTabLayout.Tabs.SelectedIndex = 0

    $sshC = New-AdminSshConnection `
        -Name "SSH C" `
        -SshHost "192.0.2.30" `
        -Username "guest" `
        -SudoPassword "sudo-test"
    $script:AdminSshConnections = @($script:AdminSshConnections) + @($sshC)
    $initialSettings = [pscustomobject]@{
        ServerHost = "192.0.2.30"
        Port = 8232
        Username = "admin-user"
        Password = "admin-password"
        AccessToken = ("A" * 32)
        RestApiExposed = $true
    }
    $createdMapping = Set-PalworldManagedApiConnection `
        -SshConnection $sshC `
        -Server "server3" `
        -Settings $initialSettings `
        -Mode Full
    if (-not $createdMapping.Created -or
        [string]$createdMapping.Connection.Name -ne "SSH C - server3" -or
        [string]$createdMapping.Connection.ManagedServerName -ne "server3" -or
        [string]$createdMapping.Connection.SshConnectionId -ne [string]$sshC.Id -or
        [string]$createdMapping.Connection.ServerHost -ne "192.0.2.30" -or
        [int]$createdMapping.Connection.Port -ne 8232 -or
        [string]$createdMapping.Connection.Username -ne "admin-user" -or
        [string]$createdMapping.Connection.Password -ne "admin-password" -or
        [string]$createdMapping.Connection.AccessToken -ne ("A" * 32)) {
        throw "Setup-style Server API registration did not persist the SSH/server mapping and credentials."
    }
    # Full SSH synchronization must refresh origin credentials without
    # replacing an operator-configured HTTPS reverse-proxy endpoint.
    $createdMapping.Connection.ServerHost = "https://gateway.example"
    $createdMapping.Connection.Port = 443
    $refreshedSettings = [pscustomobject]@{
        ServerHost = "192.0.2.31"
        Port = 8242
        Username = "refreshed-user"
        Password = "refreshed-password"
        AccessToken = ("C" * 32)
        RestApiExposed = $true
    }
    $fullSyncMapping = Set-PalworldManagedApiConnection `
        -SshConnection $sshC `
        -Server "server3" `
        -Settings $refreshedSettings `
        -Mode Full
    if ($fullSyncMapping.Created -or
        [string]$fullSyncMapping.Connection.ServerHost -ne "https://gateway.example" -or
        [int]$fullSyncMapping.Connection.Port -ne 443 -or
        [string]$fullSyncMapping.Connection.Username -ne "refreshed-user" -or
        [string]$fullSyncMapping.Connection.Password -ne "refreshed-password" -or
        [string]$fullSyncMapping.Connection.AccessToken -ne ("C" * 32)) {
        throw "Full SSH synchronization overwrote a custom TLS Server API endpoint or retained stale credentials."
    }
    $connectionCountBeforeTokenSync = $script:AdminConnections.Count
    $tokenSettings = [pscustomobject]@{
        ServerHost = "changed.example.invalid"
        Port = 9999
        Username = "changed-user"
        Password = "changed-password"
        AccessToken = ("B" * 32)
        RestApiExposed = $true
    }
    $updatedMapping = Set-PalworldManagedApiConnection `
        -SshConnection $sshC `
        -Server "server3" `
        -Settings $tokenSettings `
        -Mode Token
    if ($updatedMapping.Created -or
        [string]$updatedMapping.Connection.Id -ne [string]$createdMapping.Connection.Id -or
        $script:AdminConnections.Count -ne $connectionCountBeforeTokenSync -or
        [string]$updatedMapping.Connection.AccessToken -ne ("B" * 32) -or
        [string]$updatedMapping.Connection.ServerHost -ne "https://gateway.example" -or
        [int]$updatedMapping.Connection.Port -ne 443 -or
        [string]$updatedMapping.Connection.Password -ne "refreshed-password") {
        throw "API token synchronization did not update only the mapped Server API token."
    }
    $removedMappings = @(Remove-PalworldManagedApiConnections -SshConnection $sshC -Server "server3")
    if ($removedMappings.Count -ne 1 -or
        $null -ne (Get-PalworldManagedApiConnection -SshConnection $sshC -Server "server3")) {
        throw "Removing a managed server left a stale Server API mapping."
    }
    Disconnect-PalworldSshSession
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "ssh-ui") {
    if ($null -eq $script:AdminTabLayout -or $script:AdminTabLayout.Tabs.TabPages.Count -ne 3) {
        throw "Admin API, SSH and Licenses tabs were not created."
    }
    if ($script:AdminTabLayout.Tabs.TabPages[0].Text -ne (Get-PalworldLocalizedText "Server API" "서버 API")) { throw "Server API tab is missing." }
    if ($script:AdminTabLayout.Tabs.TabPages[1].Text -ne (Get-PalworldLocalizedText "SSH Management" "SSH 관리")) { throw "SSH Management tab is missing." }
    if ($script:AdminTabLayout.Tabs.TabPages[2].Text -ne (Get-PalworldLocalizedText "Licenses" "라이선스")) { throw "Licenses tab is missing." }
    $channelTabs = @($script:AdminTabLayout.SshPage.Controls.Find("SshChannelTabs", $true))
    if ($channelTabs.Count -ne 1 -or $channelTabs[0].TabPages.Count -ne 2) {
        throw "SSH Management and SSH Terminal channel tabs were not created."
    }
    if ($channelTabs[0].TabPages[0].Text -ne (Get-PalworldLocalizedText "SSH Management" "SSH 관리")) { throw "SSH Management output tab is missing." }
    if ($channelTabs[0].TabPages[1].Text -ne (Get-PalworldLocalizedText "SSH Terminal" "SSH 터미널")) { throw "Direct SSH Terminal tab is missing." }
    if ($script:PalworldSshCategoryCombo.Items.Count -ne 4) { throw "SSH management categories are incomplete." }
    $script:PalworldSshCategoryCombo.SelectedItem = "Manage"
    [System.Windows.Forms.Application]::DoEvents()
    if ($script:PalworldSshActionCombo.Items.Count -ne 6) { throw "Manage action list is incomplete." }
    if (-not $script:PalworldSshOutput.WordWrap -or -not $script:PalworldSshTerminalOutput.WordWrap) {
        throw "SSH output panes must use automatic word wrapping."
    }
    if ($script:PalworldSshOutput.ScrollBars -ne "ForcedVertical" -or $script:PalworldSshTerminalOutput.ScrollBars -ne "ForcedVertical") {
        throw "SSH output panes must use vertical scrollbars only."
    }
    $hostCheckButtons = @($script:AdminTabLayout.SshPage.Controls.Find("SshHostCheckButton", $true))
    if ($hostCheckButtons.Count -ne 1) { throw "SSH Host Check button is missing." }
    $createWorkDirectoryButtons = @($script:AdminTabLayout.SshPage.Controls.Find("SshCreateWorkDirectoryButton", $true))
    if ($createWorkDirectoryButtons.Count -ne 1) { throw "SSH Create Work Directory button is missing." }
    $workDirectoryStatuses = @($script:AdminTabLayout.SshPage.Controls.Find("SshWorkDirectoryStatus", $true))
    $workDirectoryStatusPattern = if ($script:ApplicationLanguage -eq "ko") { '준비 상태' } else { 'Preparation' }
    if ($workDirectoryStatuses.Count -ne 1 -or $workDirectoryStatuses[0].Text -notmatch $workDirectoryStatusPattern) {
        throw "SSH Work Directory readiness status is missing."
    }
    $bottomButtons = @($script:AdminTabLayout.SshPage.Controls.Find("SshTerminalBottomButton", $true))
    if ($bottomButtons.Count -ne 1) { throw "SSH Terminal Bottom button is missing." }
    $networkNotices = @($script:AdminTabLayout.SshPage.Controls.Find("SshNetworkNotice", $true))
    if ($networkNotices.Count -ne 1) { throw "SSH network status area is missing." }
    $script:PalworldSshSelectionSyncing = $true
    $script:PalworldSshServerCombo.Items.Clear()
    [void]$script:PalworldSshServerCombo.Items.Add("server1")
    [void]$script:PalworldSshServerCombo.Items.Add("server2")
    $script:PalworldSshServerCombo.SelectedIndex = 1
    $script:PalworldSshSelectionSyncing = $false
    $script:PalworldSshCategoryCombo.SelectedItem = "Setup"
    [System.Windows.Forms.Application]::DoEvents()
    if ($script:PalworldSshActionCombo.Items.Count -ne 2) { throw "Setup action list is incomplete." }
    if ($script:PalworldSshServerCombo.Enabled -or $script:PalworldSshServerCombo.SelectedIndex -ne -1) {
        throw "A server target remained visible for target-free Setup."
    }
    $script:PalworldSshCategoryCombo.SelectedItem = "Manage"
    [System.Windows.Forms.Application]::DoEvents()
    if (-not $script:PalworldSshServerCombo.Enabled -or
        [string]$script:PalworldSshServerCombo.SelectedItem -notmatch '^server[1-9][0-9]*$') {
        throw "A server target was not restored for a server-specific action."
    }
    $script:PalworldSshCategoryCombo.SelectedItem = "Setup"
    [System.Windows.Forms.Application]::DoEvents()
    $script:AdminTabLayout.Tabs.SelectedIndex = 1
    if ($env:PALWORLD_CLIENT_TEST_CHANNEL -eq "Terminal") {
        $channelTabs[0].SelectedIndex = 1
        if ($channelTabs[0].SelectedIndex -ne 1) { throw "Direct SSH Terminal tab could not be selected." }
    }
    $form.Show()
    [System.Windows.Forms.Application]::DoEvents()
    if ($env:PALWORLD_CLIENT_TEST_CHANNEL -eq "Terminal" -and $channelTabs[0].SelectedIndex -ne 1) {
        throw "Direct SSH Terminal tab selection changed during layout."
    }
    $terminalInputPanels = @($script:AdminTabLayout.SshPage.Controls.Find("SshTerminalInputPanel", $true))
    if ($channelTabs[0].SelectedIndex -eq 1 -and ($terminalInputPanels.Count -ne 1 -or -not $terminalInputPanels[0].Visible)) {
        throw "Direct SSH Terminal command input is not visible."
    }
    if ($env:PALWORLD_CLIENT_TEST_CHANNEL -eq "Terminal") {
        [void]$script:PalworldSshTerminalInput.Focus()
        [System.Windows.Forms.Application]::DoEvents()
        if ($form.AcceptButton -ne $script:PalworldSshTerminalSendButton) {
            throw "SSH Terminal input did not become the Enter-key default action."
        }
        $fakeShell = New-Object psobject -Property @{
            Written = ""
            PendingRead = ""
            MaximumRequestedBytes = 0
            Chunks = New-Object 'System.Collections.Generic.Queue[string]'
        }
        $fakeShell | Add-Member -MemberType ScriptProperty -Name DataAvailable -Value {
            return [bool]$this.PendingRead -or $this.Chunks.Count -gt 0
        }
        $fakeShell | Add-Member -MemberType ScriptMethod -Name ReadPalworldBoundedUtf8 -Value {
            param($maximumBytes)
            $requested = [int]$maximumBytes
            if ($requested -gt $this.MaximumRequestedBytes) {
                $this.MaximumRequestedBytes = $requested
            }
            if (-not $this.PendingRead -and $this.Chunks.Count -gt 0) {
                $this.PendingRead = [string]$this.Chunks.Dequeue()
            }
            if (-not $this.PendingRead) {
                return [pscustomobject]@{ BytesRead = 0; Text = "" }
            }
            $take = [Math]::Min($requested, $this.PendingRead.Length)
            $text = $this.PendingRead.Substring(0, $take)
            $this.PendingRead = $this.PendingRead.Substring($take)
            return [pscustomobject]@{ BytesRead = $take; Text = $text }
        }
        $fakeShell | Add-Member -MemberType ScriptMethod -Name WriteLine -Value {
            param($value)
            $this.Written = [string]$value
        }
        $script:PalworldSshShell = $fakeShell
        $script:PalworldSshTerminalOutput.Clear()
        $fakeShell.Chunks.Enqueue("terminal bounded output regression`r`n")
        $terminalReadDeadline = [DateTime]::UtcNow.AddSeconds(1)
        while ([string]$script:PalworldSshTerminalOutput.Text -notmatch 'terminal bounded output regression' -and
            [DateTime]::UtcNow -lt $terminalReadDeadline) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 20
        }
        if ([string]$script:PalworldSshTerminalOutput.Text -notmatch 'terminal bounded output regression' -or
            $fakeShell.MaximumRequestedBytes -gt 16384) {
            throw "SSH Terminal did not render output through bounded byte reads."
        }
        $script:PalworldSshTerminalInput.Text = "printf enter-regression"
        $form.AcceptButton.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        if ($fakeShell.Written -ne "printf enter-regression" -or $script:PalworldSshTerminalInput.Text) {
            throw "SSH Terminal Enter key did not send and clear the command."
        }
        $longTerminalCommand = "printf " + ("x" * 300)
        $script:PalworldSshTerminalOutput.Clear()
        $script:PalworldSshTerminalInput.Text = $longTerminalCommand
        $form.AcceptButton.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        if ($fakeShell.Written -ne $longTerminalCommand -or
            [string]$script:PalworldSshTerminalOutput.Text -notmatch [regex]::Escape("[INPUT] $longTerminalCommand")) {
            throw "SSH Terminal did not retain a visible confirmation of a long command."
        }
        Set-PalworldSshTerminalPasswordInputMode -Enabled $true -PromptSignature "password-test"
        $script:PalworldSshTerminalInput.Text = "terminal-password-secret"
        $form.AcceptButton.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        if ($fakeShell.Written -ne "terminal-password-secret" -or
            [string]$script:PalworldSshTerminalOutput.Text -match "terminal-password-secret" -or
            $script:PalworldSshTerminalInput.UseSystemPasswordChar -or
            $script:PalworldSshTerminalInput.Text) {
            throw "SSH Terminal password submission leaked input or left masking enabled."
        }
        $fakeShell | Add-Member -Force -MemberType ScriptMethod -Name WriteLine -Value {
            param($value)
            throw "simulated write failure: $value"
        }
        Set-PalworldSshTerminalPasswordInputMode -Enabled $true -PromptSignature "password-failure-test"
        $script:PalworldSshTerminalInput.Text = "terminal-failure-secret"
        $form.AcceptButton.PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        $terminalInputFailurePattern = if ($script:ApplicationLanguage -eq "ko") { "입력 실패" } else { "input failed" }
        if ([string]$script:PalworldSshTerminalOutput.Text -match "terminal-failure-secret" -or
            $script:PalworldSshTerminalInput.UseSystemPasswordChar -or
            $script:PalworldSshTerminalInput.Text -or
            [string]$script:PalworldSshStatus.Text -notmatch $terminalInputFailurePattern) {
            throw "SSH Terminal failed password input was not safely reset."
        }
        & $script:PalworldSshSetOperationState $true
        $failedTerminalShell = New-Object psobject -Property @{ DataAvailable = $true }
        $failedTerminalShell | Add-Member -MemberType ScriptMethod -Name ReadPalworldBoundedUtf8 -Value {
            param($maximumBytes)
            throw "simulated idle terminal transport failure"
        }
        $script:PalworldSshShell = $failedTerminalShell
        & $script:PalworldSshTerminalTick
        $managementContinuesPattern = if ($script:ApplicationLanguage -eq "ko") { "관리 작업 계속 진행 중" } else { "Management operation continues" }
        if ($script:PalworldSshShell -or
            -not $script:PalworldSshOperationRunning -or
            $script:PalworldSshTimer.Enabled -or
            [string]$script:PalworldSshStatus.Text -notmatch $managementContinuesPattern -or
            [string]$script:PalworldSshTerminalOutput.Text -notmatch "current SSH Management operation continues") {
            throw (
                "An idle SSH Terminal transport failure escaped or interrupted the management operation. " +
                "shell=$($null -ne $script:PalworldSshShell), running=$($script:PalworldSshOperationRunning), " +
                "timer=$($script:PalworldSshTimer.Enabled), status='$([string]$script:PalworldSshStatus.Text)', " +
                "warning=$([string]$script:PalworldSshTerminalOutput.Text -match 'current SSH Management operation continues')"
            )
        }
        & $script:PalworldSshSetOperationState $false
    }
    & $script:PalworldSshSetOperationState $true
    if (-not $script:PalworldSshCancelOperationButton.Enabled -or $script:PalworldSshRunButton.Enabled) {
        throw "SSH operation controls did not enter the running state."
    }
    & $script:PalworldSshSetOperationState $false
    if ($script:PalworldSshCancelOperationButton.Enabled) {
        throw "SSH operation controls did not leave the running state."
    }
    $script:PalworldSshTerminalOutput.Clear()
    if ($script:PalworldSshTerminalSanitizer) { $script:PalworldSshTerminalSanitizer.Reset() }
    Add-PalworldSshTerminalOutput -Text "abc**`b `b`b `b" -TerminalStream
    if ($script:PalworldSshTerminalOutput.Text -ne "abc") {
        throw "SSH terminal backspace normalization failed: '$($script:PalworldSshTerminalOutput.Text)'"
    }
    Add-PalworldSshTerminalOutput -Text "progress 10%`rprogress 20%`r`n" -TerminalStream
    if ($script:PalworldSshTerminalOutput.Text -notmatch 'progress 20%') {
        throw "SSH terminal carriage-return normalization failed."
    }
    $script:PalworldSshOutput.Clear()
    $script:PalworldSshOutput.AppendText((1..200 | ForEach-Object { "management $_`r`n" }) -join "")
    $script:PalworldSshOutput.SelectionStart = 0
    Add-PalworldSshOutput "management tail`r`n"
    if ($script:PalworldSshOutput.SelectionStart -ne $script:PalworldSshOutput.TextLength) {
        throw "SSH Management output did not automatically scroll to the bottom."
    }
    $script:PalworldSshTerminalOutput.AppendText((1..200 | ForEach-Object { "line $_`r`n" }) -join "")
    $script:PalworldSshTerminalOutput.SelectionStart = 0
    Add-PalworldSshTerminalOutput "terminal tail`r`n"
    if ($script:PalworldSshTerminalOutput.SelectionStart -ne $script:PalworldSshTerminalOutput.TextLength) {
        throw "SSH Terminal output did not automatically scroll to the bottom."
    }
    $script:PalworldSshTerminalOutput.SelectionStart = 0
    $channelTabs[0].SelectedIndex = 1
    [System.Windows.Forms.Application]::DoEvents()
    $bottomButtons[0].PerformClick()
    [System.Windows.Forms.Application]::DoEvents()
    if ($script:PalworldSshTerminalOutput.SelectionStart -ne $script:PalworldSshTerminalOutput.TextLength) {
        throw "SSH Terminal Bottom button did not move the caret to the latest output."
    }
    & $script:PalworldSshBeginStatusOperation "Regression command A"
    $script:PalworldSshLastOperationFinding = "[PASS] Regression command A"
    $script:PalworldSshLiveStatusLines = @("[INFO] first command detail")
    & $script:PalworldSshRenderStatusNotice
    & $script:PalworldSshBeginStatusOperation "Regression command B"
    $script:PalworldSshLastOperationFinding = "[WARN] Regression command B"
    $script:PalworldSshLiveStatusLines = @("[INFO] second command detail")
    & $script:PalworldSshRenderStatusNotice
    & $script:PalworldSshBeginStatusOperation "Regression command C"
    $script:PalworldSshLastOperationFinding = "[FAIL] Regression command C"
    $script:PalworldSshLiveStatusLines = @("  failure detail")
    & $script:PalworldSshRenderStatusNotice
    if ([string]$script:PalworldSshNetworkNotice.Text -notmatch 'COMMAND · Regression command A' -or
        [string]$script:PalworldSshNetworkNotice.Text -notmatch 'first command detail' -or
        [string]$script:PalworldSshNetworkNotice.Text -notmatch 'COMMAND · Regression command B' -or
        [string]$script:PalworldSshNetworkNotice.Text -notmatch 'second command detail' -or
        [string]$script:PalworldSshNetworkNotice.Text -notmatch 'COMMAND · Regression command C' -or
        [string]$script:PalworldSshNetworkNotice.Text -notmatch 'failure detail' -or
        $script:PalworldSshNetworkNotice.SelectionStart -ne $script:PalworldSshNetworkNotice.TextLength) {
        throw "SSH status history did not append and scroll by command."
    }
    $statusHistoryText = [string]$script:PalworldSshNetworkNotice.Text
    foreach ($colorCheck in @(
        [pscustomobject]@{ Text = '[PASS] Regression command A'; Color = [System.Drawing.Color]::DarkGreen },
        [pscustomobject]@{ Text = '[WARN] Regression command B'; Color = [System.Drawing.Color]::DarkOrange },
        [pscustomobject]@{ Text = '[FAIL] Regression command C'; Color = [System.Drawing.Color]::DarkRed },
        [pscustomobject]@{ Text = '  failure detail'; Color = [System.Drawing.Color]::DarkRed }
    )) {
        $colorIndex = $statusHistoryText.IndexOf([string]$colorCheck.Text, [System.StringComparison]::Ordinal)
        if ($colorIndex -lt 0) {
            throw "SSH status history color regression text is missing: $([string]$colorCheck.Text)"
        }
        $script:PalworldSshNetworkNotice.Select($colorIndex, 1)
        if ($script:PalworldSshNetworkNotice.SelectionColor.ToArgb() -ne $colorCheck.Color.ToArgb()) {
            throw "SSH status history did not apply the expected per-line status color: $([string]$colorCheck.Text)"
        }
    }
    $script:PalworldSshNetworkNotice.Select($script:PalworldSshNetworkNotice.TextLength, 0)
    $script:PalworldSshTerminalOutput.Clear()
    if ($script:PalworldSshTerminalSanitizer) { $script:PalworldSshTerminalSanitizer.Reset() }
    if ($script:ResourceUsageFooter.Parent -ne $form -or
        $script:ResourceUsageFooter.Top -lt $script:AdminTabLayout.Tabs.Bottom) {
        throw "Admin resource footer is missing or overlaps the main tabs."
    }
    $bitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
    try {
        $form.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        if ($env:PALWORLD_CLIENT_TEST_SCREENSHOT) {
            $bitmap.Save([IO.Path]::GetFullPath($env:PALWORLD_CLIENT_TEST_SCREENSHOT))
        }
    }
    finally {
        $bitmap.Dispose()
        Stop-PalworldSshUiForExit
        $shutdownReady = $script:PalworldSshClosing -and
            $null -eq $script:PalworldSshTimer -and
            $null -eq $script:PalworldSshClient -and
            $null -eq $script:PalworldSshTerminalClient -and
            $null -eq $script:PalworldSshShell
        $form.Dispose()
        if (-not $shutdownReady) {
            throw "SSH UI shutdown did not detach timers and SSH channels immediately."
        }
    }
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "admin-empty") {
    if ($connectionCombo.Items.Count -ne 1 -or $connectionCombo.SelectedIndex -ne 0) {
        throw "Empty admin store must contain only the No Server API sentinel"
    }
    if (
        $connectionUpdateButton.Enabled -or
        $connectionDeleteButton.Enabled -or
        $worldRestoreButton.Enabled -or
        $runtimeLogButton.Enabled -or
        $commandGroup.Enabled -or
        $sendButton.Enabled
    ) {
        throw "Admin actions must remain disabled without a Connection"
    }
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "restore") {
    Show-WorldRestoreDialog -Owner $form
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "restore-close") {
    foreach ($phase in @("Send", "Read", "Refresh")) {
        $env:PALWORLD_RESTORE_CLOSE_TEST_PHASE = $phase
        Show-WorldRestoreDialog -Owner $form
    }
    Remove-Item Env:PALWORLD_RESTORE_CLOSE_TEST_PHASE -ErrorAction SilentlyContinue
    $form.Dispose()
    return
}
if ($script:IsAdminEdition -and $env:PALWORLD_CLIENT_TEST_MODE -eq "logs") {
    Show-RuntimeLogDialog -Owner $form
    $form.Dispose()
    return
}
if ($env:PALWORLD_CLIENT_TEST_MODE -eq "1") {
    if ($form.Text -ne $script:ApplicationTitle) { throw "Unexpected form title" }
    $socketFailure = [System.Net.Sockets.SocketException]::new(10061)
    $httpFailure = [System.Net.Http.HttpRequestException]::new(
        "wrapped HTTP failure",
        $socketFailure
    )
    $methodFailure = [Exception]::new("GetResult wrapper", $httpFailure)
    $httpFailureDetail = Get-PalworldHttpFailureDetail -Exception $methodFailure
    $expectedConnectionFailure = Get-PalworldLocalizedText `
        "Could not connect to the Server API" `
        "Server API에 연결할 수 없습니다"
    if ($httpFailureDetail -notmatch [Regex]::Escape($expectedConnectionFailure) -or
        $httpFailureDetail -match "GetResult wrapper") {
        throw "HTTP failure detail did not unwrap the PowerShell task exception."
    }
    if ($env:PALWORLD_CLIENT_ICON_PATH -and
        ($null -eq $script:ApplicationIcon -or $null -eq $form.Icon)) {
        throw "The packaged application icon was not applied to the main window"
    }
    if ($null -eq $script:ApplicationMenuStrip -or
        $script:ApplicationLanguageMenu.DropDownItems.Count -ne 2 -or
        $script:ApplicationEnglishLanguageItem.Checked -ne ($script:ApplicationLanguage -eq "en") -or
        $script:ApplicationKoreanLanguageItem.Checked -ne ($script:ApplicationLanguage -eq "ko")) {
        throw "Application language menu is incomplete"
    }
    if ($null -eq $script:ApplicationProjectMenu -or
        $script:ApplicationLanguageMenu.Text -ne "Language" -or
        $script:ApplicationProjectMenu.Text -ne "Project") {
        throw "Project identity, contact, or license controls are incomplete"
    }
    if ($script:IsAdminEdition) {
        $adminNavigationItems = @(
            0..2 | ForEach-Object {
                $script:ApplicationMenuStrip.Items["ApplicationAdminTab$_"]
            }
        )
        if ($script:ApplicationMenuStrip.Items.Count -ne 5 -or
            @($adminNavigationItems | Where-Object { $null -eq $_ }).Count -gt 0 -or
            $script:ApplicationLanguageMenu.Alignment -ne [System.Windows.Forms.ToolStripItemAlignment]::Left -or
            $script:ApplicationProjectMenu.Alignment -ne [System.Windows.Forms.ToolStripItemAlignment]::Left -or
            $script:AdminTabLayout.Tabs.Top -lt $script:ApplicationMenuStrip.Bottom -or
            $script:AdminTabLayout.Tabs.Bottom -gt $script:ResourceUsageFooter.Top -or
            $script:ApplicationMenuStrip.Right -gt $form.ClientSize.Width) {
            throw "Admin navigation, language, and project menu layout is invalid"
        }
        $adminNavigationItems[1].PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:AdminTabLayout.Tabs.SelectedIndex -ne 1) {
            throw (
                "SSH Management navigation item did not select its TabPage " +
                "(selected=$($script:AdminTabLayout.Tabs.SelectedIndex))"
            )
        }
        $adminNavigationItems[0].PerformClick()
        [System.Windows.Forms.Application]::DoEvents()
        if ($script:AdminTabLayout.Tabs.SelectedIndex -ne 0) {
            throw "Server API navigation item did not restore its TabPage"
        }
    }
    else {
        if ($script:ApplicationLanguageMenu.Alignment -ne [System.Windows.Forms.ToolStripItemAlignment]::Right -or
            $script:ApplicationProjectMenu.Alignment -ne [System.Windows.Forms.ToolStripItemAlignment]::Right) {
            throw "Client language and project menus are not right aligned"
        }
        foreach ($topLevelControl in @($form.Controls)) {
            if ($topLevelControl -eq $script:ApplicationMenuStrip -or
                $topLevelControl -eq $script:ResourceUsageFooter) { continue }
            if ($topLevelControl.Top -lt $script:ApplicationMenuStrip.Bottom) {
                throw "User language menu overlaps the main content"
            }
        }
    }
    if ($env:OS -eq "Windows_NT") {
        if ($script:ApplicationShellIdentityError) {
            throw "Windows application identity was not initialized: $($script:ApplicationShellIdentityError)"
        }
        $actualApplicationUserModelId = [PalworldServerOperations.WindowsShellIdentity]::Get()
        if ($actualApplicationUserModelId -ne $script:ApplicationUserModelId) {
            throw "Unexpected Windows application identity: $actualApplicationUserModelId"
        }
    }
    if ($commandCombo.Items.Count -ne $script:ApiDefinitions.Count) { throw "Command list is incomplete" }
    if ($script:IsAdminEdition) {
        if ($script:AdminTabLayout.ApiPage.Controls.Contains($adminConnectionGroup) -ne $true) { throw "Admin Connection panel is missing" }
        if ($script:AdminTabLayout.ApiPage.Controls.Contains($adminToolsGroup) -ne $true) { throw "Admin Server Tools panel is missing" }
        if ($script:AdminTabLayout.Tabs.TabPages.Count -ne 3) { throw "Admin tabs are incomplete" }
        if ($null -eq $worldRestoreButton -or $null -eq $runtimeLogButton) { throw "Admin tools are missing" }
        if (-not $connectionNameText.ReadOnly -or -not $connectionHostText.ReadOnly -or -not $connectionPortText.ReadOnly) {
            throw "Admin Connection summary fields must be read-only"
        }
        if ([string]$commandCombo.Items[0] -notmatch '/v1/api/') {
            throw "Admin command display must keep API paths"
        }
        if ($null -eq $script:ResourceUsageServerCombo -or
            $null -eq $script:ResourceUsageContainerHistoryButton) {
            throw "Admin host/container resource footer is incomplete"
        }
        if ([string]$script:PalworldSshNetworkNotice.Text -notmatch 'COMMAND ·' -or
            [string]$script:PalworldSshNetworkNotice.Text -notmatch '\[INFO\]') {
            throw "SSH status history did not render its initial command and guidance"
        }
    }
    else {
        if ($form.Controls.Contains($connectionButton) -ne $true) { throw "Connection Settings button is missing" }
        if ($form.Controls.Contains($verifyConnectionButton) -ne $true) { throw "Verify Server button is missing" }
        if ($null -ne $worldRestoreButton) { throw "User edition must not expose World Restore" }
        if ($commandGroup.Enabled -ne $false -or $sendButton.Enabled -ne $false) {
            throw "User commands must remain disabled before server verification"
        }
        if ([string]$commandCombo.Items[0] -match '/v1/' -or [string]$commandCombo.Items[9] -match '/v1/') {
            throw "User command display must hide API paths"
        }
        $directWarningPattern = if ($script:ApplicationLanguage -eq "ko") {
            '권장하지 않음'
        }
        else {
            'not recommended'
        }
        if ([string]$commandCombo.Items[9] -notmatch $directWarningPattern) {
            throw "User direct-command warning must remain visible"
        }
        if ($null -ne $script:ResourceUsageServerCombo -or
            $null -eq $script:ResourceUsageHostHistoryButton) {
            throw "User host resource footer is incomplete"
        }
    }
    if ($script:ResourceUsageFooter.Parent -ne $form -or
        $script:ResourceUsageFooter.Bottom -gt $form.ClientSize.Height) {
        throw "Resource usage footer is not anchored to the form bottom"
    }
    if ($null -eq $script:ProjectStatusStrip -or
        $script:ProjectStatusStrip.Parent.Parent -ne $script:ResourceUsageFooter -or
        $script:ProjectStatusStrip.Bottom -gt $script:ResourceUsageFooter.ClientSize.Height) {
        throw "Project and GPL status row is not contained by the resource footer"
    }
    $testCurrentPayload = @'
{"sampled_at":1784446757.606085,"host":{"cpu_percent":1.64,"memory_used_bytes":3416707072,"memory_total_bytes":33615020032,"network_receive_bytes_per_second":406.76,"network_transmit_bytes_per_second":807.52,"network_interface":"eth0"},"container":{"instance":"server1","cpu_percent":1.51,"memory_used_bytes":1163816960,"network_receive_bytes_per_second":406.76,"network_transmit_bytes_per_second":807.52},"errors":[]}
'@ | ConvertFrom-Json
    $testCurrentContext = [pscustomobject]@{
        ContainerMatches = $true
        ServerName = "server1"
        Password = "resource-secret-password"
        AccessToken = ("R" * 32)
        TargetDescription = "resource-test:8212 · server1"
    }
    Set-ResourceUsagePayload -Payload $testCurrentPayload -Context $testCurrentContext
    $recentSamplePattern = if ($script:ApplicationLanguage -eq "ko") { '최근 수집' } else { 'Last sample' }
    if ([string]$script:ResourceUsageHostCpu.Text -notmatch '^CPU .+%' -or
        [string]$script:ResourceUsageHostCpu.Text -match '—' -or
        [string]$script:ResourceUsageHostMemory.Text -notmatch '/' -or
        [string]$script:ResourceUsageHostReceive.Text -notmatch 'Mbps' -or
        [string]$script:ResourceUsageFooter.Tag -notmatch $recentSamplePattern) {
        throw "A successful resource-usage payload did not update the footer."
    }
    if ($script:IsAdminEdition -and (
        [string]$script:ResourceUsageContainerCpu.Text -notmatch '^CPU .+%' -or
        [string]$script:ResourceUsageContainerMemory.Text -notmatch 'GB')) {
        throw "A successful resource-usage payload did not update the selected container."
    }
    $safeDiagnostic = ConvertTo-ResourceUsageSafeDiagnostic `
        -Text "password=resource-secret-password access_token=$('R' * 32)" `
        -Context $testCurrentContext
    if ($safeDiagnostic -match 'resource-secret-password' -or $safeDiagnostic -match ('R' * 32)) {
        throw "Resource-usage diagnostics exposed saved credentials."
    }
    if ((Get-ResourceUsageRetryDelaySeconds -Kind Transient -FailureCount 1) -ne 1 -or
        (Get-ResourceUsageRetryDelaySeconds -Kind Transient -FailureCount 6) -ne 30 -or
        (Get-ResourceUsageRetryDelaySeconds -Kind NotFound -FailureCount 1) -ne 30) {
        throw "Resource-usage retry backoff is not bounded as expected."
    }
    Set-ResourceUsagePollingResult -Kind Authentication -ContextKey "auth-test"
    if ($script:ResourceUsageBlockedContextKey -ne "auth-test" -or
        $script:ResourceUsageNextRequestUtc -ne [DateTime]::MaxValue) {
        throw "Resource-usage authentication failures were not suspended until context changes."
    }
    Reset-ResourceUsagePollingBackoff
    if ($script:ResourceUsageBlockedContextKey -or $script:ResourceUsageFailureCount -ne 0) {
        throw "Resource-usage retry state did not reset after a context change."
    }
    $originalResourceUsagePollTick = $script:ResourceUsagePollTick
    try {
        $script:ResourceUsagePollTick = { throw "simulated resource timer failure" }
        & $script:ResourceUsageTimerTick
        $temporaryResourceErrorPattern = if ($script:ApplicationLanguage -eq "ko") {
            "사용량 표시 일시 오류"
        }
        else {
            "Temporary resource display error"
        }
        if ([string]$script:ResourceUsageHostMemory.Text -notmatch $temporaryResourceErrorPattern -or
            $script:ResourceUsageNextRequestUtc -le [DateTime]::UtcNow) {
            throw "A resource polling timer failure escaped its WinForms event boundary."
        }
    }
    finally {
        $script:ResourceUsagePollTick = $originalResourceUsagePollTick
        Reset-ResourceUsagePollingBackoff
    }
    # Leave screenshot and subsequent layout checks in a healthy sampled state.
    Set-ResourceUsagePayload -Payload $testCurrentPayload -Context $testCurrentContext
    $testCpuChart = New-ResourceHistoryChart -YAxisTitle "CPU (%)" -Percent
    $testMemoryChart = New-ResourceHistoryChart -YAxisTitle (Get-PalworldLocalizedText "Memory (GB)" "메모리 (GB)")
    $testNetworkChart = New-ResourceHistoryChart -YAxisTitle (Get-PalworldLocalizedText "Rate (Mbps)" "속도 (Mbps)")
    try {
        $testHistoryPayload = [pscustomobject]@{
            points = @([pscustomobject]@{
                sampled_at = 1760000000
                host = [pscustomobject]@{
                    cpu_percent = 12.5
                    memory_used_bytes = 8GB
                    memory_total_bytes = 16GB
                    network_receive_bytes_per_second = 125000
                    network_transmit_bytes_per_second = 62500
                }
                container = [pscustomobject]@{
                    cpu_percent = 4.5
                    memory_used_bytes = 2GB
                    network_receive_bytes_per_second = 25000
                    network_transmit_bytes_per_second = 12500
                }
            })
        }
        Set-ResourceHistoryCharts `
            -CpuChart $testCpuChart -MemoryChart $testMemoryChart `
            -NetworkChart $testNetworkChart -Payload $testHistoryPayload `
            -Scope $(if ($script:IsAdminEdition) { "Container" } else { "Host" })
        if ($testCpuChart.Series.Count -ne 1 -or
            $testCpuChart.Series[0].Points.Count -ne 1 -or
            $testMemoryChart.Series.Count -lt 1 -or
            $testNetworkChart.Series.Count -ne 2) {
            throw "Resource history charts did not create the expected series"
        }
    }
    finally {
        $testCpuChart.Dispose()
        $testMemoryChart.Dispose()
        $testNetworkChart.Dispose()
    }
    if ($env:PALWORLD_CLIENT_TEST_SCREENSHOT) {
        if ($script:IsAdminEdition -and
            $env:PALWORLD_CLIENT_TEST_SCREENSHOT_TAB -eq "ssh") {
            $script:AdminTabLayout.Tabs.SelectedIndex = 1
        }
        $form.Show()
        [System.Windows.Forms.Application]::DoEvents()
        $fullBitmap = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
        try {
            $form.DrawToBitmap($fullBitmap, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $fullBitmap.Save([IO.Path]::GetFullPath($env:PALWORLD_CLIENT_TEST_SCREENSHOT))
        }
        finally { $fullBitmap.Dispose() }
    }
    $bitmap = New-Object System.Drawing.Bitmap($commandInputWidth, 23)
    try {
        $commandCombo.DrawToBitmap($bitmap, (New-Object System.Drawing.Rectangle(0, 0, $commandInputWidth, 23)))
    }
    finally {
        $bitmap.Dispose()
        if ($script:IsAdminEdition) { Disconnect-PalworldSshSession }
        $form.Dispose()
    }
    return
}
try {
    [void]$form.ShowDialog()
}
finally {
    if ($script:IsAdminEdition) { Stop-PalworldSshUiForExit }
    if (-not $form.IsDisposed) { $form.Dispose() }
}
if ($script:ApplicationRestartRequested -and
    $env:PALWORLD_CLIENT_EXE_PATH -and
    (Test-Path -LiteralPath $env:PALWORLD_CLIENT_EXE_PATH -PathType Leaf)) {
    try {
        Start-Process `
            -FilePath ([IO.Path]::GetFullPath($env:PALWORLD_CLIENT_EXE_PATH)) `
            -WorkingDirectory $script:ClientBaseDirectory
    }
    catch {
        [void][System.Windows.Forms.MessageBox]::Show(
            "The language was saved, but the application could not restart automatically.`r`n`r`n$($_.Exception.Message)",
            $script:ApplicationTitle,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        )
    }
}
