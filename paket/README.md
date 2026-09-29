# Kaynak paketi (resource pack)

Sunucunun kendi eşyaları, zırhları, blokları ve modelleri burada üretilir. Oyuncular
paketi girişte otomatik indirir; mod kurmaları gerekmez.

![Kor Kılıç önizlemesi](onizleme/kor_kilic.png)

## İlk eşya: Kor Kılıç

| Özellik | Nasıl yapıldı |
|---|---|
| 3B model (11 parça: bıçak, uç, koruma, kor taşları, sap, topuz) | `models/item/kor_kilic.json` |
| Akan magma bıçak (8 kare, yumuşak geçiş, ~1,2 sn döngü) | `kor_kilic_alev.png` + `.png.mcmeta` (`frametime: 3`, `interpolate: true`) |
| Karanlıkta parlayan bıçak ve taşlar | Model parçalarında `light_emission` (bıçak 15, taşlar 10–12) |
| Elde vanilla kılıç duruşu | `display` açıları vanilla `handheld` değerlerinden türetildi |
| Blockbench kaynağı (dokular gömülü) | `modeller/kor_kilic.bbmodel` |

Önizleme GIF'i (dönen model ve akan doku): [`onizleme/kor_kilic.gif`](onizleme/kor_kilic.gif).
Önizleme gerçek oyun görüntüsü değildir; oyunun okuyacağı dosyalardan basit bir çizimdir.

## Dizinler

| Yol | İçerik |
|---|---|
| `kaynak/` | Paketin kendisi (`pack.mcmeta` + `assets/kami/...`). Zip'e giren her şey burada |
| `modeller/` | Blockbench kaynak dosyaları (`.bbmodel`) |
| `araclar/kor_kilic.py` | Kor Kılıç'ın dokularını, modelini ve `.bbmodel` dosyasını üretir (yalnız Python) |
| `araclar/paketle.py` | Paketi doğrular ve `dist/kami-paket.zip` üretir; SHA-1'i yazar |
| `araclar/onizle.py` | Önizleme PNG/GIF'i çizer (Pillow + numpy ister; yalnız geliştirme aracı) |
| `onizleme/` | Önizleme görselleri |
| `dist/` | Derleme çıktısı (git'e girmez) |

## Hemen deneme (kendi bilgisayarınızda)

1. Paketi oluşturun (depo kökünde):
   ```bash
   python3 paket/araclar/paketle.py
   ```
   Çıktı: `paket/dist/kami-paket.zip` ve `resource-pack-sha1=…` satırı.
2. Zip'i Minecraft'ın `resourcepacks` klasörüne kopyalayın
   (Windows: `%APPDATA%\.minecraft\resourcepacks`), oyunda **Seçenekler → Kaynak Paketleri**
   bölümünden etkinleştirin.
3. Hile açık bir dünyada ya da OP olduğunuz sunucuda kılıcı alın:
   ```
   /give @s minecraft:netherite_sword[minecraft:item_model="kami:kor_kilic",minecraft:custom_name={text:"Kor Kılıç",color:"#FF8A1F",italic:false},minecraft:lore=[{text:"Magmanın kalbinden dövüldü.",color:"gray",italic:false}],minecraft:rarity="epic"]
   ```
   Sunucu konsolundan veriyorsanız `@s` yerine oyuncu adını yazın (`/give Ahmet …`).

Görünüm yalnız paketle değişir; eşya yine de bir netherite kılıçtır (hasarı, dayanıklılığı
aynı). Özel hasar ve yetenekler sonraki adımda eklentiyle eklenecek.

Bu komut ve paket Minecraft 26.2 biçimine göre hazırlandı ama oyunda henüz denenmedi; ilk
denemede bir sorun görürseniz `latest.log` çıktısıyla birlikte bildirin.

## Blockbench'te açma ve düzenleme

1. [Blockbench](https://www.blockbench.net/) (ücretsiz; tarayıcı sürümü: web.blockbench.net)
   ile `paket/modeller/kor_kilic.bbmodel` dosyasını açın. Dokular dosyanın içindedir ve alev
   dokusu önizlemede akar.
2. Düzenledikten sonra **File → Export → Export Block/Item Model** ile modeli
   `paket/kaynak/assets/kami/models/item/kor_kilic.json` üzerine, değişen dokuları
   **Save As** ile `paket/kaynak/assets/kami/textures/item/` altına kaydedin.
3. `python3 paket/araclar/paketle.py` ile doğrulayıp yeniden paketleyin.

**Önemli:** `araclar/kor_kilic.py` çalıştırılırsa bu dosyaları baştan üretir ve elle yaptığınız
değişiklikler silinir. Kılıcı Blockbench'te düzenlemeye başladıysanız üreticiyi o eşya için
kullanmayı bırakın. Ayrıca `tests/test_paket.sh` içindeki "üretici ↔ depo" kontrolünü
kaldırın; bu kontrol elle yapılan değişikliği hata sayar.

## Yeni eşya ekleme (elle)

Her eşya için üç dosya yeterli:

```
kaynak/assets/kami/items/<ad>.json          {"model": {"type": "minecraft:model", "model": "kami:item/<ad>"}}
kaynak/assets/kami/models/item/<ad>.json    Blockbench'ten dışa aktarılan model
kaynak/assets/kami/textures/item/<ad>.png   doku (animasyon için kareleri alt alta + <ad>.png.mcmeta)
```

Oyunda herhangi bir eşyaya `minecraft:item_model="kami:<ad>"` bileşeni verilince yeni görünümü alır.

## Işıltı ve animasyon teknikleri

| Etki | Nasıl | Not |
|---|---|---|
| Akan / yanıp sönen doku | Kareleri alt alta dizip `.png.mcmeta` ile `frametime` + `interpolate` | Eşya, blok ve model dokularında çalışır |
| Karanlıkta parlama | Model parçasına `"light_emission": 0-15` | Yalnız o parça parlar; çevreyi aydınlatmaz |
| Büyü parıltısı (mor) | Eşyaya `minecraft:enchantment_glint_override=true` | Rengi değiştirilemez (shader gerekir) |
| Hareketli 3B model (dönen, süzülen, saldıran) | Blockbench animasyonu + eklenti (ör. BetterModel) | Eşya modelleri tek başına kemik animasyonu yapamaz |

## Sürüm uyumluluğu

- `pack.mcmeta`: `min_format` 88 (Minecraft 26.2), `max_format` [97, 1] (26.3). Böylece 26.3
  istemcileri (ViaVersion ile giren) uyarı görmez.
- 26.3 model elemanlarındaki `shade` alanını kaldırdı; `paketle.py` bu alanı içeren modeli
  reddeder.
- Bedrock (Geyser) oyuncuları bu kılıcı normal netherite kılıç olarak görür. Java paketinin
  Bedrock'a çevrilmesi (GeyserMC Rainbow) ayrı bir adımdır.

## Sunucuda herkese otomatik gönderme (sonraki adım)

Paket bir web adresinden indirilebilir olmalı. Sonra lobi ve ana sunucunun
`server.properties` dosyasına şu ayarlar eklenir:

```
resource-pack=https://<adres>/kami-paket.zip
resource-pack-sha1=<paketle.py'nin yazdığı değer>
require-resource-pack=false
```

Barındırma yöntemi (VDS'te küçük bir web sunucusu mu, başka bir yer mi) henüz seçilmedi.
Seçilince `mc` komutuna otomatik yayınlama eklenecek.
