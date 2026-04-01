$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$installScript = Join-Path $PSScriptRoot 'install_craftos_pc.ps1'
$craftosRoot = Join-Path $repoRoot '.tools\craftos-pc'
$consoleExe = Join-Path $craftosRoot 'CraftOS-PC_console.exe'

if (-not (Test-Path $consoleExe)) {
    & $installScript | Out-Null
}

if (-not (Test-Path $consoleExe)) {
    throw "CraftOS-PC executable was not installed at $consoleExe"
}

$runRoot = Join-Path $repoRoot '.tmp\craftos-smoke'
$computerRoot = Join-Path $runRoot 'computer'
$dataRoot = Join-Path $runRoot 'data'
$stdoutPath = Join-Path $runRoot 'craftos.stdout.log'
$stderrPath = Join-Path $runRoot 'craftos.stderr.log'

Remove-Item -Recurse -Force $runRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $computerRoot, $dataRoot | Out-Null

$arguments = @(
    '--headless',
    '--rom', $craftosRoot,
    '--directory', $dataRoot,
    '--start-dir', $computerRoot,
    '--mount-ro', "/repo=$repoRoot",
    '--exec', "shell.run('/repo/test/repo_smoke.lua')"
)

$process = Start-Process -FilePath $consoleExe -ArgumentList $arguments -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -PassThru

try {
    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if ($process.HasExited) {
            break
        }

        $stdout = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -Raw } else { '' }
        $stderr = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw } else { '' }
        $combined = ($stdout + [Environment]::NewLine + $stderr)

        if ($combined -match 'CraftOS-PC repo smoke test passed' -or $combined -match 'CraftOS-PC repo smoke test failed:' -or $combined -match 'Could not load startup script:') {
            Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
            Wait-Process -Id $process.Id -Timeout 2 -ErrorAction SilentlyContinue
            $process.Refresh()
            break
        }

        Start-Sleep -Milliseconds 500
        $process.Refresh()
    }

    if (-not $process.HasExited) {
        throw 'timeout'
    }
} catch {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "CraftOS-PC smoke run timed out. See $stdoutPath and $stderrPath"
}

$stdout = if (Test-Path $stdoutPath) { Get-Content $stdoutPath -Raw } else { '' }
$stderr = if (Test-Path $stderrPath) { Get-Content $stderrPath -Raw } else { '' }
$log = ($stdout + [Environment]::NewLine + $stderr).Trim()
if ($log) {
    Write-Output $log
}

if ($log -match 'CraftOS-PC repo smoke test passed') {
    return
}

if ($process.ExitCode -ne 0) {
    throw "CraftOS-PC smoke run failed with exit code $($process.ExitCode)"
}

if ($log -notmatch 'CraftOS-PC repo smoke test passed') {
    throw "CraftOS-PC smoke run completed without reporting success. See $stdoutPath and $stderrPath"
}