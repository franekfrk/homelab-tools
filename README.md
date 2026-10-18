# Homelab Tools

Skrypty Bash do monitorowania domowego serwera Linux: bateria, zasilanie, temperatura, dyski SMART, Docker, DNS, Minecraft oraz powiadomienia Discord i opcjonalne pingi Healthchecks.

## Zawartość

| Plik | Rola |
| --- | --- |
| `homelab-checks.sh` | Okresowe kontrole, alerty o awarii i powrocie usług |
| `smart-check.sh` | Odczyt SMART skonfigurowanych dysków |
| `battery-monitor.sh` | Ciągłe monitorowanie baterii, zapis świata i awaryjne wyłączenie |
| `temp-monitor.sh` | Ciągłe monitorowanie temperatury, zapis świata i awaryjne wyłączenie |
| `discord-alert.sh` | Wspólny wysyłacz powiadomień |
| `homelab-common.sh` | Wspólna konfiguracja i funkcje; wymagany obok pozostałych skryptów |
| `systemd/` | Dwie definicje usług pobrane z serwera; lokalnie zmienione na `Restart=on-failure` |
| `cron.example` | Przykład systemowego harmonogramu `/etc/cron.d/` |

## Wymagania

Linux, Bash 4+, systemd, cron, Docker, `timeout`, `flock`, `curl`, Python 3, `dig`, `smartctl` z obsługą JSON (`-j`), `awk`, `df` i standardowe narzędzia systemowe. W kontenerze Minecraft wymagany jest działający `rcon-cli` i skonfigurowany RCON. Hasło RCON pozostaje w konfiguracji kontenera.

Usługi wymagają uprawnień do Dockera i wyłączenia systemu; załączone jednostki działają jako root. Monitory odczytują `/sys/class/power_supply/BAT*` i `/sys/class/thermal/thermal_zone*/temp`. Temperatura jest maksimum ze wszystkich dostępnych stref, niekoniecznie samym CPU. Dostosuj progi do sprzętu.

## Konfiguracja

Skopiuj `homelab-alerts.conf.example` do prywatnego pliku `/etc/homelab-alerts.conf`. Jest to wykonywany kod Bash: właścicielem powinien być root, uprawnienia `600`. Nie wczytuj niezaufanej konfiguracji. Alternatywną ścieżkę wskazuje zmienna `HOMELAB_CONFIG`.

Ustaw:

- `WEBHOOK_URL`: własny webhook Discord; `ENABLED=false` wycisza powiadomienia Discord, a nie ochronę i wyłączenie systemu.
- `HC_URL`: opcjonalny prywatny adres pingowania Healthchecks; pusta wartość wyłącza tę integrację. Ping dotyczy dostępności portu Minecraft, nie ogólnego stanu wszystkich kontroli.
- Nazwy kontenerów, host i port Minecraft, adres serwera DNS i nazwę domeny testowej.
- `SMART_DEVICES`: rzeczywiste dyski, np. `/dev/sda` lub `/dev/nvme0n1`.
- Progi, odstęp pomiarów i limity czasu. Wartości liczbowe zapisuj dziesiętnie, bez zer na początku.

Domyślnie bateria: ostrzeżenie 30%, zapis 25%, wyłączenie 20%. Temperatura: zapis 70°C, ostrzeżenie 75°C, wyłączenie 80°C. Kontrole ciągłe wykonują się co 30 sekund. Flagi powiadomień są przechowywane w `/var/lib/homelab-alerts`.

**Wyłączenie awaryjne zatrzymuje wszystkie uruchomione kontenery Dockera i wyłącza cały komputer.** Przed każdym takim wyłączeniem ponawiany jest zapis Minecraft. Nieudany zapis lub zatrzymanie kontenerów nie blokują awaryjnego wyłączenia. Zatrzymanie kontenerów ma łączny limit czasu `DOCKER_TIMEOUT`; dostosuj go do liczby i czasu zamykania usług.

## Instalacja na docelowym serwerze

Poniższe polecenia są instrukcją wdrożenia. Przy przygotowaniu tego projektu nie zostały wykonane na serwerze.

```bash
sudo install -m 755 ./*.sh /usr/local/bin/
sudo install -m 600 homelab-alerts.conf.example /etc/homelab-alerts.conf
sudoedit /etc/homelab-alerts.conf
sudo install -m 644 systemd/*.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now battery-monitor.service temp-monitor.service
```

Przy aktualizacji zachowaj istniejącą prywatną konfigurację zamiast nadpisywać ją przykładem. Na komputerze bez baterii nie włączaj `battery-monitor.service`; dostosuj też listę usług kontrolowanych przez `homelab-checks.sh`.

Po konfiguracji można zainstalować harmonogram:

```bash
sudo install -m 644 cron.example /etc/cron.d/homelab-tools
```

Nie dodawaj równolegle tych samych zadań do crontaba roota i `/etc/cron.d/`. Przykład `/etc/cron.d/` zawiera kolumnę użytkownika `root`; przy edycji przez `sudo crontab -e` należy ją pominąć.

## Ustalony harmonogram źródłowy

Zgodnie z przekazanym przez właściciela crontabem roota:

- `homelab-checks.sh`: co 5 minut;
- `smart-check.sh`: codziennie o 06:00;
- backup: codziennie o 03:00, poprzedzony próbą `save-all flush`.

Wiersz backupu został przekazany w postaci uciętej. Nie odtwarzano komendy archiwizacji ani prywatnych ścieżek. `cron.example` obejmuje wyłącznie dwa kompletne zadania monitoringu. Strefa czasowa zadań zależy od konfiguracji serwera. Bezpośredni odczyt crona roota przez SSH wymagał hasła sudo; harmonogram pochodzi z wiadomości właściciela.

## Zachowanie alertów i ograniczenia

Alerty okresowe zapisują stan dopiero po pomyślnym zakończeniu wysyłacza; błędy sieci i HTTP powodują kolejną próbę przy następnym uruchomieniu. Wyłączenie Discorda jest traktowane jako świadome pominięcie wysyłki. Ponowne włączenie nie odtwarza wyciszonych zdarzeń. SMART raportuje problem przy każdym zaplanowanym odczycie, także brak dysku, niepoprawny JSON lub błąd narzędzia.

Test Minecraft sprawdza jedynie połączenie TCP. DNS wymaga statusu `NOERROR` i rekordu A. Brak kontenera oraz niedostępny Docker są zgłaszane. Nakładające się uruchomienia kontroli blokuje `flock`. Błędy i diagnostyka trafiają na stderr; monitory można sprawdzać przez `journalctl -u battery-monitor -u temp-monitor`.

## Sprawdzenie lokalne

```bash
for script in ./*.sh; do bash -n "$script" || exit 1; done
python3 -m unittest discover -s tests -v
```

Testy korzystają z atrap poleceń, plików czujników i tymczasowej konfiguracji. Sprawdzają JSON i błędy Discorda, ponawianie alertów, brak kontenera, błędną odpowiedź DNS, błędy SMART, ponawianie zapisu i awaryjne wyłączenie. Nie kontaktują się z serwerem ani nie wyłączają komputera. Nie zastępują testu działania na docelowym sprzęcie.

## Prywatne dane

Projekt zawiera tylko neutralną konfigurację przykładową. Usunięto prywatny adres Healthchecks. Nie pobierano prywatnego `/etc/homelab-alerts.conf` ani webhooka Discord. `.gitignore` pomija lokalną konfigurację, pliki środowiskowe, logi i klucze. Nigdy nie dodawaj webhooków, adresów pingowania ani haseł do repozytorium.
