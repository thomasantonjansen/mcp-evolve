[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^\d+\.\d+\.\d+$')]
    [string]$Version,

    [Parameter(Mandatory = $false)]
    [string]$InstallerPath
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$Repository = 'thomasantonjansen/mcp-evolve'
$Tag = "v$Version"
$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

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
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    & $script:GhPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "GitHub CLI failed: gh $($Arguments -join ' ')"
    }
}

$GhPath = Get-GhPath
& $GhPath --version | Select-Object -First 1

& $GhPath auth status --hostname github.com 2>&1 | Out-Host
if ($LASTEXITCODE -ne 0) {
    throw 'GitHub CLI is not authenticated. Run: gh auth login'
}

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

if ([string]::IsNullOrWhiteSpace($InstallerPath)) {
    $artifactRoot = $env:MCP_EVOLVE_ARTIFACT_DIR
    if ([string]::IsNullOrWhiteSpace($artifactRoot)) {
        $artifactRoot = Join-Path (Split-Path -Parent $RepoRoot) 'UnityMCPApp\artifacts'
    }
    $InstallerPath = Join-Path $artifactRoot "MCP-Evolve-Setup-$Version.exe"
}

$installer = Get-Item -LiteralPath $InstallerPath -ErrorAction Stop
if ($installer.PSIsContainer) {
    throw "InstallerPath must be a file, not a directory: $InstallerPath"
}
if ($installer.Extension -ine '.exe') {
    throw "Refusing to upload a non-executable file: $($installer.Name)"
}
$expectedName = "MCP-Evolve-Setup-$Version.exe"
if ($installer.Name -cne $expectedName) {
    throw "Installer filename must be $expectedName, received $($installer.Name)"
}

# The only release inputs are the explicitly selected installer and this checksum file.
$checksum = (Get-FileHash -LiteralPath $installer.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
$checksumPath = Join-Path $installer.DirectoryName 'SHA256SUMS.txt'
"$checksum  $($installer.Name)" | Set-Content -LiteralPath $checksumPath -Encoding ascii

Write-Host "Installer: $($installer.FullName)"
Write-Host "SHA-256:   $checksum"
Write-Host "Release:   $Repository@$Tag"

$releaseView = & $GhPath release view $Tag --repo $Repository --json tagName 2>&1
$releaseExists = $LASTEXITCODE -eq 0

if ($releaseExists) {
    Write-Host 'Existing release found; replacing release assets with --clobber.'
    Invoke-Gh @('release', 'upload', $Tag, $installer.FullName, $checksumPath, '--repo', $Repository, '--clobber')
} else {
    $notesFile = New-TemporaryFile
    try {
        @"
MCP Evolve $Version

Windows x64 installer for MCP Evolve.

Verify the download with SHA256SUMS.txt before running the installer.
The separately maintained MCP Evolve Proxy is bundled and verified during the private build.
"@ | Set-Content -LiteralPath $notesFile.FullName -Encoding utf8

        Invoke-Gh @(
            'release', 'create', $Tag,
            $installer.FullName,
            $checksumPath,
            '--repo', $Repository,
            '--title', "MCP Evolve $Version",
            '--notes-file', $notesFile.FullName,
            '--latest'
        )
    } finally {
        Remove-Item -LiteralPath $notesFile.FullName -Force -ErrorAction SilentlyContinue
    }
}

$releaseUrl = & $GhPath release view $Tag --repo $Repository --json url --jq .url
if ($LASTEXITCODE -ne 0) {
    throw "Release was uploaded but could not be read back: $Repository@$Tag"
}

Write-Host ''
Write-Host 'Release published successfully.' -ForegroundColor Green
Write-Host "Download: $releaseUrl"
Write-Host "Uploaded: $($installer.Name), SHA256SUMS.txt"

