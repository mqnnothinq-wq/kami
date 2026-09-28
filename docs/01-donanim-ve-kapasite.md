# 01 — Donanım ve kapasite

Bu belge DeHost "9950X VDS-16 GB" (Hybrid+ VDS) paketinin ~100 oyunculu bir ağ için yeterli olup
olmadığını, sınırların nerede olduğunu ve satın almadan önce neyi ölçüp soracağınızı anlatır.

> **Kaynak notu:** DeHost'un sitelerine araştırma sırasında doğrudan erişilemedi; sağlayıcıyla
> ilgili bilgiler arama sonucu özetlerinden derlendi. **DOĞRULANMADI** işaretli her şeyi sipariş
> sayfasından ya da destek talebiyle yazılı olarak teyit edin.

## Karar

**Koşullu olarak alın.** Hybrid+ 16 GB paketi Velocity + lobi + tek survival düzenini yaklaşık
100 eş zamanlı oyuncuyla taşıyabilir; şu koşullarla:

1. Akşam yoğun saatinde ölçülen CPU steal ortalaması **%2'nin altında** kalmalı (aşağıda nasıl
   ölçüleceği var).
2. Heap'ler bu depodaki bütçede kalmalı: Velocity 1 GB, lobi 1,5 GB, survival 7 GB.
3. Survival dünyası oyuncular gelmeden **ön-üretilmeli** (Chunky) ve bir dünya sınırı olmalı;
   görüş/simülasyon mesafesi ölçülü tutulmalı (8/5).

**İlk sınır RAM'dir:** üçüncü bir oyun modu 24 veya 32 GB pakete geçmeyi gerektirir.
**Sunucu başına kesin tavan, survival'ın tek ana iş parçacığıdır** (~100–130 oyuncu,
DOĞRULANMADI). Bunun ötesi daha büyük bir VDS ile değil, ikinci bir survival sunucusu ya da
ikinci bir VDS ile aşılır ([docs/07](07-olcekleme.md)).

Hâlâ bilinmeyenler: 16 GB paketin fiyatı, çekirdeklerin ayrılmış mı paylaşımlı mı olduğu,
X3D verilip verilmeyeceği, DDoS sağlayıcısı/kapasitesi/Minecraft ve UDP kapsamı, veri merkezinin
şehri. Bunları aşağıdaki 11 soruyla yazılı olarak alın.

## Paket bilgileri

"Hybrid+ VDS (AMD RYZEN 9 9950X & 9950X3D)" ürün ailesi
(my.dehost.com.tr/kategori/hybrid-vds-amd-ryzen-9-9950x-9950x3d):

| Paket | vCPU | RAM | NVMe | Ağ / koruma | Güven |
|---|---|---|---|---|---|
| Hybrid+ 8 GB | 4 | 8 GB DDR5 | 100 GB | 1 Gbit, "Yurt İçi + Yurt Dışı Koruma" | orta |
| **Hybrid+ 16 GB (seçilen)** | **8** | **16 GB DDR5** | **240 GB** | aynı | orta–yüksek (5+ kaynakta aynı) |
| Hybrid+ 24 GB | 8 | 24 GB | 300 GB | aynı | orta |
| Hybrid+ 32 GB | 12 | 32 GB | 500 GB | aynı | orta |
| Hybrid+ 48 GB | 14 | 48 GB | 750 GB | aynı | orta |
| Hybrid+ 64 GB | 16 | 64 GB | 1 TB | aynı | orta |

| Konu | Bilinen | Durum |
|---|---|---|
| 16 GB aylık fiyat | Bulunamadı. "359 TL'den başlayan" ifadesi en ucuz pakete ait | **DOĞRULANMADI** |
| Yıllık ödeme | "10 ay öde 12 ay kullan" kampanyası duyuruluyor; KDV dahil mi belli değil | DOĞRULANMADI |
| "Hybrid" ne demek | Açıklanmıyor. Ayrılmış çekirdek, karma havuz ya da karışık 9950X/9950X3D filosu olabilir | **DOĞRULANMADI** |
| "8 Core" | 8 fiziksel çekirdek mi, 8 iş parçacığı (4 çekirdek × SMT) mı belli değil | **DOĞRULANMADI** |
| 9950X mi 9950X3D mi | Seçim yapılabildiğine dair kanıt yok; **X3D'yi garanti saymayın** | DOĞRULANMADI |
| Veri merkezi | Bir sayfa "İstanbul lokasyonu" diyor; kurumsal barındırma Bursa'daki PenDC'de | **DOĞRULANMADI** |
| DDoS koruması | Ücretsiz. Sayfalarda "Mikrotik ve NeoProtect", başka sayfada "Mikrotik ve RouteFence"; Minecraft sayfasında "25565/TCP'ye özel game koruması, L3/L4 kuralları" | Kapasite ve UDP 19132 kapsamı DOĞRULANMADI |
| IPv4 / IPv6 | 1 IPv4 dahil, ek IP sipariş sırasında alınabiliyor; IPv6'dan söz edilmiyor | kısmen |
| Port / trafik | 1 Gbit port; sınırsız mı, adil kullanım mı, paylaşımlı mı belli değil | DOĞRULANMADI |
| Yedek | **Ücretli ek hizmet.** "Yedekleme hizmeti satın almadıkça verilerinizi yedeklemiyoruz; sorumluluk müşteridedir" | orta |
| İşletim sistemi | 25 farklı şablon (Ubuntu, Debian, AlmaLinux, Rocky…); Ubuntu 24.04 büyük olasılıkla var | orta |
| Konsol | Açılış sırasında da çalışan VNC/HTML5 konsol | orta |
| Yerinde yükseltme | "Veri kaybı olmadan istediğiniz pakete geçebilirsiniz"; kesinti süresi ve kıst hesap belli değil | kısmen |

**NeoProtect hakkında not:** 30 Ekim 2025'te CDN77/Datapacket, büyük bir saldırı sonrasında
NeoProtect'in tüm BGP oturumlarını kapattı ve geri açmadı. DeHost'un "NeoProtect" ifadesi bu
olaydan önceye mi ait, bugünkü üst sağlayıcı kim — bilinmiyor. Soru 4'te bunu sorun.

**İtibar:** Şikayetvar'da DeHost hakkında şikâyetler var (ör. "TR Hybrid VDS 4GB (7950X3D)"
için vaat edilen performansın alınamadığı, ~12 saatlik destek yanıtı, birkaç gün süren bir
kesinti/askıya alma). Türk VDS satıcıları için alışılmış bir tablo; eleyici değil ama yıllık
ödemeden önce deneme yapmak ve makine dışı yedek tutmak için bir sebep.

## Neden 9950X / 9950X3D Minecraft'a uygun?

- **Paper her sunucuyu tek ana iş parçacığında işler.** Overworld, Nether ve End sırayla aynı
  iş parçacığında "tick"lenir. Yani bir sunucunun kapasitesini çekirdek sayısı değil, **tek
  çekirdek hızı ve bellek gecikmesi** belirler.
- **Zen 5 tek çekirdekte 2026'nın en hızlıları arasında.** AMD, Zen 4'e göre ortalama %16 IPC
  artışı açıkladı; 9950X 5,7 GHz'e çıkar. 9950X3D tek çekirdekte 9950X ile neredeyse aynıdır
  (X3D tek çekirdek hızı kaybettirmez).
- **X3D'nin 3D V-Cache'i yalnız bir yongadadır (CCD).** 9950X3D'de V-Cache'li CCD'de 96 MB
  (32 + 64 MB), diğerinde 32 MB L3 vardır; toplam 128 MB. Minecraft'ın ana iş parçacığı büyük
  veri yapılarında gezdiği için büyük önbellek muhtemelen yardımcı olur; ancak **X3D ile X3D olmayan arasında titiz bir Minecraft
  MSPT karşılaştırması bulunamadı** (barındırma bloglarında "küçük ama ölçülebilir" deniyor;
  DOĞRULANMADI).
- **Sanal makinede X3D bir piyangodur.** Sağlayıcı sanal işlemcilerinizi V-Cache'li yongaya
  sabitlemezse iş parçacıklarınız sıradan yongada ya da iki yonga arasında bölünmüş çalışabilir.
  Linux'ta 9950X3D varsayılan olarak yeni işleri önbelleksiz yongaya koyar. Bu yüzden X3D'yi
  bonus sayın, kapasite planını ona göre yapmayın. (V-Cache'i iki yongada da olan 9950X3D2
  Nisan 2026'da çıktı; sağlayıcı bunu kullanıyorsa piyango ortadan kalkar.)
- **Velocity farklıdır:** proxy çok çekirdekten yararlanır, tek çekirdek hızı onun için daha az
  önemlidir.

## Kaynak bütçesi

### RAM (16 GB)

| Süreç | Heap | Tahmini RSS |
|---|---|---|
| Velocity (+ Geyser, Floodgate, Sonar, LibreLogin) | 1 GB | ~1,5–2 GB |
| lobby | 1,5 GB | ~2,3–2,6 GB |
| survival | 7 GB | ~8,5–9 GB |
| limbo (PicoLimbo, yerel) | — | ~50 MB |
| MariaDB | — | ~0,45 GB |
| OS, sshd, journald, fail2ban, restic, dosya önbelleği | — | ~1–1,5 GB |
| **Toplam** | **9,5 GB** | **~13–15 GB** |

- JVM'ler `-XX:+AlwaysPreTouch` ve Xms = Xmx ile başlar: heap'in tamamı açılışta ayrılır.
  Bellek yetmiyorsa bunu oyuncu varken değil, açılışta görürsünüz.
- `mc doctor` kaba bir hesap yapar: toplam heap × 1,25 + 1,5 GB ≤ MemTotal. Bu düzende
  gereksinim ~13,4 GiB çıkar; 16 GB bir VDS'te "MemTotal" genelde 15–15,6 GiB görünür.
- "16 GB" ondalık (≈14,9 GiB) çıkarsa (`free -h` ile bakın) survival'ı 6,5 GB'a düşürün:
  `config/servers/survival/server.env` içinde `HEAP="6656M"` (ondalık kabul edilmez; `6.5G`
  `mc apply`'da hata verir), sonra `sudo mc apply survival` ve `sudo mc restart survival`.
- install.sh, swap yoksa 2 GB'lık bir swap dosyası açar (`vm.swappiness=1`). Bu yalnız çekirdeğin
  OOM öldürücüsüne karşı emniyet ağıdır; JVM'ler swap kullanmaya başlarsa (`vmstat`'ta `si`/`so`
  sıfırdan farklı) heap'leri küçültün.
- **Üçüncü bir backend için yer yoktur.** 2 GB'lık bir mod eklemek gereksinimi ~15,9 GiB'e çıkarır.

### CPU (8 vCPU)

- **Survival'ın ana iş parçacığı** yükte yaklaşık tam bir vCPU kullanır; lobi çok az kullanır.
- **Parça (chunk) işçileri:** Paper 8 çekirdekte kendiliğinden 2 işçi seçerdi; VM'deki çekirdek
  algısına bağlı kalmasın diye açıkça yazıldı: survival `2`, lobi `1`.
- **GC iş parçacıkları:** JVM varsayılanı her JVM için 8 (vCPU sayısı). Lobi ve Velocity
  `GC_THREADS="2"` ile sınırlandı ki lobinin GC duraklaması survival'ın çekirdeklerini çalmasın;
  survival varsayılanda (8) kalır.
- **CPU payları** (systemd `CPUWeight`): survival 300, Velocity 200, lobi 100, limbo 50.
- "8 Core" aslında 4 fiziksel çekirdek + SMT ise etkin kapasite kabaca %20–30 düşer (tahmin,
  DOĞRULANMADI). Steal düşük olduğu sürece 8 vCPU 100 oyuncuya yeter.

### Disk (240 GB NVMe)

- İşletim sistemi + çalışma zamanları ~10 GB.
- 5000 blok yarıçaplı (10000 × 10000) ön-üretilmiş bir survival dünyası ~400 bölge dosyası,
  kabaca **2–6 GB** (DOĞRULANMADI; önce 1000 yarıçap üretip alanla ölçekleyin).
- restic yinelenen veriyi bir kez saklar; varsayılan saklama (24 saatlik, 7 günlük, 4 haftalık,
  6 aylık) rahatça sığar. **Ama aynı diskteki yedek, makine kaybına karşı yedek değildir**
  ([docs/05](05-yedekleme.md)).
- `mc doctor` disk %70'i geçince uyarı, %90'ı geçince kritik verir.

### Ağ

- Parça yüklenirken oyuncu başına kabaca 100–200 KB/sn (kaba rehber, DOĞRULANMADI). 100 oyuncuda
  zirvede ~80–160 Mbit/sn, ortalamada çok daha az. **1 Gbit port fazlasıyla yeter.**
- Gerçek ağ riski bant genişliği değil **DDoS**'tur ([docs/04](04-guvenlik-ddos.md)).
- Türk oyuncular için ham donanımdan çok **Türk ISS'lerine ping** önemlidir (Türk Telekom,
  Turkcell Superonline, Vodafone). Soru 10'u sorun; deneme süresinde farklı ISS'lerden
  arkadaşlarınıza ping ölçtürün.

## Oyuncu tavanı

| Kapsam | Tahmini tavan | Koşullar |
|---|---|---|
| Tek survival (Paper 26.x) | **~100–130 oyuncu**, MSPT p95 < 40 ms | Ön-üretilmiş dünya + sınır, görüş ~8 / simülasyon ~5, varlık ve redstone çiftliği sınırları, sade eklentiler |
| Tüm makine | ~100–120 oyuncu (lobi + survival dağılımıyla) | Üçüncü mod önce RAM'e takılır |

Bu değerler tahmindir (DOĞRULANMADI). Büyük çiftlikler, çok sayıda köylü ya da kötü yazılmış
eklentiler tavanı yarıya indirebilir. RAM ve çekirdek eklemek survival'ın tavanını **yükseltmez**;
yalnız daha hızlı tek çekirdek, ikinci bir survival parçası ya da Folia (eklenti uyumsuzluğu
yüksek) yükseltir. Karşılaştırma için: PaperMC topluluğundaki bir optimizasyon rehberi "vanilla'ya
yakın ayarlarla 60–80, büyük tavizlerle 100 oyuncu tek sunucu için sert tavandır" diyor.

## Yükseltme tetikleyicileri

| Belirti (yoğun saatte, sürekli) | Ne yapılır |
|---|---|
| `MemAvailable` < 1,5 GB, JVM'ler swap'e düşüyor, `dmesg`'de OOM öldürücü satırları **ya da** yeni bir backend ekleme planı | Yerinde 24 GB'a (yalnız RAM) ya da 32 GB'a (12 vCPU, 500 GB; CPU da darsa daha mantıklı) geçin |
| Survival MSPT p95 > 40 ms (`spark tps`), 8 vCPU'da yük ortalaması > ~7 ya da steal > %5 | Önce spark ile profil alın ([docs/03](03-performans.md)). CPU sınırıysa 32 GB/12 vCPU'ya ya da adanmış sunucuya geçin |
| > ~150 eş zamanlı oyuncu, ikinci survival parçası ya da 2+ ağır oyun modu | **İkinci VDS**: Velocity ve lobi korumalı makinede kalır, backend'ler ikinci makineye ([docs/07](07-olcekleme.md)) ya da DeHost'un 7950X3D 128 GB adanmış sunucusu |
| Disk > %70 | Eski yedekleri/günlükleri budayın, yedekleri makine dışına taşıyın; yalnız dünyalar büyüyorsa disk için paket büyütün |

## CPU steal nasıl ölçülür?

"Steal" (çalınan zaman), sanal işlemcinizin hazır olduğu halde sağlayıcının fiziksel çekirdeği
başka bir müşteriye verdiği süredir. Minecraft'ın her tick'i 50 ms'lik bir bütçeye sığmak
zorunda olduğundan, yüksek steal doğrudan TPS düşüşü ve "rubber-band" (geri çekilme) olarak
hissedilir. **Yıllık ödemeden önce 24–72 saat, akşam yoğun saatleri dahil** ölçün.

install.sh `sysstat`'ı kurar ve geçmiş kaydını açar; aşağıdakiler kurulumdan sonra hazırdır.

```bash
# Anlık: 60 saniye boyunca her saniye; "st" sütunu = steal yüzdesi
vmstat 1 60

# İşlemci başına steal ve iowait (sysstat)
mpstat -P ALL 1 60

# top içinde: "%Cpu(s)" satırındaki "st"; her işlemciyi ayrı görmek için 1'e basın
top

# Geçmiş: sysstat 10 dakikada bir kaydeder; bugünün CPU özeti
sar -u
# Belirli bir günün kaydı (DD = ayın günü; Ubuntu'da dizin /var/log/sysstat)
sar -u -f /var/log/sysstat/saDD
sar -P ALL -f /var/log/sysstat/saDD

# Kısa sağlık denetimi (5 saniyelik vmstat ortalamasını da yorumlar)
sudo mc doctor
```

Donanımı tanımak ve tek çekirdek performansının saatlere göre değişip değişmediğini görmek için:

```bash
lscpu | grep -Ei 'model name|thread|core|socket|L3'
grep -m1 'model name' /proc/cpuinfo

sudo apt-get install -y sysbench
sysbench cpu --threads=1 --time=60 run    # "events per second" değerini sabah/akşam karşılaştırın
```

Sanal makinede görünen L3 boyutu sanallaştırılmış olabilir; X3D sorusunu sağlayıcıya ayrıca
sorun. Oyun yüküne özgü ölçüm için: Chunky ön-üretimi sırasında saniyedeki parça sayısı ve
oyuncular varken `spark tps` ([docs/03](03-performans.md)).

**Eşikler** (genel VPS rehberleri %10'a kadarını kabul edilebilir sayar; oyun sunucusu daha
katıdır — bu eşikler bizim önerimizdir, DOĞRULANMADI):

| Ortalama steal | Yorum | `mc doctor` |
|---|---|---|
| < %1–2 | İyi | `[TAMAM]` |
| Kısa sıçramalar < %5 | Tolere edilebilir; izlemeye devam | %2 üstü `[UYARI]` |
| **Yoğun saatte sürekli > %5** | Düğüm değişikliği isteyin ya da sağlayıcıyı bırakın | %5 üstü `[KRİTİK]` |

## Satın almadan önce DeHost'a sorulacak 11 soru

Destek talebine olduğu gibi yapıştırabilirsiniz; cevapları yazılı saklayın.

1. "8 Core" ifadesi 8 **ayrılmış fiziksel çekirdek** mi, yoksa 8 iş parçacığı (SMT) mı?
   vCPU:fiziksel CPU paylaştırma (overcommit) oranınız nedir, CPU sabitleme (pinning)
   yapıyor musunuz?
2. Sanal makinem **9950X mi 9950X3D mi** üzerinde çalışacak? X3D seçebilir miyim? Sanal makine
   V-Cache'li CCD'ye sabitleniyor mu? CPU tipi "host-passthrough" mu?
3. Hangi sanallaştırma altyapısını (hypervisor) kullanıyorsunuz? Disk yerel NVMe mi, ağ
   depolaması mı? IOPS sınırı var mı?
4. **DDoS:** NeoProtect mi, RouteFence mi, kendi Mikrotik altyapınız mı? 30 Ekim 2025
   NeoProtect/Datapacket olayından sonra üst sağlayıcınız kim? Kapasite kaç Gbps? **TCP 25565
   için Minecraft Java L7 profili** ve **UDP 19132 için Bedrock/Geyser profili** var mı? Süzme
   sürekli mi, saldırı algılanınca mı devreye giriyor? Yanlış pozitifleri nasıl çözüyorsunuz?
5. Koruma **şeffaf** mı (oyuncuların gerçek IP'leri VDS'e ulaşır) yoksa **ters vekil** (reverse
   proxy) mi? Ters vekilse PROXY protocol (HAProxy) başlığı gönderiliyor mu ve vekil IP
   aralıklarınız nedir?
6. **Yedek:** ek hizmetin fiyatı, sıklığı, saklama süresi, anlık görüntü (snapshot) desteği ve
   geri yükleme süresi nedir?
7. **IPv4:** 1 adet dahil mi, ek IP ücreti nedir? IPv6 var mı? Ters DNS (rDNS) ayarlanabiliyor
   mu? IP kara listelerde temiz mi?
8. **Yükseltme:** 16 → 24 → 32 GB'a yeniden kurulum olmadan yerinde geçebilir miyim? Kesinti ne
   kadar? Ücret kıst (prorata) hesaplanıyor mu? Disk otomatik büyüyor mu? Yükseltmeden sonra
   "10 ay öde 12 ay kullan" geçerli kalıyor mu?
9. Port ayrılmış 1 Gbit mi, paylaşımlı bir çıkış mı? Trafik sınırsız mı, adil kullanım mı?
10. Veri merkezi **hangi şehirde** (İstanbul mu, Bursa/PenDC mi)? Hangi taşıyıcılara bağlı (Türk
    Telekom, Turkcell/Superonline, Vodafone)?
11. Yukarıdaki steal/performans testini yapabilmem için deneme süresi ya da iade hakkı var mı?

Soru 5'in cevabı doğrudan ayar değiştirir: şeffafsa `haproxy-protocol = false` kalır (varsayılan);
ters vekilse değiştirmeniz gerekir. Yanlış değer **tüm bağlantıları** bozar
([docs/04](04-guvenlik-ddos.md#ddos-koruması-şeffaf-mı-ters-vekil-mi)).

## Karşılaştırma notları

Bulunabilen diğer Türk sağlayıcı verileri (arama sonuçlarından; güncelliği DOĞRULANMADI):

| Sağlayıcı / paket | CPU | RAM | Disk | Fiyat | Not |
|---|---|---|---|---|---|
| SunucumBurada "PRE-VDS-TR 16 GB" | 9950X, **4** CPU | 16 GB DDR5-5000 | **85 GB** NVMe | 849,90 ₺/ay | İstanbul, sınırsız trafik, DDoS |
| Sunucum.net.tr "RX1" | 9950X, 4 çekirdek | 4 GB DDR5 | 75 GB NVMe | 400 ₺/ay | 16 GB paket bulunamadı |
| Treas "Ekstrem" | 9950X | DDR5 | Samsung 990 Pro | bulunamadı | 10 Gbit, ücretsiz DDoS |
| Datahost | 9950X & 9950X3D | DDR5 | NVMe | bulunamadı | 10 Gbps; Şikayetvar'da kesinti şikâyeti |
| Tekdora | 9950X | — | — | bulunamadı | Fiyatlar KDV hariç |

Kâğıt üzerinde DeHost 16 GB, bulunabilen tek benzer 16 GB teklife (SunucumBurada, 4 vCPU / 85 GB)
göre **iki kat vCPU ve ~3 kat disk** veriyor. vCPU başına fiyat karşılaştırması için DeHost'un
16 GB fiyatını sipariş sayfasından okuyun (ekran görüntüsü alın; KDV'yi ve yenileme fiyatını
teyit edin).

Ölçek büyüdüğünde DeHost'taki bir sonraki basamak: "Türkiye Lokasyon — AMD Ryzen 9
7950X/7950X3D 128 GB RAM Dedicated" (adanmış sunucu; DOĞRULANMADI).
