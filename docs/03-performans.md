# 03 — Performans

Bu belge `config/` altındaki varsayılan olmayan her performans ayarını, gerekçesini ve oynanışı
değiştirip değiştirmediğini anlatır; ardından spark ile nasıl ölçüleceğini ve gecikme (lag)
olduğunda hangi sırayla ne yapılacağını gösterir.

## Temel kavramlar

- **Tick:** Minecraft sunucusu saniyede 20 kez dünyayı günceller; her güncellemenin bütçesi
  **50 ms**'dir.
- **MSPT (milisaniye / tick):** bir tick'in ne kadar sürdüğü. 50 ms'yi aşınca TPS 20'nin altına
  düşer ve oyuncular gecikme/geri çekilme hisseder.
- **TPS:** saniyedeki tick sayısı. MSPT 50'nin altındaysa TPS 20'dir; bu yüzden TPS'e değil
  **MSPT'ye** bakın — TPS sorun başlayana kadar hep 20 görünür.
- Paper bir sunucunun tüm dünyalarını **tek ana iş parçacığında** işler. Survival'ın kapasitesini
  tek çekirdek hızı belirler ([docs/01](01-donanim-ve-kapasite.md)).

**Hedefler** (survival, yoğun saatte):

| Ölçü | İyi | Dikkat | Sorun |
|---|---|---|---|
| MSPT medyan | < 30 ms | 30–40 ms | > 40 ms |
| MSPT %95'lik | < 40 ms | 40–50 ms | > 50 ms (TPS düşer) |
| CPU steal | < %2 | %2–5 | > %5 |

## Ayarlar nasıl değiştirilir?

Ayarlar depoda, `config/servers/<sunucu>/files/` altındadır. Sunucudaki dosyayı elle
düzenlemeyin: bir sonraki `mc apply` üzerine yazar.

```bash
sudo nano /opt/minecraft/kami/config/servers/survival/files/server.properties
sudo mc apply survival --dry-run   # ne değişecek?
sudo mc apply survival
sudo mc restart survival           # ya da günlük 05:00 yeniden başlatmasını bekleyin
```

- `*.properties` dosyalarında yalnız depodaki anahtarlar değiştirilir, diğer satırlar korunur.
- `*.yml` dosyaları sunucudakiyle **birleştirilir** (depoda olmayan anahtarlar Paper
  varsayılanında kalır). Depodaki bir anahtar sunucu dosyasında yoksa `mc apply` "bilinmeyen/
  yeniden adlandırılmış olabilir" diye uyarır.
- `velocity.toml`, `config.conf` gibi diğer dosyalar **tamamen** depodan gelir.

Aşağıdaki tablolarda "Oynanış" sütunu, ayarın vanilla oyun davranışını değiştirip değiştirmediğini
gösterir (dosyalardaki yorumlarda da "(oynanışı değiştirir)" diye işaretlidir).

## server.properties

| Anahtar | lobby | survival | Varsayılan | Neden | Oynanış |
|---|---|---|---|---|---|
| `view-distance` | 6 | 8 | 10 | Oyuncunun gördüğü parça yarıçapı. Çoğunlukla bellek ve bant genişliği maliyeti (Paper parçaları ayrı iş parçacığında, hız sınırıyla gönderir) | Evet: daha kısa görüş |
| `simulation-distance` | 3 | 5 | 10 | **İşlenen** alan: mob, ekin, redstone. Ana iş parçacığının en büyük maliyeti. 5'te oyuncu başına ~121 parça işlenir, 10'da 441 (~3,6 kat az iş) | Evet: uzak çiftlikler çalışmaz |
| `network-compression-threshold` | -1 | -1 | 256 | 127.0.0.1 hattında sıkıştırma yok; oyuncuya giden paketi yalnız Velocity bir kez sıkıştırır | Hayır |
| `max-players` | 150 | 120 | 20 | Gerçek oyuncu sınırı backend'dedir (Velocity sınırlamaz) | — |
| `difficulty` | peaceful | normal | easy | Lobide canavar yok; survival'da vanilla sunucu varsayılanından farklı | Evet |
| `gamemode`, `force-gamemode` | adventure, true | — | survival | Lobide blok kırılamaz/konamaz | Evet |
| `generate-structures`, `level-type` | false, `minecraft:flat` | — | true, normal | Lobi yapısız düz dünya (yalnız dünya ilk oluşturulurken etkili) | Evet |

Diğer anahtarlar (server-ip, online-mode, RCON, log-ips …) güvenlik ve giriş içindir:
[docs/04](04-guvenlik-ddos.md), [docs/08](08-giris-sistemi.md).

## bukkit.yml

| Anahtar | lobby | survival | Varsayılan | Neden | Oynanış |
|---|---|---|---|---|---|
| `settings.allow-end` | false | — | true | Lobide End dünyası yüklenmez (bellek/CPU) | Evet |
| `spawn-limits.monsters` | 0 | 50 | 70 | Oyuncu başına canavar sınırı. Doğal doğma her işlenen parçada çalışır; en ucuz varlık azaltma yolu | Evet: biraz daha az mob, çiftlik verimi hafif düşer |
| `spawn-limits.animals` | 0 | 8 | 10 | aynı | Evet |
| `spawn-limits.water-animals` | 0 | 3 | 5 | aynı | Evet |
| `spawn-limits.water-ambient` | 0 | 10 | 20 | aynı (balıklar) | Evet |
| `spawn-limits.water-underground-creature` | 0 | 3 | 5 | aynı (parlayan kalamar) | Evet |
| `spawn-limits.axolotls` | 0 | 3 | 5 | aynı | Evet |
| `spawn-limits.ambient` | 0 | 5 | 15 | aynı (yarasa) | Evet |
| `settings.shutdown-message` | Türkçe | Türkçe | "Server closed" | Yerelleştirme | — |

Daha fazla CPU gerekirse survival'da `ticks-per.monster-spawns`, `water-spawns`,
`water-ambient-spawns`, `water-underground-creature-spawns`, `axolotl-spawns` ve `ambient-spawns`
değerlerini 1'den (varsayılan: her tick) 2'ye çıkararak bu doğma denemelerini yarıya
indirebilirsiniz. **`animal-spawns`'a dokunmayın:** varsayılanı zaten 400'dür; 2 yapmak hayvan
doğma denemelerini 200 kat artırır.

## spigot.yml

| Anahtar | lobby | survival | Varsayılan | Neden | Oynanış |
|---|---|---|---|---|---|
| `settings.save-user-cache-on-stop-only` | true | true | false | `usercache.json` her girişte değil yalnız kapanışta yazılır | Hayır |
| `settings.restart-on-crash`, `restart-script` | false, `./yok.sh` | aynı | true, `./start.sh` | Yeniden başlatmayı systemd yapar; ikinci bir sunucu süreci açılmasın | Hayır |
| `world-settings.default.mob-spawn-range` | — | 5 | 8 | Simülasyon mesafesine eşitlendi: işlenmeyen uzak parçalardaki moblar mob sınırını boşuna doldurmasın | Evet (hafif) |
| `merge-radius.item` / `.exp` | — | 2,5 / 3,0 | 0,5 / -1 | Yerdeki eşya ve XP küreleri daha uzaktan birleşir: daha az varlık | Evet |
| `entity-activation-range.animals / monsters / raiders / misc / water / villagers / flying-monsters` | — | 16 / 24 / 48 / 8 / 8 / 16 / 48 | 32 / 32 / 64 / 16 / 16 / 32 / 32 | Bu mesafeden uzak varlıklar seyrek işlenir. Simülasyon 5'te üst sınır zaten 72 blok | Evet: uzak moblar daha az hareket eder |
| `entity-activation-range.tick-inactive-villagers` | — | true | true | Açıkça yazıldı: köylü/demir çiftlikleri bozulmasın | Hayır |
| `entity-tracking-range.players` | 48 | 64 | 128 | Oyuncuların birbirini gördüğü mesafe. Lobide herkes spawn'da; izleme yükü oyuncu sayısının karesiyle büyür | Evet: uzak oyuncular görünmez |
| `entity-tracking-range.animals / monsters / misc` | — | 48 / 48 / 32 | 96 / 96 / 96 | Ağ trafiği ve CPU | Evet: uzaktakiler daha yakında belirir |
| `nerf-spawner-mobs` | — | false (vanilla) | false | Açık bırakıldı; XP/mob çiftlikleri CPU'yu zorlarsa `true` yapın | `true` olursa evet: spawner mobları hareketsiz |

Boyuta özel spigot ayarının anahtarı klasör adı değil boyut kimliğidir, ör.
`world-settings."minecraft:the_nether"`.

## paper-global.yml

| Anahtar | lobby | survival | Varsayılan | Neden | Oynanış |
|---|---|---|---|---|---|
| `chunk-system.worker-threads` | 1 | 2 | -1 (otomatik; 8 çekirdekte 2) | Açıkça yazıldı: VM'deki çekirdek algısına bağlı kalmasın. Survival'da spark'ta parça yükleme birikmesi görülürse 3 yapılabilir | Hayır |
| `chunk-system.io-threads` | -1 | -1 | -1 | Otomatik (1 G/Ç iş parçacığı) | Hayır |
| `collisions.enable-player-collisions` | false | — | true | Spawn kalabalığında itişme yok; hem sıkışma hem CPU azalır | Evet |
| `misc.enable-nether` | false | — | true | Lobide Nether dünyası yüklenmez | Evet |
| `messages.no-permission` | Türkçe | Türkçe | İngilizce | Yerelleştirme | — |

## paper-world-defaults.yml

Tüm dünyalar için varsayılandır; boyuta özel ayar `world/dimensions/minecraft/<boyut>/paper-world.yml`
dosyasına yazılır.

**survival:**

| Anahtar | Değer | Varsayılan | Neden | Oynanış |
|---|---|---|---|---|
| `anticheat.anti-xray.enabled`, `engine-mode` | true, 1 | false | Gömülü madenleri gizler. Mod 1 en ucuzu (yalnız tamamen kapalı madenler); kötüye kullanım görülürse mod 3'e geçin (mod 2 en ağır paketleri üretir, mobil Bedrock oyuncularını yorar) | Hayır (hileyi engeller) |
| `chunks.prevent-moving-into-unloaded-chunks` | true | false | Sunucu yüklenmemiş parçayı eş zamanlı yüklemek için takılmaz; oyuncu kısa süre geri itilir | Evet: hızlı elytra uçuşunda hissedilir |
| `chunks.entity-per-chunk-save-limit` | experience_orb 16, arrow 16, snowball 16, ender_pearl 16, fireball 8, small_fireball 8 | sınırsız | "Lag chunk"/parça bombası kötüye kullanımını engeller | Evet: büyük inci-bekletme (stasis) odaları takılabilir |
| `collisions.max-entity-collisions` | 2 | 8 | Kalabalık hayvan çiftliklerinde büyük CPU tasarrufu | Evet: itişme azalır |
| `entities.spawning.non-player-arrow-despawn-rate`, `creative-arrow-despawn-rate` | 20 (1 sn) | spigot `arrow-despawn-rate` (1200) | Alınamayan oklar hemen silinir | Evet (yalnız görsel) |
| `entities.spawning.despawn-ranges.monster` | soft 32, hard yatay 72 / dikey varsayılan | soft 32, hard 128 | Simülasyon 5 (~80 blok) dışındaki donmuş canavarlar mob sınırını doldurmasın; dikey vanilla (AFK kuleli çiftlikler bozulmasın) | Evet |
| `entities.spawning.alt-item-despawn-rate` | açık; cobblestone, cobbled_deepslate, netherrack, dirt, gravel, sand, granite, diorite, andesite, tuff → 1200 tick (1 dk) | kapalı (5 dk) | Yerde biriken ucuz blok eşyaları | Evet |
| `entities.behavior.spawner-nerfed-mobs-should-jump` | true | false | `nerf-spawner-mobs` açılırsa çiftlikler bozulmasın; nerf kapalıyken etkisiz | Hayır |
| `environment.optimize-explosions` | true | false | Patlamalarda varlık aramaları önbelleğe alınır (TNT/creeper kalabalığı) | Tam vanilla eşdeğerliği DOĞRULANMADI |
| `fixes.fix-items-merging-through-walls` | true | false | Birleştirme yarıçapı büyütüldüğü için duvar arkasından birleşme engellenir | Hayır |
| `misc.redstone-implementation` | ALTERNATE_CURRENT | VANILLA | Çok daha az blok güncellemesi, büyük CPU tasarrufu | **Evet:** toz güncelleme sırası farklı; sıraya dayalı çok hassas makineler farklı davranabilir. Sorun olursa `VANILLA` yapın |
| `tick-rates.grass-spread` | 4 | 1 | Yalnız çimen bloğunun yayılması/toprağa dönmesi 4 tick'te bir (miselyum etkilenmez) | Evet: yayılma yavaş |
| `tick-rates.mob-spawner` | 2 | 1 | Spawner 2 tick'te bir işlenir; Paper aradaki süreyi telafi eder, üretim hızı değişmez | Hayır |

**lobby:**

| Anahtar | Değer | Neden | Oynanış |
|---|---|---|---|
| `entities.armor-stands.tick`, `do-collision-entity-lookups` | false, false | Dekoratif zırh askıları düşmez/hareket etmez | Evet |
| `environment.disable-thunder`, `disable-ice-and-snow` | true, true | Hava sabit, yıldırım ve buz/kar yok | Evet |
| `chunks.prevent-moving-into-unloaded-chunks` | true | Eş zamanlı yükleme yerine kısa geri itme | Evet |

## Lobi oyun kuralları (init-commands.txt)

`mc init lobby` sırasında RCON ile bir kez çalışır. 26.x'te oyun kuralları `minecraft:` önekli
ve **dünya başınadır**; eski camelCase adlar (`doMobSpawning` vb.) çalışmaz.

| Komut | Neden |
|---|---|
| `gamerule minecraft:spawn_mobs false`, `spawn_monsters false` | Mob yok |
| `gamerule minecraft:advance_time false` + `time set 6000` | Saat öğlende sabit |
| `gamerule minecraft:advance_weather false` + `weather clear` | Hava sabit açık |
| `gamerule minecraft:random_tick_speed 0` | Bitki büyümesi, yaprak çürümesi, buz erimesi durur (CPU) |
| `gamerule minecraft:spawn_phantoms false` | Fantom yok |
| `gamerule minecraft:fire_spread_radius_around_player 0` | Ateş yayılmaz |
| `gamerule minecraft:pvp false` | Oyuncular birbirine vuramaz |
| `gamerule minecraft:fall_damage false` | Parkur alanlarında ölüm yok |

Survival'da oyun kuralları **değiştirilmedi** (oyun modu seçilmedi). Bir kuralı sonradan
değiştirmek için: `sudo mc rcon survival "gamerule minecraft:keep_inventory true"`.

## velocity.toml

| Anahtar | Değer | Neden |
|---|---|---|
| `compression-threshold` | 256 | Oyuncuya giden, bu boyuttan büyük paketler sıkıştırılır (varsayılan) |
| `compression-level` | -1 (zlib 6) | Varsayılan; proxy CPU'su darsa 4 denenebilir |
| `[packet-limiter] decompressed-bytes-per-second` | 5242880 (5 MiB/sn) | Sıkıştırma bombalarına karşı (varsayılan) |

Depodaki `velocity.toml` tüm anahtarları bilerek açıkça yazar, çünkü Velocity'nin kod
varsayılanları örnek dosyadakilerden farklı olabiliyor (ör. `command-rate-limit`).

## JVM bayrakları

`config/jvm/paper.flags` ve `velocity.flags` dosyalarındaki satırlar, `server.env`'deki `HEAP`,
`GC_THREADS` ve `EXTRA_JAVA_OPTS` ile birleştirilip `/opt/minecraft/servers/<sunucu>/jvm.env`
dosyasına yazılır (`mc apply`).

**Paper (Aikar bayrakları, PaperMC belgelerindeki güncel set):** G1 çöp toplayıcı, kısa ve
öngörülebilir duraklamalar için ayarlanmış (`MaxGCPauseMillis=200`, genç nesil %30–40,
`G1HeapRegionSize=8M`, `InitiatingHeapOccupancyPercent=15` …). `-XX:+AlwaysPreTouch` heap'in
tamamını açılışta ayırır: bellek yetersizliği oyuncu varken değil açılışta ortaya çıkar.

**Velocity:** PaperMC'nin Velocity ayar belgesindeki set (G1, `G1HeapRegionSize=4M`) +
`-XX:+ExitOnOutOfMemoryError`: bellek biterse proxy yarı çalışır halde asılı kalmak yerine
çıkar ve systemd yeniden başlatır. Paper'da **kullanılmaz** (dünyayı kaydetmeden çıkardı).

**Heap ve GC iş parçacıkları** (`server.env`):

| Sunucu | HEAP | GC_THREADS | Sonuç |
|---|---|---|---|
| velocity | 1G | 2 | `-XX:ParallelGCThreads=2 -XX:ConcGCThreads=1` |
| lobby | 1536M | 2 | aynı |
| survival | 7G | boş | JVM varsayılanı (8 vCPU'da 8) |

JVM varsayılanı her JVM için vCPU sayısı kadar GC iş parçacığıdır; üç JVM aynı 8 vCPU'yu
paylaştığı için küçük heap'ler sınırlandı. Bunun kazancı ölçülmedi (DOĞRULANMADI); GC günlüğü ve
spark ile izleyin.

**Neden G1, neden ZGC değil?** Java 25'te ZGC yalnız nesilli (generational) modda çalışır ve
eş zamanlı GC iş parçacıklarını sürekli çalıştırır. Üç JVM'nin 8 vCPU'yu paylaştığı bu makinede
ona ayıracak boş çekirdek yok. ZGC, tahsis hızı toplamaya yetişemediğinde tahsisi durdurur; bu
yüzden fazladan heap payı ister ve 16 GB bütçede o pay yok (Minecraft için "eşit davranış için
~2 kat heap" iddiaları DOĞRULANMADI). Survival daha büyük bir makineye taşındığında yeniden
değerlendirin.

**Neden JVM dili Türkçe değil?** Her iki bayrak dosyasında `-Duser.language=en
-Duser.country=US` vardır. Türkçe yerel ayarda Java'nın `"I".toLowerCase()` işlemi noktasız
"ı" üretir. Bu, yerel ayar belirtmeden küçük harfe çeviren eklentilerde komut, malzeme ve enum
adı eşleşmelerini bozar. Örneğin LibreLogin premium sorgusundan önce adı küçük harfe çevirir;
Türkçe yerel ayarda `ILKER` → `ılker` olur, Mojang bu adı bulamaz ve premium bir ad
**korumasız** kalır. Oyuncular Türkçeyi kendi istemcilerinde seçer; eklentilerin Türkçe
mesajları kendi ayarlarından gelir ([docs/06](06-eklentiler.md#türkçe-yerelleştirme)).
`-Dfile.encoding=UTF-8` ve systemd'deki `LANG=C.UTF-8` Türkçe karakterlerin günlükte doğru
görünmesini sağlar.

**GC günlüğü:** yalnız Paper sunucularında, sunucu dizininin kökünde:
`/opt/minecraft/servers/<sunucu>/gc.log` (en çok 5 × 10 MB, döner). PaperMC belgesindeki
`logs/gc.log` biçimi kullanılmadı: ilk açılışta `logs/` henüz olmadığı için JVM günlüğü hiç
açamıyordu.

```bash
sudo tail -n 50 /opt/minecraft/servers/survival/gc.log     # "Pause Young" süreleri ms cinsinden
```

### Deneme: Compact Object Headers (isteğe bağlı)

Java 25'te `-XX:+UseCompactObjectHeaders` artık deneysel değil (varsayılan kapalı). Nesne
başlıklarını 12'den 8 bayta indirir; genel Java ölçümlerinde ~%20 daha az heap ve biraz daha az
CPU bildirildi. Paper ile bilinen bir uyumsuzluk bulunamadı, ama bu "rapor yok" demektir
(DOĞRULANMADI). Önce lobide bir hafta deneyin:

```bash
# config/servers/lobby/server.env içinde:
#   EXTRA_JAVA_OPTS="-XX:+UseCompactObjectHeaders"
sudo mc apply lobby && sudo mc restart lobby
```

spark `health` ve GC günlüğüyle önce/sonra karşılaştırın; sorun yoksa survival'da deneyin.
Geri almak için değişkeni boşaltıp tekrar uygulayın. Aynı yöntemle survival'da
`-XX:+UseTransparentHugePages` de denenebilir (makinede THP zaten `madvise`); ikisini aynı anda
denemeyin.

## İşletim sistemi ayarları (host/)

| Dosya | Ne yapar |
|---|---|
| `sysctl-99-minecraft.conf` | Bağlantı kuyrukları ve soket tamponları büyütülür, SYN cookies açık, isteğe bağlı fq + BBR, `vm.swappiness=1` (swap yalnız emniyet ağı) |
| `thp-tmpfiles.conf` | Şeffaf büyük sayfalar (THP) yalnız isteyen süreçlere (`madvise`), `defrag=defer+madvise` |
| `journald-minecraft.conf` | Günlük en çok 2 GB, 90 gün |
| `mariadb-minecraft.cnf` | `innodb_buffer_pool_size=384M`, `performance_schema=OFF` (JVM'lere yer kalsın) |
| systemd drop-in `20-resources.conf` | `CPUWeight` (survival 300, velocity 200, lobby 100, limbo 50) ve `OOMScoreAdjust` (velocity -200 en son ölür; survival 0; lobby 200; limbo 300 ilk ölür) |

## spark ile ölçüm

Paper, spark profil aracını **içinde getirir** (backend'lere ayrıca kurmayın). Velocity'de spark
`config/plugins.list` ile ayrı eklenti olarak kuruludur ve komutu `/sparkv`'dir.

Oyun içinde yetkili hesapla ya da konsoldan (RCON):

```bash
sudo mc rcon survival "spark tps"       # TPS ve MSPT (min/medyan/%95/maks), son 10 sn, 1 dk, 5 dk…
sudo mc rcon survival "spark health"    # CPU (süreç/sistem), bellek, disk, GC özeti
sudo mc rcon survival "spark profiler start --timeout 300"
# 5 dakika sonra görüntüleme bağlantısını basar; hemen durdurmak için:
sudo mc rcon survival "spark profiler stop"
# Bağlantı RCON yanıtında görünmeyebilir; sunucu günlüğünde arayın:
sudo journalctl -u mc@survival -o cat --since "15 min ago" | grep spark.lucko.me
```

Profil bağlantısı (spark.lucko.me) RCON komutu yanıtını döndürdükten sonra, yükleme bitince
basılır; bu yüzden `mc rcon` çıktısında görünmeyebilir. Ayrı bir pencerede `sudo mc log survival`
açık tutarsanız orada da görürsünüz; oyun içinde yetkili hesapla çalıştırırsanız sohbete gelir.

- Profili **sorun yaşanırken** alın (yoğun saat). Çıktı bir web bağlantısıdır (spark.lucko.me);
  en çok zaman harcayan eklenti, varlık türü ya da parça görünür. Profil verisi spark'ın
  sunucularına yüklenir; bağlantıyı yalnız güvendiğiniz kişilerle paylaşın.
- Oyun içinde `/spark tps` renkli çıktı verir; RCON çıktısında renk kodları (`§`) görünebilir.
- Bellek: `mc status` (RSS), `spark health`, `systemctl status mc@survival` ("Memory:" satırı).

## Gecikme varsa ne yapılır? (sırayla)

1. **Ölçün, tahmin etmeyin.** `spark tps` ile MSPT'ye, `sudo mc doctor` ile steal'e bakın. Steal
   yüksekse sorun sizde değil sağlayıcıdadır ([docs/01](01-donanim-ve-kapasite.md#cpu-steal-nasıl-ölçülür)).
2. **Profil alın** (`spark profiler`). Çoğu zaman tek bir sebep çıkar: bir çiftlik, bir parçada
   yüzlerce varlık, bir eklenti. Önce onu çözün (oyuncuyla konuşun, çiftliği sınırlayın, eklentiyi
   güncelleyin/kaldırın).
3. **Simülasyon mesafesi:** survival `simulation-distance` 5 → 4. Ana iş parçacığı yükünü en çok
   azaltan tek ayardır.
4. **Varlık sınırları:** `bukkit.yml` `spawn-limits` ve `ticks-per.monster-spawns: 2` (varsayılanı
   1 olan diğer `*-spawns` da; `animal-spawns` hariç, onun varsayılanı 400),
   `entity-per-chunk-save-limit`, `max-entity-collisions`; gerekirse `nerf-spawner-mobs: true`.
5. **Görüş mesafesi:** `view-distance` 8 → 7 ya da 6. Bu daha çok bellek ve bant genişliğini
   azaltır; MSPT'ye etkisi simülasyon mesafesinden küçüktür.
6. Parça yükleme birikmesi görüyorsanız (profilde parça iş parçacıkları dolu) survival
   `worker-threads: 3`.
7. Hâlâ yetmiyorsa kapasite sınırındasınız: [docs/07](07-olcekleme.md).

Her değişiklikten sonra `sudo mc apply survival` ve `sudo mc restart survival`; bir değişikliği
yaptıktan sonra ölçmeden bir sonrakine geçmeyin.
