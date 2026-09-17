@{
    RootModule        = 'OmnikeyToolkit.psm1'
    ModuleVersion     = '1.2.0'
    GUID              = '4869e906-2844-4796-a013-df7fa8c5eb6d'
    Author            = 'franekSoftSF'
    Copyright         = '(c) franekSoftSF. MIT License.'
    Description       = 'Scripted configuration, audit and mass provisioning of HID OMNIKEY readers over PC/SC. Independent tool, not affiliated with or endorsed by HID Global.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @('Invoke-OmnikeyCli', 'Invoke-OmnikeyTool', 'Invoke-OmnikeyBatch')
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('OMNIKEY', 'PCSC', 'SmartCard', 'Provisioning', 'Windows')
            LicenseUri = 'https://github.com/franekSoftSF/omnikey-provisioning-toolkit/blob/main/LICENSE'
            ProjectUri = 'https://github.com/franekSoftSF/omnikey-provisioning-toolkit'
        }
    }
}
