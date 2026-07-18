# Z-Rotations installer. Run:  irm https://raw.githubusercontent.com/itszeondk/zeon-assets/main/apep/install.ps1 | iex
# Downloads Z-Rotations.enc + UI assets and places them for Apep + WoW.
Set-StrictMode -Version 2.0

$ZRotInstaller_Version = '0.1.0'
$ZRotInstaller_Loaded  = $true

$script:BaseUrl      = 'https://raw.githubusercontent.com/itszeondk/zeon-assets/main/'
$script:SubFolder    = 'apep/'
$script:ManifestPath = 'apep/manifest.txt'

# --- Task 2: core logic functions ---

function Get-WowDirFromApepJson {
    param([string]$JsonText)
    if ([string]::IsNullOrWhiteSpace($JsonText)) { return $null }
    try { $cfg = $JsonText | ConvertFrom-Json } catch { return $null }
    try {
        if (-not $cfg.Profiles) { return $null }
        $active = $cfg.ActiveProfileName
        $activeProfile = $null
        foreach ($p in $cfg.Profiles) {
            if ($active -and $p.Name -eq $active) { $activeProfile = $p; break }
        }
        if (-not $activeProfile) { $activeProfile = $cfg.Profiles | Select-Object -First 1 }
        # SECURITY: read only the path; never touch AccountName/AccountPassword.
        $wowPath = $activeProfile.WowPath
        if ([string]::IsNullOrWhiteSpace($wowPath)) { return $null }
        return (Split-Path -Parent $wowPath)
    } catch {
        return $null
    }
}

function ConvertFrom-ZRotManifest {
    param([string]$Text)
    $map = @{}
    if ([string]::IsNullOrEmpty($Text)) { return $map }
    foreach ($line in ($Text -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith('#')) { continue }
        if ($t -match '^(\S+)\s+(\S+)$') {
            $map[($matches[1] -replace '\\','/')] = $matches[2]
        }
    }
    return $map
}

function Get-ZRotRemoteUrl {
    param([string]$Rel)
    return $script:BaseUrl + $script:SubFolder + ($Rel -replace '\\','/')
}

function Get-ZRotDestination {
    param([string]$Rel, [string]$ApepDir, [string]$WowDir)
    $rel = $Rel -replace '\\','/'
    $ext = [System.IO.Path]::GetExtension($rel).ToLowerInvariant()
    if ($ext -eq '.tga') {
        $stem = [System.IO.Path]::GetFileNameWithoutExtension($rel)
        return (Join-Path $WowDir ("Interface\ZRotations\{0}.tga" -f $stem))
    }
    if ($ext -eq '.enc') {
        $name = [System.IO.Path]::GetFileName($rel)
        return (Join-Path $ApepDir ("rotations\plugins\{0}" -f $name))
    }
    return (Join-Path $ApepDir ("media\zrotations\{0}" -f ($rel -replace '/','\')))
}

function Get-Sha1Short {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA1).Hash.ToLowerInvariant().Substring(0,10)
}

function Get-ZRotPlan {
    param([hashtable]$Remote, [hashtable]$LocalHashes)
    $install = @(); $update = @(); $current = @()
    foreach ($rel in $Remote.Keys) {
        $have = $null
        if ($LocalHashes.ContainsKey($rel)) { $have = $LocalHashes[$rel] }
        if ([string]::IsNullOrEmpty($have)) { $install += $rel }
        elseif ($have -ne $Remote[$rel]) { $update += $rel }
        else { $current += $rel }
    }
    return [pscustomobject]@{ Install = $install; Update = $update; Current = $current }
}


# --- Task 3: apply engine + validators ---

function Test-ApepDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path 'Apep.exe')) -and
           (Test-Path -LiteralPath (Join-Path $Path 'Apep.json')) -and
           (Test-Path -LiteralPath (Join-Path $Path 'rotations'))
}

function Test-WowDir {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $Path 'Interface'))
}

function Find-ApepDir {
    $candidates = @(
        (Join-Path $env:USERPROFILE 'Documents\Apep'),
        (Get-Location).Path
    )
    foreach ($c in $candidates) { if (Test-ApepDir $c) { return $c } }
    return $null
}

function Save-ZRotFile {
    param([string]$Url, [string]$Dest)
    try {
        $dir = Split-Path -Parent $Dest
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $tmp = "$Dest.tmp"
        $old = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing
        $ProgressPreference = $old
        Move-Item -LiteralPath $tmp -Destination $Dest -Force
        return $true
    } catch {
        if (Test-Path -LiteralPath "$Dest.tmp") { Remove-Item -LiteralPath "$Dest.tmp" -Force -ErrorAction SilentlyContinue }
        return $false
    }
}

function Invoke-ZRotApply {
    param([hashtable]$Remote, [string[]]$RelList, [string]$ApepDir, [string]$WowDir, [scriptblock]$OnProgress)
    $ok = 0; $failed = @(); $total = $RelList.Count; $i = 0
    foreach ($rel in $RelList) {
        $i++
        $url = Get-ZRotRemoteUrl $rel
        $dest = Get-ZRotDestination $rel $ApepDir $WowDir
        $good = Save-ZRotFile $url $dest
        if ($good) { $ok++ } else { $failed += $rel }
        if ($OnProgress) { & $OnProgress $i $total $rel $good }
    }
    return @{ Ok = $ok; Failed = $failed }
}

# --- Task 3: config persistence ---

function Get-ZRotConfigPath {
    return (Join-Path $env:LOCALAPPDATA 'ZRotations\installer.json')
}

function Save-ZRotInstallerConfig {
    param([string]$ApepDir, [string]$WowDir)
    try {
        $cfgPath = Get-ZRotConfigPath
        $cfgDir = Split-Path -Parent $cfgPath
        if (-not (Test-Path -LiteralPath $cfgDir)) { New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null }
        $obj = [pscustomobject]@{ ApepDir = $ApepDir; WowDir = $WowDir }
        ($obj | ConvertTo-Json) | Set-Content -LiteralPath $cfgPath -Encoding UTF8
    } catch {
        # Non-fatal: failing to persist paths should not block installation.
    }
}

function Read-ZRotInstallerConfig {
    $cfgPath = Get-ZRotConfigPath
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $null }
    try {
        return (Get-Content -Raw -LiteralPath $cfgPath | ConvertFrom-Json)
    } catch {
        return $null
    }
}

# --- Task 3: themed WPF GUI ---

# Base64 PNG payload for the sidebar logo mark (media/zrotations/icons/zeon-nobg.png).
# Embedded so the installer works standalone via `irm <url> | iex` with no extra fetch.
$script:ZRotLogoBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAtAAAALRCAYAAAByC5Q5AAAZNElEQVR42u3dW4xU933A8d9/ZnbZxeAh9tbUxAY7sXORRZQoclslqZBlKxVKJZRIuDKWHxaowS2OHzZSwGYtGUiIbzEhhtgES43UvuQhechLKzUPrZQ+pFIe0tptbKdyWgc3OLjmtgsG5t+Hnd0ddm5nYbks8/lIaHduZ+b85jD7naOzs2loaHkAAADFlIwAAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAICABgAAAQ0AAALaCAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgjAAAAAQ0AAAIaAAAENAAACGgAABDQAAAgoI0AAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAICABgAAAQ0AAALaCAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgjAAAAAQ0AAAIaAAAENAAACGgAABDQAAAgoI0AAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAICABgAAAQ0AAALaCAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgjAAAAAQ0AAAIaAAAENAAACGgAABDQAAAgoI0AAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAICABgAAAQ0AAALaCAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgjAAAAAQ0AAAIaAAAENAAACGgAABDQAAAgoI0AAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAICABgAAAQ0AAALaCAAAQEADAICABgAAAQ0AAAIaAAAENAAACGgjAAAAAQ0AAAIaAAAENAAACGgAABDQAAAgoI0AAAAENAAACGgAABDQAAAgoAEAQEADAICANgIAABDQAAAgoAEAQEADAMA8UjECLtTaB9blJUuqEydSmvgSkyfT1KmUGr6mFufVr1n/tumySKn5vMllR4rps5qX3W6ZKRofSzQtO6UOj31qvXLD/TQ/5pmXRZ65zNbXn3lZipnLbjGHFvc3ebvzH0u24QI978033og9zz6bTAIBzWX3Fw88EDd/+MMGAcC8Ui6XDYFwCAcAAAhoAAAQ0AAAIKABAEBAAwAA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'

function Get-ZRotInstallerXaml {
    return @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Z-Rotations Installer"
        Width="760" Height="560" MinWidth="680" MinHeight="480"
        WindowStartupLocation="CenterScreen"
        Background="#131519"
        FontFamily="Montserrat, Segoe UI Semibold"
        FontSize="13"
        Foreground="#DCDEE4">
    <Window.Resources>
        <SolidColorBrush x:Key="BrushWindow" Color="#131519"/>
        <SolidColorBrush x:Key="BrushSidebar" Color="#14181E"/>
        <SolidColorBrush x:Key="BrushContent" Color="#111217"/>
        <SolidColorBrush x:Key="BrushCard" Color="#16151C"/>
        <SolidColorBrush x:Key="BrushInput" Color="#0B0C11"/>
        <SolidColorBrush x:Key="BrushAccent" Color="#B70832"/>
        <SolidColorBrush x:Key="BrushAccentHover" Color="#C0264B"/>
        <SolidColorBrush x:Key="BrushText" Color="#DCDEE4"/>
        <SolidColorBrush x:Key="BrushMuted" Color="#737680"/>
        <SolidColorBrush x:Key="BrushSuccess" Color="#4DC778"/>
        <SolidColorBrush x:Key="BrushError" Color="#ED4052"/>
        <SolidColorBrush x:Key="BrushBorder" Color="#202027"/>
        <SolidColorBrush x:Key="BrushStepLine" Color="#202027"/>

        <Style x:Key="SidebarWordmark" TargetType="TextBlock">
            <Setter Property="FontSize" Value="17"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="HorizontalAlignment" Value="Center"/>
        </Style>

        <Style x:Key="StepLabel" TargetType="TextBlock">
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>

        <Style x:Key="PathLabel" TargetType="TextBlock">
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
        </Style>

        <Style x:Key="PathBox" TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource BrushInput}"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
            <Setter Property="Focusable" Value="True"/>
        </Style>

        <Style x:Key="GlyphText" TargetType="TextBlock">
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="HorizontalAlignment" Value="Center"/>
            <Setter Property="VerticalAlignment" Value="Center"/>
            <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
        </Style>

        <Style x:Key="SecondaryButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="BorderBrush" Value="{StaticResource BrushBorder}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="10,6"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FontSize" Value="12"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}"
                                CornerRadius="2">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{StaticResource BrushAccent}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="AccentButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource BrushAccent}"/>
            <Setter Property="Foreground" Value="{StaticResource BrushText}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Padding" Value="18,10"/>
            <Setter Property="FontSize" Value="14"/>
            <Setter Property="FontWeight" Value="Bold"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" CornerRadius="3">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource BrushAccentHover}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter TargetName="Bd" Property="Background" Value="{StaticResource BrushBorder}"/>
                                <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="AccentProgressBar" TargetType="ProgressBar">
            <Setter Property="Background" Value="{StaticResource BrushInput}"/>
            <Setter Property="Foreground" Value="{StaticResource BrushAccent}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Height" Value="4"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ProgressBar">
                        <Grid>
                            <Border Background="{TemplateBinding Background}" CornerRadius="2"/>
                            <Grid ClipToBounds="True">
                                <Border x:Name="PART_Indicator" Background="{TemplateBinding Foreground}"
                                        CornerRadius="2" HorizontalAlignment="Left"/>
                            </Grid>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style x:Key="LogBoxStyle" TargetType="TextBox">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource BrushMuted}"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="FontFamily" Value="Consolas"/>
            <Setter Property="FontSize" Value="11"/>
            <Setter Property="IsReadOnly" Value="True"/>
            <Setter Property="TextWrapping" Value="Wrap"/>
            <Setter Property="AcceptsReturn" Value="True"/>
            <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.ColumnDefinitions>
            <ColumnDefinition Width="216"/>
            <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>

        <!-- Sidebar -->
        <Border Grid.Column="0" Background="{StaticResource BrushSidebar}">
            <Grid Margin="0,28,0,20">
                <Grid.RowDefinitions>
                    <RowDefinition Height="*"/>
                    <RowDefinition Height="Auto"/>
                </Grid.RowDefinitions>

                <StackPanel Grid.Row="0" Margin="24,0,24,0">
                    <Image x:Name="LogoImage" Width="52" Height="52" HorizontalAlignment="Center"/>
                    <TextBlock Text="Z-ROTATIONS" Style="{StaticResource SidebarWordmark}" Margin="0,14,0,2"/>
                    <TextBlock Text="INSTALLER" FontSize="10" Foreground="{StaticResource BrushMuted}"
                               HorizontalAlignment="Center" Margin="0,0,0,36"/>

                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="20"/>
                            <ColumnDefinition Width="*"/>
                        </Grid.ColumnDefinitions>
                        <Grid.RowDefinitions>
                            <RowDefinition Height="32"/>
                            <RowDefinition Height="32"/>
                            <RowDefinition Height="32"/>
                        </Grid.RowDefinitions>

                        <Border Grid.Column="0" Grid.Row="0" Grid.RowSpan="3" Width="2"
                                Background="{StaticResource BrushStepLine}" Margin="0,6,0,6"/>

                        <Ellipse x:Name="StepDotDetect" Grid.Column="0" Grid.Row="0" Width="10" Height="10"
                                 Fill="{StaticResource BrushAccent}" HorizontalAlignment="Center"/>
                        <TextBlock x:Name="StepLabelDetect" Grid.Column="1" Grid.Row="0" Text="Detect"
                                   Style="{StaticResource StepLabel}" Foreground="{StaticResource BrushAccent}" Margin="10,0,0,0"/>

                        <Ellipse x:Name="StepDotInstall" Grid.Column="0" Grid.Row="1" Width="10" Height="10"
                                 Fill="{StaticResource BrushMuted}" HorizontalAlignment="Center"/>
                        <TextBlock x:Name="StepLabelInstall" Grid.Column="1" Grid.Row="1" Text="Install"
                                   Style="{StaticResource StepLabel}" Margin="10,0,0,0"/>

                        <Ellipse x:Name="StepDotDone" Grid.Column="0" Grid.Row="2" Width="10" Height="10"
                                 Fill="{StaticResource BrushMuted}" HorizontalAlignment="Center"/>
                        <TextBlock x:Name="StepLabelDone" Grid.Column="1" Grid.Row="2" Text="Done"
                                   Style="{StaticResource StepLabel}" Margin="10,0,0,0"/>
                    </Grid>
                </StackPanel>

                <TextBlock x:Name="VersionText" Grid.Row="1" Text="" FontSize="10"
                           Foreground="{StaticResource BrushMuted}" HorizontalAlignment="Center"/>
            </Grid>
        </Border>

        <!-- Content -->
        <Grid Grid.Column="1" Background="{StaticResource BrushContent}" Margin="28,26,28,24">
            <Grid.RowDefinitions>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="Auto"/>
                <RowDefinition Height="*"/>
            </Grid.RowDefinitions>

            <StackPanel Grid.Row="0" Margin="0,0,0,18">
                <TextBlock Text="Set up Z-Rotations" FontSize="20" FontWeight="Bold" Foreground="{StaticResource BrushText}"/>
                <TextBlock Text="Detects your Apep and WoW folders, then installs the rotation plugin and UI assets."
                           FontSize="12" Foreground="{StaticResource BrushMuted}" Margin="0,6,0,0" TextWrapping="Wrap"/>
            </StackPanel>

            <Border Grid.Row="1" Background="{StaticResource BrushCard}" BorderBrush="{StaticResource BrushBorder}"
                    BorderThickness="1" CornerRadius="3" Padding="18">
                <Grid>
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="60"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="84"/>
                        <ColumnDefinition Width="26"/>
                    </Grid.ColumnDefinitions>
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="14"/>
                        <RowDefinition Height="Auto"/>
                    </Grid.RowDefinitions>

                    <TextBlock Grid.Row="0" Grid.Column="0" Text="APEP" Style="{StaticResource PathLabel}"/>
                    <TextBox x:Name="ApepPathBox" Grid.Row="0" Grid.Column="1" Style="{StaticResource PathBox}" Margin="0,0,10,0" Text=""/>
                    <Button x:Name="BrowseApepButton" Grid.Row="0" Grid.Column="2" Content="Browse" Style="{StaticResource SecondaryButton}"/>
                    <TextBlock x:Name="ApepGlyph" Grid.Row="0" Grid.Column="3" Style="{StaticResource GlyphText}" Text="?"/>

                    <TextBlock Grid.Row="2" Grid.Column="0" Text="WOW" Style="{StaticResource PathLabel}"/>
                    <TextBox x:Name="WowPathBox" Grid.Row="2" Grid.Column="1" Style="{StaticResource PathBox}" Margin="0,0,10,0" Text=""/>
                    <Button x:Name="BrowseWowButton" Grid.Row="2" Grid.Column="2" Content="Browse" Style="{StaticResource SecondaryButton}"/>
                    <TextBlock x:Name="WowGlyph" Grid.Row="2" Grid.Column="3" Style="{StaticResource GlyphText}" Text="?"/>
                </Grid>
            </Border>

            <Button x:Name="InstallButton" Grid.Row="2" Content="Install" Style="{StaticResource AccentButton}"
                    HorizontalAlignment="Right" Margin="0,18,0,0" MinWidth="180"/>

            <ProgressBar x:Name="InstallProgress" Grid.Row="3" Style="{StaticResource AccentProgressBar}"
                         Minimum="0" Maximum="100" Value="0" Margin="0,14,0,0"/>

            <Border Grid.Row="4" Background="{StaticResource BrushInput}" BorderBrush="{StaticResource BrushBorder}"
                    BorderThickness="1" CornerRadius="3" Padding="10" Margin="0,14,0,0">
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <TextBox x:Name="LogBox" Style="{StaticResource LogBoxStyle}"/>
                </ScrollViewer>
            </Border>
        </Grid>
    </Grid>
</Window>
'@
}

# GUI helper functions live at SCRIPT scope (not nested in Start-ZRotInstaller):
# WPF event-handler script blocks run in a scope that cannot resolve nested
# functions, so under `irm | iex` a Browse/Install click would fail with
# "term is not recognized". They read the WPF controls through $script:z*
# references that Start-ZRotInstaller populates before showing the window.
function Write-ZRotLog {
    param([string]$Message)
    $stamp = Get-Date -Format 'HH:mm:ss'
    $script:zLogBox.AppendText("[$stamp] $Message`r`n")
    $script:zLogBox.ScrollToEnd()
}

function Set-ZRotStep {
    param([string]$Stage)
    if ($Stage -eq 'install' -or $Stage -eq 'done') {
        $script:zStepDotInstall.Fill = $script:zAccentBrush
        $script:zStepLabelInstall.Foreground = $script:zAccentBrush
    }
    if ($Stage -eq 'done') {
        $script:zStepDotDone.Fill = $script:zAccentBrush
        $script:zStepLabelDone.Foreground = $script:zAccentBrush
    }
}

function Update-ApepStatus {
    param([string]$Path)
    $script:zApepPathBox.Text = $Path
    if (Test-ApepDir $Path) {
        $script:zApepGlyph.Text = $script:zCheckGlyph
        $script:zApepGlyph.Foreground = $script:zSuccessBrush
        return $true
    } else {
        $script:zApepGlyph.Text = $script:zCrossGlyph
        $script:zApepGlyph.Foreground = $script:zErrorBrush
        return $false
    }
}

function Update-WowStatus {
    param([string]$Path)
    $script:zWowPathBox.Text = $Path
    if (Test-WowDir $Path) {
        $script:zWowGlyph.Text = $script:zCheckGlyph
        $script:zWowGlyph.Foreground = $script:zSuccessBrush
        return $true
    } else {
        $script:zWowGlyph.Text = $script:zCrossGlyph
        $script:zWowGlyph.Foreground = $script:zErrorBrush
        return $false
    }
}

function Update-InstallEnabled {
    $apepValid = Test-ApepDir $script:ZRotApepDir
    $wowValid = Test-WowDir $script:ZRotWowDir
    $script:zInstallButton.IsEnabled = ($apepValid -and $wowValid)
}

function Start-ZRotInstaller {
    Add-Type -AssemblyName PresentationFramework
    Add-Type -AssemblyName PresentationCore
    Add-Type -AssemblyName WindowsBase
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Xml

    $xamlText = Get-ZRotInstallerXaml
    $stringReader = New-Object System.IO.StringReader($xamlText)
    $xmlReader = [System.Xml.XmlReader]::Create($stringReader)
    $window = [Windows.Markup.XamlReader]::Load($xmlReader)

    $logoImage      = $window.FindName('LogoImage')
    $apepPathBox    = $window.FindName('ApepPathBox')
    $wowPathBox     = $window.FindName('WowPathBox')
    $apepGlyph      = $window.FindName('ApepGlyph')
    $wowGlyph       = $window.FindName('WowGlyph')
    $browseApepBtn  = $window.FindName('BrowseApepButton')
    $browseWowBtn   = $window.FindName('BrowseWowButton')
    $installButton  = $window.FindName('InstallButton')
    $installProgress = $window.FindName('InstallProgress')
    $logBox         = $window.FindName('LogBox')
    $versionText    = $window.FindName('VersionText')
    $stepDotInstall = $window.FindName('StepDotInstall')
    $stepLabelInstall = $window.FindName('StepLabelInstall')
    $stepDotDone    = $window.FindName('StepDotDone')
    $stepLabelDone  = $window.FindName('StepLabelDone')

    $versionText.Text = "v$ZRotInstaller_Version"

    if ($script:ZRotLogoBase64) {
        try {
            $logoBytes = [Convert]::FromBase64String($script:ZRotLogoBase64)
            $logoStream = New-Object System.IO.MemoryStream(,$logoBytes)
            $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
            $bitmap.BeginInit()
            $bitmap.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
            $bitmap.StreamSource = $logoStream
            $bitmap.EndInit()
            $bitmap.Freeze()
            $logoImage.Source = $bitmap
        } catch {
            # Non-fatal: proceed without the logo image.
        }
    }

    $accentBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xB7,0x08,0x32))
    $successBrush = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0x4D,0xC7,0x78))
    $errorBrush  = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(0xED,0x40,0x52))
    $checkGlyph  = [string][char]0x2713
    $crossGlyph  = [string][char]0x2717

    # Share the controls/brushes the top-level GUI helpers use into $script:
    # scope so event-handler closures can drive them (see the helper functions
    # defined above Start-ZRotInstaller).
    $script:zLogBox = $logBox
    $script:zApepPathBox = $apepPathBox
    $script:zWowPathBox = $wowPathBox
    $script:zApepGlyph = $apepGlyph
    $script:zWowGlyph = $wowGlyph
    $script:zInstallButton = $installButton
    $script:zStepDotInstall = $stepDotInstall
    $script:zStepLabelInstall = $stepLabelInstall
    $script:zStepDotDone = $stepDotDone
    $script:zStepLabelDone = $stepLabelDone
    $script:zAccentBrush = $accentBrush
    $script:zSuccessBrush = $successBrush
    $script:zErrorBrush = $errorBrush
    $script:zCheckGlyph = $checkGlyph
    $script:zCrossGlyph = $crossGlyph

    # --- Initial detection ---
    $script:ZRotApepDir = Find-ApepDir
    $script:ZRotWowDir = $null

    $savedCfg = Read-ZRotInstallerConfig
    if (-not $script:ZRotApepDir -and $savedCfg -and $savedCfg.ApepDir) {
        if (Test-ApepDir $savedCfg.ApepDir) { $script:ZRotApepDir = $savedCfg.ApepDir }
    }
    if (-not $script:ZRotApepDir) { $script:ZRotApepDir = '' }

    $apepOk = Update-ApepStatus $script:ZRotApepDir

    if ($apepOk) {
        $jsonPath = Join-Path $script:ZRotApepDir 'Apep.json'
        if (Test-Path -LiteralPath $jsonPath) {
            try {
                $jsonText = Get-Content -Raw -LiteralPath $jsonPath
                $derivedWow = Get-WowDirFromApepJson $jsonText
                if ($derivedWow -and (Test-WowDir $derivedWow)) { $script:ZRotWowDir = $derivedWow }
            } catch {
                # Non-fatal: fall through to manual Browse.
            }
        }
    }
    if (-not $script:ZRotWowDir -and $savedCfg -and $savedCfg.WowDir) {
        if (Test-WowDir $savedCfg.WowDir) { $script:ZRotWowDir = $savedCfg.WowDir }
    }
    if (-not $script:ZRotWowDir) { $script:ZRotWowDir = '' }

    $wowOk = Update-WowStatus $script:ZRotWowDir

    Update-InstallEnabled

    if ($apepOk) { Write-ZRotLog "Apep folder detected: $script:ZRotApepDir" }
    else { Write-ZRotLog 'Apep folder not found automatically. Use Browse to select it.' }
    if ($wowOk) { Write-ZRotLog "WoW folder detected: $script:ZRotWowDir" }
    else { Write-ZRotLog 'WoW folder not found automatically. Use Browse to select it.' }

    Save-ZRotInstallerConfig $script:ZRotApepDir $script:ZRotWowDir

    # --- Browse handlers ---
    $browseApepBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select your Apep folder'
        if ($script:ZRotApepDir) { $dlg.SelectedPath = $script:ZRotApepDir }
        $result = $dlg.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:ZRotApepDir = $dlg.SelectedPath
            $apepOk2 = Update-ApepStatus $script:ZRotApepDir
            Update-InstallEnabled
            if ($apepOk2) { Write-ZRotLog "Apep folder set: $script:ZRotApepDir" }
            else { Write-ZRotLog "Selected folder does not look like an Apep install: $script:ZRotApepDir" }
            Save-ZRotInstallerConfig $script:ZRotApepDir $script:ZRotWowDir
        }
    }.GetNewClosure())

    $browseWowBtn.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = 'Select your World of Warcraft folder'
        if ($script:ZRotWowDir) { $dlg.SelectedPath = $script:ZRotWowDir }
        $result = $dlg.ShowDialog()
        if ($result -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:ZRotWowDir = $dlg.SelectedPath
            $wowOk2 = Update-WowStatus $script:ZRotWowDir
            Update-InstallEnabled
            if ($wowOk2) { Write-ZRotLog "WoW folder set: $script:ZRotWowDir" }
            else { Write-ZRotLog "Selected folder does not look like a WoW install: $script:ZRotWowDir" }
            Save-ZRotInstallerConfig $script:ZRotApepDir $script:ZRotWowDir
        }
    }.GetNewClosure())

    # --- Install / Update handler ---
    $installButton.Add_Click({
        $installButton.IsEnabled = $false
        try {
            if (-not (Test-ApepDir $script:ZRotApepDir)) {
                Write-ZRotLog 'Cannot install: Apep folder is not valid.'
                return
            }
            if (-not (Test-WowDir $script:ZRotWowDir)) {
                Write-ZRotLog 'Cannot install: WoW folder is not valid.'
                return
            }

            Set-ZRotStep 'install'
            $installProgress.Value = 0
            Write-ZRotLog 'Fetching manifest...'

            $manifestUrl = Get-ZRotRemoteUrl 'manifest.txt'
            $manifestText = $null
            $oldProgressPref = $ProgressPreference
            try {
                $ProgressPreference = 'SilentlyContinue'
                $manifestText = (Invoke-WebRequest -Uri $manifestUrl -UseBasicParsing).Content
            } catch {
                Write-ZRotLog "Failed to download manifest: $($_.Exception.Message)"
                return
            } finally {
                $ProgressPreference = $oldProgressPref
            }

            $remote = ConvertFrom-ZRotManifest $manifestText
            $localHashes = @{}
            foreach ($rel in $remote.Keys) {
                $dest = Get-ZRotDestination $rel $script:ZRotApepDir $script:ZRotWowDir
                $hash = Get-Sha1Short $dest
                if ($hash) { $localHashes[$rel] = $hash }
            }
            $plan = Get-ZRotPlan $remote $localHashes
            $relList = @($plan.Install) + @($plan.Update)

            if ($relList.Count -eq 0) {
                Write-ZRotLog 'Already up to date.'
                Set-ZRotStep 'done'
                $installProgress.Value = 100
                return
            }

            $installProgress.Maximum = $relList.Count
            Write-ZRotLog "Installing $($relList.Count) file(s)..."

            $progressHandler = {
                param($i, $t, $rel, $ok)
                $installProgress.Value = $i
                if ($ok) { Write-ZRotLog "  OK   $rel" }
                else { Write-ZRotLog "  FAIL $rel" }
                [System.Windows.Forms.Application]::DoEvents()
            }.GetNewClosure()

            $result = Invoke-ZRotApply $remote $relList $script:ZRotApepDir $script:ZRotWowDir $progressHandler

            Write-ZRotLog "Done. $($result.Ok) succeeded, $($result.Failed.Count) failed."
            if ($result.Failed.Count -gt 0) {
                foreach ($f in $result.Failed) { Write-ZRotLog "  Failed: $f" }
            }

            Update-ApepStatus $script:ZRotApepDir | Out-Null
            Update-WowStatus $script:ZRotWowDir | Out-Null
            Update-InstallEnabled
            Save-ZRotInstallerConfig $script:ZRotApepDir $script:ZRotWowDir
            Set-ZRotStep 'done'
        } finally {
            Update-InstallEnabled
        }
    }.GetNewClosure())

    $window.ShowDialog() | Out-Null
}


# Execution guard: do nothing when dot-sourced (tests) or when ZROT_TEST is set.
if ($MyInvocation.InvocationName -ne '.' -and -not $env:ZROT_TEST) {
    Start-ZRotInstaller
}
