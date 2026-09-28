# 05 — Yedekleme

Yedekler [restic](https://restic.net) ile alınır: şifreli, yinelenen veriyi bir kez saklayan,
sıkıştıran ve SFTP/S3/B2 gibi uzak depolara doğrudan yazabilen tek bir araç. DeHost'un yedek
hizmeti ücretli bir ektir ve siz satın almadıkça verinizden siz sorumlusunuz; bu yüzden bu
belgedeki **uzak depo** adımı zorunlu sayılmalıdır.

## Ne yedeklenir, nasıl?

`mc backup all` (her saat otomatik) her sunucu dizinini ayrı bir anlık görüntü (snapshot) olarak
alır. Etiket = sunucu adı, makine adı = `BACKUP_HOST` (varsayılan `mc01`).

| Ne | Dahil | Hariç | Tutarlılık |
|---|---|---|---|
| **Paper** (lobby, survival): `/opt/minecraft/servers/<sunucu>` | Dünya (`world/`, 26.x'te tüm boyutlar bu klasörde), ayarlar, eklentiler ve eklenti verileri, jar'lar | `cache/`, `libraries/`, `versions/`, `logs/`, `plugins/.paper-remapped`, `*.jar.old` | Sunucu çalışıyorsa önce RCON ile `save-off` ve `save-all flush`, yedek bitince (hata olsa bile) `save-on` |
| **Velocity**: `/opt/minecraft/servers/velocity` | `velocity.toml`, eklenti ayarları, Floodgate `key.pem`, Sonar ve LibreLogin veritabanları | `logs/`, tüm `*.jar` (yeniden indirilebilir), eklenti önbellekleri | LibreLogin'in SQLite veritabanının **tutarlı kopyası** (`user-data.db.yedek`) SQLite'ın çevrimiçi yedek API'siyle alınır ve bütünlüğü (`quick_check`) denetlenir |
| **limbo** | `server.toml` vb. küçük dosyalar | `logs/`, `pico_limbo` ikilisi | Durumsuz |
| **MariaDB** (yalnız `mc backup all`) | `DB_DATABASES`'teki veritabanları (varsayılan `luckperms`) | — | `mariadb-dump --single-transaction`; depoya `mariadb.sql` adıyla, `_mariadb` etiketiyle yazılır |
| **artifacts** (yalnız `mc backup all`): `/opt/minecraft/artifacts` | Derlenmiş LibreLogin jar'ı ve `.sha256` dosyası (elle eklediğiniz `local` eklentiler de) | — | `_artifacts` etiketiyle. Aynı commit'ten yeniden derlemek bire bir aynı jar'ı vermeyebilir ve derleme depoları kapanabilir; bu yüzden saklanır |

**Neden save-off / save-all flush?** Paper dünyayı arka planda parça parça diske yazar. `save-off`
otomatik kaydı durdurur, `save-all flush` bekleyen tüm yazmaları diske döker; restic böylece
yarım yazılmış bölge dosyası kopyalamaz. Oyuncular bu sırada oynamaya devam eder. RCON yanıt
vermezse (sunucu yeni açılıyor olabilir) birkaç kez denenir; yine olmazsa o sunucu tutarsız
kopya alınmasın diye **atlanır** ve yedek hatalı biter.

**Yedeğe girmeyenler (ayrıca saklayın):**

- `/etc/minecraft/restic.pass` — yedek parolası. **Kaybolursa yedekler açılamaz.**
- `/etc/minecraft/backup.env` — depo adresi ve bulut kimlik bilgileri.
- `/etc/minecraft/secrets.env` — kaybolursa install.sh yenilerini üretir; kritik değildir.
- Depo (`/opt/minecraft/kami`) — değişikliklerinizi git'e işleyip GitHub'a gönderin.

## Zamanlama ve saklama

| Zamanlayıcı | Ne zaman | Ne yapar |
|---|---|---|
| `mc-backup.timer` | Her saat :07 (en çok 60 sn rastgele gecikme); makine kapalıyken kaçırılan çalışma açılışta telafi edilir | `mc backup all` (düşük öncelik: `Nice=10`, `IOSchedulingClass=idle`; en çok 2 saat) |
| `mc-prune.timer` | Her gün 04:30 | `mc backup prune`: eski anlık görüntüleri siler + `LOG_RETENTION_DAYS`'ten eski günlükleri siler |
| `mc-daily-restart.timer` | Her gün 05:00 | Geri sayımlı yeniden başlatma; yedek sürüyorsa bitmesini bekler (aynı kilit) |

Saklama politikası `config/network.env` içindedir ve her sunucu etiketi için ayrı uygulanır
(`restic forget --prune --group-by host,tags`):

| Değişken | Varsayılan | Anlamı |
|---|---|---|
| `BACKUP_KEEP_HOURLY` | 24 | Son 24 saatin her saatinden bir yedek |
| `BACKUP_KEEP_DAILY` | 7 | Son 7 günün her gününden bir |
| `BACKUP_KEEP_WEEKLY` | 4 | Son 4 haftanın her haftasından bir |
| `BACKUP_KEEP_MONTHLY` | 6 | Son 6 ayın her ayından bir |

Yedek, budama ve geri yükleme aynı kilidi (`/opt/minecraft/.backup.lock`) kullanır; aynı anda
çalışmazlar.

## Uzak depo kurulumu

Depo `/etc/minecraft/backup.env` dosyasında tanımlanır (root, 0600; bash `ANAHTAR=değer`
biçimi). Varsayılan:

```bash
RESTIC_REPOSITORY=/var/backups/minecraft/restic
RESTIC_PASSWORD_FILE=/etc/minecraft/restic.pass
BACKUP_HOST=mc01
```

`RESTIC_REPOSITORY`'yi uzak bir adresle değiştirin. Depo yoksa ilk yedekte aynı parolayla
**kendiliğinden oluşturulur**; parola ya da kimlik bilgisi yanlışsa yeni depo açılmaz, hata
verilir. Değişiklikten sonra deneyin:

```bash
sudo nano /etc/minecraft/backup.env
sudo mc backup all        # ilk tam yedek uzun sürebilir
sudo mc backup list
sudo mc doctor            # "Yedek deposu uzak" ve "Son yedek … dakika önce" görünmeli
```

### Örnek 1: SFTP (ör. Hetzner Storage Box)

restic, SFTP için sistemin `ssh` komutunu root olarak kullanır; bu yüzden root'a ait bir anahtar
ve bir SSH takma adı hazırlayın.

```bash
# 1) Root için ayrı bir SSH anahtarı
sudo ssh-keygen -t ed25519 -N '' -f /root/.ssh/yedek_ed25519

# 2) Takma ad (kullanıcı adı ve portu kendi kutunuza göre yazın)
sudo tee -a /root/.ssh/config >/dev/null <<'EOF'
Host yedek
    HostName u123456.your-storagebox.de
    User u123456
    Port 23
    IdentityFile /root/.ssh/yedek_ed25519
EOF

# 3) Açık anahtarı kutuya yükleyin (yöntem için sağlayıcının belgesine bakın), sonra
#    bir kez elle bağlanıp sunucu parmak izini onaylayın (zamanlayıcı soru soramaz):
sudo ssh yedek
```

`backup.env`:

```bash
RESTIC_REPOSITORY=sftp:yedek:/minecraft
```

Hetzner Storage Box'ın SSH/SFTP portu (22 ya da 23) ve anahtar yükleme yöntemi için Hetzner'in
güncel belgesine bakın (DOĞRULANMADI). Herhangi bir SFTP sunucusu (ikinci bir VDS, evdeki bir
NAS) aynı şekilde kullanılabilir.

### Örnek 2: S3 uyumlu depolama (Backblaze B2, Cloudflare R2)

Önce sağlayıcının panelinde bir kova (bucket) ve **yalnız o kovaya** yetkili bir erişim anahtarı
oluşturun.

```bash
# Backblaze B2 (S3 uyumlu uç nokta; bölgeyi kendi kovanıza göre yazın)
RESTIC_REPOSITORY=s3:https://s3.eu-central-003.backblazeb2.com/kova-adi/minecraft
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...

# Cloudflare R2
RESTIC_REPOSITORY=s3:https://<hesap-kimligi>.r2.cloudflarestorage.com/kova-adi/minecraft
AWS_ACCESS_KEY_ID=...
AWS_SECRET_ACCESS_KEY=...

# Backblaze B2 (restic'in kendi B2 desteği)
RESTIC_REPOSITORY=b2:kova-adi:minecraft
B2_ACCOUNT_ID=...
B2_ACCOUNT_KEY=...
```

(Bu satırlardan **birini** seçin. R2 için ayrıca `AWS_DEFAULT_REGION=auto` gerekebilir;
DOĞRULANMADI.)

### Ek güvenlik: silemeyen kimlik bilgisi

Makine ele geçirilirse saldırgan `backup.env`'deki kimlik bilgisiyle yedekleri de silebilir.
Daha güvenli düzen: bu makineye **yalnız yazabilen** (silemeyen) bir anahtar verin (ör. B2'de
"deleteFiles" yetkisi olmayan uygulama anahtarı ya da `--append-only` çalışan bir rest-server)
ve budamayı (`restic forget --prune`) güvendiğiniz başka bir makineden yapın. Bu durumda
`mc-prune.timer`'ın restic adımı hata verir; günlük budaması (log) yine çalışır. Bu, depodaki
betiklerin hazır desteklediği bir düzen değildir; kendiniz kurarsınız.

### Yerel depodan uzağa taşımak

`RESTIC_REPOSITORY` değişince yeni depo boş başlar; eski yerel yedekler kendiliğinden taşınmaz.
İsterseniz kopyalayın:

```bash
sudo -i
set -a; . /etc/minecraft/backup.env; set +a
restic copy --from-repo /var/backups/minecraft/restic --from-password-file /etc/minecraft/restic.pass
exit
```

Taşıdıktan sonra yerel depo yer kaplamasın diye `/var/backups/minecraft/restic` silinebilir.

## restic parolası

`/etc/minecraft/restic.pass` install.sh tarafından rastgele üretilir ve depo bununla şifrelenir.

- Bir kopyasını **makine dışında** saklayın: parola yöneticisi (Bitwarden, KeePass…) ya da
  kâğıda yazıp güvenli bir yere.

  ```bash
  sudo cat /etc/minecraft/restic.pass
  ```

- VDS silinirse yeni makinede bu parola ve `backup.env` olmadan uzak depodaki yedekler
  **açılamaz**. restic'in "parola sıfırlama" diye bir özelliği yoktur.
- Parolayı ekran görüntüsüyle, Discord'da vb. paylaşmayın.

## Listeleme ve geri yükleme

```bash
sudo mc backup list              # tüm anlık görüntüler
sudo mc backup list survival     # yalnız survival
sudo mc backup list _mariadb     # veritabanı dökümleri
sudo mc backup list _artifacts   # derlenmiş jar'lar (/opt/minecraft/artifacts)
```

Geri yükleme (örnek: survival'ı belirli bir anlık görüntüye döndürmek):

```bash
sudo mc restore survival 1a2b3c4d     # ya da en yenisi için: latest
```

Komut önce anlık görüntünün gerçekten `survival`'a ait olduğunu denetler, özet bilgi gösterir ve
**büyük harflerle `EVET` yazmanızı** ister. Onaylarsanız:

1. Anlık görüntü önce geçici bir dizine açılır (başarısız olursa canlı dizine dokunulmaz).
2. Sunucu çalışıyorsa durdurulur. (Velocity geri yüklenirken **tüm oyuncuların** bağlantısı kopar.)
3. Mevcut dizin `/opt/minecraft/servers/survival.onceki-YYYYAAGG-SSDDss` adıyla kenara alınır.
4. Geri yüklenen dizin yerine konur; yedekte olmayan yeniden üretilebilir içerik (Paper
   önbellekleri, Velocity jar'ları, `pico_limbo`) eski dizinden kopyalanır; sahiplik düzeltilir.
5. Velocity'de LibreLogin'in tutarlı kopyası canlı veritabanı yapılır.

Sonra:

```bash
sudo mc start survival
# Her şey yolundaysa kenara alınan eski dizini silin. servers/ yönetici kullanıcısına kapalı (0750)
# olduğundan "*" root kabuğunda genişletilmeli (sh -c); yoksa rm hiçbir şey silmeden başarılı döner.
sudo sh -c 'ls -d /opt/minecraft/servers/survival.onceki-*'      # önce ne silineceğine bakın
sudo sh -c 'rm -rf /opt/minecraft/servers/survival.onceki-*'
```

**Veritabanını (LuckPerms) geri yüklemek** elle yapılır. Önce sunucuları durdurun
(`sudo mc stop all`), sonra:

```bash
sudo -i
set -a; . /etc/minecraft/backup.env; set +a
restic snapshots --host "$BACKUP_HOST" --tag _mariadb     # tarih/saate bakıp kimliği seçin
restic dump <snapshot> /mariadb.sql | mariadb
exit
```

**Derlenmiş jar'ları (`/opt/minecraft/artifacts`) geri yüklemek** de elle yapılır (özgün yollara
yazar):

```bash
sudo -i
set -a; . /etc/minecraft/backup.env; set +a
restic restore latest --host "$BACKUP_HOST" --tag _artifacts --target /
exit
```

**Tek bir dosyayı** (ör. bir oyuncunun envanteri) geri almak için tüm sunucuyu döndürmek
gerekmez: anlık görüntüyü geçici bir dizine açıp dosyayı elle kopyalayın (aşağıdaki test
yöntemiyle), sunucu kapalıyken yerine koyun.

### Makine tamamen kaybolursa

1. Yeni VDS'e [docs/02](02-kurulum.md) adımlarını uygulayın (2–6. adımlar).
2. **Önce zamanlayıcıları durdurun.** install.sh saatlik yedeği zaten açtı ve **boş** bir
   `luckperms` veritabanı oluşturdu; eski depo bağlandıktan sonra çalışan bir saatlik yedek bu boş
   veritabanını en yeni `_mariadb` anlık görüntüsü olarak yazar:

   ```bash
   sudo systemctl stop mc-backup.timer mc-prune.timer mc-daily-restart.timer
   ```

3. Sakladığınız `backup.env` ve `restic.pass` dosyalarını `/etc/minecraft/` altına koyun
   (`sudo chmod 600 /etc/minecraft/backup.env /etc/minecraft/restic.pass`). `BACKUP_HOST` eski
   değerle aynı olmalı.
4. Sunucuları geri yükleyin: `sudo mc restore velocity latest`, `limbo`, `lobby`, `survival`.
5. Veritabanını ve derlenmiş jar'ları geri yükleyin (yukarıdaki `restic dump … | mariadb` ve
   `restic restore latest --host "$BACKUP_HOST" --tag _artifacts --target /`). Veritabanında
   `latest` **kullanmayın**: `restic snapshots --host "$BACKUP_HOST" --tag _mariadb` listesinden
   makine kaybından **önceki** anlık görüntünün kimliğini seçin.
6. Yeni makinede gizli değerler yenidir; geri yüklenen dosyalara yazılmaları için
   `sudo mc apply all` çalıştırın.
7. `sudo mc download` (Velocity ve PicoLimbo ikilileri yedekte yoktur; LibreLogin
   `/opt/minecraft/artifacts/`'tan kopyalanır — orada yoksa `sudo mc build-librelogin`),
   `sudo mc start all`, duman testi.
8. Zamanlayıcıları yeniden başlatın ve ilk yedeği alın:

   ```bash
   sudo systemctl start mc-backup.timer mc-prune.timer mc-daily-restart.timer
   sudo mc backup all && sudo mc doctor
   ```

## Aylık geri yükleme testi

Hiç denenmemiş bir yedek, yedek sayılmaz. Ayda bir, sunuculara dokunmadan:

```bash
sudo -i
set -a; . /etc/minecraft/backup.env; set +a
restic snapshots --host "$BACKUP_HOST" --tag survival --latest 3
restic restore latest --host "$BACKUP_HOST" --tag survival --target /root/geri-yukleme-testi
ls -la /root/geri-yukleme-testi/opt/minecraft/servers/survival/world
du -sh /root/geri-yukleme-testi
# Deponun bütünlüğü (verinin %5'ini okuyarak; uzak depoda indirme ücreti doğurabilir):
restic check --read-data-subset=5%
rm -rf /root/geri-yukleme-testi
exit
```

Aynı şeyi `velocity` (LibreLogin `user-data.db.yedek` dosyası orada mı?) ve `_mariadb`
(`restic dump --host "$BACKUP_HOST" --tag _mariadb latest /mariadb.sql | head`) için de yapın. Diskte açılacak kadar
yer olduğundan emin olun (`df -h /`).

Daha kapsamlı test: yılda birkaç kez küçük geçici bir VPS'e tüm ağı "makine kaybolursa"
adımlarıyla geri kurun.

## Disk takibi

```bash
df -h /                                           # genel doluluk
sudo sh -c 'du -sh /opt/minecraft/servers/* /var/backups/minecraft' 2>/dev/null   # "*" root kabuğunda
sudo journalctl --disk-usage                      # günlükler (en çok 2 GB; sudo'suz yalnız kendi günlüğünüz)
sudo mc doctor                                    # %70 üstü uyarı, %90 üstü kritik
sudo sh -c 'set -a; . /etc/minecraft/backup.env; set +a; restic stats --mode raw-data'
```

Yer azalırsa: yerel depo kullanıyorsanız uzağa taşıyın, saklama değerlerini düşürün
(`BACKUP_KEEP_*`), eski `*.onceki-*` dizinlerini silin, `sudo mc backup prune` çalıştırın.
Zamanlayıcıların durumu: `systemctl list-timers 'mc-*'`, son yedeğin günlüğü:
`sudo journalctl -u mc-backup.service -n 50 --no-pager`.
