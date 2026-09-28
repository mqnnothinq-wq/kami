# 06 — Eklentiler

Bu belge kurulu eklentileri, elle eklenebilecek önerilen eklentileri, `config/plugins.list`
dosyasının nasıl çalıştığını, Türkçe yerelleştirmeyi ve LuckPerms grup düzenini anlatır.

> Eklenti sürüm bilgileri Eylül 2026 araştırmasına dayanır; eklenti sayfasından güncel durumu
> kontrol edin. **Yalnız resmî kaynaklardan** indirin ([docs/04](04-guvenlik-ddos.md#eklentiler-asla-sızdırılmış-ya-da-crack-eklenti-kurmayın)).

## Kurulu eklentiler

`config/plugins.list` içinde etkin olanlar:

| Eklenti | Nerede | Kaynak | Ne işe yarar |
|---|---|---|---|
| Geyser | velocity | `geysermc` | Bedrock (telefon, konsol, Windows) istemcilerini UDP 19132'den kabul eder ve Java protokolüne çevirir |
| Floodgate | velocity | `geysermc` | Bedrock oyuncularının Java hesabı olmadan girmesini sağlar; adları `.` önekiyle görünür. Yalnız proxy'de kurulu olması yeterli |
| LuckPerms | velocity + tüm Paper sunucuları | `luckperms` | İzinler ve gruplar; hepsi aynı MariaDB veritabanını kullanır, değişiklikler anında yayılır |
| Sonar | velocity | `github` | Anti-bot: her yeni oyuncuyu ilk girişte doğrular |
| LibreLogin | velocity | `local` (`/opt/minecraft/artifacts/LibreLogin-39397c4.jar`) | Karma giriş: premium otomatik, cracked `/register`–`/login` ([docs/08](08-giris-sistemi.md)) |
| spark | velocity | `modrinth` | Profil aracı. Paper'da **gömülü** gelir (backend'lere kurmayın); Velocity'de ayrı eklenti, komutu `/sparkv` |
| ViaVersion | tüm Paper sunucuları | `hangar` | 26.3 istemcilerinin 26.2 sunuculara girmesini sağlar. **Zorunlu**: oyuncuların başlatıcıları 26.3'e güncellendi |
| Chunky | survival | `modrinth` | Dünya ön-üretimi ([docs/02](02-kurulum.md#14-dünya-ön-üretimi-chunky)) |

Eklenti olmayan ama ağın parçası olan: **PicoLimbo** (giriş bekleme sunucusu, `limbo`; yerel
ikili, `mc download core limbo` ile iner).

`plugins.list`'te yorum satırı olarak hazır bekleyen isteğe bağlı örnekler: ViaBackwards,
FastAsyncWorldEdit, WorldEdit, WorldGuard, CoreProtect, EssentialsX, TAB, SkinsRestorer.
Etkinleştirmek için satır başındaki `#` işaretini kaldırın (url satırlarında adresi ve özeti
doldurun).

## Önerilen, elle eklenecek eklentiler

Oyun modu seçilince ihtiyaca göre ekleyin. "26.2 durumu" Eylül 2026 araştırmasındandır.

| Eklenti | Nerede | Ne için | 26.2 durumu ve notlar |
|---|---|---|---|
| **EssentialsX** (+ Chat, Spawn) | survival (lobi isteğe bağlı) | /home, /tpa, kitler, ekonomi, sohbet biçimi | Kararlı 2.22.0 yalnız 26.1.2'yi hedefliyor; 26.2 desteği yalnız **geliştirme sürümlerinde** (essentialsx.net). Elle indirip `local` ya da `url` + sha256 ile ekleyin. GitHub varlık adı sürüm içerdiği için `github` kaynağı çalışmaz |
| **CoreProtect CE** | survival | Blok/sandık kaydı ve geri alma (grief) | 26.2 desteği **v24.1** (24 Eylül 2026) ile geldi; indirme bağlantısı bir **Patreon gönderisinde**, otomatik indirilemez. Otomatik temizlik (auto-purge) Patreon'a özel: `/co purge t:30d`'yi düzenli elle çalıştırın |
| **WorldEdit** / **FastAsyncWorldEdit** | survival | Yönetici düzenleme aracı (WorldGuard birini ister) | WorldEdit 7.4.5 (26.3 için 7.4.6 beta); FAWE 2.15.3'ten beri 26.2. FAWE daha hızlıdır |
| **WorldGuard** | lobby + survival | Spawn ve bölge koruması | 7.0.18 (Temmuz 2026); ardından ana dal "MC 26.2 gerektirir"e geçti. WorldEdit ya da FAWE gerekir |
| **TAB** | velocity (+ backend'ler) | Sekme listesi, isim etiketleri | 6.2.0 (Eylül 2026) 26.3 desteği ekledi; Velocity modülü var. PlaceholderAPI yer tutucuları için backend köprüsü gerekip gerekmediği DOĞRULANMADI |
| **SkinsRestorer** | velocity (+ backend'ler) | Cracked oyuncuların skin seçebilmesi (`/skin`) | 15.12.6 (Eylül 2026) 26.3 ekledi. Premium oyuncular skinlerini zaten Mojang'dan alır. Kurulum yeri (yalnız proxy mi, proxy + backend mi) için eklenti belgesine bakın |
| **BlueMap** | survival | Web haritası | 5.28 (Eylül 2026) 26.3'e kadar. Web sunucusu kendi portunda çalışır (varsayılan 8100): UFW'de açın ya da bir ters vekil arkasına koyun. İlk çizimi yoğun saatte başlatmayın (RAM/CPU) |
| **GrimAC** | survival | Hile önleme (anticheat) | 2.3.74 1.8–26.2'yi kapsıyor (Modrinth). Geyser ile "kısmen uyumlu": Bedrock oyuncularını denetlemez |
| **VaultUnlocked** | survival | Ekonomi API köprüsü | 2.20.1 26.2 desteği ekledi. Eski Vault artık bakım görmüyor |
| Ekonomi + mağaza | survival | TR ekonomisi | EssentialsX ekonomisi + **EconomyShopGUI** 7.2.1 (26.2, `lang-tr.yml` içerir) ya da **QuickShop-Hikari**. Satışlarda Mojang kurallarına uyun ([docs/04](04-guvenlik-ddos.md#mojang-kullanım-kuralları-sunucu-ve-mağaza)) |
| **NuVotifier** + **VotingPlugin** | velocity (+ survival) | Oy ödülleri (Türk sunucu listeleri) | NuVotifier 2.7.3, Velocity'den iletimi destekler; VotingPlugin 7.1.1. MCSunucular.com'un NuVotifier v2 jetonu ve v1 RSA desteklediği bildiriliyor (DOĞRULANMADI). NuVotifier bir TCP portu dinler (varsayılan 8192): UFW'de açın |
| PlaceholderAPI | lobby + survival | Yer tutucular | 2.12.3 26.2 desteği ("Paper'da deneysel") |
| DiscordSRV | survival | Discord sohbet köprüsü | 1.30.5; 26.2 DOĞRULANMADI. Halefi "Ascension" alfa: canlıda kullanmayın |
| Arsa koruma | survival | Oyuncu arazi koruması | GriefPrevention 26.2 DOĞRULANMADI; HuskClaims bir alternatif |
| /lobby, /hub komutu | velocity | Lobiye dönüş kısayolu | Küçük üçüncü taraf eklentiler (Hangar); kurmadan önce kaynak kodunu gözden geçirin. Şimdilik oyuncular `/server lobby` kullanır |

**Sunucu listesi açıklaması (MOTD)** için eklenti gerekmez: `velocity.toml` `motd` MiniMessage
biçimini zaten destekler.

## plugins.list nasıl çalışır?

`sudo mc download plugins` (ya da `sudo mc download`) bu dosyayı okur. Her satır:

```
# sunucular        ad            kaynak      kimlik                                   [sha256]
velocity           Geyser        geysermc    geyser/velocity
backends           ViaVersion    hangar      ViaVersion
```

| Sütun | Anlamı |
|---|---|
| sunucular | Virgülle ayrılmış sunucu adları (`lobby,survival`), `backends` (tüm Paper sunucuları; `mc new-server` ile eklenenler dahil) ya da `all` (tüm Paper sunucuları + Velocity; limbo hariç) |
| ad | Dosya adı: `plugins/<ad>.jar`. Aynı sunucuda bir kez kullanılabilir |
| kaynak | Aşağıdaki türlerden biri |
| kimlik | Kaynağa göre değişir |
| sha256 | İsteğe bağlı (url'de zorunlu) 64 haneli SHA-256 özeti |

**Kaynak türleri:**

| Kaynak | Kimlik biçimi | Örnek | Doğrulama |
|---|---|---|---|
| `geysermc` | `proje/platform` | `geyser/velocity`, `floodgate/velocity` | sha256 (kaynaktan) |
| `luckperms` | `bukkit` ya da `velocity` | `bukkit` | Kaynak özet vermez; yalnız HTTPS |
| `modrinth` | Proje kısa adı (modrinth.com/plugin/**kısa-ad**) | `chunky`, `worldguard` | sha512 (kaynaktan). Paper için `PAPER_MC_VERSION` ile uyumlu, `release` türündeki en yeni sürüm seçilir |
| `hangar` | Hangar proje adı | `ViaVersion`, `ViaBackwards` | sha256 (kaynaktan). En yeni "release" |
| `github` | `sahip/depo:varlık-adı` | `jonesdevelopment/sonar:Sonar-Velocity.jar` | GitHub `digest` varsa sha256. Varlık adı her sürümde **aynı** olmalı |
| `url` | `https://…` doğrudan adres | `https://…/Eklenti-1.0.jar` | 5. sütunda sha256 **zorunlu** |
| `local` | `$MC_ROOT/artifacts/…jar` | `$MC_ROOT/artifacts/LibreLogin-39397c4.jar` | Dosya `/opt/minecraft/artifacts/` altında olmalı; yanında `<jar>.sha256` varsa onunla karşılaştırılır; 5. sütun isteğe bağlı |

**Nereye iner?** Sunucu daha önce hiç başlamadıysa doğrudan `plugins/<ad>.jar`'a; başladıysa
`plugins/update/<ad>.jar`'a. Bekleyen güncellemeler sunucu bir sonraki başlatıldığında
(`mc restart` ya da 05:00 yeniden başlatması) yerine konur. Çalışan sunucunun dosyalarına
dokunulmaz. Aynı dosya zaten kuruluysa atlanır.

**5. sütun (sha256) bir sabitlemedir:** kaynak yeni bir sürüm yayımlayınca özet tutmaz, indirme
"sabitlenen sha256 uyuşmuyor (yeni sürüm çıkmış olabilir)" hatası verir ve eski dosya yerinde
kalır. Yeni sürümü denedikten sonra özeti bilerek güncellersiniz.

Bir kaynak başarısız olursa diğerleri yine indirilir; sonda özet tablo basılır ve komut 1 ile
çıkar.

### Eklenti ekleme adımları

Örnek: survival'a WorldGuard ve WorldEdit eklemek.

1. `config/plugins.list`'e satırları ekleyin (ya da hazır yorum satırlarının `#`'ini kaldırın):

   ```
   survival           WorldEdit     modrinth    worldedit
   backends           WorldGuard    modrinth    worldguard
   ```

2. Deneyin ve indirin:

   ```bash
   sudo mc download --dry-run plugins survival
   sudo mc download plugins            # tüm sunucular için
   ```

3. Yeniden başlatın: `sudo mc restart survival` (ya da 05:00'ı bekleyin).
4. Eklentinin ayarlarını değiştirmek isterseniz: eklenti ilk açılışta kendi dosyasını üretir;
   sonra depoya **yalnız değiştirmek istediğiniz anahtarları** içeren bir dosya koyun, ör.
   `config/servers/survival/files/plugins/WorldGuard/config.yml`, ve
   `sudo mc apply survival && sudo mc restart survival`. YAML dosyaları sunucudakiyle
   birleştirilir; dizin adı eklentinin `plugins/` altında oluşturduğu adla birebir aynı olmalı
   (büyük/küçük harf dahil).
5. Değişiklikleri depoya işleyin: `sudo git -C /opt/minecraft/kami add -A && sudo git -C /opt/minecraft/kami commit -m "WorldGuard eklendi"`.
   ("Author identity unknown" hatası alırsanız git kimliğini bir kez tanımlayın:
   [docs/02, 4. adım](02-kurulum.md#4-depoyu-indirin).)

### Elle indirilen eklenti (CoreProtect, EssentialsX geliştirme sürümü…)

Patreon ya da geliştirme sürümü sayfasından indirdiğiniz dosyayı `local` kaynağıyla ekleyin:

```bash
# Dosyayı bilgisayarınızdan sunucuya kopyalayın (kendi bilgisayarınızda):
scp CoreProtect-24.1.jar yonetici@203.0.113.10:/tmp/

# Sunucuda:
sudo install -m 0644 -o root -g root /tmp/CoreProtect-24.1.jar /opt/minecraft/artifacts/
sha256sum /opt/minecraft/artifacts/CoreProtect-24.1.jar
```

`plugins.list`:

```
survival           CoreProtect   local       $MC_ROOT/artifacts/CoreProtect-24.1.jar   <yukarıdaki sha256>
```

Dosya kalıcı bir HTTPS adresinde duruyorsa `url` kaynağını da kullanabilirsiniz (sha256
zorunlu). `/opt/minecraft/artifacts/` saatlik yedeğe `_artifacts` etiketiyle girer
([docs/05](05-yedekleme.md)).

### Eklenti kaldırma

Satırı `plugins.list`'ten silmek (ya da `#` ile kapatmak) jar'ı **silmez**. Elle kaldırın:

```bash
sudo rm -f /opt/minecraft/servers/survival/plugins/WorldGuard.jar /opt/minecraft/servers/survival/plugins/update/WorldGuard.jar
sudo mc restart survival
```

Depodaki ayar dosyasını da (`config/servers/<sunucu>/files/plugins/<Eklenti>/`) silin, yoksa
`mc apply` uyarı verir. Eklentinin veri klasörü (`plugins/<Eklenti>/`) kalır; gerekmiyorsa silin.

## Türkçe yerelleştirme

JVM dili bilerek İngilizcedir ([docs/03](03-performans.md#jvm-bayrakları)); Türkçe her
bileşenin kendi ayarından gelir. Tüm ayar dosyaları UTF-8 olmalıdır. Minecraft kullanıcı adları
yalnız ASCII'dir (Türkçe harf içeremez).

| Bileşen | Türkçe | Nasıl ayarlanır |
|---|---|---|
| Minecraft / Paper (vanilla mesajlar) | Evet | Oyuncu istemcisinde Türkçe seçer |
| Velocity | Evet (`messages_tr_TR`) | İstemci diline göre otomatik |
| LibreLogin | Eklentide yok | Depoda kısmi Türkçe `plugins/librelogin/messages.conf`; eksik anahtarlar İngilizce kalır |
| Sonar | Evet (`messages/tr.yml`) | Depoda `plugins/sonar/language.properties`: `language=tr` (ilk açılıştan **önce** yerleştirilir; sonradan değiştirmek mevcut dosyaları çevirmez) |
| Geyser | Evet (`tr_tr`) | İstemci diline göre; yedek dil depoda `default-locale: tr_tr` |
| PicoLimbo | — | Depodaki `server.toml` metinleri Türkçe |
| Paper izin mesajı, yeniden başlatma/kapanma mesajları | — | Depoda `paper-global.yml` `messages.no-permission`, `spigot.yml` `messages.restart`, `bukkit.yml` `shutdown-message` |
| LuckPerms | Crowdin çevirileri (Türkçe DOĞRULANMADI) | `lp translations install`; istemci diline göre |
| EssentialsX | Evet (`messages_tr.properties`) | `plugins/Essentials/config.yml`: `locale: tr` (isteğe bağlı `per-player-locale: true`) |
| GrimAC | Evet (`messages/tr.yml`) | Seçim yolu DOĞRULANMADI; eklenti belgesine bakın |
| SkinsRestorer | Evet (`locale_tr.json`) | İstemci diline göre (DOĞRULANMADI) |
| EconomyShopGUI / QuickShop-Hikari | `lang-tr.yml` / Crowdin | Eklenti ayarı / istemci dili |
| BlueMap web arayüzü | Evet (`tr.conf`) | Web arayüzü dil ayarı |

## LuckPerms grup ve yetki yolu önerisi

Önerilen yetki yolu (track): **default → vip → rehber → moderator → admin → kurucu**. Her grup bir
öncekinden miras alır. `vip` **yalnız kozmetik** ayrıcalık içerir (Mojang kuralları: oyun avantajı
satılamaz).

Komutlar LuckPerms'ün Paper tarafında (`lp`) RCON ile çalıştırılır; hepsi ortak veritabanına
yazıldığı için her sunucuda geçerlidir. Oyun içinde yetkili hesapla aynı komutları başına `/`
koyarak da yazabilirsiniz.

```bash
# Gruplar ve ağırlıklar (yüksek ağırlık = üst grup)
sudo mc rcon lobby "lp creategroup vip"
sudo mc rcon lobby "lp creategroup rehber"
sudo mc rcon lobby "lp creategroup moderator"
sudo mc rcon lobby "lp creategroup admin"
sudo mc rcon lobby "lp creategroup kurucu"
sudo mc rcon lobby "lp group vip setweight 10"
sudo mc rcon lobby "lp group rehber setweight 20"
sudo mc rcon lobby "lp group moderator setweight 30"
sudo mc rcon lobby "lp group admin setweight 40"
sudo mc rcon lobby "lp group kurucu setweight 50"

# Miras zinciri
sudo mc rcon lobby "lp group vip parent add default"
sudo mc rcon lobby "lp group rehber parent add vip"
sudo mc rcon lobby "lp group moderator parent add rehber"
sudo mc rcon lobby "lp group admin parent add moderator"
sudo mc rcon lobby "lp group kurucu parent add admin"

# Yetki yolu
sudo mc rcon lobby "lp createtrack yetki"
sudo mc rcon lobby "lp track yetki append default"
sudo mc rcon lobby "lp track yetki append vip"
sudo mc rcon lobby "lp track yetki append rehber"
sudo mc rcon lobby "lp track yetki append moderator"
sudo mc rcon lobby "lp track yetki append admin"
sudo mc rcon lobby "lp track yetki append kurucu"

# Sohbet önekleri (görünmesi için EssentialsX Chat gibi bir sohbet biçimi eklentisi gerekir).
# Önekteki boşluk korunsun diye LuckPerms'e çift tırnakla, kabuğa tek tırnakla verilir.
sudo mc rcon lobby 'lp group vip meta setprefix 10 "&6[VIP]&r "'
sudo mc rcon lobby 'lp group rehber meta setprefix 20 "&a[Rehber]&r "'
sudo mc rcon lobby 'lp group moderator meta setprefix 30 "&9[Mod]&r "'
sudo mc rcon lobby 'lp group admin meta setprefix 40 "&c[Admin]&r "'
sudo mc rcon lobby 'lp group kurucu meta setprefix 50 "&4[Kurucu]&r "'

# Kurucuya her şey (tırnak içinde; yoksa kabuk "*" işaretini genişletir)
sudo mc rcon lobby "lp group kurucu permission set * true"
```

Örnek izinler (kurduğunuz eklentilere göre uyarlayın):

| Grup | Örnek izin | Açıklama |
|---|---|---|
| vip | `essentials.chat.color` (EssentialsX varsa) | Renkli sohbet — kozmetik |
| rehber | `librepremium.user.info` | Bir oyuncunun giriş kaydını görme (LibreLogin, proxy) |
| moderator | `minecraft.command.kick`, `coreprotect.lookup` (CoreProtect varsa) | Atma, blok kaydı sorgulama |
| admin | `librepremium.user.pass-change`, `librepremium.user.delete`, `minecraft.command.ban` | Şifre sıfırlama, hesap silme, yasaklama |
| kurucu | `*` | Her şey |

```bash
sudo mc rcon lobby "lp group rehber permission set librepremium.user.info true"
```

**Oyuncuya grup vermek** (oyuncu en az bir kez girmiş olmalı; UUID notu için
[docs/02](02-kurulum.md#13-yönetici-yetkisi-luckperms--op)):

```bash
sudo mc rcon lobby "lp user Ahmet parent add vip"      # VIP ekle
sudo mc rcon lobby "lp user Mehmet promote yetki"      # yolda bir basamak yükselt
sudo mc rcon lobby "lp user Mehmet demote yetki"       # bir basamak düşür
sudo mc rcon lobby "lp user Mehmet info"
```

İpuçları:

- Velocity tarafında komut `lpv`'dir (oyun içinde `/lpv`). Velocity'deki izinler (ör. LibreLogin
  yetkili komutları) proxy'de değerlendirilir; LuckPerms'ün `server` bağlamı orada `velocity`'dir.
  Bir izni yalnız bir sunucuda vermek için sona `server=survival` ekleyin.
- Değişiklikler proxy üzerinden eklenti mesajlarıyla yayılır. Bu mesajlar oyuncu bağlantıları
  üzerinden gider: komutu çalıştırdığınız sunucuda oyuncu yoksa biri girene kadar bekler, o an
  oyuncusu olmayan sunuculara ulaşmaz. Değişiklik bir sunucuya yansımadıysa
  `lp sync`'i **o sunucuda** çalıştırın (komut yalnız çalıştığı sunucunun verisini veritabanından
  yeniler): `sudo mc rcon survival "lp sync"`, Velocity için `sudo mc cmd velocity lpv sync`.
- Yetkili hesaplar premium olmalıdır; premium hesaplarda LibreLogin `unregister`/`cracked`
  komutlarını kullanmayın ([docs/08](08-giris-sistemi.md#yetkili-komutları)).
- `/server` komutu Velocity'de varsayılan olarak herkese açıktır (oyuncular lobiyle survival
  arasında böyle geçer). Kapatmak isterseniz önce bir lobi menüsü/NPC eklentisi kurun, sonra
  `lpv group default permission set velocity.command.server false`.
