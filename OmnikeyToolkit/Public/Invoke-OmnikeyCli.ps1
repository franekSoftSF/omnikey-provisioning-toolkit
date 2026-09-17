function Invoke-OmnikeyCli {
    <#
    .SYNOPSIS
      Entry point of Omnikey.ps1: one command for every tool. Returns the exit code
      (0 OK/PASS, 2 FAIL); execution errors throw (the calling script exits with 1).
      Without a command it runs the interactive menu until "0" (errors are shown, not fatal).
    #>
    [CmdletBinding()]
    [OutputType([int])]
    param(
        [string]$Command = "",
        [string]$ProfilePath = "",
        [ValidateSet("en", "pl")][string]$Lang = "en",
        [string]$ReaderMatch = "",
        [switch]$NoReboot,
        [int]$RebootWait = 10,
        [int]$CardTimeout = 30,
        [string]$OutProfile = ".\reader-profile.json",
        [switch]$Loop,
        [string]$LogCsv = ".\omnikey-provisioning.csv",
        [string]$InventoryMap = "",
        [int]$PollMs = 500,
        [int]$StableSec = 4,
        [int]$VerifyRetry = 30,
        # names of the parameters the user actually passed (for per-command validation)
        [string[]]$Bound = @(),
        # set by the menu: ask instead of failing when several readers are connected
        [switch]$Interactive
    )
    Set-MessageLanguage $Lang

    if (-not $Command) {
        while ($true) {
            $sel = Read-MenuSelection
            if (-not $sel) { return [int]0 }
            if (-not $sel.Command) {
                if ($sel.Invalid) { Write-Host (T menuInvalid $sel.Invalid) -ForegroundColor Red }
                Write-Host ""
                continue
            }
            try {
                [void](Invoke-OmnikeyCli -Command $sel.Command -ProfilePath $(if ($sel.ProfilePath) { $sel.ProfilePath } else { $ProfilePath }) `
                    -Lang $Lang -ReaderMatch $ReaderMatch -NoReboot:$NoReboot -RebootWait $RebootWait -CardTimeout $CardTimeout `
                    -OutProfile $OutProfile -LogCsv $LogCsv -InventoryMap $InventoryMap -PollMs $PollMs -StableSec $StableSec `
                    -VerifyRetry $VerifyRetry -Interactive)
            }
            catch { Write-Host $_.Exception.Message -ForegroundColor Red }
            finally { Set-MessageLanguage $Lang }
            Write-Host ""
        }
    }
    $Command = $Command.ToLower()
    if (-not $script:CliCommandParams.ContainsKey($Command)) { throw (T menuInvalid $Command) }
    Assert-CliParameter $Command $Bound
    if ($Command -in 'set', 'verify', 'batch' -and -not $ProfilePath) { throw (T profileNeeded $Command) }

    switch ($Command) {
        'readers' { Show-ReaderList $ReaderMatch; return [int]0 }
        'configure' { return [int](Invoke-ReaderConfigurator $ReaderMatch ([bool]$Interactive) $Lang ([bool]$NoReboot) $script:BackupDir) }
        'restore' { return [int](Invoke-ReaderRestore $ReaderMatch ([bool]$Interactive) $Lang ([bool]$NoReboot) $ProfilePath $script:BackupDir) }
        'batch' {
            return [int](Invoke-OmnikeyBatch -ProfilePath $ProfilePath -LogCsv $LogCsv -InventoryMap $InventoryMap -Lang $Lang `
                -ReaderMatch $(if ($ReaderMatch) { $ReaderMatch } else { 'OMNIKEY' }) `
                -PollMs $PollMs -StableSec $StableSec -RebootWait $RebootWait -VerifyRetry $VerifyRetry)
        }
        default {
            $match = Resolve-SingleReader $ReaderMatch ([bool]$Interactive)
            return [int](Invoke-OmnikeyTool -Mode $script:CliModes[$Command] -ProfilePath $ProfilePath -Lang $Lang -ReaderMatch $match `
                -NoReboot:$NoReboot -RebootWait $RebootWait -CardTimeout $CardTimeout -OutProfile $OutProfile -Loop:$Loop -BackupDir $script:BackupDir)
        }
    }
}
