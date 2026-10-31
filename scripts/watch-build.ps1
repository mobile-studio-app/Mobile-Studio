# scripts/watch-build.ps1
# Automatically monitors the latest GitHub Actions build for Mobile Studio,
# prints live progress, and downloads MobileStudio.ipa into the release/ folder.

$ErrorActionPreference = "Stop"
# The repository is the one the origin remote points at (https://github.com/<owner>/<name>).
$origin = git -C $PSScriptRoot remote get-url origin
if ($origin -notmatch "github\.com[:/]([^/]+)/([^/]+?)(\.git)?$") { throw "origin isn't a GitHub repository: $origin" }
$repoOwner = $Matches[1]
$repoName = $Matches[2]

# 1. Ensure release/ directory exists
$rootDir = (Get-Item $PSScriptRoot).Parent.FullName
$releaseDir = Join-Path $rootDir "release"
if (-not (Test-Path $releaseDir)) {
    New-Item -ItemType Directory -Path $releaseDir | Out-Null
}

# 2. Retrieve GitHub token from Git Credential Manager
Write-Host "?? Authenticating with Git Credential Manager..." -ForegroundColor Cyan
$gcmInput = "protocol=https`nhost=github.com`nusername=$repoOwner`n"
$gcmOutput = $gcmInput | git credential fill 2>&1
$token = ""
foreach ($line in ($gcmOutput -split "`n")) {
    if ($line -match "^password=(.+)$") {
        $token = $matches[1].Trim()
        break
    }
}

if (-not $token) {
    Write-Host "❌ Could not find credentials for $repoOwner. Run 'git push' first to authenticate." -ForegroundColor Red
    exit 1
}

$headers = @{
    "Authorization" = "Bearer $token"
    "User-Agent"    = "MobileStudio-Watcher"
    "Accept"        = "application/vnd.github+json"
}

# 3. Fetch latest workflow run
Write-Host "?? Checking latest GitHub Actions run for $repoOwner/$repoName..." -ForegroundColor Cyan
$runsUrl = "https://api.github.com/repos/$repoOwner/$repoName/actions/runs?per_page=1"
$runsResponse = Invoke-RestMethod -Uri $runsUrl -Headers $headers
$run = $runsResponse.workflow_runs[0]

if (-not $run) {
    Write-Host "❌ No workflow runs found." -ForegroundColor Red
    exit 1
}

$runId = $run.id
$commitMsg = $run.head_commit.message -split "`n" | Select-Object -First 1
Write-Host "▶ Watching Run #${runId}: '$commitMsg'" -ForegroundColor Yellow
Write-Host "  URL: $($run.html_url)" -ForegroundColor Gray

# 4. Poll workflow status
$lastStatus = ""
while ($true) {
    $currentRun = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoOwner/$repoName/actions/runs/$runId" -Headers $headers
    $status = $currentRun.status
    $conclusion = $currentRun.conclusion

    $timeStr = (Get-Date).ToString("HH:mm:ss")
    if ($status -ne $lastStatus) {
        Write-Host "[$timeStr] Status: $status $(if ($conclusion) { "($conclusion)" })" -ForegroundColor Yellow
        $lastStatus = $status
    } else {
        Write-Host "." -NoNewline -ForegroundColor DarkGray
    }

    if ($status -eq "completed") {
        Write-Host ""
        if ($conclusion -eq "success") {
            Write-Host "✅ Build succeeded!" -ForegroundColor Green
            break
        } else {
            Write-Host "❌ Build failed ($conclusion)." -ForegroundColor Red

            # Fetch failed job error details
            $jobs = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoOwner/$repoName/actions/runs/$runId/jobs" -Headers $headers
            foreach ($job in $jobs.jobs) {
                if ($job.conclusion -eq "failure") {
                    Write-Host "  Job: $($job.name)" -ForegroundColor Red
                    foreach ($step in $job.steps) {
                        if ($step.conclusion -eq "failure") {
                            Write-Host "  Failed Step: $($step.name)" -ForegroundColor Red
                        }
                    }
                    try {
                        $logText = curl.exe -s -L -H "Authorization: Bearer $token" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$repoOwner/$repoName/actions/jobs/$($job.id)/logs" 2>$null
                        if ($logText) {
                            $errorLines = $logText -split "`n" | Where-Object { $_ -match "##\[error\]|error:|fatal error|BUILD FAILED|Undefined symbols" } | Select-Object -First 15
                            if ($errorLines) {
                                Write-Host "`n  Compiler Errors:" -ForegroundColor Magenta
                                foreach ($errLine in $errorLines) {
                                    Write-Host "    $errLine" -ForegroundColor Red
                                }
                            }
                        }
                    } catch {}
                }
            }
            exit 1
        }
    }
    Start-Sleep -Seconds 5
}

# 5. Fetch and download artifact
Write-Host "?? Fetching build artifacts..." -ForegroundColor Cyan
$artifactsUrl = "https://api.github.com/repos/$repoOwner/$repoName/actions/runs/$runId/artifacts"
$artifactsResponse = Invoke-RestMethod -Uri $artifactsUrl -Headers $headers
$artifact = $artifactsResponse.artifacts | Where-Object { $_.name -eq "MobileStudio-ipa" } | Select-Object -First 1

if (-not $artifact) {
    Write-Host "❌ MobileStudio-ipa artifact not found in run." -ForegroundColor Red
    exit 1
}

$downloadZipPath = Join-Path $releaseDir "MobileStudio-artifact.zip"
Write-Host "?? Downloading $($artifact.name) ($([math]::Round($artifact.size_in_bytes / 1MB, 2)) MB)..." -ForegroundColor Cyan

# GitHub artifact download endpoint redirects to Azure blob
$dlHeaders = @{
    "Authorization" = "Bearer $token"
    "User-Agent"    = "MobileStudio-Watcher"
    "Accept"        = "application/vnd.github+json"
}
Invoke-WebRequest -Uri $artifact.archive_download_url -Headers $dlHeaders -OutFile $downloadZipPath

# 6. Extract IPA
Write-Host "?? Extracting MobileStudio.ipa..." -ForegroundColor Cyan
Expand-Archive -Path $downloadZipPath -DestinationPath $releaseDir -Force
Remove-Item -Path $downloadZipPath -Force

$ipaPath = Join-Path $releaseDir "MobileStudio.ipa"
if (Test-Path $ipaPath) {
    $ipaSize = [math]::Round((Get-Item $ipaPath).Length / 1MB, 2)
    Write-Host "🎉 SUCCESS! IPA saved to: $ipaPath ($ipaSize MB)" -ForegroundColor Green
} else {
    Write-Host "⚠️ Artifact extracted to $releaseDir" -ForegroundColor Yellow
}
