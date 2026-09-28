# 02 — Kurulum (sıfırdan canlıya)

Bu belge, boş bir VDS'ten oyuncuların girebildiği bir ağa kadar her adımı sırayla anlatır.
Komutları olduğu gibi kopyalayın; `203.0.113.10` gördüğünüz yerlere kendi sunucu IP'nizi,
`yonetici` yerine kendi kullanıcı adınızı yazın.

Toplam süre: kabaca 1–2 saat (dünya ön-üretimi hariç).

**Neye ihtiyacınız var?**

- VDS (Ubuntu 24.04) ve DeHost panelinde verilen root parolası
- Windows, macOS ya da Linux bir bilgisayar (SSH istemcisi Windows 10/11'de hazır gelir)
- Test için: bir premium (Mojang) Java hesabı, bir cracked Java istemcisi, bir Bedrock cihazı
  (telefon/konsol/Windows)
- İsteğe bağlı: bir alan adı (ör. `oyna.ornek.com`)

## İçindekiler

1. [VDS siparişi](#1-vds-siparişi)
2. [SSH ile ilk bağlantı](#2-ssh-ile-ilk-bağlantı)
3. [Yönetici kullanıcı ve SSH anahtarı](#3-yönetici-kullanıcı-ve-ssh-anahtarı)
4. [Depoyu indirin](#4-depoyu-indirin)
5. [Ayarları gözden geçirin](#5-ayarları-gözden-geçirin)
6. [install.sh ile makineyi hazırlayın](#6-installsh-ile-makineyi-hazırlayın)
7. [Uzak yedek deposu](#7-uzak-yedek-deposu)
8. [LibreLogin'i derleyin](#8-librelogini-derleyin)
9. [Sunucu dosyalarını indirin](#9-sunucu-dosyalarını-indirin)
10. [mc init ile ilk kurulum](#10-mc-init-ile-ilk-kurulum)
11. [Başlatın ve sağlık denetimi](#11-başlatın-ve-sağlık-denetimi)
12. [Giriş testleri](#12-giriş-testleri)
13. [Yönetici yetkisi (LuckPerms / OP)](#13-yönetici-yetkisi-luckperms--op)
14. [Dünya ön-üretimi (Chunky)](#14-dünya-ön-üretimi-chunky)
15. [DNS](#15-dns)
16. [Duman testi ve canlıya alma](#16-duman-testi-ve-canlıya-alma)
17. [Sorun giderme](#17-sorun-giderme)

## 1. VDS siparişi

- Paket: Hybrid+ VDS 16 GB. Siparişten önce [docs/01](01-donanim-ve-kapasite.md#satın-almadan-önce-dehosta-sorulacak-11-soru)
  içindeki soruları sorun; mümkünse aylık başlayıp ilk 24–72 saatte steal ölçün.
- İşletim sistemi: **Ubuntu 24.04 LTS (64 bit)**. Debian 12/13 de desteklenir ama belgeler
  Ubuntu'ya göre yazıldı.
- Panelden sunucunun **IP adresini** ve **root parolasını** not edin. Paneldeki VNC/HTML5 konsolu,
  SSH'a erişemediğinizde kurtarma yoludur; yerini öğrenin.

## 2. SSH ile ilk bağlantı

Windows'ta **PowerShell**'i açın (Başlat → "PowerShell"); macOS/Linux'ta Terminal'i açın:

```powershell
ssh root@203.0.113.10
```

İlk bağlantıda "Are you sure you want to continue connecting?" sorusuna `yes` yazın, sonra root
parolasını girin (yazarken ekranda görünmez). Girdikten sonra sistemi güncelleyin:

```bash
apt-get update && apt-get -y upgrade
# Çekirdek güncellendiyse yeniden başlatın (sonra tekrar bağlanın):
[ -f /var/run/reboot-required ] && reboot
```

## 3. Yönetici kullanıcı ve SSH anahtarı

Her işi root olarak yapmak yerine `sudo` yetkili bir kullanıcı açın (hâlâ root oturumundasınız):

```bash
adduser yonetici            # parola ve (isteğe bağlı) bilgiler sorulur
usermod -aG sudo yonetici
```

Şimdi **kendi bilgisayarınızda** (sunucuda değil) bir SSH anahtarı oluşturup sunucuya
yükleyin. Anahtar, paroladan çok daha güvenlidir.

**Windows (PowerShell):**

```powershell
ssh-keygen -t ed25519 -C "yonetici@kami"
# Enter'a basarak varsayılan konumu kabul edin; bir anahtar parolası (passphrase) belirleyin.

# Açık anahtarı sunucuya yükleyin (Windows'ta ssh-copy-id yoktur):
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh yonetici@203.0.113.10 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
```

**macOS / Linux:**

```bash
ssh-keygen -t ed25519 -C "yonetici@kami"
ssh-copy-id yonetici@203.0.113.10
```

**Deneyin** (root oturumunu kapatmadan, yeni bir pencerede):

```powershell
ssh yonetici@203.0.113.10
sudo whoami        # "root" yazmalı
```

SSH girişinde kullanıcı parolası değil, (belirlediyseniz) anahtar parolası sorulmalı; `sudo` ise
kullanıcı parolanızı ister (bu normaldir). Bu çalışana kadar root oturumunu açık tutun. Parola girişini kapatma işini 6. adımda `--harden-ssh` ile yapacağız.

Bundan sonraki tüm komutlar `yonetici` kullanıcısıyla, `sudo` ile çalıştırılır.

## 4. Depoyu indirin

Depo **`/opt/minecraft/kami`** konumunda olmalıdır (systemd birimleri ve zamanlayıcılar bu yolu
bekler; `/root` ya da `/home` altına koymayın).

```bash
sudo apt-get update && sudo apt-get install -y git
sudo git clone https://github.com/mqnnothinq-wq/kami.git /opt/minecraft/kami
cd /opt/minecraft/kami
# Bir kez: depodaki değişiklikleri işlerken (sudo git commit) kullanılacak ad ve adres.
# Yapılmazsa commit "Author identity unknown" hatasıyla durur.
sudo git config --global user.name "Adınız"
sudo git config --global user.email "adres@ornek.com"
```

Depo özelse GitHub bir erişim jetonu (token) ya da "deploy key" ister. Kendi çatalınızı (fork)
kullanıyorsanız adresi ona göre değiştirin.

Depo root'a ait olmalı ve başkaları yazamamalıdır: zamanlayıcılar buradaki betikleri root olarak
çalıştırır. `sudo git clone` bunu zaten sağlar; install.sh aksini görürse uyarır.

## 5. Ayarları gözden geçirin

Dosyaları `sudo nano <dosya>` ile düzenleyebilirsiniz (kaydet: Ctrl+O, Enter; çık: Ctrl+X).
Yaptığınız değişiklikleri `sudo git -C /opt/minecraft/kami diff` ile görürsünüz.

| Dosya | Neye bakın |
|---|---|
| `config/network.env` | `DOWNLOAD_USER_AGENT`: PaperMC indirme servisi iletişim bilgisi içeren bir User-Agent ister; kendi adresinizle değiştirin. `VELOCITY_VERSION` (ilk kurulumda `latest` kalabilir; testten sonra sabitleyin). `LOG_RETENTION_DAYS` (KVKK saklama süresi, varsayılan 90). `BACKUP_KEEP_*` (yedek saklama). |
| `config/servers/velocity/files/velocity.toml` | `motd` (sunucu listesinde görünen açıklama, MiniMessage biçimi; hatalı etiket proxy'yi açılmaz yapar). `show-max-players`. |
| `config/servers/velocity/files/plugins/Geyser-Velocity/config.yml` | `gameplay.server-name` (Bedrock menüsünde görünen ad). |
| `config/servers/velocity/files/plugins/librelogin/messages.conf` | `prompt-register` içindeki `ornek.com/kvkk` adresini kendi aydınlatma metninizin adresiyle değiştirin ([docs/04](04-guvenlik-ddos.md#kvkk-kişisel-verilerin-korunması)). |
| `config/servers/limbo/files/server.toml` | `welcome_message` ve sekme listesi metinleri. |
| `config/servers/lobby/files/server.properties`, `survival/...` | `max-players`, `difficulty`; görüş mesafeleri için önce [docs/03](03-performans.md) okuyun. |

Ayarların anlamları: [docs/03](03-performans.md) (performans), [docs/08](08-giris-sistemi.md)
(giriş). Kurulumdan sonra değişiklik yaptığınızda `sudo mc apply` ve yeniden başlatma gerekir.

## 6. install.sh ile makineyi hazırlayın

Önce **kuru çalıştırma** ile ne yapacağını görün (hiçbir şeyi değiştirmez), sonra gerçekten
çalıştırın:

```bash
sudo bash /opt/minecraft/kami/scripts/install.sh --dry-run
sudo bash /opt/minecraft/kami/scripts/install.sh
```

**Seçenekler:**

| Seçenek | Anlamı |
|---|---|
| `--dry-run` | Hiçbir şeyi değiştirmeden yapılacak her işlemi `[kuru]` önekiyle yazdırır |
| `--java=temurin` | Java 25'i Adoptium deposundan `temurin-25-jre` olarak kurar (**varsayılan**) |
| `--java=openjdk` | Ubuntu 24.04'ün kendi `openjdk-25-jre` paketini kullanır (Debian 12'de yok) |
| `--no-swap` | Swap yoksa bile 2 GB swap dosyası oluşturmaz |
| `--harden-ssh` | SSH'ta parola girişini kapatır. **Yalnız** komutu çalıştıran kullanıcının `authorized_keys` dosyasında anahtar varsa çalışır; yoksa reddeder |

**Ne yapar?** (Tekrar çalıştırmak güvenlidir; var olan gizli değerlere ve yedek parolasına asla
dokunmaz.)

- Paketler: curl, git, jq, procps, ufw, fail2ban, python3, restic, zstd, mariadb-server, sysstat,
  unattended-upgrades
- Java 25 ve `/usr/bin/java`'nın Java 25'i göstermesi (`update-alternatives`); sürümün ön sürüm
  (`-` içeren) olmadığı denetlenir
- mikefarah `yq` v4.53.6 (SHA-256 doğrulamalı) → `/usr/local/bin/yq`
- `minecraft` sistem kullanıcısı; LibreLogin derlemesi için ayrı, grupsuz ve oturum açamayan
  `kami-build` sistem kullanıcısı; `/opt/minecraft/servers` (sunucular) ve
  `/opt/minecraft/artifacts` (yerelde derlenen jar'lar)
- Saat dilimi `Europe/Istanbul`, NTP
- Çekirdek ağ ayarları, journald sınırları, THP `madvise`, otomatik güncelleme ve needrestart
  ayarları (`host/` dizini)
- 2 GB swap (yoksa)
- UFW: SSH portu(ları), `25565/tcp`, `19132/udp` — başka hiçbir şey
- fail2ban (SSH hapsi)
- Gizli değerler: `/etc/minecraft/secrets.env`, `/etc/minecraft/restic.pass`,
  `/etc/minecraft/backup.env` (hepsi root, 0600)
- MariaDB: `minecraft` kullanıcısı ve `luckperms` veritabanı
- systemd birimleri; yedek (saatlik), budama (04:30) ve **günlük 05:00 yeniden başlatma**
  zamanlayıcılarını etkinleştirir; sunucu birimlerini açılışta başlayacak şekilde etkinleştirir
  (ilk başlatmayı `mc init` yapar)
- `/usr/local/bin/mc` → `/opt/minecraft/kami/scripts/mc`

SSH anahtarıyla girebildiğinizi doğruladıysanız parola girişini kapatın:

```bash
sudo bash /opt/minecraft/kami/scripts/install.sh --harden-ssh
```

Bu, `/etc/ssh/sshd_config.d/00-kami-hardening.conf` dosyasını yazar: `PasswordAuthentication no`,
`KbdInteractiveAuthentication no`, `PermitRootLogin prohibit-password`, `MaxAuthTries 3`.
Yeni bir pencerede tekrar girmeyi deneyin. Kilitlenirseniz DeHost panelindeki VNC konsolundan
girip bu dosyayı silin ve `sudo systemctl reload ssh` çalıştırın.

## 7. Uzak yedek deposu

install.sh saatlik yedeği hemen başlatır, ama varsayılan depo **aynı makinededir**
(`/var/backups/minecraft/restic`) ve makine kaybına karşı korumaz. DeHost'un yedek hizmeti
ücretli bir ektir. Şimdi bir uzak depo tanımlayın:

```bash
sudo nano /etc/minecraft/backup.env
```

Örnekler (SFTP, S3 uyumlu B2/R2) ve ayrıntılar: [docs/05](05-yedekleme.md#uzak-depo-kurulumu).
Ayrıca parolanın bir kopyasını **makine dışında** (parola yöneticisi) saklayın:

```bash
sudo cat /etc/minecraft/restic.pass
```

Parola kaybolursa yedekler **açılamaz**.

## 8. LibreLogin'i derleyin

Karma giriş eklentisi LibreLogin'in 26.x/Velocity 4 ile çalışan yayınlanmış bir sürümü yok; sabit
bir geliştirme commit'inden (`LIBRELOGIN_COMMIT`, `config/network.env`) derlenir:

```bash
sudo mc build-librelogin
# aynı şey:  sudo /opt/minecraft/kami/scripts/build-librelogin.sh
```

Ne yapar:

1. `config/plugins.list`'teki LibreLogin satırının bu commit'in jar'ını gösterdiğini denetler,
   sonra `https://github.com/kyngs/LibreLogin` (dal `dev`) deposunu `/var/tmp` altında root'a ait
   geçici bir dizinin içine klonlar ve `LIBRELOGIN_COMMIT` commit'ine geçer.
2. JDK 25 gerekir: sistemde zaten bir JDK 25 `javac` yoksa `temurin-25-jdk`'yı install.sh'in
   eklediği Adoptium deposundan geçici olarak kurar, iş bitince (derleme başarısız olsa da)
   kaldırır (`--keep-jdk` ile bırakılır; zaten kuruluysa dokunulmaz). Kurma/kaldırma
   `/usr/bin/java` seçimini (sunucuların kullandığı Java) değiştirirse betik eskisini geri koyar.
3. Klonlamayı ve `./gradlew --no-daemon build` komutunu **ayrı, yetkisiz `kami-build` sistem
   kullanıcısıyla** (install.sh oluşturur, yoksa betik oluşturur; ek grubu, evi ve kabuğu yoktur;
   geçici bir HOME ile) çalıştırır; asla root ya da `minecraft` olarak değil, çünkü derleme
   indirilen kodu çalıştırır. Komutlar denetim uçbirimi olmadan çalışır ve çıktılarındaki denetim
   karakterleri silinir. Gradle bitince `kami-build`'in **tüm** süreçleri durdurulur; jar ancak
   ondan sonra okunur. Geçici dizin sonunda silinir.
4. Çıktıyı `/opt/minecraft/artifacts/LibreLogin-39397c4.jar` (commit'in ilk 7 hanesi) ve yanına
   `LibreLogin-39397c4.jar.sha256` olarak koyar, SHA-256 özetini ve sonraki adımı yazar.

Seçenekler: `--commit <sha>` (başka bir commit; 7–40 onaltılık hane), `--keep-jdk` (JDK'yı
bırak), `--dry-run` ya da `-n` (hiçbir şey kurmadan/indirmeden yalnız ne yapılacağını yazar),
`--help`.

- Derleme internet ister (GitHub, Maven Central, repo.papermc.io, repo.kyngs.xyz,
  services.gradle.org), birkaç yüz MB geçici alan kullanır ve birkaç dakika sürer.
  Ağ ya da derleme hatasında Türkçe bir hata mesajıyla durur; tekrar deneyebilirsiniz.
- `network.env`'deki `LIBRELOGIN_COMMIT` ile `config/plugins.list`'teki
  `$MC_ROOT/artifacts/LibreLogin-<ilk7>.jar` satırı **aynı commit'i** göstermelidir; göstermiyorsa
  betik derlemeye başlamadan hata verir (yoksa `mc download` eski jar'ı kurardı). `--commit` ile
  başka bir commit derlerseniz yalnız uyarır ve "`mc download` bu jar'ı kurmaz" der: o commit'i
  kullanacaksanız iki satırı birlikte güncelleyin, sonra giriş duman testini yeniden yapın.
- `kami-build` kullanıcısını başka işe kullanmayın: derleme başlarken bu kullanıcının çalışan bir
  süreci varsa betik reddeder (artık süreçleri `sudo pkill -KILL -U kami-build` ile durdurun).
- `/var/tmp` noexec bağlıysa (bazı sıkılaştırma rehberleri böyle yapar) `gradlew` çalıştırılamaz ve
  betik bunu söyleyerek durur. Çalıştırılabilir bir dizin verin:
  `sudo install -d -m 0755 /opt/kami-tmp && sudo env TMPDIR=/opt/kami-tmp mc build-librelogin`.
- Aynı commit'i yeniden derlerseniz dosyanın üzerine yazılır; derleme bire bir tekrarlanabilir
  olmadığından özet değişebilir (betik bunu uyarı olarak yazar). Aynı anda yalnız bir derleme
  çalışabilir.
- Jar'ı Velocity'ye koyan `sudo mc download plugins velocity`'dir (9. adımdaki `mc download` bunu
  zaten yapar). Velocity daha önce çalıştıysa jar `plugins/update/` altına iner ve
  `sudo mc restart velocity` ile devreye girer.
- `--java=openjdk` ile kurduysanız Adoptium deposu eklenmemiştir; önce Ubuntu'nun
  `openjdk-25-jdk-headless` paketini kurmanız gerekebilir (JDK 25 `javac` varsa betik onu
  kullanır).

## 9. Sunucu dosyalarını indirin

```bash
sudo mc download --dry-run     # ne indirileceğini gösterir
sudo mc download               # Paper, Velocity, PicoLimbo ve config/plugins.list'teki eklentiler
```

- Paper ve Velocity PaperMC'nin Fill v3 API'sinden, SHA-256 doğrulamalı iner.
- PicoLimbo GitHub sürümünden iner (GitHub özet bilgisi varsa doğrulanır).
- Eklentiler kaynağın verdiği özetle (Modrinth sha512, Geyser/Hangar sha256…) doğrulanır;
  LibreLogin `/opt/minecraft/artifacts/` altından kopyalanır. 8. adımı atladıysanız LibreLogin
  satırı "local: dosya yok … (LibreLogin için önce: sudo mc build-librelogin)" hatası verir.
- Sonda bir özet tablo basılır. Bir kaynak başarısız olursa diğerlerine devam edilir ve komut
  1 ile çıkar; sorunu giderip tekrar çalıştırın (zaten inmiş olanlar atlanır).
- GitHub API saatte 60 isteği aşarsanız bir jetonla çalıştırın. Jetonu komut satırına yazmayın
  (`ps` çıktısında ve kabuk geçmişinde görünür); gizli olarak okutup aktarın:

  ```bash
  read -rs GITHUB_TOKEN && export GITHUB_TOKEN     # jetonu yapıştırın, Enter (ekranda görünmez)
  sudo --preserve-env=GITHUB_TOKEN mc download
  unset GITHUB_TOKEN
  ```

## 10. mc init ile ilk kurulum

```bash
sudo mc init all --accept-eula
```

`--accept-eula` ile **Minecraft EULA'sını** (https://aka.ms/MinecraftEULA) kabul etmiş olursunuz;
bu seçenek olmadan komut EULA bağlantısını gösterip çıkar.

Sıra: önce `limbo`, `lobby`, `survival`, en son `velocity`. Her sunucu için:

- **Paper (lobby, survival):** `eula.txt` yazılır → ayarlar uygulanır → **ilk açılış**
  (eklentiler kendi ayar dosyalarını üretir, survival dünyası oluşturulur) → durdurulur → ayarlar
  yeniden uygulanır (artık eklenti dosyaları var) → **ikinci açılış** → `init-commands.txt`
  satırları RCON ile sırayla çalıştırılır (lobinin oyun kuralları, saat, hava) → durdurulur.
- `gamerule minecraft:…` satırlarından biri hata yanıtı alırsa (ör. "Unknown or incomplete
  command", "Incorrect argument", "Unknown game rule", `<--[HERE]`) aynı komut bir kez
  `minecraft:` öneki olmadan denenir; hangi biçimin çalıştığı günlüğe yazılır.
- **Velocity:** ayarlar uygulanır → ilk açılış (Geyser, Floodgate, Sonar, LuckPerms dosyalarını
  üretir; Floodgate `key.pem` anahtarını oluşturur) → durdurulur → ayarlar yeniden uygulanır.
- **limbo (PicoLimbo):** EULA/RCON yok; açılır, `127.0.0.1:30065`'i dinliyor mu bakılır,
  durdurulur. Dış arayüzde dinliyorsa hata verir.

Her açılışta hazır satırı en çok 10 dakika beklenir; hata olursa günlüğün son satırları basılır.
Bir init komutu başarısız olursa sonda listelenir; `sudo mc rcon <sunucu> "<komut>"` ile elle
tamamlayabilirsiniz.

## 11. Başlatın ve sağlık denetimi

```bash
sudo mc start all       # önce limbo/lobby/survival, en son velocity
mc status               # durum, bellek (RSS), heap
sudo mc log velocity    # canlı günlük; çıkmak için Ctrl+C
sudo mc backup all      # ilk yedek (depoyu da ilk kez oluşturur)
sudo mc doctor
```

Velocity günlüğünde şunları görmeniz **normaldir**:

- `!! THIS IS NOT A RELEASE, USE THIS ONLY IF YOU WERE INSTRUCTED TO DO SO. DO NOT USE THIS IN
  PRODUCTION !!` — LibreLogin'in geliştirme sürümü olduğu için basılır; bu yüzden duman testi
  zorunludur ([docs/08](08-giris-sistemi.md)).
- Velocity'nin "offline mode" uyarısı — karma giriş nedeniyle `online-mode = false`; premium
  oyuncuları LibreLogin oyuncu bazında online moda zorlar.

`mc doctor` her satıra `[TAMAM]`, `[UYARI]` ya da `[KRİTİK]` yazar: Java sürümü, RAM bütçesi,
swap, CPU steal, `secrets.env` izinleri, UFW, portların yalnız 127.0.0.1'de dinlenmesi, disk,
yedek deposunun yeri ve son yedeğin yaşı, sunucu dosyaları. **Kritik** satırları giderin. Uzak
depo tanımlamadıysanız "Yedek deposu yerel" uyarısı görürsünüz; bu bilinçli bir uyarıdır. Henüz
hiç yedek alınmadıysa yedek satırı da **kritik** çıkar ("restic snapshots çalışmadı" — uzak depo
ilk yedekte oluşturulur — ya da "Hiç yedek yok"); `sudo mc backup all` başarıyla bittikten sonra
`sudo mc doctor`'ı tekrarlayın.

## 12. Giriş testleri

Sunucu adresi: IP'niz ya da alan adınız (Java için port yazmanız gerekmez: 25565).

1. **Premium Java hesabı:** Sonar bot doğrulaması premium oyuncuları da kapsar: bir adla bir
   IP'den ilk bağlantıda "tekrar bağlan" diyerek bağlantıyı keser — tekrar bağlanın. Sonra
   doğrudan lobiye düşmelisiniz ve "Premium hesabınla otomatik giriş yapıldı" mesajı görünmeli.
   Şifre sorulmamalı.
2. **Cracked Java istemcisi (Mojang'da kayıtlı olmayan bir adla):** ilk bağlantıda Sonar bot
   doğrulaması yapar ve "tekrar bağlan" diyerek bağlantıyı keser — tekrar bağlanın. Boş bir
   bekleme alanına (limbo) düşer ve `/register <şifre> <şifre>` istenir. Kayıttan sonra lobiye
   geçersiniz.
3. **Bedrock (telefon/konsol/Windows):** Sunucu ekle → adres: IP ya da alan adı, port: `19132`.
   Şifresiz lobiye düşmeli; adınız `.` önekiyle görünür (ör. `.Ahmet`).
4. Lobiden ana sunucuya: `/server survival`; geri: `/server lobby`. (Lobi menüsü/NPC eklentisi
   kurulana kadar oyuncular bu komutları kullanır.)

## 13. Yönetici yetkisi (LuckPerms / OP)

İzinler LuckPerms ile yönetilir; Velocity ve tüm Paper sunucuları aynı MariaDB veritabanını
kullandığı için bir kez verilen yetki her yerde geçerlidir.

**Önemli:** yetkiyi, oyuncu ağa **en az bir kez girdikten sonra** verin. Karma girişte UUID'ler
Mojang'dan değil LibreLogin'den gelir: Java oyuncuları (premium da olsa) addan türetilen
"offline" UUID alır, Bedrock oyuncuları `00000000-0000-0000-…` ile başlayan Floodgate UUID'si
alır. Oyuncu girmeden adla yetki verirseniz LuckPerms yanlış (Mojang) UUID'ye yazabilir.
**Mojang UUID'sini asla `/lp`'ye yapıştırmayın**; adı kullanın ya da doğru UUID'yi
`sudo mc cmd velocity librelogin user info <ad>` ile öğrenin (yanıt `sudo mc log velocity`'de).

Yönetici hesabınızla bir kez girip çıktıktan sonra (lobi çalışıyor olmalı):

```bash
# Tırnaklar önemli: yoksa kabuk "*" işaretini dosya adlarına çevirir.
sudo mc rcon lobby "lp user OyuncuAdiniz permission set * true"

# Bedrock hesabı için adın başında nokta vardır:
sudo mc rcon lobby "lp user .OyuncuAdiniz permission set * true"
```

`*` her şeye izin verir; yalnız kurucu hesabına verin. Kalıcı düzen için grup ve yetki yolu
(track) kurun: [docs/06](06-eklentiler.md#luckperms-grup-ve-yetki-yolu-önerisi). Değişiklik bir
sunucuya yansımadıysa (eklenti mesajları oyuncu bağlantıları üzerinden gider; o an oyuncusu
olmayan sunuculara ulaşmaz) `lp sync`'i **o sunucuda** çalıştırın; komut yalnız çalıştığı
sunucunun verisini veritabanından yeniler: `sudo mc rcon survival "lp sync"` (Velocity için:
`sudo mc cmd velocity lpv sync`). Velocity tarafındaki komut `lpv`'dir (ör. oyun içinde
`/lpv user <ad> info`).

**OP** yalnız o Paper sunucusunda vanilla yetki verir ve proxy'yi kapsamaz; LuckPerms varken
gerekmez. Yine de isterseniz:

```bash
sudo mc rcon survival "op OyuncuAdiniz"
```

**Yönetici hesapları premium olmalıdır.** Premium hesabı Mojang doğrular; cracked bir yetkili
hesabı yalnız şifresi kadar güvenlidir (ve aynı IP'den 30 dakikalık oturum özelliği ortak IP'lerde
risklidir). Premium hesaplarda `librelogin user unregister` ya da `user cracked` **kullanmayın**
([docs/08](08-giris-sistemi.md#yetkili-komutları)).

## 14. Dünya ön-üretimi (Chunky)

Oyuncular gelmeden önce survival dünyasını bir sınır içinde üretmek, oyun sırasındaki en büyük
CPU yükünü (arazi üretimi) ortadan kaldırır. Chunky yalnız survival'a kuruludur. Sunucu
çalışırken, oyuncu yokken yapın:

```bash
sudo mc start survival
# Dünya sınırı: "set" değeri ÇAPTIR → 10000 = merkezden her yöne 5000 blok
sudo mc rcon survival "worldborder center 0 0"
sudo mc rcon survival "worldborder set 10000"
# Ön-üretim (sınırla aynı alan)
sudo mc rcon survival "chunky world world"
sudo mc rcon survival "chunky shape square"
sudo mc rcon survival "chunky center 0 0"
sudo mc rcon survival "chunky radius 5000"
sudo mc rcon survival "chunky start"
# İlerleme; durdurma / sürdürme
sudo mc rcon survival "chunky progress"
sudo mc rcon survival "chunky pause"
sudo mc rcon survival "chunky continue"
```

- Chunky bir onay isterse `sudo mc rcon survival "chunky confirm"`.
- Süre ve boyut tahmini (DOĞRULANMADI): 10000 × 10000 alan ≈ 390 bin parça, saniyede 200–800
  parçayla ~10–35 dakika, diskte ~2–6 GB. Önce `chunky radius 1000` ile deneyip ölçekleyebilirsiniz.
  Sürerken `mc log survival` ile izleyin; bu sırada CPU steal ölçümü de yapabilirsiniz.
- **26.x dünya düzeni:** 26.1'den beri tüm boyutlar tek bir `world/` klasöründedir
  (`world/dimensions/minecraft/overworld`, `…/the_nether`, `…/the_end`); `world_nether` ve
  `world_the_end` klasörleri yoktur. Overworld'ün adı `world`'dür. **Nether ve End'in Chunky'deki
  dünya adı DOĞRULANMADI**: oyun içinde yetkili hesapla `/chunky world ` yazıp **Tab**'a basarak
  geçerli adları görün. Nether için yarıçapın 1/8'i yeterlidir (`chunky radius 625`).
- Ön-üretim bitince `sudo mc rcon survival "chunky progress"` tamamlandığını göstermeli. Sınırın
  Nether'da nasıl uygulandığını oyun içinde `/execute in minecraft:the_nether run worldborder get`
  ile kontrol edin.

## 15. DNS

Oyuncuların IP yerine bir ad yazması için alan adınızın DNS paneline bir **A kaydı** ekleyin:

| Tür | Ad | Değer | Not |
|---|---|---|---|
| A | `oyna` | `203.0.113.10` | Oyuncular `oyna.ornek.com` yazar |

Cloudflare kullanıyorsanız kaydı **"DNS only" (gri bulut)** yapın; turuncu bulut (proxy) Minecraft
trafiğini taşımaz.

**İsteğe bağlı SRV kaydı:** oyuncuların doğrudan `ornek.com` yazması (A kaydı alt alanda iken) ya
da standart dışı bir port kullanmanız gerekiyorsa:

| Tür | Ad | Öncelik | Ağırlık | Port | Hedef |
|---|---|---|---|---|---|
| SRV | `_minecraft._tcp` (tam ad: `_minecraft._tcp.ornek.com`) | 0 | 5 | 25565 | `oyna.ornek.com` |

- SRV yalnız Java içindir. **Bedrock SRV desteklemez**: Bedrock oyuncuları adresi ve `19132`
  portunu elle girer.
- Alan adına göre farklı sunucuya yönlendirme (forced hosts) isterseniz hem `velocity.toml`
  `[forced-hosts]` tablosuna hem LibreLogin `config.conf` içindeki `lobby` haritasına eklemeniz
  gerekir ([docs/08](08-giris-sistemi.md#configconf-anahtarları)).
- Ters DNS (rDNS) için DeHost'a sorun (soru 7).

## 16. Duman testi ve canlıya alma

LibreLogin bir geliştirme sürümü olduğu için canlıya almadan önce aşağıdaki testlerin **hepsi**
geçmelidir. Aynı testi Velocity, Floodgate ya da LibreLogin her güncellendiğinde tekrarlayın.
Ayrıntılar: [docs/08](08-giris-sistemi.md#duman-testi-canlıya-alma-kapısı). Java testlerinde her
yeni ad + IP çifti (premium dahil) ilk bağlantıda Sonar'ın "tekrar bağlan" mesajıyla bir kez
atılır; bu bir başarısızlık değildir, tekrar bağlanın.

- [ ] 1. Premium 26.2 istemcisi, Sonar'ın ilk bağlantıdaki bir kerelik "tekrar bağlan"ından
      sonra doğrudan lobiye otomatik girişle düşer;
      `sudo mc cmd velocity librelogin user info <ad>` çıktısında premium UUID dolu.
- [ ] 2. Premium bir adı kullanan cracked istemci **atılır**.
- [ ] 3. Yeni cracked ad: Sonar denetimi → tekrar bağlan → limbo → `/register` → lobi. Giriş
      yapmadan önce `/server survival` ve sohbet engelli.
- [ ] 4. Aynı cracked oyuncu 30 dakika içinde aynı IP'den tekrar gelince otomatik girer; başka
      IP'den gelince önce Sonar denetimi (tekrar bağlan), sonra şifre sorulur.
- [ ] 5. Bedrock oyuncusu (Geyser) şifresiz lobiye `.Ad` olarak düşer.
- [ ] 6. 26.3 istemcisi limbo'ya ve lobiye ulaşır.
- [ ] 7. Adında büyük "I" harfi olan premium bir test hesabı online moda zorlanır (Türkçe dil
      hatası düzeltmesinin kanıtı).
- [ ] 8. `sudo mc restart velocity` sonrası `config.conf` yeniden üretilmez ve günlükte
      "Failed to check if player is coming from Floodgate" satırı yoktur.

Hepsi geçtiyse: `config/network.env` içinde `VELOCITY_VERSION`'ı test ettiğiniz sürüme
sabitleyin (ör. `"4.2.1"`), değişiklikleri depoya işleyin
(`sudo git -C /opt/minecraft/kami add -A && sudo git -C /opt/minecraft/kami commit -m "Canlıya
alındı"`; git kimliği 4. adımda tanımlandı) ve sunucuyu duyurun.

## 17. Sorun giderme

Önce her zaman: `sudo mc doctor`, `mc status`, `sudo mc log <sunucu>`. Geçmiş günlük için:
`sudo journalctl -u mc@<sunucu> --since "1 hour ago" -o cat --no-pager`.

| Belirti | Olası neden | Çözüm |
|---|---|---|
| `mc init limbo`: "30065 portu zaten dinleniyor" ya da günlükte "Address already in use" / "Failed to bind" | Aynı portu başka bir süreç (eski bir sunucu, elle başlatılmış java) kullanıyor | `sudo ss -ltnp \| grep -E '25565\|3006[5-7]\|3106[6-7]'` ile süreci bulun, durdurun. Portu değiştirecekseniz `server.env`'i düzenleyip `sudo mc apply` |
| Sunucu açılmıyor, günlükte "UnsupportedClassVersionError" ya da Java sürüm hatası | `/usr/bin/java` Java 25 değil ya da ön sürüm (EA) | `sudo mc doctor` Java satırı; `sudo update-alternatives --config java` ile Java 25'i seçin ya da install.sh'i yeniden çalıştırın |
| Oyuncu "Your server did not send a forwarding request to the proxy…" (Türkçe istemcide "Sunucun Velocity'ye yönlendirme isteğinde bulunmadı…") ile atılıyor | Paper tarafında Velocity iletimi kapalı. En sık neden: `PAPER_VELOCITY_SECRET` boş/okunamadı; Paper günlüğünde "Velocity is enabled, but no secret key was specified … Disabling velocity" görünür | `/etc/minecraft/secrets.env` içinde `VELOCITY_FORWARDING_SECRET` ve `PAPER_VELOCITY_SECRET` dolu ve **aynı** mı bakın; `paper-global.yml`'de `proxies.velocity.enabled: true` mi (`sudo mc apply`); `sudo mc restart all` |
| Oyuncu "Unable to verify player details" ile atılıyor | **İletim sırrı uyuşmuyor** (Velocity ve Paper farklı sır kullanıyor) | İki değişkeni aynı değere getirin, `sudo mc restart all`. Limbo da aynı `VELOCITY_FORWARDING_SECRET`'i kullanır |
| Oyuncu "This server requires you to connect with Velocity." ile atılıyor | Paper iletim bekliyor ama gelmedi: biri backend'e proxy'yi atlayarak doğrudan bağlanıyor ya da Velocity'de `player-info-forwarding-mode` `MODERN` değil | Backend'ler yalnız 127.0.0.1'de dinlemeli (`sudo mc doctor` port satırları); `velocity.toml`'u depodan yeniden uygulayın (`sudo mc apply velocity`, `sudo mc restart velocity`) |
| **Hiç kimse** bağlanamıyor, istemci hemen kopuyor/zaman aşımı; Velocity günlüğünde HAProxy/çözümleme hataları | `haproxy-protocol` değeri koruma türüyle uyuşmuyor | [docs/04](04-guvenlik-ddos.md#ddos-koruması-şeffaf-mı-ters-vekil-mi): şeffaf korumada `false`, PROXY başlığı gönderen ters vekilde `true` |
| Bedrock oyuncuları bağlanamıyor, Java çalışıyor | UDP 19132 kapalı ya da sağlayıcı süzüyor; Geyser açılmadı | `sudo ufw status` (19132/udp ALLOW olmalı); `sudo ss -lunp \| grep 19132`; `mc log velocity`'de Geyser açılış satırları. DeHost'a UDP 19132'nin süzülüp süzülmediğini sorun |
| Günlükte "DO NOT USE THIS IN PRODUCTION" | LibreLogin geliştirme sürümü | Beklenen durum; duman testini yapın |
| `mc init` "EULA'sını kabul etmelisiniz" diyor | `--accept-eula` verilmedi | EULA'yı okuyun: `sudo mc init all --accept-eula` |
| "Giriş sunucusu şu an kapalı" (kick-no-limbo) | limbo çalışmıyor | `sudo mc start limbo`; `sudo mc log limbo` |
| Cracked oyuncu "Bu isim kullanımda" ya da premium adla atılıyor | Ad Mojang'da kayıtlı (premium) ya da başka biri kaydetmiş | Oyuncu başka bir ad seçmeli; ayrıntı [docs/08](08-giris-sistemi.md) |
| `mc download` LibreLogin için "dosya yok" | 8. adım yapılmadı ya da commit/ad uyuşmuyor | `sudo mc build-librelogin`; `plugins.list` satırı ile `LIBRELOGIN_COMMIT`'in ilk 7 hanesi aynı olmalı |
| `mc build-librelogin`: "Uyuşmazlık: network.env LIBRELOGIN_COMMIT …" | `plugins.list`'teki LibreLogin satırı başka bir commit'in jar'ını gösteriyor | İki satırı aynı commit'e getirin (`$MC_ROOT/artifacts/LibreLogin-<ilk7>.jar`), tekrar çalıştırın |
| `mc build-librelogin`: "noexec bağlı" ya da `gradlew` çıkış 126/127 | Geçici dizin (`/var/tmp`) noexec | `sudo install -d -m 0755 /opt/kami-tmp && sudo env TMPDIR=/opt/kami-tmp mc build-librelogin` |
| `mc apply` "eklenti henüz config üretmedi" uyarısı | Eklenti ilk açılışta dosyasını oluşturmadan önce uygulandı | Sunucuyu bir kez başlatıp durdurun, `sudo mc apply <sunucu>` tekrarlayın (`mc init` bunu kendisi yapar) |
| Değişiklik etkisiz | Ayar uygulanmadı ya da sunucu yeniden başlamadı | `sudo mc apply <sunucu>` → `sudo mc restart <sunucu>` |
| `mc doctor`: "RAM yetersiz olabilir" | Heap toplamı makineye göre fazla | Önerilen kadar `HEAP` düşürün ya da paketi büyütün ([docs/07](07-olcekleme.md)) |
