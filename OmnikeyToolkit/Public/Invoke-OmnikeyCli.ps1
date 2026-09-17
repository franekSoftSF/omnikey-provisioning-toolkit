function Invoke-OmnikeyCli {
    <#
    .SYNOPSIS
      Entry point of Omnikey.ps1: one command for every tool. Returns the exit code
      (0 OK/PASS, 2 FAIL); execution errors throw (the calling script exits with 1).
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
        [string[]]$Bound = @()
    )
    Set-MessageLanguage $Lang

    if (-not $Command) {
        $sel = Read-MenuSelection
        if (-not $sel) { return [int]0 }
        $Command = $sel.Command
        if ($sel.ProfilePath) { $ProfilePath = $sel.ProfilePath }
    }
    $Command = $Command.ToLower()
    if (-not $script:CliCommandParams.ContainsKey($Command)) { throw (T menuInvalid $Command) }
    Assert-CliParameters $Command $Bound
    if ($Command -in 'set', 'verify', 'batch' -and -not $ProfilePath) { throw (T profileNeeded $Command) }

    switch ($Command) {
        'readers' { Show-ReaderList $ReaderMatch; return [int]0 }
        'batch' {
            return [int](Invoke-OmnikeyBatch -ProfilePath $ProfilePath -LogCsv $LogCsv -InventoryMap $InventoryMap -Lang $Lang `
                -ReaderMatch $(if ($ReaderMatch) { $ReaderMatch } else { 'OMNIKEY' }) `
                -PollMs $PollMs -StableSec $StableSec -RebootWait $RebootWait -VerifyRetry $VerifyRetry)
        }
        default {
            $match = Resolve-SingleReader $ReaderMatch
            return [int](Invoke-OmnikeyTool -Mode $script:CliModes[$Command] -ProfilePath $ProfilePath -Lang $Lang -ReaderMatch $match `
                -NoReboot:$NoReboot -RebootWait $RebootWait -CardTimeout $CardTimeout -OutProfile $OutProfile -Loop:$Loop)
        }
    }
}
