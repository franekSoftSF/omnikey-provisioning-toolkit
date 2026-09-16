# OMNIKEY Provisioning Toolkit

**Scripted configuration, audit and mass provisioning of HID OMNIKEY® smart card readers** (currently: **OMNIKEY 5022**; protocol-compatible with the AViatoR family — 5122/5422 contactless slot) —
no Workbench GUI required. Built around a real deployment across a large fleet for a banking-sector customer,
with the key use case of enabling **MIFARE Classic emulation support (`mifarePreferred`)** on
dual-interface cards.

Pure PowerShell, zero external dependencies (raw `winscard.dll` P/Invoke). Works with the reader
alone — no smart card needed, except for the card test mode.

> **Disclaimer:** independent tool, not affiliated with or endorsed by HID Global.
> OMNIKEY® is a trademark of HID Global / ASSA ABLOY AB. All proprietary APDUs used here come from
> HID's official public samples: [hidglobal/HID-OMNIKEY-Sample-Codes](https://github.com/hidglobal/HID-OMNIKEY-Sample-Codes).
> Test on a small batch before any full rollout. Use at your own risk.

---

## Features

- **Get** — dump the full contactless configuration of a connected reader
- **Set** — apply a JSON profile (write → Apply → reader reboot)
- **Verify** — audit the reader against a profile; exit code for pipelines (`0`/`2`)
- **Export** — snapshot the current reader configuration as a Batch-ready profile
  ("golden unit" workflow)
- **TestCard** — present a card, get its ATR/UID, identification (MIFARE Classic 1K/4K,
  Plus SL1/SL2, Ultralight, CPU/T=CL…) and a clear verdict whether the reader sees it as
  **MIFARE Classic**; optional `-Loop` mode for testing a whole stack of cards
- **Batch provisioning station** — powered-USB-hub workflow for hundreds/thousands of units:
  auto-detects batches, applies the profile, verifies by serial number after reboot,
  beeps PASS/FAIL, writes a per-unit CSV audit trail, fully resumable
- Messages in **English** (default) or **Polish** (`-Lang pl`)

## Repository layout

```
omnikey-provisioning-toolkit/
├── README.md
├── LICENSE                          # MIT
├── .gitignore                       # keeps CSV logs & customer profiles out of git
├── CheckProfile5022.ps1             # single-reader tool: Get/Set/Verify/Export/TestCard
├── Batch-Omnikey5022-Provision.ps1  # mass provisioning station
├── profiles/
│   └── example-profile.json
└── tests/                           # Pester 5 suite (no hardware needed)
```

## Requirements

- Windows 10/11, PowerShell 5.1+ (also works on PowerShell 7)
- Smart Card service (`SCardSvr`)
- Reader: HID OMNIKEY **5022** (the protocol layer matches the AViatoR family — 5122/5422
  contactless slot — but only 5022 was tested at scale)
- Driver, one of:
  - **HID OMNIKEY CCID Driver** v2.3.4+ (recommended; escape commands work out of the box) —
    [hidglobal.com/drivers](https://www.hidglobal.com/drivers); for mass rollout deploy the INF via
    `pnputil /add-driver <inf> /install`
  - Microsoft inbox CCID driver **with escape commands enabled**:
    `EscapeCommandEnable=1` (DWORD) under the device's `Device Parameters`, then replug

First run on a fresh machine:

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Unblock-File .\CheckProfile5022.ps1, .\Batch-Omnikey5022-Provision.ps1
```

Close Workbench before using the tools — it holds the reader and DIRECT connect will fail.

---

## Single-reader tool: `CheckProfile5022.ps1`

```powershell
.\CheckProfile5022.ps1 -Mode Get                                        # dump configuration
.\CheckProfile5022.ps1 -Mode Export -OutProfile .\my-profile.json       # reader -> profile JSON
.\CheckProfile5022.ps1 -Mode Set    -Profile .\my-profile.json          # profile -> reader (+reboot)
.\CheckProfile5022.ps1 -Mode Verify -Profile .\my-profile.json          # audit, exit 0=PASS 2=FAIL
.\CheckProfile5022.ps1 -Mode TestCard                                   # single card test
.\CheckProfile5022.ps1 -Mode TestCard -Loop                             # test a stack of cards
```

![CheckProfile5022 applying a full profile to an OMNIKEY 5022](docs/img/CheckProfile5022.png)

*`Set` mode: every profile parameter confirmed, then Apply + reader reboot.*

Common parameters: `-Lang en|pl`, `-ReaderMatch <regex>` (default `5022`),
`-CardTimeout <s>` (TestCard), `-NoReboot` (Set).

### Card test (`TestCard`)

Reads the card's PC/SC ATR and UID, identifies the technology and gives a verdict:

```
Reader mifarePreferred: ENABLED
Present a card on the reader (waiting up to 30s)...
ATR: 3B8F8001804F0CA000000306030001000000006A
UID: 04A1B2C3D4E5F6
Card identified as: MIFARE Classic 1K
VERDICT: reader sees this card as MIFARE CLASSIC - emulation/native Classic WORKS for this card.
```

The verdict is **context-aware**: if the card presents as a CPU card, the tool tells you whether
that is expected (`mifarePreferred` disabled — enable and retest) or meaningful
(`mifarePreferred` enabled — this card exposes no Classic emulation).

`-Loop` tests cards one after another: double beep = Classic, low beep = other,
waits for card removal between cards, `Ctrl+C` ends with a summary
(`Cards tested: 12 | MIFARE Classic: 11 | other: 1`).

Recognised storage types: MIFARE Classic 1K/4K, Mini, Plus SL1 2K/4K (Classic mode),
Plus SL2 2K/4K, Ultralight, Ultralight C, Topaz/Jewel, FeliCa; anything else is shown with its
raw PC/SC code. Note: PC/SC cannot distinguish *native* Classic from a *dual-interface emulation* —
to tell them apart, test the same card with `mifarePreferred` off (emulated cards flip to CPU,
native Classic stays Classic).

---

## Profile reference

A profile is a JSON file. **Every key is optional** — only listed keys are set/verified,
everything else on the reader is left untouched. `Export` produces a full snapshot; delete keys
you don't want to enforce.

```json
{
  "iso14443a": {
    "enabled": true,
    "mifarePreferred": true,
    "mifareKeyCache": false,
    "rx": [212, 424],
    "tx": [212, 424]
  },
  "iso14443b": { "enabled": true, "rx": [212, 424], "tx": [212, 424] },
  "iso15693":  { "enabled": true },
  "felica":    { "enabled": true, "rx": [212], "tx": [212] },
  "iclass":    { "enabled": true },
  "emdSuppression": true,
  "sleepModeCardDetection": true,
  "sleepModePollingFrequency": "0.7Hz",
  "pollingSearchOrder": ["iso14443a", "iso14443b", "iclass", "felica", "iso15693"]
}
```

| Profile key | Workbench equivalent | Values | Description |
|---|---|---|---|
| `iso14443a.enabled` | ISO14443A → Enabled | `true`/`false` | Polling for ISO/IEC 14443 Type A (MIFARE family). |
| `iso14443a.mifarePreferred` | **MIFARE emulation preferred** | `true`/`false` | Dual-interface cards exposing a MIFARE Classic emulation (e.g. CardOS DI) are presented as **MIFARE Classic** instead of a CPU card. The key setting of this toolkit. |
| `iso14443a.mifareKeyCache` | MIFARE key cache enabled | `true`/`false` | Cache MIFARE keys in the reader between card sessions. |
| `iso14443a.rx` / `.tx` | Rx/Tx Baud Rates | `212`,`424`,`848` | Extra bit rates (kbps). **106 is always on** — do not list it. |
| `iso14443b.enabled` + `rx/tx` | ISO14443B | as above | ISO/IEC 14443 Type B. |
| `iso15693.enabled` | ISO15693 | `true`/`false` | ISO/IEC 15693 vicinity cards. |
| `felica.enabled` + `rx/tx` | Felica | `212`,`424` | FeliCa. |
| `iclass.enabled` | iClass | `true`/`false` | HID iCLASS credentials. |
| `emdSuppression` | EMD Suppression | `true`/`false` | Filters spurious detections; recommended `true`. |
| `sleepModeCardDetection` | Sleep Mode Card Detection | `true`/`false` | Card detection during low-power sleep. |
| `sleepModePollingFrequency` | Sleep Mode Polling Frequency | `41Hz` `20Hz` `10Hz` `5Hz` `2.5Hz` `1.3Hz` `0.7Hz` `0.3Hz` `0.15Hz` `0.08Hz` | Sleep polling rate (Workbench shows e.g. `0.7Hz (1.4s)`). |
| `pollingSearchOrder` | Polling Search Order | up to 5 of `iso14443a` `iso14443b` `iso15693` `iclass` `felica` `none` | Technology search order; put the production card technology first. |

<details>
<summary><b>Under the hood: APDU map</b></summary>

All settings use HID proprietary TLV escape APDUs (`FF 70 07 6B …`) sent via `SCardControl`
with IOCTL `0x3136B0` in PC/SC **DIRECT** mode (no card required):

| Item | Tech tag | Sub-tag |
|---|---|---|
| ISO14443A enable / baud / key cache / MIFARE preferred | `A2` | `80` / `81` / `83` / `84` |
| ISO14443B enable / baud | `A3` | `80` / `81` |
| ISO15693 enable | `A4` | `80` |
| FeliCa enable / baud | `A5` | `80` / `81` |
| iCLASS enable | `A6` | `83` |
| EMD / polling order / sleep freq / sleep detection | `A0` | `87` / `89` / `8D` / `8E` |
| Serial / product name / firmware | `A0` | `92` / `82` / `85` |
| Apply settings / reboot device | `A9` | `80` / `83` |

Baud byte: `rxNibble << 4 | txNibble`; bits `212=1`, `424=2`, `848=4` (106 implicit).
Get responses: `BD 03 <sub> 01 <val> 90 00`; polling order: `BD 07 89 05 <5B> 90 00`.
Reference: `ContactlessSlotConfiguration.cs`, `ReaderCapabilities.cs` in HID's sample repo.
</details>

---

## Mass provisioning: `Batch-Omnikey5022-Provision.ps1`

Designed for an operator with a **powered** USB hub:

```powershell
.\Batch-Omnikey5022-Provision.ps1 -ProfilePath .\profiles\my-profile.json -LogCsv .\prov.csv -Lang pl
```

1. Plug a batch (8–10 readers) into the hub — the script detects it automatically
   (reader count stable for `-StableSec`, default 4 s).
2. Each unit: read **serial / product name / firmware** → check **all** profile parameters →
   already compliant? `PASS` without touching it → otherwise apply everything, `Apply`, reboot.
3. Post-reboot verification is **matched by serial number** (USB indices may shuffle).
4. Double beep = batch OK, low beep = at least one FAIL. Unplug, plug the next batch. `Ctrl+C` ends.

### CSV audit trail

```
timestamp;serial;product_name;firmware;inventory_number;result;detail
2026-09-14T10:32:11;EXAMPLE0001;OMNIKEY 5022;2.0.0;;PASS;configured and verified
2026-09-14T10:33:05;EXAMPLE0002;OMNIKEY 5022;2.0.0;;PASS;already compliant
```

- `inventory_number` is left **empty for the customer** to fill in (e.g. Excel), or pre-filled
  via `-InventoryMap map.csv` (columns `serial;inventory_number`).
- The CSV is also the **resume state**: units logged `PASS` are skipped in later sessions
  (re-checked, not re-written). Start a fresh CSV when you change the profile —
  `PASS` means *compliant with the entire profile*.

### Failure diagnostics

A failed post-reboot verification logs a trace:

```
verify failed: scans:30 maxReaders:1 serialsSeen:[EXAMPLE0001] errors:[escape:0x80100017] ctxResets:2
```

- `maxReaders:0` → the unit never re-enumerated: check **hub power**, raise `-RebootWait`.
- `errors:[connect/escape:0x…]` → the unit came back but PC/SC access failed; the code points
  at driver vs timing.

---

## Recommended workflow (golden unit)

```powershell
# 1. Configure ONE reference reader (Workbench or Tool -Mode Set)
# 2. Snapshot it:
.\CheckProfile5022.ps1 -Mode Export -OutProfile .\profiles\my-profile.json
# 3. Self-test the chain (must be all-PASS):
.\CheckProfile5022.ps1 -Mode Verify -Profile .\profiles\my-profile.json
# 4. Card sanity check on the reference unit:
.\CheckProfile5022.ps1 -Mode TestCard
# 5. Run the series:
.\Batch-Omnikey5022-Provision.ps1 -ProfilePath .\profiles\my-profile.json -LogCsv .\prov.csv
# 6. Spot-check configured units with Verify / TestCard (e.g. 1 in 50).
```

Throughput note: with a 10-port powered hub, expect ~2.5–3 min per batch including handling —
roughly 200–300 units per hour of operator time on one station; physical packing dominates.

## Exit codes

| Code | Meaning |
|---|---|
| `0` | OK / audit or card-test PASS (`TestCard -Loop` always exits 0; summary on console) |
| `1` | Execution error (connection, profile, write failure, card timeout) |
| `2` | Verify / TestCard FAIL |

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Cannot connect in DIRECT mode` | Another app holds the reader — close **Workbench**. |
| `SCardControl 0x80100016 / escape errors` | Microsoft CCID driver without escape enabled → install the HID driver or set `EscapeCommandEnable=1` and replug. |
| Unit configured but reported FAIL after reboot | Fixed in current versions: Windows stops the Smart Card service when the last reader disappears (`SCARD_E_NO_SERVICE`); the tools now auto-recover the PC/SC context. If it persists: powered hub, `-RebootWait 15`. |
| `Add-Type: type WinSCard already exists` | Fixed: each script uses its own namespace (`OmniTool`/`OmniBatch`) with an idempotent guard. If you modify the P/Invoke signatures, **rename the namespace** — .NET types cannot be unloaded from a live session. |
| Card shows as CPU although it "is MIFARE" | Dual-interface card + `mifarePreferred` disabled → enable and retest (`TestCard` prints this hint itself). |
| Auth test fails on customer cards | Expected: production cards don't use transport keys; it does not indicate a misconfigured reader. |

## Testing

The `tests/` folder holds a [Pester 5](https://pester.dev) suite that runs **without a reader,
a card or the Smart Card service**: every reader exchange goes through a mocked `Send-Escape`,
and the expected APDUs are written out by hand from the protocol notes, not taken from the scripts.

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -MaximumVersion 5.99.99 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester ./tests -Output Detailed
```

Works on Windows PowerShell 5.1 and PowerShell 7. What is covered:

- **Profile → operations** (`Build-Ops`): every key type (bool / baud / sleep frequency /
  polling order), partial profiles, errors for unknown frequency or technology names
- **Parsers**: `Parse-Bool`, `Parse-Byte`, `Parse-Ascii` (serial / product name TLV), firmware,
  baud-byte encoding (106 kbps implicit), card-type classification from the ATR (`TestCard`)
- **Op engine**: the exact SET APDUs for `profiles/example-profile.json`, checks never write
- **Regressions** for the pitfalls below: ops stay data-only (no closures); `Apply-All`
  returns `@{errors=@()}` on success, never `$null`, and sends no Apply/Reboot after a failed write
- **Repo guards**: CLI parameters unchanged, P/Invoke signatures tied to their namespace,
  EN/PL message keys in sync, LF line endings

Both scripts can be dot-sourced (`. .\CheckProfile5022.ps1`) to load their functions without
touching PC/SC. Run them as usual (`.\CheckProfile5022.ps1 …`) for real work.

## Development notes

- PowerShell pitfalls this codebase already paid for — keep them in mind when contributing:
  script functions are **not visible inside `GetNewClosure()` scriptblocks** (ops engine is
  data-only for this reason), and **empty arrays unroll to `$null`** across function boundaries
  (multi-value results are returned as hashtables).
- Windows-only (winscard P/Invoke). A Linux port would target `pcscd` + pyscard —
  all APDUs in this README apply unchanged.

## Trademark & legal notice

- This is an **independent, community-made tool**. It is **not** a product of, affiliated with,
  sponsored or endorsed by **HID Global Corporation** or **ASSA ABLOY AB**.
- **HID®, OMNIKEY® and the HID Brick logo** are trademarks or registered trademarks of
  HID Global / ASSA ABLOY AB. They are used here solely to identify hardware compatibility
  (nominative use); no affiliation is implied.
- The proprietary APDU commands used by this toolkit are taken exclusively from **information
  HID Global has published themselves** in their public sample code repository
  ([hidglobal/HID-OMNIKEY-Sample-Codes](https://github.com/hidglobal/HID-OMNIKEY-Sample-Codes)).
  No reverse engineering of drivers or firmware was performed, and no HID documentation is
  reproduced in this repository — for official documentation and screenshots, see
  [hidglobal.com](https://www.hidglobal.com).
- The **official configuration tool** for OMNIKEY readers is HID's *OMNIKEY Workbench Tool*.
  If you need vendor support or warranty coverage, use official HID channels — and report
  issues with **this** toolkit here, in this repository's issue tracker, never to HID support.
- Provided *as is*, without warranty of any kind. You are responsible for validating the
  configuration on your hardware before any production rollout.

## License

MIT — see [LICENSE](LICENSE).
