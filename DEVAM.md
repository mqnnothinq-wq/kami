# Devam notu: buluttan yerel bilgisayara geçiş

Bu dosya, bulut oturumunda yapılan işi ve sıradaki adımları özetler. Yeni (yerel) Claude Code
oturumu işe buradan başlamalı. Tarih: 30 Eylül 2026. Dal: `claude/minecraft-tr-server-setup-njrd6r`.

## Yerelde başlarken

1. **Ortam:** Windows'ta **WSL2 + Ubuntu 24.04** önerilir. Betikler bash ile yazıldı, sunucu da Linux.
   Klonlayıp dala geçin:
   ```bash
   git clone https://github.com/mqnnothinq-wq/kami && cd kami
   git checkout claude/minecraft-tr-server-setup-njrd6r
   ```
2. **Gerekenler:**
   - git, bash, python3 (3.11+), jq
   - [mikefarah yq v4](https://github.com/mikefarah/yq). Ubuntu'daki `yq` paketi farklı bir araçtır, o işe yaramaz.
   - İsteğe bağlı: shellcheck; önizleme çizmek için `pip install pillow numpy`
3. **Testler** (hepsi geçmeli, ~850 kontrol):
   ```bash
   YQ=$(command -v yq) bash tests/run.sh
   ```
4. Depo kökünde Claude Code'u açıp ilk mesajı şöyle yazın: **"DEVAM.md'yi oku, 'Sıradaki iş'ten devam et."**
5. **İzin kipi:** `.claude/settings.json` içinde `"defaultMode": "bypassPermissions"` var (sahibinin isteğiyle).
   Yerelde bu ayar, Claude'un **sizin bilgisayarınızda** komutları sormadan çalıştırması demektir. Kapatmak
   için dosyayı silin ya da değeri `"default"` yapın.

## Şu ana kadar yapılanlar (hepsi pushlandı)

| Alan | Nerede | Not |
|---|---|---|
| Altyapı: Velocity 4.2 + Paper 26.2 (lobby, survival) + PicoLimbo, karma giriş (LibreLogin), Geyser/Floodgate, Sonar | `config/`, `scripts/`, `systemd/`, `host/` | `mc` komutu, kurulum, yedek (restic), güncelleme, yeni sunucu ekleme |
| Türkçe belgeler | `README.md`, `docs/01..09` | Kurulum adım adım: `docs/02-kurulum.md` |
| Testler | `tests/` | `tests/run.sh` hepsini çalıştırır |
| Kaynak paketi: Kor Kılıç (3B model, akan magma dokusu, parlama) | `paket/` | `python3 paket/araclar/paketle.py` → `paket/dist/kami-paket.zip` |
| BetterModel: Kor Kristali (lobi süsü) + emote'lar (selam, zafer, dans) | `paket/bettermodel/`, önizleme `paket/onizleme/` | Kurulum ve oyunda deneme: `paket/README.md` |
| Araştırma raporları (İngilizce): ücretsiz içerik/oynanış eklentileri, üretim araçları | `notlar/arastirma/` | Araç ve eklenti belgesi için kaynak |

Hiçbiri gerçek sunucuda ya da oyunda denenmedi. Bulutta Paper ve Mojang indirmeleri engelliydi.
İlk kurulumda `docs/02-kurulum.md` içindeki kontrol listesi izlenmeli.

## Sıradaki iş: veri paketi (MCreator hattı)

Plan onaylandı, kod yazımına başlanmadı.

**Sahibinin kararları:**
- MCreator **veri paketi** için kullanılacak. Mod yolu seçilmedi, çünkü herkes mod kurmak zorunda kalır ve Bedrock desteği gider.
- İlk örnek pakette **Türkçe başarımlar, Kor Kılıç tarifi, özel ganimet ve köylü takasları** olacak.
- MCreator sahibinin bilgisayarında kurulu.

**Doğrulanmış bilgiler:**
- MCreator son sürümü (2026.3) en çok **Minecraft 26.1.x**'e çıktı veriyor; sunucu 26.2. Data Pack 26.1.x üreticisinin öğe türleri:
  - achievement, recipe, loottable, villagertrade, enchantment, damagetype;
  - function, structure, feature, biome, dimension ve etiketler.
  - `pack.mcmeta` çıktısı `101.1` biçiminde.
- Minecraft 26.2 paket biçimleri: **veri paketi 107.1**, kaynak paketi 88.
- 26.1'den 26.2'ye kıran değişiklikler (MCreator çıktısı için denetlenecek):
  - Varlık yüklemi (entity predicate) biçimi değişti: `type` alanı `entity_type` oldu, türe özel alt yüklemler en üst düzeye taşındı.
  - Etiket adı: `#concrete_powder` → `#concrete_powders`.
  - Özellik türleri: `pointed_dripstone` → `speleothem`, `dripstone_cluster` → `speleothem_cluster`.
  - Kaldırılanlar: `noise_gradient`, `weird_scaled_sampler`.
- Köylü takasları 26.x'te veriye dayalı:
  - Takas dosyaları `data/<ns>/villager_trade/<meslek>/<seviye>/*.json` altında. Alanlar: `wants`, `additional_wants`, `gives`, `max_uses`, `reputation_discount`, `xp`, `given_item_modifiers`.
  - Seviye havuzları `data/minecraft/tags/villager_trade/<meslek>/level_N.json` etiketleriyle kurulur. Etiketler paketler arasında birleşir, bu yüzden vanilla dosyayı ezmeden takas eklenebilir.
- Tarif `result` alanı `components` kabul eder (vanilla örneği: `suspicious_stew_from_*`).
  - `smithing_transform` biçimi: `template`, `base`, `addition`, `result`.
- Başarım biçimi: `criteria` / `display` / `requirements` / `parent`. Kullanılacak tetikleyiciler: `inventory_changed`, `changed_dimension`, `villager_trade`.
- Paper'da veri paketi klasörü: `servers/<sunucu>/world/datapacks/`.
- Vanilla 26.2 veri dosyalarının kopyası: git deposu `misode/mcmeta`, etiket `26.2-data`.

**Adımlar:**
1. `veri/araclar/kami_veri.py` (yalnız Python stdlib, deterministik) → `veri/kaynak/` altında `kami` paketi.
   - **Türkçe başarımlar:** "KAMI" sekmesi; Hoş geldin, ilk demir, ilk elmas, Nether, End, Kor Kılıç, ilk takas, Kor hazinesi.
   - **Kor Kılıç:** `smithing_transform` tarifi. Taban netherite kılıçtır, büyüler korunur. Sonuç bileşenleri `paket/README.md`'deki `/give` ile aynıdır.
   - **Ganimet:**
     - `kami:sandik/kor_hazinesi` tablosu;
     - Nether kalesi ve bastion sandıklarına düşük olasılıklı bir havuz.
   - **Köylü takasları:** 3–4 Türkçe adlı takas, etiket eklemesiyle.
2. `veri/araclar/veri_paketle.py`
   - Doğrulama, ardından deterministik `veri/dist/kami-veri.zip` üretimi.
   - `veri/mcreator/*.zip` (MCreator dışa aktarımları) için:
     - `pack.mcmeta` 26.2'ye uyarlanır;
     - yukarıdaki kıran kalıplar taranır;
     - `kami` ad alanıyla çakışma reddedilir.
   - `.gitignore`'a `/veri/dist/` eklenir.
3. `mc datapack <sunucu>` komutu:
   - zip'leri `world/datapacks/` klasörüne koyar;
   - RCON ile `minecraft:reload` ve `datapack list` çalıştırır.
   - `docs/09-komutlar.md` ve `tests/test_mc.sh` güncellenir.
4. `docs/10-veri-paketi-mcreator.md`
   - MCreator'da çalışma alanı: "Data Pack for Java Edition 26.1.x", mod kimliği `kami` dışında bir ad (ör. `kami_ek`).
   - Akış: dışa aktar → `veri/mcreator/` → `veri_paketle.py` → git → `sudo mc datapack survival`.
   - 26.2 uyarıları ve tek oyunculu dünyada deneme adımları.
5. `tests/test_veri.sh` → `tests/run.sh`'e eklenir. Ardından testler, commit ve push.

## Diğer kalan işler (sırasız)

- **Blockbench kontrolü:** `paket/modeller/kor_kilic.bbmodel` ve `paket/bettermodel/**/*.bbmodel` dosyalarını masaüstü
  Blockbench'te açıp hata olup olmadığına bakın; ekran görüntüsünü `paket/onizleme/` altına koyun.
- **Ücretsiz araç ve eklenti belgesi** (`docs/11-...`): kaynak `notlar/arastirma/`. İçerik:
  - CraftEngine CE, BetterModel + MythicMobs Free, Rainbow, zMenu, DecentHolograms;
  - FancyNpcs, TAB, CarbonChat, LibertyBans, GrimAC, BlueMap, AuraSkills, Hubbly.
  - `config/plugins.list` yorumları da güncellenir.
- **Lobi şematiği** (onaylı plan): uçan ada + doğa temalı, ~120×120.
  - Bölümler: mod seçim alanları, bilgi/kurallar panosu, mağaza/VIP köşesi.
  - Çıktılar: `builds/lobi/uret.py` → `.schem` (Sponge v3) + önizleme; lobby için void `generator-settings`; WorldEdit.
- **Paket barındırma kararı:** CraftEngine'in kendi sunucusu mu, VDS'te küçük bir web sunucusu mu?
  - BetterModel'in `build.zip` paketiyle birleştirilmesi.
  - `server.properties` → `resource-pack` ayarları.
- **ChatGPT paylaşımı** (`https://chatgpt.com/s/cx_6abd1669b1e48191b03086d7c2be1257`): bulutta erişim engelliydi.
  - İçerik `ithal/chatgpt-<tarih>/` altına alınacak ve `OZET.md` yazılacak.
  - Özet: depoyla örtüşen, çelişen ve yeni olan kısımlar. Birleştirme onaydan sonra yapılır.
- **VDS'te ilk gerçek deneme** (`docs/02-kurulum.md`):
  - LibreLogin dev derlemesinin duman testi;
  - kaynak paketi ve BetterModel'in oyunda denenmesi.
