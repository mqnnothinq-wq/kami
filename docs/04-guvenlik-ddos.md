# 04 — Güvenlik ve DDoS

Bu belge neye karşı korunduğumuzu, hangi önlemin nerede olduğunu ve sizin neyi yapmanız
gerektiğini anlatır. Sonda KVKK ve Mojang kullanım kuralları hakkında notlar var (hukuki tavsiye
değildir).

## Tehdit modeli

| Tehdit | Olasılık | Önlem (bu depoda) | Sizin işiniz |
|---|---|---|---|
| DDoS (TCP 25565 / UDP 19132 seli) | Yüksek (TR sunucularında yaygın) | Sağlayıcının DDoS koruması; Velocity `login-ratelimit`, paket sınırlayıcı; çekirdek SYN cookies | Koruma türünü DeHost'a sorun, `haproxy-protocol`'ü ona göre ayarlayın |
| Bot saldırısı (sahte oyuncu seli) | Yüksek | Sonar (her yeni oyuncu doğrulanır), Velocity giriş hız sınırı, Paper `max-joins-per-tick` | Saldırı sırasında `mc log velocity` izleyin |
| Girişi atlatma (backend'e ya da limbo'ya doğrudan bağlanma) | Orta | Backend'ler ve limbo yalnız 127.0.0.1'de; modern forwarding HMAC sırrı; UFW | `mc doctor` port satırları hep `[TAMAM]` olmalı |
| Hesap çalma (cracked adlar) | Orta | LibreLogin: BCrypt, 5 yanlış denemede atma, yasaklı şifre listesi, premium adların ayrılması | Yetkili hesapları premium olsun ([docs/08](08-giris-sistemi.md)) |
| Arka kapılı eklenti (sızdırılmış/"crack" ücretli eklentiler) | Orta | Yalnız resmî kaynaklar, özet (hash) doğrulama; sunucular yetkisiz `minecraft` kullanıcısıyla, sertleştirilmiş systemd biriminde | Asla sızdırılmış eklenti kurmayın |
| SSH kaba kuvvet | Yüksek (sürekli taranır) | UFW `limit`, fail2ban, isteğe bağlı parola girişini kapatma | `--harden-ssh` |
| RCON / veritabanı / yönetim portlarına erişim | Düşük (kapalı) | RCON ve MariaDB yalnız 127.0.0.1; query ve management server kapalı | Yeni port açarken dikkat |
| Gizli değerlerin sızması | Düşük | `/etc/minecraft/*` root 0600, git'e girmez (`.gitignore`) | Ekran görüntüsü/paylaşımda dikkat |
| Veri kaybı (disk, silinen VDS, fidye) | Orta | Saatlik restic yedeği | **Uzak depo** tanımlayın ([docs/05](05-yedekleme.md)) |

## Açık portlar ve güvenlik duvarı (UFW)

install.sh UFW'yi şöyle kurar: gelen her şey reddedilir, yalnız şunlar açılır:

| Port | Ne | Kural |
|---|---|---|
| SSH portu (sshd'den okunur; genelde 22/tcp) | Yönetim | `ufw limit` (bir IP 30 saniyede 6 ya da daha fazla bağlantı denerse engellenir) |
| 25565/tcp | Velocity (Java) | `ufw allow` |
| 19132/udp | Geyser (Bedrock) | `ufw allow` |

Kontrol:

```bash
sudo ufw status verbose
sudo ss -ltnp     # dinleyen TCP portları: 25565 dışındaki Minecraft portları 127.0.0.1'de olmalı
sudo ss -lunp     # dinleyen UDP portları: 19132
```

**127.0.0.1'de kalanlar** (dışarıdan erişilemez, UFW kuralı gerekmez):

| Hizmet | Adres |
|---|---|
| limbo (PicoLimbo) | 127.0.0.1:30065 |
| lobby / survival | 127.0.0.1:30066 / 30067 |
| RCON (lobby / survival) | 127.0.0.1:31066 / 31067 (`rcon.ip=127.0.0.1`) |
| MariaDB | 127.0.0.1:3306 (`bind-address`, `local-infile=0`) |

Backend'lerde `enable-query=false`, `management-server-enabled=false`, `accepts-transfers=false`.
Velocity'de `[query] enabled = false`. `mc doctor` her Minecraft portunun yalnız 127.0.0.1'de
dinlendiğini denetler; dış arayüzde dinleyen bir limbo ya da backend **kritik** hatadır, çünkü
girişi atlatmanın klasik yoludur.

İleride bir eklenti port isterse (NuVotifier 8192/tcp, BlueMap web 8100/tcp gibi) kuralı elle
ekleyin ve yalnız gerekeni açın:

```bash
sudo ufw allow 8192/tcp comment 'NuVotifier'
```

**Bedrock'un geleceği:** Geyser, Bedrock'un RakNet'ten NetherNet'e geçişini hazırlıyor (RakNet
Bedrock 26.60'ta kaldırılacak; tarih DOĞRULANMADI). NetherNet 19132/**TCP** ve ayrı bir UDP portu
ister. O gün geldiğinde hem UFW'de hem DeHost korumasında bu portları açtırmanız gerekecek.

## DDoS koruması şeffaf mı, ters vekil mi?

DeHost ücretsiz DDoS koruması veriyor ("Mikrotik ve NeoProtect" / "RouteFence", 25565/TCP'ye
özel L3/L4 kurallar). Koruma iki şekilde olabilir ve **Velocity'deki bir ayar buna göre doğru
olmalıdır**:

| | Şeffaf (satır içi) süzme | Ters vekil (ör. NeoProtect GameShield) |
|---|---|---|
| Nasıl çalışır | Trafik sizin IP'nize gelir, sağlayıcı yolda süzer | Oyuncular vekilin IP'sine bağlanır, vekil size iletir |
| Oyuncu IP'leri | Gerçek IP'ler görünür | Vekil PROXY protocol başlığı gönderirse gerçek, göndermezse hep vekilin IP'leri |
| `velocity.toml` `haproxy-protocol` | **`false`** (depodaki değer) | `true` (vekil PROXY başlığı gönderiyorsa) |
| Geyser | Değişiklik yok | `advanced.bedrock.use-haproxy-protocol: true` + `haproxy-protocol-whitelisted-ips` (vekil Bedrock'u da taşıyorsa) |
| UFW | Değişiklik yok | 25565'i yalnız vekilin IP aralıklarına açın (NeoProtect listesi: `https://api.neoprotect.net/v2/public/servers/txt`) |

Depo, DeHost'un dahil korumasını **şeffaf** kabul eder (DOĞRULANMADI; soru 5,
[docs/01](01-donanim-ve-kapasite.md#satın-almadan-önce-dehosta-sorulacak-11-soru)). Ayrı bir
GameShield hesabı açarsanız durum değişir.

**Yanlış değer neye yol açar?**

- `haproxy-protocol = true` ama PROXY başlığı gelmiyor: Velocity her bağlantının başında bu
  başlığı bekler → **hiç kimse bağlanamaz**; istemciler hemen kopar ya da zaman aşımına düşer,
  Velocity günlüğünde HAProxy çözümleme hataları görülür.
- `haproxy-protocol = false` ama vekil PROXY başlığı gönderiyor: el sıkışma bozuk görünür →
  yine **hiç kimse bağlanamaz**.
- Vekil var ama PROXY başlığı yok: herkes vekilin birkaç IP'sinden geliyor görünür; IP başına
  giriş hız sınırı (3 sn) ve Sonar'ın IP başına 5 oyuncu sınırı gerçek oyuncuları engeller, IP
  yasakları anlamsızlaşır.

**Hangisi olduğunu kendiniz nasıl anlarsınız?** Oyuncular bağlıyken kurulu bağlantıların karşı
uç adreslerine bakın (Velocity IP'leri günlüğe yazmasa da çekirdek görür):

```bash
sudo ss -tn state established '( sport = :25565 )' | awk 'NR>1 {print $4}' | sed 's/:[0-9]*$//' | sort | uniq -c | sort -rn | head
```

Çok sayıda farklı ev/mobil IP'si görüyorsanız koruma şeffaftır. Tüm bağlantılar birkaç aynı
adresten geliyorsa önünüzde bir vekil vardır; DeHost'a PROXY protocol'ü sorun.

`haproxy-protocol`'ü değiştirmek için `config/servers/velocity/files/velocity.toml`'u düzenleyin,
`sudo mc apply velocity` ve `sudo mc restart velocity`.

## Velocity ve backend'ler arası güven

- **Modern forwarding:** Velocity oyuncunun adını, UUID'sini ve IP'sini backend'lere HMAC ile
  imzalı gönderir (`player-info-forwarding-mode = "MODERN"`). Backend'ler (Paper ve PicoLimbo)
  imzayı doğrular; sırrı bilmeyen biri backend'e oyuncu kimliği uyduramaz.
- **Sır nerede?** `/etc/minecraft/secrets.env` (root, 0600) içinde `VELOCITY_FORWARDING_SECRET`
  ve `PAPER_VELOCITY_SECRET` (aynı değer, 64 hane hex). systemd bunları ortam değişkeni olarak
  verir; Velocity, Paper ve PicoLimbo ortamdan okur. Hiçbir config dosyasına yazılmaz,
  `forwarding.secret` dosyası oluşturulmaz, git'e girmez.
- **Sırrı değiştirmek** (sızdığını düşünüyorsanız):

  ```bash
  NEW=$(openssl rand -hex 32)
  sudo sed -i "s/^VELOCITY_FORWARDING_SECRET=.*/VELOCITY_FORWARDING_SECRET='$NEW'/; s/^PAPER_VELOCITY_SECRET=.*/PAPER_VELOCITY_SECRET='$NEW'/" /etc/minecraft/secrets.env
  sudo mc restart all
  ```

- **Diğer gizli değerler:** `RCON_PASSWORD` değişirse `sudo mc apply all` (server.properties'e
  yazılır) ve Paper sunucularını yeniden başlatın. `DB_PASSWORD` değişirse install.sh'i yeniden
  çalıştırın (MariaDB kullanıcısını eşitler), sonra `sudo mc apply all` ve `sudo mc restart all`.
- **Floodgate anahtarı:** `/opt/minecraft/servers/velocity/plugins/floodgate/key.pem`. Bu anahtara
  sahip olan, Java doğrulamasını atlayıp Bedrock oyuncusu gibi görünebilir. Paylaşmayın, git'e
  koymayın (`.gitignore`'da). Floodgate yalnız proxy'de kurulu olduğu için başka bir sunucuya
  kopyalanması da gerekmez. Sızdıysa Velocity durdurulup dosya silinir; bir sonraki açılışta
  yenisi üretilir.

## Sonar (anti-bot) ayarları

`config/servers/velocity/files/plugins/sonar/config.yml`:

| Anahtar | Değer | Neden |
|---|---|---|
| `verification.timing` | ALWAYS | Her yeni oyuncu doğrulanır (yalnız saldırı sırasında değil). İlk girişte oyuncu "tekrar bağlan" mesajıyla atılır; bu beklenen durumdur |
| `verification.check-geyser-players` | false | Bedrock adlarındaki `.` Sonar'ın ad desenine (`^[a-zA-Z0-9_]+$`) uymaz |
| `verification.transfer.enabled` | false | Transfer paketi yok; oyuncu kendisi tekrar bağlanır |
| `general.max-online-per-ip` | 5 (varsayılan 3) | Mobil CGNAT ve internet kafeler aynı IP'yi paylaşır |
| `general.log-player-addresses` | false | KVKK |
| `database.type` / `maximum-age` | H2 / 5 gün | Doğrulanmış oyuncular yeniden başlatmada unutulmaz; IP'ler düz metin, en çok 5 gün |

Sonar mesajları Türkçedir (`language.properties`: `language=tr`, ilk açılıştan önce yerleştirilir).
Sonar'ın Velocity 4.2 üzerinde çalışması statik olarak kontrol edildi ama sahada test edilmedi;
duman testinde gözlemleyin.

## SSH sertleştirme ve fail2ban

- `sudo bash /opt/minecraft/kami/scripts/install.sh --harden-ssh` parola ile girişi kapatır
  (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`), root'a yalnız anahtarla izin
  verir (`PermitRootLogin prohibit-password`) ve `MaxAuthTries 3` yapar. Komutu çalıştıran
  yöneticinin `authorized_keys` dosyasında anahtar yoksa **reddeder** (kilitlenmeyesiniz diye).
- fail2ban SSH hapsini journald'dan okur: 10 dakikada 5 hatalı deneme → 1 saat yasak; tekrar
  edenlerde süre artar (en çok 1 hafta). Yasaklar UFW ile uygulanır. Ayarlar
  `/etc/fail2ban/jail.d/minecraft.conf`; kendi `jail.local` dosyanız varsa onun değerleri geçerlidir.

```bash
sudo fail2ban-client status sshd
sudo fail2ban-client set sshd unbanip 198.51.100.7    # kendinizi yasakladıysanız (VNC konsolundan)
```

SSH portunu değiştirmek önerilmez: Ubuntu 24.04 SSH'ı soket etkinleştirmeyle başlatır ve port
değişikliği ek adımlar ister; fail2ban + anahtar girişi yeterlidir.

## Sunucu süreçlerinin yalıtımı

- Tüm sunucular `minecraft` sistem kullanıcısıyla çalışır (kabuk yok). Sunucu dizinleri
  `/opt/minecraft/servers/<sunucu>` bu kullanıcıya aittir.
- `mc@.service` sertleştirilmiştir: `NoNewPrivileges`, `ProtectSystem=strict` (yalnız kendi
  sunucu dizinine yazabilir), `ProtectHome`, `PrivateTmp`, `PrivateDevices`, çekirdek ayarlarına
  erişim yok, yetenek (capability) yok. `MemoryDenyWriteExecute` bilerek yok: Java'nın JIT
  derleyicisini bozar.
- Betikler root olarak çalışırken sunucu dizinlerindeki dosyalara `minecraft` kimliğiyle
  dokunur ve sembolik bağları izlemez: ele geçirilmiş bir sunucu, root'un bir dosyasının üzerine
  yazdıramaz.
- Depo (`/opt/minecraft/kami`) root'a ait olmalı ve başkası yazamamalıdır: zamanlayıcılar oradaki
  betikleri root olarak çalıştırır. Kontrol/düzeltme:

  ```bash
  sudo chown -R root:root /opt/minecraft/kami && sudo chmod -R go-w /opt/minecraft/kami
  ```

## Eklentiler: asla sızdırılmış ya da "crack" eklenti kurmayın

- 2023'teki **fractureiser** kötü amaçlı yazılımı, ele geçirilmiş CurseForge/Bukkit hesapları
  üzerinden yayılan eklenti ve modlarla Windows ve Linux makinelere bulaştı.
- "Crack"lenmiş ücretli eklentilerde **force-OP arka kapıları** (gizli bir komutla kendine OP
  verme) yaygındır; bu tür arka kapıların kodu internette açıkça bulunuyor.
- Yalnız resmî kaynakları kullanın (Modrinth, Hangar, GitHub sürümleri, geliştiricinin sitesi).
  `config/plugins.list` indirilen dosyanın özetini kaynağın verdiği değerle doğrular; elle
  indirdiğiniz dosyalar için 5. sütuna SHA-256 yazın ([docs/06](06-eklentiler.md)).
- Discord'da "ücretsiz premium eklenti" paylaşanlardan dosya almayın.

## Güncelleme politikası

| Ne | Nasıl | Ne zaman |
|---|---|---|
| İşletim sistemi güvenlik güncellemeleri | `unattended-upgrades` otomatik | Günlük |
| Java (temurin/openjdk), MariaDB | Otomatik güncellemeden **hariç**; elle `sudo apt-get update && sudo apt-get upgrade`, ardından `sudo mc countdown-restart 5` | Haftalık, duyurulu bakımda |
| Servis yeniden başlatmaları | needrestart Minecraft ve MariaDB birimlerini kendiliğinden yeniden başlatmaz (oyuncular rastgele saatte atılmasın) | Kütüphane güncellemeleri 05:00 yeniden başlatmasında devreye girer |
| Çekirdek güncellemesi | Makine asla kendiliğinden yeniden başlamaz; `/var/run/reboot-required` varsa duyurup `sudo reboot` | Gerektikçe |
| Paper, Velocity, eklentiler | `sudo mc download` (elle; zamanlanmış değildir). Yeni dosyalar `server.jar.new` / `plugins/update/` olarak bekler, bir sonraki yeniden başlatmada devreye girer | Haftalık |

- Giriş zincirini etkileyen güncellemelerden (Velocity, Floodgate, Geyser, LibreLogin, Sonar)
  sonra **duman testini** tekrarlayın ([docs/08](08-giris-sistemi.md#duman-testi-canlıya-alma-kapısı)).
- Test ettiğiniz Velocity sürümünü `network.env`'de sabitleyin (`VELOCITY_VERSION="4.2.1"` gibi);
  `latest` bir gün LibreLogin'i bozan bir sürüme atlayabilir.
- **Geri alma:** yeni jar devreye girdiğinde eskisi `server.jar.old` olarak kalır.

  ```bash
  sudo mc stop velocity
  cd /opt/minecraft/servers/velocity && sudo mv server.jar server.jar.bozuk && sudo mv server.jar.old server.jar
  sudo mc start velocity
  ```

  Ardından `network.env`'de sürümü çalışan sürüme sabitleyin; yoksa bir sonraki `mc download`
  yeniden en yeniyi indirir.

## KVKK (kişisel verilerin korunması)

> Bu bölüm hukuki tavsiye değildir. Aşağıdaki yasal bilgiler arama sonuçlarından derlendi ve
> **DOĞRULANMADI**. Sunucuyu açmadan önce bir hukukçuya danışın.

Kullanıcı adları, IP adresleri ve bağlantı zamanları kişisel veridir. KVKK, amacı sona eren
verinin silinmesini ya da anonimleştirilmesini ister.

**Bu depoda yapılanlar (veri en aza indirme):**

| Yer | Ayar |
|---|---|
| Velocity | `enable-player-address-logging = false` (günlükte IP yerine "withheld"), `log-command-executions = false` (`/login` ve `/register` şifreleriyle günlüğe düşmesin) |
| Paper | `log-ips=false` |
| Sonar | `log-player-addresses: false`; H2 kaydı en çok 5 gün |
| Geyser | `log-player-ip-addresses: false` |
| LibreLogin | E-posta ile şifre sıfırlama ve 2FA kapalı (daha az veri) |
| Günlük saklama | `mc backup prune` (her gün 04:30) sunucu `logs/*.log.gz` dosyalarını `LOG_RETENTION_DAYS` (varsayılan **90**) günden eskiyse siler; journald `MaxRetentionSec=90day` |
| Yedekler | restic ile şifreli; sunucu `logs/` dizinleri yedeğe girmez |

`LOG_RETENTION_DAYS`'i değiştirirseniz `host/journald-minecraft.conf` içindeki
`MaxRetentionSec`'i de aynı yapın ve install.sh'i yeniden çalıştırın.

**Hâlâ saklanan kişisel veriler:**

- LibreLogin veritabanı (`plugins/librelogin/user-data.db`): UUID, premium UUID, ad, şifre özeti
  (BCrypt; yetkililer düz şifreyi göremez), kayıt ve son görülme zamanı, **son IP (düz metin)**,
  son sunucu.
- Sonar H2 veritabanı: doğrulanmış oyuncuların IP'leri (5 gün).
- LuckPerms (MariaDB): UUID, ad, izinler.
- Dünya verisi: oyuncu dosyaları (`world/playerdata/<uuid>.dat`), istatistikler.
- Sunucu günlükleri: ad, giriş/çıkış, sohbet ve oyuncu komutları (90 gün).
- Yedekler: yukarıdakilerin kopyaları; saklama politikasına göre en çok ~6 ay (aylık yedekler).

**Yurt dışına aktarım:** LibreLogin, premium denetimi için oyuncu adlarını `api.mojang.com`'a,
o yanıt vermezse `playerdb.co` ve `api.minetools.eu`'ya gönderir. Uzak yedek deposu yurt dışındaysa
(B2, R2, Hetzner) yedekler de oradadır. Bunları aydınlatma metninde belirtin.

**Yapmanız gerekenler:**

1. Bir **aydınlatma metni** yayımlayın (web sitenizde) ve bağlantısını
   `config/servers/velocity/files/plugins/librelogin/messages.conf` içindeki `prompt-register`
   satırına yazın (`ornek.com/kvkk` yerine). İçerikte en az: veri sorumlusunun kimliği ve
   iletişim bilgisi, işlenen veriler, amaçlar (hesap güvenliği, hile/bot önleme, sunucu
   işletimi), hukuki sebep, yurt dışına aktarım, saklama süreleri, KVKK madde 11 hakları ve
   başvuru yolu.
2. **Yazılı saklama süresi** belirleyin (ör. günlükler 90 gün, yedekler 6 ay) ve ayarları buna
   uydurun.
3. **Silme talepleri:** `sudo mc cmd velocity librelogin user delete <ad>`; LuckPerms kaydı için
   `sudo mc rcon lobby "lp user <ad> clear"`; oyuncu dosyası `world/playerdata/<uuid>.dat`.
   Yedeklerdeki kopyalar saklama süresi dolunca silinir; bunu aydınlatma metninde belirtin.
4. Kayıt olmadan ayrılan adlar için LibreLogin veritabanında boş satırlar birikir; bunların
   düzenli temizlenmesi önerilir ([docs/08](08-giris-sistemi.md#kvkk-saklanan-veriler)).
5. Oyuncularınızın bir kısmı büyük olasılıkla çocuk; bunun doğurduğu yükümlülükleri hukukçunuza
   sorun.

**VERBİS:** 50'den az çalışanı **ve** yıllık mali bilançosu 100 milyon TL'nin altında olan veri
sorumluları kayıttan muaf görünüyor; hobi sunucusu muhtemelen muaftır (DOĞRULANMADI). 5651 sayılı
kanun kapsamında sohbetli bir oyun sunucusunun "yer sağlayıcı" mı "içerik sağlayıcı" mı sayılacağı
da belirsizdir; hukuki görüş alın.

## Mojang kullanım kuralları (sunucu ve mağaza)

Minecraft Kullanım Kuralları (minecraft.net/usage-guidelines) özetle (özet arama sonuçlarından,
metnin kendisiyle DOĞRULANMADI; satışa başlamadan önce güncel metni okuyun):

- **Oyun avantajı satılamaz** (pay-to-win yasak): daha güçlü eşya, ek can, özel kit, hızlanma vb.
- **Kozmetikler serbesttir** (pelerin hariç): renkli isim, sohbet öneki, parçacık efekti, evcil
  hayvan görünümü gibi.
- Ücretli giriş varsa herkes için aynı fiyat olmalıdır.
- Mağaza Mojang/Microsoft ile bağlantılı olmadığını belirtmeli, satın alma geçmişi ve iletişim
  bilgisi sunmalıdır.
- Kurallara uymayan sunucular kara listeye alınabilir.

Bu yüzden önerilen LuckPerms düzeninde `vip` grubu **yalnız kozmetik** ayrıcalıklar içerir
([docs/06](06-eklentiler.md#luckperms-grup-ve-yetki-yolu-önerisi)).
