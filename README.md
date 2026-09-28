# kami — Türkiye Minecraft ağı altyapısı

Bu depo, tek bir sanal sunucuda (VDS) yaklaşık 100 eş zamanlı oyunculu bir Minecraft ağını
kurmak ve işletmek için gereken her şeyi içerir: Velocity proxy, bir giriş bekleme sunucusu
(limbo), bir lobi ve bir ana oyun sunucusu (survival), Bedrock desteği (Geyser/Floodgate),
karma giriş (premium oyuncular otomatik, cracked oyuncular `/register`–`/login`), bot koruması,
ortak izin veritabanı, saatlik şifreli yedek ve tek bir yönetim komutu (`mc`). Kurulum Ubuntu
24.04 (Debian 12/13 de desteklenir) üzerinde betiklerle yapılır; tüm ayarlar `config/`
altındadır ve git ile izlenir. Oyun modu henüz seçilmediği için `survival` genel amaçlı bir
"ana sunucu" olarak kurulur; yeni modlar `mc new-server` ile eklenir.

> Belgeler Linux uzmanı olmayan bir sunucu sahibi için yazıldı. Komutların çoğu olduğu gibi
> kopyalanıp yapıştırılabilir. Emin olunamayan bilgiler **DOĞRULANMADI** diye işaretlidir.

## Karar: DeHost "9950X VDS-16 GB" alınır mı?

**Evet, koşullu olarak.** Hybrid+ VDS 16 GB (8 vCPU, 16 GB DDR5, 240 GB NVMe, 1 Gbit, ücretsiz
DDoS koruması) bu depodaki düzeni (Velocity + lobi + tek survival) yaklaşık 100 oyuncuyla
taşıyabilir. Koşullar:

- **İlk sınır RAM'dir.** Heap'ler toplam 9,5 GB; JVM ek yükü, MariaDB ve işletim sistemiyle
  birlikte ~13–15 GB kullanılır. Üçüncü bir oyun modu eklemek 24 veya 32 GB pakete geçmeyi
  gerektirir.
- **Sunucu başına tavan, tek iş parçacıklı ana döngüdür (tick).** Bir Paper sunucusu tüm
  dünyalarını tek çekirdekte işler; ön-üretilmiş dünya ve ölçülü görüş mesafesiyle tek bir
  survival sunucusu için tahmini tavan **~100–130 oyuncudur** (DOĞRULANMADI, ölçün). Bunun
  ötesi daha büyük VDS ile değil, ikinci bir sunucu/parça (shard) ile aşılır.
- **X3D garanti değildir.** Paket adı "9950X & 9950X3D" diyor; hangisinin verileceği ve sanal
  işlemcinizin V-Cache'li yongaya sabitlenip sabitlenmediği bilinmiyor. Kapasiteyi X3D'ye göre
  planlamayın.
- **İlk 24–72 saatte CPU "steal" ölçün.** Akşam yoğun saatleri dahil ortalama steal %1–2'nin
  altında olmalı; yoğun saatte sürekli %5'in üstündeyse düğüm değişikliği isteyin ya da
  bırakın. Yıllık ödemeden önce bunu yapın. Ayrıntı: [docs/01](docs/01-donanim-ve-kapasite.md).

## Mimari

```
                        İnternet (oyuncular)
                                |
          DeHost DDoS koruması (şeffaf kabul edildi — DOĞRULANMADI, bkz. docs/04)
                                |
+-------------------------------|----------------- VDS (Ubuntu 24.04) ----------+
|  UFW: yalnız SSH, 25565/tcp, 19132/udp açık                                    |
|                               |                                               |
|   Java  --> 0.0.0.0:25565/TCP |   Bedrock --> 0.0.0.0:19132/UDP               |
|             +-----------------v-------------------------+                     |
|             |  Velocity (proxy)                         |                     |
|             |  Geyser + Floodgate, Sonar (anti-bot),    |                     |
|             |  LibreLogin (karma giriş), LuckPerms      |                     |
|             +--+--------------+-------------+-----------+                     |
|                | modern forwarding (HMAC imzalı sır)    |                     |
|                v              v             v                                 |
|   limbo 127.0.0.1:30065  lobby 127.0.0.1:30066  survival 127.0.0.1:30067      |
|   (PicoLimbo, giriş      (Paper, RCON 31066)    (Paper, RCON 31067)           |
|    bekleme)                                                                    |
|                                                                               |
|   MariaDB 127.0.0.1:3306 (LuckPerms)     restic yedek (saatlik) --> uzak depo  |
+-------------------------------------------------------------------------------+
```

Dışarıya yalnız Velocity (Java, TCP 25565) ve Geyser (Bedrock, UDP 19132) açıktır. Limbo,
lobi, survival, RCON ve MariaDB yalnız `127.0.0.1` üzerinde dinler; dışarıdan erişilemez.

## Bellek planı (16 GB)

| Süreç | Heap (Xms = Xmx) | Tahmini gerçek kullanım (RSS) |
|---|---|---|
| Velocity + Geyser + Floodgate + Sonar + LibreLogin | 1 GB | ~1,5–2 GB |
| lobby (Paper) | 1,5 GB | ~2,3–2,6 GB |
| survival (Paper) | 7 GB | ~8,5–9 GB |
| limbo (PicoLimbo, Java değil, yerel ikili) | — | ~50 MB |
| MariaDB (`innodb_buffer_pool_size = 384M`) | — | ~0,45 GB |
| İşletim sistemi, restic, dosya önbelleği | — | ~1–1,5 GB |
| **Toplam** | **9,5 GB** | **~13–15 GB** |

RSS değerleri tahmindir (DOĞRULANMADI); `mc status` ve `mc doctor` gerçek değerleri gösterir.
Heap'ler `config/servers/<sunucu>/server.env` içindeki `HEAP` değişkeninden gelir.

## Hızlı başlangıç

Adım adım, açıklamalı anlatım: **[docs/02-kurulum.md](docs/02-kurulum.md)**. Kısaca (sudo
yetkili kullanıcıyla, Ubuntu 24.04 üzerinde):

```bash
sudo apt-get update && sudo apt-get install -y git
sudo git clone https://github.com/mqnnothinq-wq/kami.git /opt/minecraft/kami
sudo nano /opt/minecraft/kami/config/network.env            # sürümler, User-Agent, saklama süreleri
sudo bash /opt/minecraft/kami/scripts/install.sh --dry-run  # önce ne yapacağını görün
sudo bash /opt/minecraft/kami/scripts/install.sh            # Java 25, UFW, MariaDB, gizli değerler, systemd, mc
sudo nano /etc/minecraft/backup.env                         # UZAK yedek deposu (docs/05)
sudo mc build-librelogin                                    # giriş eklentisini kaynaktan derler
sudo mc download                                            # Paper, Velocity, PicoLimbo ve eklentiler
sudo mc init all --accept-eula                              # ilk açılış + ayarlar (Minecraft EULA'yı kabul edersiniz)
sudo mc start all
sudo mc backup all                                          # ilk yedek (yoksa doctor yedek satırını KRİTİK gösterir)
sudo mc doctor                                              # sağlık denetimi
mc status
```

Canlıya almadan önce [docs/08](docs/08-giris-sistemi.md#duman-testi-canlıya-alma-kapısı)
içindeki **giriş duman testini** mutlaka yapın.

## Depo yapısı

| Yol | İçerik |
|---|---|
| `config/network.env` | Ağ geneli ayarlar: sürümler, açık portlar, User-Agent, veritabanı, yedek ve günlük saklama süreleri |
| `config/plugins.list` | Hangi eklentinin hangi sunucuya nereden indirileceği ([docs/06](docs/06-eklentiler.md)) |
| `config/jvm/paper.flags`, `velocity.flags` | JVM bayrakları (Aikar/G1, dil sabitleme, GC günlüğü) |
| `config/servers/<sunucu>/server.env` | Sunucu türü (`velocity`, `paper`, `limbo`), port, RCON portu, heap, CPU payı, OOM önceliği |
| `config/servers/<sunucu>/files/` | Sunucuya uygulanan ayar dosyaları (`mc apply`) |
| `config/servers/<sunucu>/init-commands.txt` | İlk kurulumda RCON ile bir kez çalışan komutlar (oyun kuralları vb.) |
| `scripts/mc` | Yönetim aracı; `/usr/local/bin/mc` bu dosyaya bağlanır ([docs/09](docs/09-komutlar.md)) |
| `scripts/install.sh` | Makineyi hazırlar (paketler, Java, UFW, fail2ban, MariaDB, gizli değerler, systemd) |
| `scripts/download.sh` | Sunucu jar'larını, PicoLimbo'yu ve eklentileri indirir, özetlerini doğrular |
| `scripts/apply-config.sh` | `config/` ağacını sunucu dizinlerine uygular, `jvm.env` ve systemd eklerini üretir |
| `scripts/backup.sh` | restic ile yedek, budama, listeleme, geri yükleme |
| `scripts/new-server.sh` | Yeni bir Paper sunucusu tanımlar |
| `scripts/build-librelogin.sh` | LibreLogin'i sabit commit'ten derler |
| `scripts/lib.sh`, `scripts/rcon.py` | Ortak yardımcılar, bağımlılıksız RCON istemcisi |
| `systemd/` | `mc@.service` şablonu, konsol FIFO'su ve zamanlayıcılar (yedek, budama, günlük yeniden başlatma) |
| `host/` | İşletim sistemi ayar dosyaları (sysctl, journald, MariaDB, fail2ban, THP, otomatik güncelleme) |
| `tests/` | Testler: `YQ=/usr/local/bin/yq bash tests/run.sh` (shellcheck ve mikefarah yq gerekir) |
| `docs/` | Bu belgeler |

## Belgeler

1. [Donanım ve kapasite](docs/01-donanim-ve-kapasite.md) — VDS değerlendirmesi, steal ölçümü, DeHost'a sorulacaklar
2. [Kurulum](docs/02-kurulum.md) — sıfırdan canlıya, sorun giderme
3. [Performans](docs/03-performans.md) — ayarların gerekçesi, spark ile ölçüm, gecikmede ne yapılır
4. [Güvenlik ve DDoS](docs/04-guvenlik-ddos.md) — tehdit modeli, güvenlik duvarı, KVKK, Mojang kuralları
5. [Yedekleme](docs/05-yedekleme.md) — restic, uzak depo, geri yükleme, aylık test
6. [Eklentiler](docs/06-eklentiler.md) — kurulu ve önerilen eklentiler, `plugins.list`, LuckPerms grupları
7. [Ölçekleme](docs/07-olcekleme.md) — yeni mod, VDS büyütme, ikinci VDS, Paper 26.3'e geçiş
8. [Giriş sistemi](docs/08-giris-sistemi.md) — karma giriş, komutlar, duman testi, riskler
9. [Komutlar](docs/09-komutlar.md) — `mc` başvurusu, systemd birimleri, dosya konumları

## Bileşen sürümleri

| Bileşen | Sürüm / kaynak | Not |
|---|---|---|
| Paper | 26.2, kanal **STABLE** (Fill v3 API'deki en yeni kararlı build) | 26.3 henüz BETA; 26.3 istemcileri ViaVersion ile girer |
| Velocity | **≥ 4.2.0** (`VELOCITY_VERSION="latest"` = SNAPSHOT olmayan en yeni) | 4.2.1 çıkınca ona geçin (paket seli bellek düzeltmesi); test ettikten sonra sürümü sabitleyin |
| Java | **25**, Eclipse Temurin (`temurin-25-jre`, Adoptium deposu) | Yedek: Ubuntu 24.04'te `openjdk-25-jre` (`--java=openjdk`) |
| Geyser / Floodgate | download.geysermc.org'daki en yeni build (yalnız Velocity'de) | Geyser'in Java tarafı 26.2'yi hedefler |
| LibreLogin | **dev@39397c4** (0.25.0-SNAPSHOT), kaynaktan derlenir | Yayınlanmış 26.x sürümü yok; jar "DO NOT USE IN PRODUCTION" uyarısı basar |
| PicoLimbo | **v1.14.1+mc26.3** (yerel ikili, MIT) | Giriş bekleme sunucusu; 26.3 istemcilerini de kabul eder |
| Sonar | GitHub'daki en yeni sürüm (araştırma sırasında 2.1.52) | Anti-bot; Velocity 4.2 üzerinde çalışması sahada test edilmeli |
| LuckPerms | metadata.luckperms.net'teki en yeni sürüm | Velocity + tüm Paper sunucuları, ortak MariaDB |
| ViaVersion | Hangar'daki en yeni sürüm (araştırma sırasında 5.12.0) | Yalnız Paper sunucularında |
| Chunky, spark | Modrinth | Chunky yalnız survival'da; spark Paper'da gömülü, Velocity'de ayrı eklenti |
| MariaDB, restic | Dağıtım paketleri (Ubuntu 24.04'te restic 0.16.4) | |
| yq | mikefarah v4.53.6 (SHA-256 sabit) | Ubuntu'daki `yq` paketi farklı bir araçtır |

## Önemli uyarılar

- **LibreLogin kendi derlediğiniz bir geliştirme sürümüdür.** Açılışta "DO NOT USE THIS IN
  PRODUCTION" uyarısı basması beklenen durumdur. Canlıya almadan önce ve Velocity, Floodgate ya
  da LibreLogin her güncellendiğinde [giriş duman testini](docs/08-giris-sistemi.md#duman-testi-canlıya-alma-kapısı)
  yapın. Test geçmezse canlıya almayın.
- **Satın almadan önce DeHost'a soruları sorun** ([docs/01](docs/01-donanim-ve-kapasite.md#satın-almadan-önce-dehosta-sorulacak-11-soru)):
  gerçek çekirdek mi, 9950X mi X3D mi, DDoS koruması şeffaf mı ters vekil mi, hangi şehir.
  Özellikle DDoS sorusunun cevabı Velocity'deki `haproxy-protocol` ayarını belirler; yanlış
  değer **tüm bağlantıları** bozar.
- **DeHost'un yedekleri ücretli ektir** ve siz satın almadıkça verinizden siz sorumlusunuz.
  Bu depo saatlik restic yedeği alır ama varsayılan depo **aynı makinededir**. Kurulumdan hemen
  sonra `/etc/minecraft/backup.env` içinde **uzak** bir depo tanımlayın ve
  `/etc/minecraft/restic.pass` dosyasının bir kopyasını makine dışında saklayın
  ([docs/05](docs/05-yedekleme.md)).
- **Paper 26.3'e erken geçmeyin.** 26.3 Fill'de STABLE olana, Geyser ve kullandığınız eklentiler
  26.3'ü destekleyene kadar 26.2'de kalın. Dünya ileri dönüştürülür, **geri dönüş yoktur**
  ([docs/07](docs/07-olcekleme.md#paper-263e-geçiş-kontrol-listesi)).
- `config/servers/velocity/files/plugins/librelogin/messages.conf` içindeki
  `ornek.com/kvkk` adresini kendi KVKK aydınlatma metninizin adresiyle değiştirin
  ([docs/04](docs/04-guvenlik-ddos.md#kvkk-kişisel-verilerin-korunması)).
