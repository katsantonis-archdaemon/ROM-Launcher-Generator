Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.Windows.Forms

# Vista-style folder picker via IFileOpenDialog (WinForms' FolderBrowserDialog looks dated on some .NET versions)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

namespace RomLauncherUi
{
    [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogRCW { }

    [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOpenDialog
    {
        [PreserveSig] int Show(IntPtr parent);
        void SetFileTypes(uint cFileTypes, IntPtr rgFilterSpec);
        void SetFileTypeIndex(uint iFileType);
        void GetFileTypeIndex(out uint piFileType);
        void Advise(IntPtr pfde, out uint pdwCookie);
        void Unadvise(uint dwCookie);
        void SetOptions(uint fos);
        void GetOptions(out uint pfos);
        void SetDefaultFolder(IShellItem psi);
        void SetFolder(IShellItem psi);
        void GetFolder(out IShellItem ppsi);
        void GetCurrentSelection(out IShellItem ppsi);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string pszName);
        void GetFileName([MarshalAs(UnmanagedType.LPWStr)] out string pszName);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string pszTitle);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string pszText);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string pszLabel);
        void GetResult(out IShellItem ppsi);
        void AddPlace(IShellItem psi, uint fdap);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string pszDefaultExtension);
        void Close(int hr);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter([MarshalAs(UnmanagedType.IUnknown)] object pFilter);
        void GetResults([MarshalAs(UnmanagedType.IUnknown)] out object ppenum);
        void GetSelectedItems([MarshalAs(UnmanagedType.IUnknown)] out object ppsai);
    }

    [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem
    {
        void BindToHandler(IntPtr pbc, ref Guid bhid, ref Guid riid, out IntPtr ppv);
        void GetParent(out IShellItem ppsi);
        void GetDisplayName(uint sigdnName, out IntPtr ppszName);
        void GetAttributes(uint sfgaoMask, out uint psfgaoAttribs);
        void Compare(IShellItem psi, uint hint, out int piOrder);
    }

    public static class ModernFolderPicker
    {
        private const uint FOS_PICKFOLDERS = 0x00000020;
        private const uint FOS_FORCEFILESYSTEM = 0x00000040;
        private const uint SIGDN_FILESYSPATH = 0x80058000;

        public static string ShowDialog(string title, string initialDirectory)
        {
            IFileOpenDialog dialog = (IFileOpenDialog)new FileOpenDialogRCW();
            try
            {
                dialog.SetOptions(FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM);
                if (!string.IsNullOrEmpty(title))
                {
                    dialog.SetTitle(title);
                }

                int hr = dialog.Show(IntPtr.Zero);
                if (hr != 0)
                {
                    return null; // user cancelled or dialog failed
                }

                IShellItem result;
                dialog.GetResult(out result);
                IntPtr pszPath;
                result.GetDisplayName(SIGDN_FILESYSPATH, out pszPath);
                string path = Marshal.PtrToStringUni(pszPath);
                Marshal.FreeCoTaskMem(pszPath);
                return path;
            }
            catch
            {
                return null;
            }
            finally
            {
                Marshal.ReleaseComObject(dialog);
            }
        }
    }
}
"@ -ErrorAction SilentlyContinue


# ROM Launcher Generator - scans a Roms folder, builds a .bat per game.

$KnownConsoles = @(
    "nes","snes","mastersystem","genesis","gb","gbc","gba","n64",
    "ps1","dreamcast","ps2","gamecube","xbox","wii","ds","psp",
    "3ds","psvita","switch"
)

$SkipExtensions = @(".bat",".txt",".ini",".cfg",".db",".jpg",".jpeg",".png",".url",".lnk")

# .cue/.gdi/.ccd/.m3u are the "primary" file for a multi-file dump; matching
# .bin/.iso/.img/.sub/.raw with the same base name are companions, not games.
$PrimaryDiscExtensions = @(".cue", ".gdi", ".ccd", ".m3u")
$CompanionDiscExtensions = @(".bin", ".iso", ".img", ".sub", ".raw")

$ConfigPath = Join-Path $PSScriptRoot "rom-launcher-config.json"

function Load-Config {
    if (Test-Path $ConfigPath) {
        try {
            $raw = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
            $map = @{}
            foreach ($prop in $raw.PSObject.Properties) {
                $map[$prop.Name] = $prop.Value
            }
            return $map
        } catch {
            return @{}
        }
    }
    return @{}
}

function Save-Config($map) {
    try {
        $map | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8
    } catch {
        # Non-fatal - config is a convenience, not required for the tool to work
    }
}

# Strips region/language/version tags: "Crash Bandicoot (USA) (Rev 1) [!]" -> "Crash Bandicoot"
function Get-CleanName([string]$name) {
    $clean = $name
    $clean = [regex]::Replace($clean, '\s*[\(\[][^\)\]]*[\)\]]\s*', ' ')
    $clean = $clean -replace '\s{2,}', ' '
    $clean = $clean.Trim(' ', '-')
    if ([string]::IsNullOrWhiteSpace($clean)) { return $name }
    return $clean
}

# Strips a trailing "Disc N" / "Disk N" so multi-disc games share one group key.
function Get-DiscGroupKey([string]$cleanName) {
    $key = [regex]::Replace($cleanName, '\s*-?\s*Dis[ck]\s*\d+\s*$', '', 'IgnoreCase')
    return $key.Trim(' ', '-')
}

# Extracts the disc/disk number from a name for ordering, or 1 if none found.
function Get-DiscNumber([string]$name) {
    $m = [regex]::Match($name, 'Dis[ck]\s*(\d+)', 'IgnoreCase')
    if ($m.Success) { return [int]$m.Groups[1].Value }
    return 1
}

# Organizes a PS1 folder: any game with 2+ discs gets its files moved into
# a "multi" subfolder and gets an .m3u playlist written next to it. Games that
# already have a matching .m3u are left untouched (safe to re-run on Scan).
#
# The .m3u must list exactly one file per disc: the .cue if that disc has one
# (the .cue is what actually tells the emulator which .bin belongs to it - the
# .bin itself is never a valid entry), otherwise the disc's own image file
# (.chd/.iso/etc, which is self-contained and needs no .cue).
#
# Returns a list of objects for each newly-organized game: { GameName, M3uPath, MultiDir, ExpectedFiles }
function Invoke-Ps1MultiDiscOrganize([string]$ps1FolderPath, [string[]]$skipExtensions) {
    $results = New-Object System.Collections.Generic.List[object]
    $binLikeExtensions = @(".bin", ".sub", ".raw", ".img")  # never valid as their own m3u entry

    $files = Get-ChildItem -Path $ps1FolderPath -File -ErrorAction SilentlyContinue |
             Where-Object { $skipExtensions -notcontains $_.Extension.ToLower() }

    if ($files.Count -eq 0) { return $results }

    $groups = @{}
    foreach ($f in $files) {
        $cleanName = Get-CleanName $f.BaseName
        $groupKey = Get-DiscGroupKey $cleanName
        if (-not $groups.ContainsKey($groupKey)) { $groups[$groupKey] = New-Object System.Collections.Generic.List[object] }
        $groups[$groupKey].Add($f)
    }

    $multiDir = Join-Path $ps1FolderPath "multi"

    foreach ($groupKey in $groups.Keys) {
        $discFiles = $groups[$groupKey]
        if ($discFiles.Count -lt 2) { continue }  # single-file game, leave as-is

        $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
        $safeGroupKey = -join ($groupKey.ToCharArray() | ForEach-Object { if ($invalidChars -contains $_) { '_' } else { $_ } })
        $safeGroupKey = $safeGroupKey.Trim()

        $m3uPath = Join-Path $ps1FolderPath "$safeGroupKey.m3u"
        if (Test-Path $m3uPath) { continue }  # already organized, don't touch

        if (-not (Test-Path $multiDir)) {
            New-Item -ItemType Directory -Path $multiDir -Force | Out-Null
        }

        # Group this game's files by disc number, so multi-track discs (one .cue + several .bin)
        # still produce exactly one m3u line for that disc.
        $discNumberGroups = @{}
        foreach ($f in $discFiles) {
            $discNum = Get-DiscNumber $f.BaseName
            if (-not $discNumberGroups.ContainsKey($discNum)) {
                $discNumberGroups[$discNum] = New-Object System.Collections.Generic.List[object]
            }
            $discNumberGroups[$discNum].Add($f)
        }

        $m3uLines = New-Object System.Collections.Generic.List[string]
        $expectedFiles = New-Object System.Collections.Generic.List[string]

        foreach ($discNum in ($discNumberGroups.Keys | Sort-Object)) {
            $discGroup = $discNumberGroups[$discNum]

            # Move every file for this disc into multi/ first (the .cue needs its .bin alongside it)
            foreach ($f in $discGroup) {
                $destPath = Join-Path $multiDir $f.Name
                try {
                    Move-Item -Path $f.FullName -Destination $destPath -Force -ErrorAction Stop
                    $expectedFiles.Add($destPath)
                } catch {
                    Debug-Log "  Failed to move $($f.Name) into multi/: $($_.Exception.Message)"
                }
            }

            # Pick the one file that represents this disc in the m3u: prefer .cue,
            # otherwise the first file that isn't a raw .bin-like companion.
            $cueFile = $discGroup | Where-Object { $_.Extension.ToLower() -eq ".cue" } | Select-Object -First 1
            $launchFile = if ($cueFile) {
                $cueFile
            } else {
                $discGroup | Where-Object { $binLikeExtensions -notcontains $_.Extension.ToLower() } | Select-Object -First 1
            }

            if ($launchFile) {
                $m3uLines.Add("multi/$($launchFile.Name)")
            } else {
                Debug-Log "  '$groupKey' disc $discNum has no .cue or standalone image - skipped in m3u"
            }
        }

        if ($m3uLines.Count -gt 0) {
            Set-Content -Path $m3uPath -Value $m3uLines -Encoding UTF8
            Debug-Log "  Organized '$groupKey': $($m3uLines.Count) disc(s) -> multi/, wrote $safeGroupKey.m3u"
            $results.Add([PSCustomObject]@{
                GameName      = $groupKey
                M3uPath       = $m3uPath
                MultiDir      = $multiDir
                M3uLines      = $m3uLines
                ExpectedFiles = $expectedFiles
            })
        }
    }

    return $results
}

# ---------- SteamGridDB ----------

function Get-SgdbGameId([string]$apiKey, [string]$gameName) {
    try {
        $encoded = [uri]::EscapeDataString($gameName)
        $headers = @{ "Authorization" = "Bearer $apiKey" }
        $resp = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/search/autocomplete/$encoded" -Headers $headers -Method Get -ErrorAction Stop
        if ($resp.success -and $resp.data.Count -gt 0) {
            Debug-Log "    SGDB match: '$gameName' -> id $($resp.data[0].id)"
            return $resp.data[0].id
        }
        Debug-Log "    SGDB: no match for '$gameName'"
    } catch {
        Debug-Log "    SGDB search failed for '$gameName': $($_.Exception.Message)"
        return $null
    }
    return $null
}

# Downloads the first result for one asset type to destPath. Returns whether it saved.
# Downloads the first result for one asset type to destPath. Returns its candidate id, or $null.
function Save-SgdbAsset([string]$apiKey, [int]$gameId, [string]$assetType, [string]$destPath) {
    try {
        $headers = @{ "Authorization" = "Bearer $apiKey" }
        $resp = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/$assetType/game/$gameId" -Headers $headers -Method Get -ErrorAction Stop
        if ($resp.success -and $resp.data.Count -gt 0) {
            $url = $resp.data[0].url
            Invoke-WebRequest -Uri $url -OutFile $destPath -ErrorAction Stop
            return $resp.data[0].id
        }
    } catch {
        Debug-Log "    SGDB $assetType download failed (id $gameId): $($_.Exception.Message)"
        return $null
    }
    return $null
}

# Returns up to $max candidate asset objects (each has .url, .thumb) for the picker.
function Get-SgdbAssetCandidates([string]$apiKey, [int]$gameId, [string]$assetType, [int]$max = 12) {
    try {
        $headers = @{ "Authorization" = "Bearer $apiKey" }
        $resp = Invoke-RestMethod -Uri "https://www.steamgriddb.com/api/v2/$assetType/game/$gameId" -Headers $headers -Method Get -ErrorAction Stop
        if ($resp.success -and $resp.data.Count -gt 0) {
            return $resp.data | Select-Object -First $max
        }
    } catch {
        Debug-Log "    SGDB $assetType candidate fetch failed (id $gameId): $($_.Exception.Message)"
    }
    return @()
}

# Fetches grid/hero/logo/icon into <ArtRoot>\<GameName>\. Misses are skipped silently.
# Returns $null if no SGDB match, otherwise an object with GameId/GameName/DestDir/Assets.
function Get-GameArtwork([string]$apiKey, [string]$gameName, [string]$artRoot) {
    $gameId = Get-SgdbGameId -apiKey $apiKey -gameName $gameName
    if (-not $gameId) { return $null }

    # titles can contain ":" etc. (e.g. "Sonic Colors: Ultimate") - not valid in a folder name
    $invalidChars = [System.IO.Path]::GetInvalidFileNameChars()
    $safeName = -join ($gameName.ToCharArray() | ForEach-Object { if ($invalidChars -contains $_) { '_' } else { $_ } })
    $safeName = $safeName.Trim()

    $destDir = Join-Path $artRoot $safeName
    if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $assetMap = @{
        "grids"  = "grid.png"
        "heroes" = "hero.png"
        "logos"  = "logo.png"
        "icons"  = "icon.png"
    }

    $any = $false
    $selectedIds = @{}
    foreach ($assetType in $assetMap.Keys) {
        $destPath = Join-Path $destDir $assetMap[$assetType]
        if (Test-Path $destPath) { $any = $true; continue }  # already have it - id unknown, no highlight
        $chosenId = Save-SgdbAsset -apiKey $apiKey -gameId $gameId -assetType $assetType -destPath $destPath
        if ($chosenId) {
            $any = $true
            $selectedIds[$assetType] = $chosenId
        }
    }

    if (-not $any) { return $null }

    return [PSCustomObject]@{
        GameId      = $gameId
        GameName    = $gameName
        DestDir     = $destDir
        Assets      = $assetMap
        SelectedIds = $selectedIds
    }
}

# ---------- Preview / verification ----------

# Verifies this session's launchers and m3u files are actually correct on disk right now.
# Returns a list of problem objects: { Kind, GameName, Path, Reason }. Empty list = all good.
function Test-SessionOutputs {
    $problems = New-Object System.Collections.Generic.List[object]

    foreach ($launcher in $Global:SessionLaunchers) {
        if (-not (Test-Path $launcher.BatPath)) {
            $problems.Add([PSCustomObject]@{ Kind = "Launcher"; GameName = $launcher.GameName; Path = $launcher.BatPath; Reason = "File is missing" })
            continue
        }

        if (-not (Test-Path $launcher.ExpectedEmu)) {
            $problems.Add([PSCustomObject]@{ Kind = "Launcher"; GameName = $launcher.GameName; Path = $launcher.BatPath; Reason = "Emulator path no longer exists: $($launcher.ExpectedEmu)" })
        }
        if (-not (Test-Path $launcher.ExpectedRom)) {
            $problems.Add([PSCustomObject]@{ Kind = "Launcher"; GameName = $launcher.GameName; Path = $launcher.BatPath; Reason = "ROM/playlist path no longer exists: $($launcher.ExpectedRom)" })
        }

        # Cross-check the .bat's actual written content, not just our in-memory record -
        # catches manual edits or a write that silently didn't take.
        try {
            $content = Get-Content -Path $launcher.BatPath -Raw -ErrorAction Stop
            if ($content -notmatch [regex]::Escape($launcher.ExpectedEmu)) {
                $problems.Add([PSCustomObject]@{ Kind = "Launcher"; GameName = $launcher.GameName; Path = $launcher.BatPath; Reason = "File content doesn't reference the expected emulator path" })
            }
            if ($content -notmatch [regex]::Escape($launcher.ExpectedRom)) {
                $problems.Add([PSCustomObject]@{ Kind = "Launcher"; GameName = $launcher.GameName; Path = $launcher.BatPath; Reason = "File content doesn't reference the expected ROM/playlist path" })
            }
        } catch {
            $problems.Add([PSCustomObject]@{ Kind = "Launcher"; GameName = $launcher.GameName; Path = $launcher.BatPath; Reason = "Could not read file: $($_.Exception.Message)" })
        }
    }

    foreach ($m3u in $Global:SessionM3u) {
        if (-not (Test-Path $m3u.M3uPath)) {
            $problems.Add([PSCustomObject]@{ Kind = "M3U"; GameName = $m3u.GameName; Path = $m3u.M3uPath; Reason = "File is missing" })
            continue
        }
        if (-not (Test-Path $m3u.MultiDir)) {
            $problems.Add([PSCustomObject]@{ Kind = "M3U"; GameName = $m3u.GameName; Path = $m3u.M3uPath; Reason = "multi/ folder is missing" })
        }

        $lines = Get-Content -Path $m3u.M3uPath -ErrorAction SilentlyContinue
        if (-not $lines -or $lines.Count -eq 0) {
            $problems.Add([PSCustomObject]@{ Kind = "M3U"; GameName = $m3u.GameName; Path = $m3u.M3uPath; Reason = "Playlist is empty" })
            continue
        }

        $ps1FolderPath = Split-Path $m3u.M3uPath -Parent
        foreach ($line in $lines) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            $resolvedPath = Join-Path $ps1FolderPath $line
            if (-not (Test-Path $resolvedPath)) {
                $problems.Add([PSCustomObject]@{ Kind = "M3U"; GameName = $m3u.GameName; Path = $m3u.M3uPath; Reason = "Listed disc file not found: $line" })
            }
        }
    }

    return $problems
}

# ---------- XAML UI definition ----------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="ROM Launcher Generator" Height="820" Width="880" MinHeight="600" MinWidth="700"
        WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI">
    <Window.Background>
        <LinearGradientBrush StartPoint="0,0" EndPoint="1,1">
            <GradientStop Color="#1A1D24" Offset="0"/>
            <GradientStop Color="#121419" Offset="1"/>
        </LinearGradientBrush>
    </Window.Background>
    <Window.Resources>

        <SolidColorBrush x:Key="Surface" Color="#16181D"/>
        <SolidColorBrush x:Key="SurfaceRaised" Color="#22262F"/>
        <SolidColorBrush x:Key="FieldBg" Color="#282C36"/>
        <SolidColorBrush x:Key="FieldBorder" Color="#3A3F4C"/>
        <SolidColorBrush x:Key="FieldBorderFocus" Color="#5B8DEF"/>
        <SolidColorBrush x:Key="TextPrimary" Color="#F1F3F6"/>
        <SolidColorBrush x:Key="TextMuted" Color="#9199A8"/>
        <SolidColorBrush x:Key="TextFaint" Color="#5C6270"/>
        <SolidColorBrush x:Key="Accent" Color="#5B8DEF"/>
        <SolidColorBrush x:Key="AccentHover" Color="#6F9CF2"/>
        <SolidColorBrush x:Key="AccentPressed" Color="#4A76D1"/>
        <SolidColorBrush x:Key="AccentDim" Color="#2A3B5C"/>
        <SolidColorBrush x:Key="Success" Color="#7FB069"/>
        <SolidColorBrush x:Key="Warn" Color="#D8A657"/>
        <SolidColorBrush x:Key="Danger" Color="#D9736A"/>


        <!-- Primary (filled) button - used once, for the main action -->
        <Style x:Key="PrimaryButton" TargetType="Button">
            <Setter Property="Background" Value="{StaticResource Accent}"/>
            <Setter Property="Foreground" Value="White"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="18,9"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bg" Background="{TemplateBinding Background}" CornerRadius="6">
                            <Border.Effect>
                                <DropShadowEffect Color="#5B8DEF" Opacity="0.25" BlurRadius="8" ShadowDepth="0"/>
                            </Border.Effect>
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                               Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bg" Property="Background" Value="{StaticResource AccentHover}"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter TargetName="Bg" Property="Background" Value="{StaticResource AccentPressed}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- Secondary (outline) button - Browse, Scan, and other supporting actions -->
        <Style x:Key="SecondaryButton" TargetType="Button">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Padding" Value="14,7"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="{StaticResource FieldBorder}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bg" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="6">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"
                                              Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Bg" Property="Background" Value="{StaticResource SurfaceRaised}"/>
                                <Setter TargetName="Bg" Property="BorderBrush" Value="{StaticResource TextMuted}"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="{StaticResource TextFaint}"/>
                                <Setter TargetName="Bg" Property="BorderBrush" Value="{StaticResource FieldBorder}"/>
                                <Setter Property="Cursor" Value="Arrow"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{StaticResource FieldBg}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="CaretBrush" Value="{StaticResource TextPrimary}"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="{StaticResource FieldBorder}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Bg" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="Bg" Property="BorderBrush" Value="{StaticResource FieldBorderFocus}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{StaticResource FieldBg}"/>
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="CaretBrush" Value="{StaticResource TextPrimary}"/>
            <Setter Property="Padding" Value="10,7"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="BorderBrush" Value="{StaticResource FieldBorder}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border x:Name="Bg" Background="{TemplateBinding Background}"
                                BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsFocused" Value="True">
                                <Setter TargetName="Bg" Property="BorderBrush" Value="{StaticResource FieldBorderFocus}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <Style TargetType="Label">
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="Padding" Value="0"/>
        </Style>
        <Style TargetType="TextBlock">
            <Setter Property="Foreground" Value="{StaticResource TextPrimary}"/>
            <Setter Property="FontSize" Value="13"/>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{StaticResource TextMuted}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="CheckBox">
                        <StackPanel Orientation="Horizontal">
                            <Border x:Name="Box" Width="16" Height="16" CornerRadius="4"
                                    Background="{StaticResource FieldBg}"
                                    BorderBrush="{StaticResource FieldBorder}" BorderThickness="1"
                                    VerticalAlignment="Center">
                                <Path x:Name="Check" Data="M 3,8 L 6.5,11.5 L 13,4"
                                      Stroke="White" StrokeThickness="2"
                                      StrokeStartLineCap="Round" StrokeEndLineCap="Round"
                                      StrokeLineJoin="Round" Visibility="Collapsed"/>
                            </Border>
                            <ContentPresenter Margin="8,0,0,0" VerticalAlignment="Center"/>
                        </StackPanel>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True">
                                <Setter TargetName="Box" Property="Background" Value="{StaticResource Accent}"/>
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource Accent}"/>
                                <Setter TargetName="Check" Property="Visibility" Value="Visible"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter TargetName="Box" Property="BorderBrush" Value="{StaticResource TextMuted}"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Minimal scrollbar: thin rounded thumb only, no arrows, no visible track -->
        <Style x:Key="ThumbStyle" TargetType="Thumb">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Thumb">
                        <Border Background="{StaticResource FieldBorder}" CornerRadius="4" Margin="2,0"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="10"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Grid Background="Transparent">
                            <Track Name="PART_Track" IsDirectionReversed="True">
                                <Track.Thumb>
                                    <Thumb Style="{StaticResource ThumbStyle}"/>
                                </Track.Thumb>
                                <Track.IncreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageDownCommand" Opacity="0" Focusable="False"/>
                                </Track.IncreaseRepeatButton>
                                <Track.DecreaseRepeatButton>
                                    <RepeatButton Command="ScrollBar.PageUpCommand" Opacity="0" Focusable="False"/>
                                </Track.DecreaseRepeatButton>
                            </Track>
                        </Grid>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>

    <Grid Margin="28,26,28,24">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="28"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="16"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="14"/>
            <RowDefinition Height="140"/>
        </Grid.RowDefinitions>

        <!-- Header -->
        <StackPanel Grid.Row="0" Orientation="Horizontal">
            <Border Width="4" Height="46" CornerRadius="2" Margin="0,0,12,0">
                <Border.Background>
                    <LinearGradientBrush StartPoint="0,0" EndPoint="0,1">
                        <GradientStop Color="#6F9CF2" Offset="0"/>
                        <GradientStop Color="#4A76D1" Offset="1"/>
                    </LinearGradientBrush>
                </Border.Background>
            </Border>
            <StackPanel>
                <TextBlock Text="ROM Launcher Generator" FontSize="22" FontWeight="SemiBold"/>
                <TextBlock Text="Turn a Roms folder into ready-to-use launchers, sorted by console."
                           Foreground="{StaticResource TextMuted}" FontSize="13" Margin="0,4,0,0"/>
            </StackPanel>
        </StackPanel>

        <!-- Roms folder -->
        <Grid Grid.Row="2" Margin="0,0,0,10">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="130"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Label Grid.Column="0" Content="Roms folder" VerticalAlignment="Center"/>
            <TextBox Grid.Column="1" Name="RootBox" VerticalAlignment="Center"/>
            <Button Grid.Column="3" Name="BrowseRootBtn" Content="Browse" Style="{StaticResource SecondaryButton}"/>
        </Grid>

        <!-- Output folder -->
        <Grid Grid.Row="3" Margin="0,0,0,14">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="130"/>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Label Grid.Column="0" Content="Output folder" VerticalAlignment="Center"/>
            <TextBox Grid.Column="1" Name="OutBox" VerticalAlignment="Center"/>
            <Button Grid.Column="3" Name="BrowseOutBtn" Content="Browse" Style="{StaticResource SecondaryButton}"/>
        </Grid>

        <!-- Options -->
        <Border Grid.Row="4" Background="{StaticResource SurfaceRaised}" CornerRadius="8"
                BorderBrush="{StaticResource FieldBorder}" BorderThickness="1" Padding="14,12">
            <StackPanel>
                <StackPanel Orientation="Horizontal">
                    <CheckBox Name="CleanNamesCheck" Content="Clean up launcher names" IsChecked="True" Margin="0,0,18,0"/>
                    <CheckBox Name="GroupDiscsCheck" Content="Group multi-disc games" IsChecked="True" Margin="0,0,18,0"/>
                    <CheckBox Name="SaveLogCheck" Content="Save log file" IsChecked="False"/>
                </StackPanel>

                <Grid Margin="0,12,0,0">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="130"/>
                        <ColumnDefinition Width="220"/>
                    </Grid.ColumnDefinitions>
                    <CheckBox Grid.Column="0" Name="FetchArtCheck" Content="Fetch artwork" IsChecked="False"
                              VerticalAlignment="Center"/>
                    <Grid Grid.Column="1">
                        <PasswordBox Name="SgdbKeyBox" VerticalAlignment="Center"
                                 ToolTip="Your SteamGridDB API key, from steamgriddb.com/profile/preferences/api"/>
                        <TextBlock Name="SgdbKeyPlaceholder" Text="SteamGridDB API key" Foreground="{StaticResource TextFaint}"
                                   VerticalAlignment="Center" Margin="11,0,0,0" IsHitTestVisible="False"/>
                    </Grid>
                </Grid>
            </StackPanel>
        </Border>

        <!-- Scan -->
        <Button Grid.Row="5" Name="ScanBtn" Content="Scan for consoles" HorizontalAlignment="Right"
                Style="{StaticResource SecondaryButton}" Margin="0,18,0,0"/>

        <!-- Console list -->
        <Border Grid.Row="6" Background="{StaticResource SurfaceRaised}" CornerRadius="8"
                BorderBrush="{StaticResource FieldBorder}" BorderThickness="1">
            <Grid>
                <TextBlock Name="EmptyStateText" Text="Scan a Roms folder to see detected consoles here."
                           Foreground="{StaticResource TextFaint}" HorizontalAlignment="Center"
                           VerticalAlignment="Center" FontSize="13"/>
                <ScrollViewer VerticalScrollBarVisibility="Auto">
                    <StackPanel Name="ConsoleList" Margin="4"/>
                </ScrollViewer>
            </Grid>
        </Border>

        <!-- Generate -->
        <Grid Grid.Row="8">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="*"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="Auto"/>
                <ColumnDefinition Width="10"/>
                <ColumnDefinition Width="Auto"/>
            </Grid.ColumnDefinitions>
            <Button Grid.Column="1" Name="PreviewBtn" Content="Preview"
                    Style="{StaticResource SecondaryButton}" Visibility="Collapsed"/>
            <Button Grid.Column="3" Name="ReviewArtBtn" Content="Review artwork"
                    Style="{StaticResource SecondaryButton}" Visibility="Collapsed"/>
            <Button Grid.Column="5" Name="GenerateBtn" Content="Generate launchers"
                    Style="{StaticResource PrimaryButton}"/>
        </Grid>

        <!-- Log -->
        <DockPanel Grid.Row="10">
            <TextBlock DockPanel.Dock="Top" Text="OUTPUT" Foreground="{StaticResource TextFaint}"
                       FontSize="10" FontWeight="SemiBold" Margin="2,0,0,4"/>
            <Border Background="#0D0F13" CornerRadius="6"
                    BorderBrush="{StaticResource FieldBorder}" BorderThickness="1">
                <ScrollViewer VerticalScrollBarVisibility="Auto" Margin="4">
                    <TextBox Name="LogBox" IsReadOnly="True" TextWrapping="Wrap" Background="Transparent"
                             Foreground="{StaticResource TextMuted}"
                             BorderThickness="0" FontFamily="Cascadia Mono, Consolas" FontSize="12" Padding="10,8"/>
                </ScrollViewer>
            </Border>
        </DockPanel>
    </Grid>
</Window>
"@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)

$RootBox        = $window.FindName("RootBox")
$OutBox         = $window.FindName("OutBox")
$BrowseRootBtn  = $window.FindName("BrowseRootBtn")
$BrowseOutBtn   = $window.FindName("BrowseOutBtn")
$ScanBtn        = $window.FindName("ScanBtn")
$ConsoleList    = $window.FindName("ConsoleList")
$GenerateBtn    = $window.FindName("GenerateBtn")
$ReviewArtBtn   = $window.FindName("ReviewArtBtn")
$PreviewBtn     = $window.FindName("PreviewBtn")
$LogBox         = $window.FindName("LogBox")
$CleanNamesCheck= $window.FindName("CleanNamesCheck")
$GroupDiscsCheck= $window.FindName("GroupDiscsCheck")
$FetchArtCheck  = $window.FindName("FetchArtCheck")
$SgdbKeyBox     = $window.FindName("SgdbKeyBox")
$SgdbKeyPlaceholder = $window.FindName("SgdbKeyPlaceholder")
$SaveLogCheck   = $window.FindName("SaveLogCheck")

function Update-SgdbPlaceholder {
    $SgdbKeyPlaceholder.Visibility = if ([string]::IsNullOrEmpty($SgdbKeyBox.Password)) { "Visible" } else { "Collapsed" }
}
$SgdbKeyBox.Add_PasswordChanged({ Update-SgdbPlaceholder })

$Global:LogLines = New-Object System.Collections.Generic.List[string]

function Log($msg) {
    $LogBox.AppendText("$msg`r`n")
    $LogBox.ScrollToEnd()
    $Global:LogLines.Add($msg)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg"
}

function Debug-Log($msg) {
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg" -ForegroundColor DarkGray
}

function Browse-Folder($textbox) {
    $selected = $null
    try {
        $selected = [RomLauncherUi.ModernFolderPicker]::ShowDialog("Select a folder", $null)
    } catch {
        $selected = $null
    }

    if ($selected) {
        $textbox.Text = $selected
    } elseif ($selected -eq $null -and -not ("RomLauncherUi.ModernFolderPicker" -as [type])) {
        # Modern picker type failed to load - fall back to the classic tree-view dialog
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        if ($dialog.ShowDialog() -eq "OK") {
            $textbox.Text = $dialog.SelectedPath
        }
    }
    # If $selected is $null but the type loaded fine, the user simply cancelled - do nothing.
}

function Browse-File($textbox) {
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Filter = "Executable files (*.exe)|*.exe|All files (*.*)|*.*"
    if ($dialog.ShowDialog() -eq "OK") {
        $textbox.Text = $dialog.FileName
    }
}

$BrowseRootBtn.Add_Click({ Browse-Folder $RootBox })
$BrowseOutBtn.Add_Click({ Browse-Folder $OutBox })

# Load remembered emulator paths (console name -> path) at startup.
# The reserved key "__sgdb_api_key" stores the SteamGridDB API key, if remembered.
$Global:EmuConfig = Load-Config
if ($Global:EmuConfig.ContainsKey("__sgdb_api_key")) {
    $SgdbKeyBox.Password = $Global:EmuConfig["__sgdb_api_key"]
}
Update-SgdbPlaceholder

# Holds one entry per detected console: Name, Path, EmuTextBox, IsKnown
$Global:ConsoleEntries = @()

$ScanBtn.Add_Click({
    $ConsoleList.Children.Clear()
    $Global:ConsoleEntries = @()
    $Global:SessionM3u = New-Object System.Collections.Generic.List[object]
    $LogBox.Clear()
    $Global:LogLines.Clear()
    Debug-Log "=== Scan started ==="

    $root = $RootBox.Text.Trim('"')
    Debug-Log "Roms folder: $root"
    if (-not (Test-Path $root)) {
        Log "[ERROR] Roms folder does not exist: $root"
        return
    }

    $subfolders = Get-ChildItem -Path $root -Directory
    Debug-Log "Found $($subfolders.Count) subfolder(s) under Roms folder"
    if ($subfolders.Count -eq 0) {
        Log "[INFO] No subfolders found in $root"
        return
    }

    foreach ($folder in $subfolders) {
        if ($folder.Name.ToLower() -eq "ps1") {
            $organizeResults = Invoke-Ps1MultiDiscOrganize -ps1FolderPath $folder.FullName -skipExtensions $SkipExtensions
            if ($organizeResults.Count -gt 0) {
                foreach ($r in $organizeResults) { $Global:SessionM3u.Add($r) }
                Log "[OK] ps1: organized $($organizeResults.Count) multi-disc game(s) into multi/ with .m3u playlists"
            }
        }

        $files = Get-ChildItem -Path $folder.FullName -File -ErrorAction SilentlyContinue
        $romFiles = $files | Where-Object { $SkipExtensions -notcontains $_.Extension.ToLower() }
        Debug-Log "  $($folder.Name): $($files.Count) file(s), $($romFiles.Count) counted as ROMs"

        if ($romFiles.Count -eq 0) { continue }

        $isKnown = $KnownConsoles -contains $folder.Name.ToLower()
        $bc = [System.Windows.Media.BrushConverter]::new()

        # --- Row card: a subtle rounded container per console ---
        $card = New-Object System.Windows.Controls.Border
        $card.Background = $bc.ConvertFromString("#282C36")
        $card.CornerRadius = New-Object System.Windows.CornerRadius(6)
        $card.Padding = "12,10"
        $card.Margin = "0,0,0,6"
        $card.BorderThickness = "1"
        if (-not $isKnown) {
            $card.BorderBrush = $bc.ConvertFromString("#E0B23C")
        } else {
            $card.BorderBrush = $bc.ConvertFromString("#343945")
        }

        $row = New-Object System.Windows.Controls.Grid
        $col0 = New-Object System.Windows.Controls.ColumnDefinition; $col0.Width = New-Object System.Windows.GridLength(170)
        $col1 = New-Object System.Windows.Controls.ColumnDefinition; $col1.Width = New-Object System.Windows.GridLength(1, [System.Windows.GridUnitType]::Star)
        $col2 = New-Object System.Windows.Controls.ColumnDefinition; $col2.Width = New-Object System.Windows.GridLength(10)
        $col3 = New-Object System.Windows.Controls.ColumnDefinition; $col3.Width = New-Object System.Windows.GridLength(0, [System.Windows.GridUnitType]::Auto)
        $row.ColumnDefinitions.Add($col0)
        $row.ColumnDefinitions.Add($col1)
        $row.ColumnDefinitions.Add($col2)
        $row.ColumnDefinitions.Add($col3)

        $labelStack = New-Object System.Windows.Controls.StackPanel
        $labelStack.VerticalAlignment = "Center"
        [System.Windows.Controls.Grid]::SetColumn($labelStack, 0)

        $label = New-Object System.Windows.Controls.TextBlock
        $label.Text = $folder.Name
        $label.FontWeight = "SemiBold"
        $label.Foreground = $bc.ConvertFromString("#EDEFF2")
        $label.ToolTip = $folder.FullName
        $labelStack.Children.Add($label) | Out-Null

        if (-not $isKnown) {
            $subLabel = New-Object System.Windows.Controls.TextBlock
            $subLabel.Text = "not in the known console list"
            $subLabel.FontSize = 11
            $subLabel.Foreground = $bc.ConvertFromString("#E0B23C")
            $subLabel.Margin = "0,2,0,0"
            $labelStack.Children.Add($subLabel) | Out-Null
        }

        $fieldWrap = New-Object System.Windows.Controls.Grid
        [System.Windows.Controls.Grid]::SetColumn($fieldWrap, 1)

        $emuBox = New-Object System.Windows.Controls.TextBox
        $emuBox.VerticalAlignment = "Center"
        # Auto-fill from remembered config, matched case-insensitively
        $rememberedKey = $Global:EmuConfig.Keys | Where-Object { $_ -ieq $folder.Name }
        if ($rememberedKey) {
            $emuBox.Text = $Global:EmuConfig[$rememberedKey]
        }

        $emuPlaceholder = New-Object System.Windows.Controls.TextBlock
        $emuPlaceholder.Text = "Emulator .exe path"
        $emuPlaceholder.Foreground = $bc.ConvertFromString("#5C6270")
        $emuPlaceholder.VerticalAlignment = "Center"
        $emuPlaceholder.Margin = "11,0,0,0"
        $emuPlaceholder.IsHitTestVisible = $false
        $emuPlaceholder.Visibility = if ($emuBox.Text) { "Collapsed" } else { "Visible" }
        $closureEmuBox = $emuBox
        $closureEmuPlaceholder = $emuPlaceholder
        $emuBox.Add_TextChanged({
            $closureEmuPlaceholder.Visibility = if ([string]::IsNullOrEmpty($closureEmuBox.Text)) { "Visible" } else { "Collapsed" }
        }.GetNewClosure())

        $fieldWrap.Children.Add($emuBox) | Out-Null
        $fieldWrap.Children.Add($emuPlaceholder) | Out-Null

        $browseEmuBtn = New-Object System.Windows.Controls.Button
        $browseEmuBtn.Content = "Browse"
        $browseEmuBtn.Style = $window.FindResource("SecondaryButton")
        [System.Windows.Controls.Grid]::SetColumn($browseEmuBtn, 3)
        $browseEmuBtn.Add_Click({ Browse-File $closureEmuBox }.GetNewClosure())

        $row.Children.Add($labelStack)   | Out-Null
        $row.Children.Add($fieldWrap)    | Out-Null
        $row.Children.Add($browseEmuBtn) | Out-Null

        $card.Child = $row
        $ConsoleList.Children.Add($card) | Out-Null

        $Global:ConsoleEntries += [PSCustomObject]@{
            Name    = $folder.Name
            Path    = $folder.FullName
            EmuBox  = $emuBox
            IsKnown = $isKnown
        }
    }

    Log "[OK] Found $($Global:ConsoleEntries.Count) console folder(s). Emulator paths were auto-filled where remembered - set the rest, then click Generate."
    Debug-Log "=== Scan finished ==="
})

$GenerateBtn.Add_Click({
    Debug-Log "=== Generate started ==="
    $PreviewBtn.Visibility = "Collapsed"
    $ReviewArtBtn.Visibility = "Collapsed"
    $outRoot = $OutBox.Text.Trim('"')
    if ([string]::IsNullOrWhiteSpace($outRoot)) {
        Log "[ERROR] Please choose an output folder first."
        return
    }
    if (-not (Test-Path $outRoot)) {
        New-Item -ItemType Directory -Path $outRoot -Force | Out-Null
        Log "[INFO] Created output folder: $outRoot"
    }

    if ($Global:ConsoleEntries.Count -eq 0) {
        Log "[ERROR] Nothing to generate - click Scan first."
        return
    }

    $doCleanNames = $CleanNamesCheck.IsChecked
    $doGroupDiscs = $GroupDiscsCheck.IsChecked
    $doFetchArt   = $FetchArtCheck.IsChecked
    $sgdbApiKey   = $SgdbKeyBox.Password.Trim()
    Debug-Log "Options: cleanNames=$doCleanNames groupDiscs=$doGroupDiscs fetchArt=$doFetchArt saveLog=$($SaveLogCheck.IsChecked)"

    if ($doFetchArt -and [string]::IsNullOrWhiteSpace($sgdbApiKey)) {
        Log "[WARN] Fetch artwork was checked but no SteamGridDB API key was entered - skipping artwork this run."
        $doFetchArt = $false
    }

    if ($doFetchArt) {
        $Global:EmuConfig["__sgdb_api_key"] = $sgdbApiKey
        $artRoot = Join-Path $PSScriptRoot "Artwork"
        if (-not (Test-Path $artRoot)) {
            New-Item -ItemType Directory -Path $artRoot -Force | Out-Null
        }
    }

    $totalLaunchers = 0
    $totalSkipped = 0
    $totalConsoles = 0
    $totalArtFetched = 0
    $Global:SessionArtwork = New-Object System.Collections.Generic.List[object]
    $Global:SessionLaunchers = New-Object System.Collections.Generic.List[object]

    foreach ($entry in $Global:ConsoleEntries) {
        $emuPath = $entry.EmuBox.Text.Trim('"')
        Debug-Log "  $($entry.Name): emulator = $emuPath"
        if ([string]::IsNullOrWhiteSpace($emuPath) -or -not (Test-Path $emuPath)) {
            Log "[WARN] Skipping $($entry.Name): emulator path is empty or invalid."
            continue
        }

        # Remember this emulator path for next time
        $Global:EmuConfig[$entry.Name] = $emuPath

        $outDir = Join-Path $outRoot $entry.Name
        if (-not (Test-Path $outDir)) {
            New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        }

        $romFiles = Get-ChildItem -Path $entry.Path -File | Where-Object {
            $SkipExtensions -notcontains $_.Extension.ToLower()
        }

        # --- Group files into launchable units ---
        # Each unit: @{ LaunchFile = <FileInfo to pass to emulator>; DisplayName = <string> }
        $units = New-Object System.Collections.Generic.List[object]
        $consumed = New-Object System.Collections.Generic.HashSet[string]

        if ($doGroupDiscs) {
            # First pass: primary disc files (.cue/.gdi/.ccd/.m3u) each define one unit.
            # Their same-basename companions (.bin/.iso/.img/.sub/.raw) are consumed silently.
            foreach ($f in $romFiles) {
                if ($PrimaryDiscExtensions -contains $f.Extension.ToLower()) {
                    $displayName = if ($doCleanNames) { Get-CleanName $f.BaseName } else { $f.BaseName }
                    $units.Add([PSCustomObject]@{ LaunchFile = $f; DisplayName = $displayName })
                    $consumed.Add($f.Name) | Out-Null
                    foreach ($sibling in $romFiles) {
                        if ($sibling.BaseName -eq $f.BaseName -and $CompanionDiscExtensions -contains $sibling.Extension.ToLower()) {
                            $consumed.Add($sibling.Name) | Out-Null
                        }
                    }
                }
            }
        }

        # Remaining files (not consumed as companions) become their own units,
        # grouped by disc-stripped name so "(Disc 1)"/"(Disc 2)" pairs collapse to one.
        $remaining = $romFiles | Where-Object { -not $consumed.Contains($_.Name) }

        if ($doGroupDiscs) {
            $groups = @{}
            foreach ($f in $remaining) {
                $baseName = if ($doCleanNames) { Get-CleanName $f.BaseName } else { $f.BaseName }
                $groupKey = Get-DiscGroupKey $baseName
                if (-not $groups.ContainsKey($groupKey)) {
                    $groups[$groupKey] = $f  # first file in the group becomes the launch target
                }
            }
            foreach ($key in $groups.Keys) {
                $units.Add([PSCustomObject]@{ LaunchFile = $groups[$key]; DisplayName = $key })
            }
        } else {
            foreach ($f in $remaining) {
                $displayName = if ($doCleanNames) { Get-CleanName $f.BaseName } else { $f.BaseName }
                $units.Add([PSCustomObject]@{ LaunchFile = $f; DisplayName = $displayName })
            }
        }

        $count = 0
        $skipped = 0
        foreach ($unit in $units) {
            $batName = "$($unit.DisplayName).bat"
            $batPath = Join-Path $outDir $batName

            if (Test-Path $batPath) {
                $skipped++
            } else {
                $content = "@echo off`r`nstart `"`" `"$emuPath`" `"$($unit.LaunchFile.FullName)`"`r`nexit`r`n"
                Set-Content -Path $batPath -Value $content -NoNewline
                $count++
            }

            $Global:SessionLaunchers.Add([PSCustomObject]@{
                Console       = $entry.Name
                GameName      = $unit.DisplayName
                BatPath       = $batPath
                ExpectedEmu   = $emuPath
                ExpectedRom   = $unit.LaunchFile.FullName
            })

            # Artwork is fetched for every unit (new or already-existing launcher),
            # so turning this on later still backfills art for older launchers.
            # Missing/unmatched art is skipped silently by design - no warning logged.
            if ($doFetchArt) {
                $artResult = Get-GameArtwork -apiKey $sgdbApiKey -gameName $unit.DisplayName -artRoot $artRoot
                if ($artResult) {
                    $totalArtFetched++
                    $Global:SessionArtwork.Add($artResult)
                }
            }
        }

        $totalLaunchers += $count
        $totalSkipped += $skipped
        $totalConsoles++

        $skipNote = if ($skipped -gt 0) { ", $skipped already existed (skipped)" } else { "" }
        Log "[OK] $($entry.Name): $count launcher(s) created$skipNote"
    }

    Save-Config $Global:EmuConfig

    Log "----------------------------------------"
    $artNote = if ($doFetchArt) { " Artwork fetched for $totalArtFetched game(s)." } else { "" }
    Log "Done! $totalLaunchers launcher(s) created across $totalConsoles console(s). $totalSkipped skipped (already existed).$artNote"

    if ($doFetchArt -and $Global:SessionArtwork.Count -gt 0) {
        $Global:SgdbApiKeyForReview = $sgdbApiKey
        $ReviewArtBtn.Visibility = "Visible"
    }

    if ($Global:SessionLaunchers.Count -gt 0) {
        $PreviewBtn.Visibility = "Visible"
    }

    if ($SaveLogCheck.IsChecked) {
        try {
            $logFileName = "rom-launcher-log_{0}.txt" -f (Get-Date -Format "yyyy-MM-dd_HH-mm-ss")
            $logFilePath = Join-Path $PSScriptRoot $logFileName
            $Global:LogLines | Set-Content -Path $logFilePath -Encoding UTF8
            Log "Log saved to: $logFilePath"
        } catch {
            Log "[WARN] Could not write log file: $($_.Exception.Message)"
        }
    }
    Debug-Log "=== Generate finished ==="
})

function Show-AssetPicker([string]$apiKey, [PSCustomObject]$artEntry, [string]$assetType, [string]$assetFileName) {
    $currentId = if ($artEntry.SelectedIds.ContainsKey($assetType)) { $artEntry.SelectedIds[$assetType] } else { $null }

    $safeTitle = [System.Security.SecurityElement]::Escape("$($artEntry.GameName) - $assetType")
    $pickerXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="$safeTitle" Height="520" Width="720"
        WindowStartupLocation="CenterOwner" Background="#16181D">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="$safeTitle" Foreground="#EDEFF2"
                   FontSize="16" FontWeight="SemiBold" Margin="0,0,0,12"/>
        <Grid Grid.Row="1">
            <TextBlock Name="LoadingText" Text="Loading previews..." Foreground="#8B93A1"
                       HorizontalAlignment="Center" VerticalAlignment="Center" FontSize="13"/>
            <ScrollViewer VerticalScrollBarVisibility="Auto">
                <ItemsControl Name="CandidateGrid">
                    <ItemsControl.ItemsPanel>
                        <ItemsPanelTemplate>
                            <WrapPanel/>
                        </ItemsPanelTemplate>
                    </ItemsControl.ItemsPanel>
                </ItemsControl>
            </ScrollViewer>
        </Grid>
    </Grid>
</Window>
"@
    $pickerReader = New-Object System.Xml.XmlNodeReader ([xml]$pickerXaml)
    $pickerWindow = [Windows.Markup.XamlReader]::Load($pickerReader)
    $pickerWindow.Owner = $window
    $loadingText = $pickerWindow.FindName("LoadingText")
    $grid = $pickerWindow.FindName("CandidateGrid")

    $pickerWindow.Add_ContentRendered({
        # Force this frame to actually paint before the blocking network call below,
        # otherwise "Loading previews..." would never visibly appear on screen.
        $pickerWindow.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)

        $candidates = Get-SgdbAssetCandidates -apiKey $apiKey -gameId $artEntry.GameId -assetType $assetType -max 12
        $loadingText.Visibility = "Collapsed"

        if ($candidates.Count -eq 0) {
            $loadingText.Text = "No previews found for this game."
            $loadingText.Visibility = "Visible"
            return
        }

        foreach ($candidate in $candidates) {
            $isCurrent = ($currentId -and $candidate.id -eq $currentId)

            $tile = New-Object System.Windows.Controls.Border
            $tile.Width = 150
            $tile.Height = 150
            $tile.Margin = "6"
            $tile.CornerRadius = New-Object System.Windows.CornerRadius(6)
            $tile.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#1E2129")
            $tile.BorderThickness = if ($isCurrent) { "2" } else { "1" }
            $tile.BorderBrush = [System.Windows.Media.BrushConverter]::new().ConvertFromString(
                $(if ($isCurrent) { "#5B8DEF" } else { "#343945" })
            )
            $tile.Cursor = "Hand"

            $tileGrid = New-Object System.Windows.Controls.Grid

            $img = New-Object System.Windows.Controls.Image
            $img.Stretch = "Uniform"
            $img.Margin = "6"
            try {
                $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                $bitmap.BeginInit()
                $bitmap.UriSource = New-Object System.Uri($candidate.thumb)
                $bitmap.CacheOption = "OnLoad"
                $bitmap.EndInit()
                $img.Source = $bitmap
            } catch {
                Debug-Log "  Thumbnail load failed: $($_.Exception.Message)"
            }
            $tileGrid.Children.Add($img) | Out-Null

            if ($isCurrent) {
                $badge = New-Object System.Windows.Controls.Border
                $badge.Background = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#5B8DEF")
                $badge.CornerRadius = New-Object System.Windows.CornerRadius(4)
                $badge.Padding = "6,2"
                $badge.HorizontalAlignment = "Left"
                $badge.VerticalAlignment = "Top"
                $badge.Margin = "4"
                $badgeText = New-Object System.Windows.Controls.TextBlock
                $badgeText.Text = "Current"
                $badgeText.FontSize = 10
                $badgeText.FontWeight = "SemiBold"
                $badgeText.Foreground = "White"
                $badge.Child = $badgeText
                $tileGrid.Children.Add($badge) | Out-Null
            }

            $tile.Child = $tileGrid

            # Local copies for GetNewClosure() - nested closures (this one lives inside
            # the Add_ContentRendered closure) don't reliably inherit outer-outer scope,
            # so pickerWindow/artEntry/etc. must be captured explicitly at this level.
            $closurePickerWindow = $pickerWindow
            $closureArtEntry     = $artEntry
            $closureAssetType    = $assetType
            $closureAssetFile    = $assetFileName
            $closureCandidate    = $candidate

            $tile.Add_MouseLeftButtonUp({
                param($s, $e)
                try {
                    $destPath = Join-Path $closureArtEntry.DestDir $closureAssetFile
                    Invoke-WebRequest -Uri $closureCandidate.url -OutFile $destPath -ErrorAction Stop
                    $closureArtEntry.SelectedIds[$closureAssetType] = $closureCandidate.id
                    Debug-Log "  Swapped $closureAssetType for $($closureArtEntry.GameName)"
                } catch {
                    Debug-Log "  Swap failed: $($_.Exception.Message)"
                }
                $closurePickerWindow.Close()
            }.GetNewClosure())

            $grid.Items.Add($tile) | Out-Null
        }
    })

    $pickerWindow.ShowDialog() | Out-Null
}

function Show-ArtworkReview {
    if ($Global:SessionArtwork.Count -eq 0) { return }

    $reviewXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Review artwork" Height="560" Width="700"
        WindowStartupLocation="CenterOwner" Background="#16181D">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Click any thumbnail to swap it for another option."
                   Foreground="#8B93A1" FontSize="13" Margin="0,0,0,12"/>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto">
            <StackPanel Name="GameList"/>
        </ScrollViewer>
    </Grid>
</Window>
"@
    $reviewReader = New-Object System.Xml.XmlNodeReader ([xml]$reviewXaml)
    $reviewWindow = [Windows.Markup.XamlReader]::Load($reviewReader)
    $reviewWindow.Owner = $window
    $gameList = $reviewWindow.FindName("GameList")
    $bc = [System.Windows.Media.BrushConverter]::new()

    foreach ($artEntry in $Global:SessionArtwork) {
        $card = New-Object System.Windows.Controls.Border
        $card.Background = $bc.ConvertFromString("#1E2129")
        $card.CornerRadius = New-Object System.Windows.CornerRadius(8)
        $card.Padding = "12"
        $card.Margin = "0,0,0,8"

        $stack = New-Object System.Windows.Controls.StackPanel

        $title = New-Object System.Windows.Controls.TextBlock
        $title.Text = $artEntry.GameName
        $title.Foreground = $bc.ConvertFromString("#EDEFF2")
        $title.FontWeight = "SemiBold"
        $title.Margin = "0,0,0,8"
        $stack.Children.Add($title) | Out-Null

        $thumbRow = New-Object System.Windows.Controls.StackPanel
        $thumbRow.Orientation = "Horizontal"

        foreach ($assetType in $artEntry.Assets.Keys) {
            $fileName = $artEntry.Assets[$assetType]
            $filePath = Join-Path $artEntry.DestDir $fileName

            $thumbBorder = New-Object System.Windows.Controls.Border
            $thumbBorder.Width = 100
            $thumbBorder.Height = 100
            $thumbBorder.Margin = "0,0,10,0"
            $thumbBorder.CornerRadius = New-Object System.Windows.CornerRadius(6)
            $thumbBorder.Background = $bc.ConvertFromString("#252932")
            $thumbBorder.BorderBrush = $bc.ConvertFromString("#343945")
            $thumbBorder.BorderThickness = "1"
            $thumbBorder.Cursor = "Hand"
            $thumbBorder.ToolTip = $assetType

            if (Test-Path $filePath) {
                $img = New-Object System.Windows.Controls.Image
                $img.Stretch = "Uniform"
                $img.Margin = "4"
                try {
                    $bitmap = New-Object System.Windows.Media.Imaging.BitmapImage
                    $bitmap.BeginInit()
                    $bitmap.UriSource = New-Object System.Uri($filePath)
                    $bitmap.CacheOption = "OnLoad"
                    $bitmap.EndInit()
                    $img.Source = $bitmap
                } catch { }
                $thumbBorder.Child = $img
            }

            $thumbBorder.Add_MouseLeftButtonUp({
                Show-AssetPicker -apiKey $Global:SgdbApiKeyForReview -artEntry $artEntry -assetType $assetType -assetFileName $fileName
                # Refresh this thumbnail after a possible swap
                if (Test-Path $filePath) {
                    $img2 = New-Object System.Windows.Controls.Image
                    $img2.Stretch = "Uniform"
                    $img2.Margin = "4"
                    $bmp2 = New-Object System.Windows.Media.Imaging.BitmapImage
                    $bmp2.BeginInit()
                    $bmp2.UriSource = New-Object System.Uri($filePath)
                    $bmp2.CacheOption = "OnLoad"
                    $bmp2.CreateOptions = "IgnoreImageCache"
                    $bmp2.EndInit()
                    $img2.Source = $bmp2
                    $thumbBorder.Child = $img2
                }
            }.GetNewClosure())

            $thumbRow.Children.Add($thumbBorder) | Out-Null
        }

        $stack.Children.Add($thumbRow) | Out-Null
        $card.Child = $stack
        $gameList.Children.Add($card) | Out-Null
    }

    $reviewWindow.ShowDialog() | Out-Null
}

function Show-PreviewReport {
    $problems = Test-SessionOutputs
    $checkedCount = $Global:SessionLaunchers.Count + $Global:SessionM3u.Count

    $reportXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Preview" SizeToContent="WidthAndHeight"
        MinWidth="360" MaxWidth="640" MaxHeight="560"
        WindowStartupLocation="CenterOwner" Background="#16181D">
    <Grid Margin="16">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Name="SummaryText" Foreground="#EDEFF2"
                   FontSize="14" Margin="0,0,0,12" TextWrapping="Wrap" MaxWidth="600"/>
        <ScrollViewer Grid.Row="1" VerticalScrollBarVisibility="Auto" MaxHeight="460">
            <StackPanel Name="ProblemList" MinWidth="320"/>
        </ScrollViewer>
    </Grid>
</Window>
"@
    $reportReader = New-Object System.Xml.XmlNodeReader ([xml]$reportXaml)
    $reportWindow = [Windows.Markup.XamlReader]::Load($reportReader)
    $reportWindow.Owner = $window
    $summaryText = $reportWindow.FindName("SummaryText")
    $problemList = $reportWindow.FindName("ProblemList")
    $bc = [System.Windows.Media.BrushConverter]::new()

    if ($problems.Count -eq 0) {
        $summaryText.Text = "Checked $checkedCount item(s) from this session - everything looks good."
        $summaryText.Foreground = $bc.ConvertFromString("#7FB069")
    } else {
        $summaryText.Text = "Checked $checkedCount item(s) from this session - found $($problems.Count) problem(s):"
        $summaryText.Foreground = $bc.ConvertFromString("#D9736A")

        foreach ($p in $problems) {
            $card = New-Object System.Windows.Controls.Border
            $card.Background = $bc.ConvertFromString("#1E2129")
            $card.CornerRadius = New-Object System.Windows.CornerRadius(6)
            $card.Padding = "10"
            $card.Margin = "0,0,0,6"

            $stack = New-Object System.Windows.Controls.StackPanel

            $header = New-Object System.Windows.Controls.TextBlock
            $header.Text = "[$($p.Kind)] $($p.GameName)"
            $header.Foreground = $bc.ConvertFromString("#EDEFF2")
            $header.FontWeight = "SemiBold"
            $header.FontSize = 13
            $stack.Children.Add($header) | Out-Null

            $reasonText = New-Object System.Windows.Controls.TextBlock
            $reasonText.Text = $p.Reason
            $reasonText.Foreground = $bc.ConvertFromString("#D9736A")
            $reasonText.FontSize = 12
            $reasonText.Margin = "0,2,0,0"
            $reasonText.TextWrapping = "Wrap"
            $stack.Children.Add($reasonText) | Out-Null

            $pathText = New-Object System.Windows.Controls.TextBlock
            $pathText.Text = $p.Path
            $pathText.Foreground = $bc.ConvertFromString("#5C6270")
            $pathText.FontSize = 11
            $pathText.Margin = "0,2,0,0"
            $pathText.TextWrapping = "Wrap"
            $stack.Children.Add($pathText) | Out-Null

            $card.Child = $stack
            $problemList.Children.Add($card) | Out-Null
        }
    }

    $reportWindow.ShowDialog() | Out-Null
}

$ReviewArtBtn.Add_Click({ Show-ArtworkReview })
$PreviewBtn.Add_Click({ Show-PreviewReport })

$window.ShowDialog() | Out-Null
