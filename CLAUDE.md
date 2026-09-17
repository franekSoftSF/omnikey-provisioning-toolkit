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
Od v1.2 cała logika jest w module `OmnikeyToolkit/` (psd1 + psm1; komponenty = pliki .ps1 w
kolejności z `$ComponentFiles` w psm1: Messages, Native, Transport, Apdu, Models, Profile, Engine,
Card, Batch, Cli, Configure + Public: `Invoke-OmnikeyCli`, `Invoke-OmnikeyTool`, `Invoke-OmnikeyBatch`).
Tylko `Private/Transport.ps1` woła winscard (za funkcjami `Invoke-Native*` — mockowalne).
Skrypty w roocie to cienkie wrappery (param → Import-Module -Force → funkcja → `exit $code`;
pilnuje tego tests/Repo.Tests.ps1):
- `Omnikey.ps1` — jeden punkt wejścia: `get|set|verify|export|testcard|batch|readers|configure`, bez
  komendy = menu. Bez `-ReaderMatch` bierze jedyny czytnik OMNIKEY (kilka ⇒ w menu wybór numeru,
  z linii poleceń błąd z listą — skrypt nigdy nie zgaduje);
  `-ReaderMatch <model>` (np. 3121) mapuje na nazwę PC/SC z rejestru. Parametr spoza komendy = błąd.
- Menu (`Omnikey.ps1` bez komendy) wraca po każdej akcji; błąd akcji = czerwony komunikat i dalej
  menu; `0` = wyjście. Pozycja 8 / komenda `configure` (Private/Configure.ps1): pytania tylko o klucze
  modelu, domyślnie obecna wartość (Enter), podsumowanie zmian, opcjonalny zapis profilu, zapis do
  czytnika TYLKO zmienionych kluczy przez `Invoke-OmnikeyTool -Mode Set` (temp JSON). Odpowiedzi
  zwracane jako `@{value}` (lekcja 2: puste listy). Get/Export: wartości na zielono (`Write-ConfigLine`).
- `Private/Models.ps1` — rejestr modeli (dane): product name z A0 82 → klucze profilu, `verified`,
  `emvcoVoltage`. 5022 (contactless, verified), 3121 (contact, verified), 5422/5122 (wg OK5422.cs,
  NIEzweryfikowane). Nieznany model: tylko odczyt, zapis zablokowany (Set/Batch).
- Walidacja profilu (Profile.ps1): nieznane klucze (poza `_*`), typy, baud, napięcia, klucze
  nieobsługiwane przez model ⇒ throw z komunikatem EN/PL przed jakimkolwiek zapisem.
- `CheckProfile5022.ps1` — narzędzie pojedynczej sztuki (wrapper, CLI z v1.0). Tryby:
  `Get` (dump), `Set -Profile` (zapis + Apply + reboot; `-NoReboot`), `Verify -Profile`
  (audyt, exit 0/2), `Export -OutProfile` (snapshot czytnika → profil JSON zgodny z Batch),
  `TestCard` (ATR/UID, identyfikacja typu karty, werdykt MIFARE Classic; `-Loop` = stos kart,
  beepy, podsumowanie). Wspólne: `-Lang en|pl`, `-ReaderMatch` (regex, default "5022").
- `Batch-Omnikey5022-Provision.ps1` (v10, wrapper) — stacja wsadowa na zasilanym hubie USB:
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
- Capabilities (A0, ReaderCapabilities.cs): platform 83 (`AViatoR`), contact slots 8B,
  contactless slots 8C, fw label 96.
- Gniazdo stykowe (ContactSlotConfiguration.cs), kontener A3: GET `FF70076B0AA208A006A304A002 <SS> 0000`,
  SET `FF70076B0BA209A107A305A003 <SS> 01 <val> 00`; SS: 82 voltage sequence
  (`first | second<<2 | third<<4`, 5V=3 3V=2 1.8V=1, 00=auto), 83 operating mode (00 ISO7816,
  01 EMVCo), 85 enable. Na 5022 te GET dają `9E0200039000`.

Zweryfikowane na sprzęcie 2026-09-17:
- OMNIKEY 5022 (fw 2.0.0): product `OMNIKEY 5022`, 0 contact / 1 contactless slot. Wyjście
  Get/Verify/Set modułu = v1.0 (fixtures w tests/fixtures, serial zamaskowany).
- OMNIKEY 3121 (fw 1.6.0, USB 076B:3031, nazwa PC/SC "HID Global OMNIKEY 3x21 Smart Card Reader 0"):
  product `OMNIKEY 3121`, platform AViatoR, 1 contact / 0 contactless slot, **serial pusty**
  (`BD0292009000`; atrybut PC/SC też "?"). Contact slot GET/SET + Apply + Reboot działa
  (EMVCo, sekwencja 1.8V,3V,5V = 0x39, `auto` = 0x00 i przywrócenie 0x1B zweryfikowane w ISO 7816).
  **W trybie EMVCo 3121 raportuje voltage sequence `03` (tylko 5V)**; zapisana sekwencja wraca po
  przełączeniu na ISO 7816 (bez ponownego zapisu). Wcześniejszy wniosek "auto nie jest trzymane" był
  BŁĘDNY (test łączył EMVCo + auto). W rejestrze `emvcoVoltage='5V'` ⇒ profil emvco + inna sekwencja
  = błąd walidacji; `configure` pomija pytanie o napięcia po wyborze EMVCo.
  Contactless GET na 3121 zwracają częściowo błędy `9E02...`, częściowo przypadkowe wartości —
  dlatego decyduje rejestr modeli, nie odpowiedzi czytnika.
- HID Global "Crescendo NFC Reader" (USB-C, USB 076B:5521, nazwa PC/SC "HID Global Crescendo NFC
  Reader 0"): urządzenie złożone = czytnik CCID na sterowniku **Microsoft Usbccid (WUDF)** + port
  szeregowy USB (COM, nie ruszać). NIE ma go w HID-OMNIKEY-Sample-Codes. Każdy escape (A0 80..96,
  A2/A3/A6...) ⇒ `SCardControl` rc `0x00000001` (sterownik MS bez `EscapeCommandEnable=1`), więc nie
  wiadomo, czy mówi AViatoR TLV. Atrybuty PC/SC działają (vendor "HID Global", type "Crescendo NFC
  Reader", serial jest). `readers` go wypisuje, ale komendy konfiguracyjne idą tylko do nazw z "OMNIKEY".
  Włączenie escape w rejestrze = zmiana systemu po stronie użytkownika; potem ponowna sonda GET-only.

## Twarde lekcje (naruszenie któregoś = regresja, którą już raz naprawialiśmy)
1. PowerShell closures (`GetNewClosure()`) NIE widzą funkcji skryptu → silnik operacji jest
   DANOWY: `ConvertTo-OperationList` (dawniej `Build-Ops`) produkuje hashtabele
   `{kind: bool|baud|freq|poll|mode|volt, ...}`, wykonują je `Invoke-OpApply`/`Invoke-OpCheck`.
   Nie wracać do scriptblocków. W module dodatkowo: scriptblock utworzony POZA modułem nie widzi
   prywatnych funkcji modułu → bloki dla `Invoke-WithReader` definiujemy tylko wewnątrz modułu.
2. Pusta tablica zwrócona z funkcji rozwija się do `$null` przez granice funkcji → wyniki
   wielowartościowe ZAWSZE jako hashtable (np. `Invoke-OpApplyAll`, dawniej `Apply-All` →
   `@{errors=@()}`); listy zwracane jako `,@(...)` — i NIE owijać ich ponownie w `@(...)` przy
   odbiorze (`@(Get-ReaderList)` = tablica z jedną tablicą w środku).
3. Windows zatrzymuje SCardSvr, gdy znika ostatni czytnik (reboot jedynej sztuki!) →
   `SCARD_E_NO_SERVICE 0x8010001D` unieważnia kontekst; wzorzec Initialize-/Reset-Context
   z auto-odtwarzaniem w `Get-ReaderList`/`Invoke-WithReader` (Transport.ps1) jest obowiązkowy.
4. `Add-Type` nie redefiniuje typów w sesji → namespace C# z guardem `-as [type]`. Moduł używa
   `OmniTool` (sygnatury bajt w bajt jak w v1.0 CheckProfile5022.ps1); `OmniBatch` wycofany,
   nazwa zarezerwowana; historia hashy: `$PInvokeHistory` w tests/Repo.Tests.ps1.
   **Zmiana sygnatur P/Invoke ⇒ zmiana nazwy namespace** (typów .NET nie da się wyładować).
5. Sterowniki: HID OMNIKEY CCID (v2.3.4+) = escape działa od razu; Microsoft CCID wymaga
   `EscapeCommandEnable=1` + replug. Workbench otwarty = DIRECT connect fail.
6. Repo: LF wszędzie (`.gitattributes`: `* text=auto eol=lf`), i18n przez słownik `$MSG.en/.pl`
   + `T key args` (Private/Messages.ps1), exit codes 0/1/2, CSV `;`-separated UTF-8.
   W stringach PowerShell cudzysłów to `""` albo backtick — NIE `\"`.

## Stan i proces release
v1.0.0 opublikowane, v1.1.0-rc1 prerelease. Release = ZIP runtime-only (`Omnikey.ps1`,
`CheckProfile5022.ps1`, Batch, `OmnikeyToolkit/`, profiles/, README, LICENSE — bez
.gitattributes/.gitignore/docs/tests) + `SHA256SUMS.txt`;
`gh release create vX.Y.Z <zip> SHA256SUMS.txt --title "..." --notes-file release-notes.md`
(jedna linia, notes zawsze z pliku). Nazwa ZIP i katalogu w środku = `<repo>-vX.Y.Z`.
Od v1.1.0 automatycznie: push taga `v*` → `.github/workflows/release.yml` (najpierw CI) buduje
ZIP + SHA256SUMS i robi `gh release create`. Notes: `docs/release-notes/<tag>.md` albo wersji
bazowej (`v1.1.0-rc1` → `v1.1.0.md`), pierwszy nagłówek `# ` = tytuł; tag z sufiksem = prerelease.
Lista plików ZIP: `RELEASE_FILES` w release.yml (pilnuje test w Repo.Tests.ps1). Release sprawdza,
że `ModuleVersion` w OmnikeyToolkit.psd1 = wersja z taga bez sufiksu.
Screenshot README: `docs/img/CheckProfile5022.png` (seriale zamaskowane; obowiązuje
dla każdego przyszłego obrazka).

## Backlog (kolejność ustalona 2026-09-16)
1. [x] Testy Pester (`tests/`, Pester 5, PS 5.1 + 7; skipped = walidacja do zrobienia w 3): `Build-Ops` (profil→ops), parsery (`Parse-Bool/Byte/Ascii`, baud, ATR),
   regresje na lekcje 1–2. Mockować Send-Escape. Testy charakteryzacyjne — siatka pod refaktor (3).
2. [x] GitHub Actions (`ci.yml`, `release.yml`): PSScriptAnalyzer na push/PR + workflow release-on-tag (ZIP+SHA+release).
3. [x] Refaktor na moduły PowerShell (v1.2.0): transport PC/SC, rejestr modeli z auto-detekcją,
   silnik profili, karty, batch; walidacja profilu; `Omnikey.ps1` + menu; OMNIKEY 3121 (contact
   slot, zweryfikowane na sprzęcie). `CheckProfile5022.ps1` i Batch = cienkie wrappery, CLI bez zmian.
4. [ ] `-WhatIf`/dry-run w Set i Batch (sama faza check, zero zapisu) — w module;
   `Invoke-OpCheckAll` zwraca już `diff` (name/want/have).
5. [ ] OMNIKEY 5023 w rejestrze modeli (EKSPERYMENTALNE do testu na sprzęcie; auto-detekcja jest).
   Wg `OK5023.cs` w repo HID: te same klasy konfiguracji co 5022, ale BEZ
   `sleepModePollingFrequency`/`sleepModeCardDetection`; ma Secure Processor (SAM secure session).
6. [ ] Kreator profilu z kart: skan próbek kart klienta → minimalna konfiguracja (tylko potrzebne
   technologie) + zawsze pytanie o FIDO. Rozpoznanie CPU (DESFire EV3/FIDO) wymaga komend
   poza ATR — decyzja o źródle APDU (NXP) otwarta. Konfiguracja czytnika NIE daje "tylko
   odczytu" karty — to prawa dostępu na karcie + brak kluczy w czytniku.
7. [ ] TestCard `-Loop`: opcjonalny CSV per karta (uid;type;verdict).
7a. [ ] Batch dla czytników bez numeru seryjnego (OMNIKEY 3121): dziś FAIL `read error
   (no-serial:OMNIKEY 3121)` — potrzebny tryb po jednej sztuce albo inna identyfikacja.
7b. [ ] Weryfikacja 5422/5122 na sprzęcie (dziś wg OK5422.cs, oznaczone jako eksperymentalne).
7c. [ ] HID Crescendo NFC Reader (076B:5521): po włączeniu `EscapeCommandEnable=1` przez użytkownika
   sonda GET-only. Odpowie jak AViatoR ⇒ wpis w rejestrze (najpierw odczyt, zapis po teście na
   sprzęcie). Nie odpowie ⇒ konfiguracja innym kanałem (np. port COM) = poza regułą źródła APDU,
   wymaga decyzji właściciela.
8. [ ] Wsparcie OMNIKEY 5x27 (5127/5427) — UWAGA: inny mechanizm (EEM web serwer/TFTP,
   192.168.63.99), osobny skrypt obok, nie rozszerzenie obecnych.
9. [ ] Ewentualny port pyscard/Python (Linux) — APDU bez zmian.

## Konwencje pracy
Kod i README po angielsku; komunikaty runtime EN/PL. Commity: prefiksy `docs:`, `fix:`,
`feat:`, `test:`, `ci:`. Żadnych danych klienta w repo (seriale, liczby sztuk, nazwy) — .gitignore blokuje
`*.csv` i profile produkcyjne; to jest wymóg, nie sugestia.
