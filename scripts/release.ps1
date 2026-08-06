[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [string]$InstallerPath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Repository = 'thomasantonjansen/mcp-evolve'
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$TotalTimer = [System.Diagnostics.Stopwatch]::StartNew()

function Step {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [scriptblock]$Action
    )

    Write-Host ""
    Write-Host ">>> $Name" -ForegroundColor Cyan

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & $Action
    $sw.Stop()

    Write-Host ("<<< {0}: {1:N2}s" -f $Name, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
}

function Get-GhPath {
    $command = Get-Command gh.exe -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $knownPath = Join-Path ${env:ProgramFiles} 'GitHub CLI\gh.exe'
    if (Test-Path -LiteralPath $knownPath) {
        return $knownPath
    }

    throw 'GitHub CLI (gh) is not available. Install it from https://cli.github.com/.'
}

function Invoke-Gh {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments
    )

    & $script:GhPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI failed: gh $($Arguments -join ' ')"
    }
}

Step "Locate GitHub CLI" {
    $script:GhPath = Get-GhPath
    & $script:GhPath --version | Select-Object -First 1
}

Step "GitHub authentication" {
    & $GhPath auth status --hostname github.com 2>&1 | Out-Host
    if ($LASTEXITCODE -ne 0) {
        throw 'GitHub CLI is not authenticated. Run: gh auth login'
    }
}

Step "Repository validation" {
    $repoJson = & $GhPath repo view $Repository --json nameWithOwner,visibility 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub repository $Repository could not be read. Create it before releasing."
    }

    $repoInfo = $repoJson | ConvertFrom-Json

    if ([string]$repoInfo.nameWithOwner -ne $Repository) {
        throw "Unexpected repository returned by GitHub CLI: $($repoInfo.nameWithOwner)"
    }

    if ([string]$repoInfo.visibility -notin @('PUBLIC', 'public')) {
        throw "Refusing to release: $Repository is not public."
    }
}

Step "Locate installer" {
    if ([string]::IsNullOrWhiteSpace($Version) -and [string]::IsNullOrWhiteSpace($InstallerPath)) {
        $artifactRoot = $env:MCP_EVOLVE_ARTIFACT_DIR
        if ([string]::IsNullOrWhiteSpace($artifactRoot)) {
            $artifactRoot = Join-Path (Split-Path -Parent $RepoRoot) 'UnityMCPApp\artifacts'
        }

        $candidates = @(Get-ChildItem -LiteralPath $artifactRoot -File -Filter 'MCP-Evolve-Setup-*.exe' |
            Where-Object { $_.Name -match '^MCP-Evolve-Setup-(\d+\.\d+\.\d+)\.exe$' })

        if (-not $candidates) {
            throw "No MCP Evolve installer matching MCP-Evolve-Setup-X.Y.Z.exe was found in $artifactRoot"
        }

        $selected = $candidates |
            Sort-Object -Property @{
                Expression = {
                    $versionText = [regex]::Match($_.Name, '^MCP-Evolve-Setup-(\d+\.\d+\.\d+)\.exe$').Groups[1].Value
                    $parts = $versionText -split '\.'
                    '{0:D20}.{1:D20}.{2:D20}' -f [int]$parts[0], [int]$parts[1], [int]$parts[2]
                }
                Descending = $true
            } |
            Select-Object -First 1

        $script:Version = [regex]::Match($selected.Name, '^MCP-Evolve-Setup-(\d+\.\d+\.\d+)\.exe$').Groups[1].Value
        $script:InstallerPath = $selected.FullName
        Write-Host "No version supplied; selected latest installer: $($selected.Name)"
    }
    elseif ([string]::IsNullOrWhiteSpace($Version)) {
        $providedName = Split-Path -Leaf $InstallerPath
        if ($providedName -notmatch '^MCP-Evolve-Setup-(\d+\.\d+\.\d+)\.exe$') {
            throw "Installer filename must match MCP-Evolve-Setup-X.Y.Z.exe: $providedName"
        }
        $script:Version = $matches[1]
    }
    else {
        if ($Version -notmatch '^\d+\.\d+\.\d+$') {
            throw "Version must use X.Y.Z format, received: $Version"
        }
        $script:Version = $Version
    }

    if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
        $artifactRoot = $env:MCP_EVOLVE_ARTIFACT_DIR
        if ([string]::IsNullOrWhiteSpace($artifactRoot)) {
            $artifactRoot = Join-Path (Split-Path -Parent $RepoRoot) 'UnityMCPApp\artifacts'
        }

        $script:InstallerPath = Join-Path $artifactRoot "MCP-Evolve-Setup-$script:Version.exe"
    }
    elseif ([string]::IsNullOrWhiteSpace($script:InstallerPath)) {
        $script:InstallerPath = $InstallerPath
    }

    $script:Tag = "v$script:Version"
    $script:installer = Get-Item -LiteralPath $script:InstallerPath -ErrorAction Stop

    if ($installer.PSIsContainer) {
        throw "InstallerPath must be a file, not a directory: $script:InstallerPath"
    }

    if ($installer.Extension -ine '.exe') {
        throw "Refusing to upload a non-executable file: $($installer.Name)"
    }

    $expectedName = "MCP-Evolve-Setup-$script:Version.exe"

    if ($installer.Name -cne $expectedName) {
        throw "Installer filename must be $expectedName, received $($installer.Name)"
    }
}

Step "Generate SHA256" {
    $script:checksum = (Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256).Hash.ToLowerInvariant()

    $script:checksumPath = Join-Path $installer.DirectoryName 'SHA256SUMS.txt'

    "$checksum  $($installer.Name)" |
        Set-Content -LiteralPath $checksumPath -Encoding ascii
}

Write-Host ""
Write-Host "Installer: $($installer.FullName)"
Write-Host "SHA-256:   $checksum"
Write-Host "Release:   $Repository@$Tag"

Step "Check existing release" {
    $strictNativePreference = $PSNativeCommandUseErrorActionPreference
    $PSNativeCommandUseErrorActionPreference = $false

    try {
        $releaseView = & $GhPath release view $Tag --repo $Repository --json tagName 2>&1
        $script:releaseExitCode = $LASTEXITCODE
    }
    finally {
        $PSNativeCommandUseErrorActionPreference = $strictNativePreference
    }

    $script:releaseExists = $releaseExitCode -eq 0
}

if ($releaseExists) {

    Step "Upload assets" {
        Write-Host 'Existing release found; replacing release assets with --clobber.'

        Invoke-Gh @(
            'release',
            'upload',
            $Tag,
            $installer.FullName,
            $checksumPath,
            '--repo',
            $Repository,
            '--clobber'
        )
    }

}
else {

    Step "Create release" {
        $notesFile = New-TemporaryFile

        try {
@"
MCP Evolve $Version

Windows x64 installer for MCP Evolve.

Verify the download with SHA256SUMS.txt before running the installer.
The separately maintained MCP Evolve Proxy is bundled and verified during the private build.
"@ | Set-Content -LiteralPath $notesFile.FullName -Encoding utf8

            Invoke-Gh @(
                'release',
                'create',
                $Tag,
                $installer.FullName,
                $checksumPath,
                '--repo',
                $Repository,
                '--title',
                "MCP Evolve $Version",
                '--notes-file',
                $notesFile.FullName,
                '--latest'
            )
        }
        finally {
            Remove-Item -LiteralPath $notesFile.FullName -Force -ErrorAction SilentlyContinue
        }
    }

}

Step "Read release URL" {
    $script:releaseUrl = & $GhPath release view $Tag --repo $Repository --json url --jq .url

    if ($LASTEXITCODE -ne 0) {
        throw "Release was uploaded but could not be read back: $Repository@$Tag"
    }
}

$TotalTimer.Stop()

Write-Host ""
Write-Host 'Release published successfully.' -ForegroundColor Green
Write-Host "Download: $releaseUrl"
Write-Host "Uploaded: $($installer.Name), SHA256SUMS.txt"
Write-Host ("TOTAL: {0:N2}s" -f $TotalTimer.Elapsed.TotalSeconds) -ForegroundColor Yellow
