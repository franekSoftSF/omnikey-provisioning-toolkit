# CLAUDE.md — OMNIKEY Provisioning Toolkit (project brief)

Repo: https://github.com/franekSoftSF/omnikey-provisioning-toolkit — public, MIT, v1.0.0 released.
Niezależne narzędzie (NIE produkt HID/ASSA ABLOY); APDU wyłącznie z publicznego repo
`hidglobal/HID-OMNIKEY-Sample-Codes`. Sekcja "Trademark & legal notice" w README jest wiążąca —
nie osłabiać, nie dodawać materiałów HID (screeny Workbencha, fragmenty PDF) do repo.

## Cel i kontekst
Masowa, skryptowa konfiguracja czytników HID OMNIKEY 5022 (rodzina AViatoR; protokół wspólny
z 5122/5422 contactless) bez GUI Workbencha. Powstało przy wdrożeniu bankowym z dużą serią
sztuk; kluczowe ustawienie: `mifarePreferred` (karty dual-interface z emulacją MIFARE Classic
prezentowane jako Classic zamiast CPU). Publicznie NIE podajemy liczby sztuk ani klienta
("a large fleet", "banking-sector customer").

## Komponenty
- `CheckProfile5022.ps1` — narzędzie pojedynczej sztuki. Tryby:
  `Get` (dump), `Set -Profile` (zapis + Apply + reboot; `-NoReboot`), `Verify -Profile`
  (audyt, exit 0/2), `Export -OutProfile` (snapshot czytnika → profil JSON zgodny z Batch),
  `TestCard` (ATR/UID, identyfikacja typu karty, werdykt MIFARE Classic; `-Loop` = stos kart,
  beepy, podsumowanie). Wspólne: `-Lang en|pl`, `-ReaderMatch` (regex, default "5022").
- `Batch-Omnikey5022-Provision.ps1` (v9) — stacja wsadowa na zasilanym hubie USB:
  auto-detekcja partii (liczba czytników stabilna `-StableSec`), pełny Check→Apply→Reboot→
  Verify per sztuka, dopasowanie po NUMERZE SERYJNYM (indeksy USB się tasują),
  CSV: `timestamp;serial;product_name;firmware;inventory_number;result;detail`
  (`inventory_number` puste dla klienta lub z `-InventoryMap` serial;inventory_number),
  wznawialny po CSV (PASS = zgodny z CAŁYM profilem — zmiana profilu ⇒ nowy CSV).
- `profiles/example-profile.json` — schemat profilu; każdy klucz opcjonalny, ustawiane/
  weryfikowane tylko obecne klucze.

## Rdzeń techniczny (nie zgadywać — to jest zweryfikowane na sprzęcie)
Transport: PC/SC DIRECT (bez karty), CCID Escape `SCardControl` IOCTL `0x3136B0`,
czysty P/Invoke na `winscard.dll` (zero zależności). TestCard używa SHARED + `SCardTransmit`.

APDU (TLV HID AViatoR):
- GET: `FF70076B0AA208A006A404 <TT> 02 <SS> 0000` → `BD03 <SS> 01 <val> 9000`
- SET: `FF70076B0BA209A107A405 <TT> 03 <SS> 01 <val> 00`
- TT: A2=14443A, A3=14443B, A4=15693, A5=FeliCa, A6=iCLASS, A0=general
- SS: 80 enable (iCLASS: **83**), 81 baud, 83 keycache(A2), 84 mifarePreferred(A2),
  87 EMD, 8D sleepFreq (0..9 → 41Hz..0.08Hz), 8E sleepDetect
- Polling order: GET `...A404A002890000` → `BD078905 <5B> 9000`;
  SET `FF70076B0FA20DA10BA409A0078905 <5B> 00`; kody: 0=none 1=15693 2=14443A 3=14443B
  4=iclass 6=felica
- Identity (A0): serial 92, product name 82 (TLV ASCII: len w bajcie[3], ASCII od [4]),
  firmware 85 (`BD058503 maj min pat 9000`)
- Apply `FF70076B08A206A104A902800000`, Reboot `...830000`
- Baud byte: `rxNibble<<4 | txNibble`; bity 212=1, 424=2, 848=4; 106 zawsze aktywne
  (w profilu NIE listujemy 106)
- Karty (TestCard): pseudo-ATR PC/SC part 3, RID `A0 00 00 03 06`; kody: 0001/0002 Classic
  1K/4K, 0026 Mini, 0036/0037 Plus SL1 (=Classic verdict YES), 0038/0039 Plus SL2,
  0003/003A UL/UL-C, 0030 Topaz, 000C FeliCa. UID: `FFCA000000`.

## Twarde lekcje (naruszenie któregoś = regresja, którą już raz naprawialiśmy)
1. PowerShell closures (`GetNewClosure()`) NIE widzą funkcji skryptu → silnik operacji jest
   DANOWY: `Build-Ops` produkuje hashtabele `{kind: bool|baud|freq|poll, ...}`, wykonują je
   `Invoke-OpApply`/`Invoke-OpCheck`. Nie wracać do scriptblocków.
2. Pusta tablica zwrócona z funkcji rozwija się do `$null` przez granice funkcji → wyniki
   wielowartościowe ZAWSZE jako hashtable (np. `Apply-All` → `@{errors=@()}`);
   listy zwracane jako `,@(...)` z jawnym `@(...)`.
3. Windows zatrzymuje SCardSvr, gdy znika ostatni czytnik (reboot jedynej sztuki!) →
   `SCARD_E_NO_SERVICE 0x8010001D` unieważnia kontekst; wzorzec Ensure-/Reset-Context
   z auto-odtwarzaniem w Get-Readers/With-Reader jest obowiązkowy.
4. `Add-Type` nie redefiniuje typów w sesji → każdy skrypt ma własny namespace C#
   (`OmniTool`, `OmniBatch`) z guardem `-as [type]`. **Zmiana sygnatur P/Invoke ⇒ zmiana
   nazwy namespace** (typów .NET nie da się wyładować).
5. Sterowniki: HID OMNIKEY CCID (v2.3.4+) = escape działa od razu; Microsoft CCID wymaga
   `EscapeCommandEnable=1` + replug. Workbench otwarty = DIRECT connect fail.
6. Repo: LF wszędzie (`.gitattributes`: `* text=auto eol=lf`), i18n przez słownik `$MSG.en/.pl`
   + `T key args`, exit codes 0/1/2, CSV `;`-separated UTF-8.

## Stan i proces release
v1.0.0 opublikowane. Release = ZIP runtime-only (`CheckProfile5022.ps1`, Batch, profiles/,
README, LICENSE — bez .gitattributes/.gitignore/docs) + `SHA256SUMS.txt`;
`gh release create vX.Y.Z <zip> SHA256SUMS.txt --title "..." --notes-file release-notes.md`
(jedna linia, notes zawsze z pliku). Nazwa ZIP i katalogu w środku = tag.
Screenshot README: `docs/img/CheckProfile5022.png` (seriale zamaskowane; obowiązuje
dla każdego przyszłego obrazka).

## Backlog (kolejność ustalona 2026-09-16)
1. [ ] Testy Pester: `Build-Ops` (profil→ops), parsery (`Parse-Bool/Byte/Ascii`, baud, ATR),
   regresje na lekcje 1–2. Mockować Send-Escape. Testy charakteryzacyjne — siatka pod refaktor (3).
2. [ ] GitHub Actions: PSScriptAnalyzer na push/PR + workflow release-on-tag (ZIP+SHA+release).
3. [ ] Refaktor na moduły PowerShell (transport PC/SC, rejestr modeli, silnik profili, karty,
   batch). `CheckProfile5022.ps1` i Batch zostają jako cienkie wrappery — CLI bez zmian.
   Walidacja wartości profilu (bool/baud/poll) wchodzi tu, raz, w module.
4. [ ] `-WhatIf`/dry-run w Set i Batch (sama faza check, zero zapisu) — w module, po refaktorze.
5. [ ] Auto-detekcja modelu czytnika + OMNIKEY 5023 (EKSPERYMENTALNE do testu na sprzęcie).
   Wg `OK5023.cs` w repo HID: te same klasy konfiguracji co 5022, ale BEZ
   `sleepModePollingFrequency`/`sleepModeCardDetection`; ma Secure Processor (SAM secure session).
6. [ ] Kreator profilu z kart: skan próbek kart klienta → minimalna konfiguracja (tylko potrzebne
   technologie) + zawsze pytanie o FIDO. Rozpoznanie CPU (DESFire EV3/FIDO) wymaga komend
   poza ATR — decyzja o źródle APDU (NXP) otwarta. Konfiguracja czytnika NIE daje "tylko
   odczytu" karty — to prawa dostępu na karcie + brak kluczy w czytniku.
7. [ ] TestCard `-Loop`: opcjonalny CSV per karta (uid;type;verdict).
8. [ ] Wsparcie OMNIKEY 5x27 (5127/5427) — UWAGA: inny mechanizm (EEM web serwer/TFTP,
   192.168.63.99), osobny skrypt obok, nie rozszerzenie obecnych.
9. [ ] Ewentualny port pyscard/Python (Linux) — APDU bez zmian.

## Konwencje pracy
Kod i README po angielsku; komunikaty runtime EN/PL. Commity: prefiksy `docs:`, `fix:`,
`feat:`, `test:`, `ci:`. Żadnych danych klienta w repo (seriale, liczby sztuk, nazwy) — .gitignore blokuje
`*.csv` i profile produkcyjne; to jest wymóg, nie sugestia.
