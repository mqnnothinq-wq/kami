# 09 — Komut başvurusu

`mc`, bu deponun yönetim aracıdır: `/usr/local/bin/mc` → `/opt/minecraft/kami/scripts/mc`
(install.sh kurar). Tüm komutları **`sudo` ile** çalıştırın; `mc status` ve `mc help` dışındaki
komutların çoğu root ister (sunucu dosyaları, gizli değerler, systemd).

`<sunucu>`: `config/servers/` altındaki bir ad (`velocity`, `limbo`, `lobby`, `survival` ve
`mc new-server` ile eklenenler) ya da `all`.

## Özet

| Komut | Ne yapar |
|---|---|
| `mc download [--dry-run] [all\|core\|plugins] [sunucu]` | Paper/Velocity jar'larını, PicoLimbo'yu ve eklentileri indirir, doğrular |
| `mc apply [--dry-run] [sunucu\|all]` | `config/` ağacını sunucu dizinlerine uygular; `jvm.env` ve systemd eklerini üretir |
| `mc init <sunucu\|all> --accept-eula` | İlk kurulum: EULA, ayarlar, ilk açılış, ayarları yeniden uygulama, init komutları |
| `mc new-server <ad> <port> <heap> [--from <kaynak>]` | Yeni bir Paper sunucusu tanımlar (yalnız `config/`'i değiştirir) |
| `mc build-librelogin [--commit <sha>] [--keep-jdk] [--dry-run]` | LibreLogin'i sabit commit'ten derler → `/opt/minecraft/artifacts/` |
| `mc start [sunucu\|all]` | Başlatır (`all`: önce limbo/lobby/survival…, en son velocity) |
| `mc stop [sunucu\|all]` | Durdurur (`all`: önce velocity, sonra diğerleri) |
| `mc restart [sunucu\|all]` | Durdurup başlatır |
| `mc status [sunucu\|all]` | Durum tablosu: tür, port, durum, bellek (RSS), heap |
| `mc log <sunucu> [journalctl seçenekleri]` | Canlı günlük (Ctrl+C ile çıkılır). `mc logs` da olur |
| `mc cmd <sunucu> <komut...>` | Sunucu konsoluna komut yazar (Velocity dahil); yanıt günlükte |
| `mc rcon <sunucu> <komut...>` | RCON ile çalıştırır ve yanıtı basar (yalnız Paper) |
| `mc say <mesaj...>` | Çalışan tüm Paper sunucularına duyuru |
| `mc countdown-restart [dakika]` | Geri sayımlı yeniden başlatma (varsayılan 5 dk) |
| `mc backup [sunucu\|all]` | restic yedeği |
| `mc backup list [sunucu]` | Anlık görüntüleri listeler |
| `mc backup prune` | Eski yedekleri ve eski günlükleri siler |
| `mc restore <sunucu> <snapshot>` | Yedekten geri yükler (`EVET` onayı ister) |
| `mc doctor` | Salt-okunur sağlık denetimi |
| `mc help` | Yardım |

## Kurulum ve yapılandırma

### mc download

```bash
sudo mc download                      # her şey, tüm sunucular (varsayılan: all all)
sudo mc download core                 # yalnız sunucu jar'ları / PicoLimbo
sudo mc download plugins velocity     # yalnız Velocity eklentileri
sudo mc download all skyblock         # tek sunucu
sudo mc download --dry-run            # hiçbir şey indirmeden ne yapılacağını göster
```

- **core:** Paper → `PAPER_MC_VERSION`'ın en yeni `STABLE` build'i; Velocity → `VELOCITY_VERSION`
  (`latest` = SNAPSHOT olmayan en yeni); ikisi de PaperMC Fill v3 API'sinden, SHA-256 doğrulamalı.
  Limbo → `PICOLIMBO_VERSION` GitHub sürümü. Sunucu dosyası zaten varsa yenisi `server.jar.new` /
  `pico_limbo.new` olarak bekler ve bir sonraki başlatmada devreye girer.
- **plugins:** `config/plugins.list` ([docs/06](06-eklentiler.md#pluginslist-nasıl-çalışır)).
  Sunucu hiç başlamadıysa `plugins/`'e, başladıysa `plugins/update/`'e iner.
- Aynı sürüm zaten kuruluysa atlanır. Bir öğe başarısız olursa diğerlerine devam edilir, sonda
  özet tablo basılır ve komut **1** ile çıkar.
- GitHub API sınırına takılırsanız bir jetonla çalıştırın. Jetonu komut satırına yazmayın
  (`sudo GITHUB_TOKEN=… mc download` jetonu `ps` çıktısına ve kabuk geçmişine koyar):

  ```bash
  read -rs GITHUB_TOKEN && export GITHUB_TOKEN     # jetonu yapıştırın, Enter (ekranda görünmez)
  sudo --preserve-env=GITHUB_TOKEN mc download
  unset GITHUB_TOKEN
  ```

### mc apply

```bash
sudo mc apply                  # tüm sunucular
sudo mc apply survival
sudo mc apply --dry-run lobby  # farkları gösterir (gizli değerler maskelenir), hiçbir şey yazmaz
```

`config/servers/<sunucu>/files/<yol>` → `/opt/minecraft/servers/<sunucu>/<yol>`:

| Dosya türü | Davranış |
|---|---|
| `*.properties` | Anahtar birleştirme: depodaki anahtarlar yazılır/eklenir, diğer satırlar korunur |
| `*.yml`, `*.yaml` | Hedef varsa yq ile derin birleştirme (depodaki anahtarlar kazanır, diziler bütünüyle değişir). Hedef yoksa kopyalanır; ama `plugins/` altındaysa **atlanır** ("eklenti henüz config üretmedi" uyarısı) |
| Diğer (`*.toml`, `*.conf`, `*.txt`…) | Dosyanın tamamı depodan gelir |

Önce dosyalardaki `@@DEĞİŞKEN@@` yer tutucuları doldurulur (sıra: `server.env` →
`/etc/minecraft/secrets.env` → `network.env`; `@@SERVER_NAME@@` = sunucu adı). Tanımsız bir yer
tutucu ya da bozuk YAML varsa **hiçbir dosya yazılmaz**. Ayrıca üretilenler:

- `/opt/minecraft/servers/<sunucu>/jvm.env` — `JAVA_MEM`, `JAVA_OPTS`, `SERVER_ARGS`
- `/etc/systemd/system/mc@<sunucu>.service.d/20-resources.conf` — `CPUWeight`, `OOMScoreAdjust`
- velocity için `10-order.conf` (kapanışta önce proxy dursun), limbo için `30-exec.conf`
  (PicoLimbo'yu çalıştıran `ExecStart`)

Çalışan bir sunucuya uygulanan değişiklikler **yeniden başlatınca** geçerli olur
(`sudo mc restart <sunucu>`).

### mc init

```bash
sudo mc init all --accept-eula
sudo mc init skyblock --accept-eula
```

`--accept-eula` yoksa Minecraft EULA bağlantısını (https://aka.ms/MinecraftEULA) gösterip çıkar.
Sunucu dosyası yoksa ("önce 'mc download' çalıştırın") ya da sunucu çalışıyorsa başlamaz.

| Tür | Adımlar |
|---|---|
| paper | `eula.txt` → apply → ilk açılış (hazır satırı beklenir) → durdur → apply → ikinci açılış → `init-commands.txt` satırları RCON ile → durdur |
| velocity | apply → ilk açılış → durdur → apply |
| limbo | apply → açılış, `127.0.0.1:<port>` dinleniyor mu (dış arayüzde dinliyorsa hata) → durdur |

- `all`: önce limbo/lobby/survival (ve diğer Paper sunucuları), en son velocity.
- Hazır satırı için en çok 10 dakika beklenir (`MC_READY_TIMEOUT`); sunucu çökerse günlüğün son
  satırları basılır.
- `gamerule minecraft:<ad> …` satırı hata yanıtı alırsa ("Unknown or incomplete command",
  "Incorrect argument", "Unknown game rule", `<--[HERE]` ya da RCON hatası) bir kez **öneksiz**
  (`gamerule <ad> …`) denenir; hangi biçimin çalıştığı günlüğe yazılır ve yalnız öneksiz çalışan
  kurallar sonda listelenir (`init-commands.txt`'yi buna göre güncelleyin).
- Başarısız init komutları sonda listelenir ve komut 1 ile çıkar; `sudo mc rcon <sunucu>
  "<komut>"` ile elle tamamlayın.

### mc new-server

```bash
sudo mc new-server skyblock 30068 3G
sudo mc new-server minigames 30069 2G --from lobby
```

Ad: küçük harf/rakam/tire, 2–31 karakter. Port 1024–64535, RCON = port + 1000. Heap: `2G`,
`1536M`. Kaynak sunucunun `config/` dizinini kopyalar, `server.env`'i yazar (`CPU_WEIGHT=100`,
`OOM_SCORE_ADJUST=100`), `velocity.toml` `[servers]` tablosuna ekler, port çakışmalarını ve RAM
bütçesini denetler, sonraki adımları yazdırır. Ayrıntı: [docs/07](07-olcekleme.md#yeni-oyun-modu-eklemek-mc-new-server).

### mc build-librelogin

```bash
sudo mc build-librelogin                   # network.env LIBRELOGIN_COMMIT
sudo mc build-librelogin --commit <sha>    # başka commit (network.env ve plugins.list'i de güncelleyin)
sudo mc build-librelogin --keep-jdk        # derleme için kurulan temurin-25-jdk'yı bırak
sudo mc build-librelogin --dry-run         # yalnız ne yapılacağını yazar
# aynı betik: sudo /opt/minecraft/kami/scripts/build-librelogin.sh [seçenekler]
```

`https://github.com/kyngs/LibreLogin` (dal `dev`) deposunu `/var/tmp` altında geçici bir dizine
klonlar, commit'e geçer; JDK 25 `javac` yoksa `temurin-25-jdk`'yı (Adoptium deposu) geçici kurar;
`./gradlew --no-daemon build` komutunu **ayrı `kami-build` sistem kullanıcısıyla** (asla root ya
da `minecraft` değil; install.sh oluşturur, yoksa betik oluşturur) denetim uçbirimi olmadan
çalıştırır; Gradle bitince bu kullanıcının tüm süreçlerini durdurur; sonucu
`/opt/minecraft/artifacts/LibreLogin-<ilk7>.jar` (0644 root) ve `.sha256` olarak koyar, özeti ve
sonraki adımı (`sudo mc download plugins velocity`) yazar.

- `network.env` `LIBRELOGIN_COMMIT` ile `plugins.list`'teki LibreLogin satırı farklı jar'ları
  gösteriyorsa derlemeye başlamadan **hata** verir. `--commit` ile verilen commit'te yalnız uyarır
  (o jar'ı `mc download` kurmaz; iki satırı birlikte güncelleyin). LibreLogin `local` satırı hiç
  yoksa uyarır.
- `kami-build`'in çalışan bir süreci varsa derlemeyi reddeder; geçici dizin noexec bağlıysa
  anlaşılır bir hatayla durur (`sudo env TMPDIR=<çalıştırılabilir dizin> mc build-librelogin`).
- Ağ/derleme hatasında Türkçe bir mesajla durur; aynı anda yalnız bir derleme çalışır. Kurduğu
  JDK'yı (başarısız derlemede de) kaldırır ve `/usr/bin/java` seçimi değiştiyse eskisini geri koyar.
- Derleme kullanıcısına temiz bir ortam verilir; yalnız vekil sunucu ve sertifika değişkenleri
  (`http(s)_proxy`, `no_proxy`, `JAVA_TOOL_OPTIONS`, `GRADLE_OPTS`, `SSL_CERT_FILE`,
  `GIT_SSL_CAINFO`) aktarılır (sudo bunları varsayılan olarak siler; gerekirse
  `sudo --preserve-env=https_proxy,…` ile verin).
- `--dry-run` root gerektirmez ve hiçbir şey kurmaz, indirmez, yazmaz.

## Çalıştırma

```bash
sudo mc start all
sudo mc stop survival
sudo mc restart velocity      # tüm oyuncuların bağlantısı kopar
mc status
```

`mc status` örneği:

```
SUNUCU         TÜR       PORT   DURUM                         RSS    HEAP
velocity       velocity  25565  active (running)             1.6G      1G
limbo          limbo     30065  active (running)              41M       -
lobby          paper     30066  active (running)             2.4G   1536M
survival       paper     30067  active (running)             8.7G      7G
```

Oyun içinde `/stop` ya da `/restart` sunucuyu durdurur ve systemd 10 saniye sonra **yeniden
başlatır** (`Restart=always`). Gerçekten durdurmak için `sudo mc stop <sunucu>` kullanın. Aynı
şey Velocity konsolundaki `shutdown`/`end` için de geçerlidir.

## Konsol

| Yöntem | Ne zaman | Yanıt |
|---|---|---|
| `sudo mc cmd <sunucu> <komut>` | Her sunucu (Velocity dahil); sunucunun konsoluna yazılmış gibi | Yanıtı `sudo mc log <sunucu>`'da görürsünüz |
| `sudo mc rcon <sunucu> <komut>` | Yalnız Paper; betiklerde ve yanıtı hemen görmek için | Yanıt doğrudan basılır (10 sn zaman aşımı) |
| `sudo mc log <sunucu>` | Canlı günlük | `journalctl -u mc@<sunucu> -f -o cat` |

Kabuğun özel karakterleri (`*`, `?`, `!`, `&`…) içeren komutları **tırnak içinde** verin:

```bash
sudo mc rcon survival list
sudo mc rcon survival "spark tps"
sudo mc rcon lobby "lp user Ahmet permission set * true"
sudo mc cmd velocity glist                        # proxy'deki oyuncular
sudo mc cmd velocity send Ahmet lobby             # oyuncuyu sunucuya gönder
sudo mc cmd velocity librelogin user info Ahmet
sudo mc cmd velocity velocity reload              # velocity.toml'u yeniden oku
sudo mc log velocity
```

Konsol, systemd'nin açtığı bir FIFO üzerinden çalışır: `/run/minecraft/<sunucu>.stdin`
(sunucu çalışırken vardır). `mc cmd` sunucu kapalıyken "Konsol girişi yok" der.

**Geçmiş günlükler:**

```bash
sudo journalctl -u mc@survival --since "2 hours ago" -o cat --no-pager
sudo journalctl -u mc@velocity --since today -o cat --no-pager | grep -i error
sudo mc log survival -n 200                        # son 200 satırdan itibaren canlı
sudo less /opt/minecraft/servers/survival/logs/latest.log
```

Sunucuların kendi `logs/` dizinlerindeki eski `*.log.gz` dosyaları `LOG_RETENTION_DAYS`
(varsayılan 90) günden eskiyse her gün silinir; journald 90 günü ve 2 GB'ı aşan kısmı siler.

### mc say ve mc countdown-restart

```bash
sudo mc say "Etkinlik 10 dakika sonra başlıyor!"
sudo mc countdown-restart          # 5 dakika
sudo mc countdown-restart 15
```

`countdown-restart`: çalışan Paper sunucularına N dakika, 1 dakika, 30 saniye ve 10 saniye kala
duyuru yapar, sonra **yalnız o an çalışan** sunucuları yeniden başlatır (önce velocity durur,
sonra diğerleri; başlatırken tersine). Bilerek durdurduğunuz sunucular kapalı kalır. Hiçbir
sunucu çalışmıyorsa bir şey yapmaz. Yedek ya da geri yükleme sürüyorsa bitmesini en çok 15
dakika bekler (`MC_LOCK_WAIT`), bitmezse yeniden başlatmayı atlar.

## Yedekleme

```bash
sudo mc backup                     # = mc backup all: tüm sunucular + MariaDB + artifacts/
sudo mc backup survival            # tek sunucu
sudo mc backup list                # tümü
sudo mc backup list survival       # ayrıca: _mariadb, _artifacts
sudo mc backup prune               # saklama politikası + eski günlükler
sudo mc restore survival 1a2b3c4d  # ya da: latest; büyük harflerle EVET yazarak onaylanır
sudo mc backup help
```

Ayrıntı: [docs/05](05-yedekleme.md).

## mc doctor

```bash
sudo mc doctor
```

Hiçbir şeyi değiştirmez. Her satır `[TAMAM]`, `[UYARI]` ya da `[KRİTİK]`:

| Denetim | Uyarı / kritik eşiği |
|---|---|
| `/usr/bin/java` Java ≥ 25 mi, ön sürüm (`-` içeren) mi; PATH'teki java aynı mı; sunucu yolunda `!`/`+` var mı | < 25 ya da EA sürüm: kritik |
| RAM: toplam heap × 1,25 + 1,5 GB ≤ MemTotal | Aşarsa uyarı (hangi heap'in ne kadar düşürüleceğini önerir) |
| Swap var mı | Yoksa uyarı |
| CPU steal (5 sn `vmstat`) | > %2 uyarı, > %5 kritik |
| `/etc/minecraft/secrets.env` izinleri | 0600/0400 root değilse kritik |
| UFW etkin mi; 25565/tcp ve 19132/udp açık mı | Değilse kritik |
| Velocity dışındaki sunucuların oyun ve RCON portları yalnız 127.0.0.1'de mi | Dış arayüzde dinliyorsa kritik |
| Disk doluluğu | > %70 uyarı, > %90 kritik |
| Yedek deposu yerel mi; son yedek ne zaman | Yerel: uyarı. Son yedek > 2 saat: uyarı, > 26 saat ya da hiç yok: kritik |
| Her sunucunun `server.jar` / `pico_limbo` dosyası var mı | Yoksa kritik |
| LibreLogin: `network.env` `LIBRELOGIN_COMMIT` ↔ `plugins.list` `LibreLogin-<ilk7>.jar` ↔ `/opt/minecraft/artifacts` | Uyuşmazlık kritik; jar henüz derlenmediyse uyarı (`sudo mc build-librelogin`) |

Root olmadan çalıştırılırsa erişemediği denetimleri atlar. Kritik bulgu varsa sıfırdan farklı
kodla çıkar.

## systemd birimleri ve zamanlayıcılar

| Birim | Ne |
|---|---|
| `mc@.service` | Tek şablon: `mc@velocity`, `mc@limbo`, `mc@lobby`, `mc@survival`… `minecraft` kullanıcısıyla, sertleştirilmiş. Açılışta başlar (install.sh etkinleştirir). Başlarken bekleyen güncellemeleri uygular (`server.jar.new`, `pico_limbo.new`, `plugins/update/*.jar`) |
| `mc@.socket` | Konsol FIFO'su `/run/minecraft/<sunucu>.stdin` |
| `mc-backup.timer` → `mc-backup.service` | Her saat :07 → `mc backup all` |
| `mc-prune.timer` → `mc-prune.service` | Her gün 04:30 → `mc backup prune` |
| `mc-daily-restart.timer` → `mc-daily-restart.service` | Her gün 05:00 (Europe/Istanbul) → `mc countdown-restart 5` |

```bash
systemctl list-timers 'mc-*'
systemctl status mc@survival
sudo journalctl -u mc-backup.service -n 50 --no-pager     # son yedeğin çıktısı
```

**Günlük yeniden başlatmayı kapatmak / açmak:**

```bash
sudo systemctl disable --now mc-daily-restart.timer
sudo systemctl enable --now mc-daily-restart.timer
```

Not: install.sh'i yeniden çalıştırmak bu zamanlayıcıyı **yeniden etkinleştirir**; kapalı
tutmak istiyorsanız install.sh'ten sonra `disable` komutunu tekrarlayın. Günlük yeniden başlatma
bekleyen jar/eklenti güncellemelerini devreye sokar; kapatırsanız güncellemelerden sonra elle
`sudo mc countdown-restart 5` çalıştırın.

**Saatini değiştirmek** (ör. 06:00):

```bash
sudo systemctl edit mc-daily-restart.timer
```

Açılan düzenleyiciye yazın, kaydedin:

```
[Timer]
OnCalendar=
OnCalendar=*-*-* 06:00:00
```

Bu bir ek dosya (`/etc/systemd/system/mc-daily-restart.timer.d/override.conf`) oluşturur ve
install.sh onu silmez.

**Sunucu birimlerinin ek dosyaları** (`/etc/systemd/system/mc@<sunucu>.service.d/`: `10-order.conf`,
`20-resources.conf`, `30-exec.conf`) `mc apply` tarafından üretilir; elle düzenlemeyin, kaynağı
`server.env`'dir.

## Dosya konumları

| Yol | İçerik |
|---|---|
| `/opt/minecraft/kami/` | Bu depo (root'a ait). `config/` burada düzenlenir |
| `/opt/minecraft/servers/<sunucu>/` | Sunucu dizini (`minecraft` kullanıcısının): `server.jar` (limbo: `pico_limbo`), `plugins/`, `world/`, `logs/`, `jvm.env` |
| `/opt/minecraft/servers/<sunucu>/world/dimensions/minecraft/{overworld,the_nether,the_end}/` | 26.x dünya düzeni (tüm boyutlar tek `world/` altında) |
| `/opt/minecraft/servers/<sunucu>/gc.log*` | Paper GC günlüğü (5 × 10 MB) |
| `/opt/minecraft/servers/velocity/plugins/librelogin/user-data.db` | LibreLogin hesap veritabanı (SQLite) |
| `/opt/minecraft/servers/velocity/plugins/floodgate/key.pem` | Floodgate anahtarı (gizli) |
| `/opt/minecraft/artifacts/` | Yerelde derlenen jar'lar (LibreLogin) |
| `/etc/minecraft/secrets.env` | İletim sırrı, RCON ve veritabanı parolaları (root, 0600) |
| `/etc/minecraft/backup.env` | restic deposu ve bulut kimlik bilgileri (root, 0600) |
| `/etc/minecraft/restic.pass` | Yedek parolası (root, 0600) — **makine dışında da saklayın** |
| `/var/backups/minecraft/restic` | Varsayılan (yerel) yedek deposu |
| `/run/minecraft/<sunucu>.stdin` | Konsol FIFO'su |
| `/etc/systemd/system/mc@.service`, `mc@.socket`, `mc-*.timer`, `mc-*.service` | systemd birimleri |
| `/usr/local/bin/mc`, `/usr/local/bin/yq` | Yönetim aracı, mikefarah yq |
| `/etc/sysctl.d/99-minecraft.conf`, `/etc/systemd/journald.conf.d/minecraft.conf`, `/etc/tmpfiles.d/minecraft-thp.conf` | Çekirdek, günlük ve THP ayarları |
| `/etc/fail2ban/jail.d/minecraft.conf` | fail2ban ayarları |
| `/etc/mysql/mariadb.conf.d/60-minecraft.cnf` | MariaDB ayarları |
| `/etc/needrestart/conf.d/minecraft.conf`, `/etc/apt/apt.conf.d/52unattended-upgrades-minecraft` | Otomatik güncelleme ve yeniden başlatma istisnaları |
| `/etc/ssh/sshd_config.d/00-kami-hardening.conf` | `--harden-ssh` ile SSH ayarı |
| `/swapfile` | 2 GB swap (install.sh) |
| Günlükler | `sudo journalctl -u mc@<sunucu>` (etiket `mc-<sunucu>`), ayrıca `/opt/minecraft/servers/<sunucu>/logs/` (root ile okunur) |

## İleri düzey ortam değişkenleri

| Değişken | Nerede | Anlamı |
|---|---|---|
| `GITHUB_TOKEN` | `mc download` | GitHub API istek sınırını aşmak için jeton. Betik onu curl'ün komut satırına koymaz; siz de `sudo --preserve-env=GITHUB_TOKEN` ile aktarın ([mc download](#mc-download)) |
| `PICOLIMBO_SHA256` | `network.env` → `mc download` | PicoLimbo arşivinin (`pico_limbo_linux-x86_64-musl.tar.gz`) beklenen SHA-256'sı (isteğe bağlı sabitleme). GitHub sürümünde özet yoksa arşiv yalnız HTTPS'e güvenilerek kurulur; bu değer verilirse doğrulanır, GitHub özetiyle çelişirse indirme durur. `PICOLIMBO_VERSION` değişince bunu da güncelleyin |
| `MC_READY_TIMEOUT` | `mc init` | Hazır satırı için en uzun bekleme (sn, varsayılan 600) |
| `MC_RCON_WAIT` | `mc init` | RCON'un açılması için bekleme (sn, varsayılan 60) |
| `MC_LOCK_WAIT` | `mc countdown-restart` | Yedek kilidi için bekleme (sn, varsayılan 900) |
| `LIBRELOGIN_BUILD_USER`, `TMPDIR` | `mc build-librelogin` | Derleme kullanıcısı (varsayılan `kami-build`; root, `minecraft` ya da ek gruplu bir kullanıcı olamaz), geçici dizin kökü (varsayılan `/var/tmp`; noexec olmamalı). sudo ile aktarmak için: `sudo env TMPDIR=/opt/kami-tmp mc build-librelogin` |
| `YQ` | `mc apply`, testler | mikefarah yq yolu (varsayılan PATH'teki `yq`) |

`MC_ROOT`, `MC_ETC`, `MC_USER`, `MC_NO_SYSTEMD` gibi değişkenler yalnız testler içindir; gerçek
kurulumda değiştirmeyin (systemd birimleri `/opt/minecraft` yolunu sabit bekler).
Testleri çalıştırmak (geliştiriciler için; shellcheck ve mikefarah yq gerekir):

```bash
YQ=/usr/local/bin/yq bash /opt/minecraft/kami/tests/run.sh
```
