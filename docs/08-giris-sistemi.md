# 08 — Giriş sistemi (karma giriş)

Bu ağ hem **premium** (Mojang hesabı olan) hem **cracked** Java oyuncularını ve Bedrock
oyuncularını kabul eder:

- **Premium** oyuncular hiçbir şey yazmadan girer; adları otomatik olarak onlara ayrılır.
- **Cracked** oyuncular bir bekleme alanında (limbo) `/register` ya da `/login` yapar.
- **Bedrock** oyuncuları (Geyser/Floodgate) şifresiz girer.

Bunu Velocity üzerinde çalışan **LibreLogin** eklentisi ve giriş bekleme sunucusu **PicoLimbo**
sağlar.

> **Uyarı:** LibreLogin'in Velocity 4 / Minecraft 26.x ile çalışan yayınlanmış bir sürümü yok.
> Sabit bir geliştirme commit'i (`dev@39397c4`, 0.25.0-SNAPSHOT) kaynaktan derlenir ve açılışta
> "DO NOT USE THIS IN PRODUCTION" uyarısı basar. Bu yüzden aşağıdaki
> [duman testi](#duman-testi-canlıya-alma-kapısı) **canlıya alma kapısıdır**: geçmezse açmayın.

## Nasıl çalışır?

```
Java oyuncusu (TCP 25565)                         Bedrock oyuncusu (UDP 19132)
        |                                                   |
        v                                                   v
  Velocity: Sonar bot doğrulaması                     Geyser (Bedrock -> Java çevirisi)
  (ilk girişte "tekrar bağlan")                             |
        |                                                   v
        v                                   Floodgate: Bedrock oyuncusu olarak tanınır
  LibreLogin: bu ad kimde?                  (Sonar atlanır, LibreLogin şifre istemez)
        |                                                   |
        +--> ad veritabanında premium kayıtlı                +--> LOBBY (ad ".Ahmet")
        |    ya da Mojang'da kayıtlı (premium)
        |       -> Velocity bu oyuncu için online mod (Mojang oturum doğrulaması)
        |            +--> doğrulama başarılı  -> otomatik giriş -> LOBBY
        |            +--> cracked istemci      -> ATILIR (ad premium'a ait)
        |
        +--> premium değil (cracked)
                -> LIMBO (PicoLimbo, 127.0.0.1:30065, izleyici modu, boşluk)
                     +--> kayıtlı değil: /register <şifre> <şifre>
                     +--> kayıtlı:       /login <şifre>
                     |    (aynı IP'den 30 dk içinde tekrar gelen oturumla otomatik girer)
                     +--> 90 sn içinde giriş yapmazsa atılır
                -> LOBBY
```

Adımlar:

1. **Sonar** giriş paketini Velocity'nin ağ katmanında yakalar; botlar LibreLogin'e ve Mojang
   sorgularına hiç ulaşmaz. Her yeni oyuncu ilk girişte doğrulanır ve "tekrar bağlan" mesajıyla
   atılır; doğrulanmış oyuncular 5 gün hatırlanır.
2. **Floodgate** Bedrock oyuncularını tanır; LibreLogin onları doğrudan lobiye gönderir.
3. **LibreLogin** ada bakar: veritabanında premium olarak kayıtlıysa ya da Mojang'da bu ad
   varsa (sonuç 10 dakika önbellekte) Velocity'ye bu bağlantı için **online modu** zorlatır.
   Oyuncu gerçekten o hesabın sahibiyse Mojang doğrular ve otomatik giriş yapılır; cracked
   istemciyle gelen atılır. Premium adlar ilk görüldüğünde şifresiz kaydedilir ve **ayrılır**
   (`auto-register = true`): başka biri o adı cracked olarak alamaz.
4. Premium olmayan adlar **limbo**'ya gönderilir. Limbo yalnız 127.0.0.1'de dinler, oyuncu
   izleyici modunda boşlukta bekler. Giriş yapılmadan sohbet ve `/server` gibi komutlar engellidir.
5. Başarılı girişten sonra oyuncu **lobby**'ye geçer (`limbo` hiçbir zaman Velocity'nin
   `try` listesinde değildir).

Mojang ve yedek sorgu servisleri (playerdb.co, api.minetools.eu) yanıt vermezse LibreLogin
"kapalı kalır": önbellekte olmayan oyuncular girişte reddedilir ("Mojang API şu an yoğun…").

### Oyuncuların bilmesi gerekenler

- Cracked bir oyuncunun seçtiği ad **Mojang'da başka birine aitse** o adla giremez (premium'a
  ayrılmıştır) ve başka bir ad seçmelidir. Türkiye'de pek çok yaygın ad premium olarak alınmış
  olabilir; bunu duyurun.
- Adlar yalnız `A-Z a-z 0-9 _` ve 3–16 karakter olabilir (**Türkçe harf yok**).
- Adın büyük/küçük harfi kayıttaki gibi olmalıdır ("Bu isim farklı büyük/küçük harfle kayıtlı").
- Oyunu sonradan satın alan cracked oyuncu, verilerini koruyarak `/premium <şifre>` ile otomatik
  girişe geçebilir.

Örnek duyuru metni:

> Sunucumuza hem premium hem cracked hesapla girebilirsiniz. Premium hesaplar otomatik giriş
> yapar. Cracked oyuncular ilk girişte `/register <şifre> <şifre>`, sonraki girişlerde
> `/login <şifre>` yazar. Adınız Mojang'da başka birine aitse o adı kullanamazsınız. İlk
> bağlantıda bot koruması sizi bir kez atabilir; tekrar bağlanın. Bedrock (telefon/konsol)
> oyuncuları adres + 19132 portuyla şifresiz girer.

## Oyuncu komutları

| Komut | Diğer adları | Ne yapar |
|---|---|---|
| `/register <şifre> <şifre>` | `/reg` | Cracked oyuncu için kayıt (en az 6 karakter; yaygın şifreler reddedilir) |
| `/login <şifre>` | `/l`, `/log` | Giriş (5 yanlış denemede atılır) |
| `/changepassword <eski> <yeni>` | `/changepass`, `/passwd`, `/passch` | Şifre değiştirme |
| `/premium <şifre>` → `/premiumconfirm` | `/autologin`; `/confirmpremium` | Oyunu satın almış cracked oyuncu otomatik girişe geçer (5 dakika içinde onay); UUID'si ve verileri aynı kalır. Bundan sonra cracked istemciyle o hesaba **giremez** |
| `/cracked` | `/manuallogin` | Otomatik girişi kapatır; sonra şifreyle girilir |

## Yetkili komutları

Velocity'de çalışır: oyun içinde yetkiyle `/librelogin …` ya da sunucu konsolundan
`sudo mc cmd velocity librelogin …` (yanıt `sudo mc log velocity`'de görünür). İzin önekleri
eski adla `librepremium.` şeklindedir.

| Görev | Komut | İzin |
|---|---|---|
| Hesap bilgisi (premium UUID, son görülme…) | `librelogin user info <ad>` | `librepremium.user.info` |
| Aynı kişiye ait olası hesaplar | `librelogin user alts <ad>` | `librelogin.user.alts` |
| Zorla kayıt | `librelogin user register <ad> <şifre>` | `librepremium.user.register` |
| Şifre sıfırlama | `librelogin user pass-change <ad> <yeniŞifre>` | `librepremium.user.pass-change` |
| Çevrimiçi oyuncuyu zorla giriş yaptırma | `librelogin user login <ad>` | `librepremium.user.login` |
| Ad değiştirme | `librelogin user migrate <ad> <yeniAd>` | `librepremium.user.migrate` |
| Kaydı tamamen silme | `librelogin user delete <ad>` | `librepremium.user.delete` |
| Kaydı sıfırlama (şifre, IP **ve premium UUID** silinir) | `librelogin user unregister <ad>` | `librepremium.user.unregister` |
| Premium aç / kapat | `librelogin user premium <ad>` / `user cracked <ad>` | `librepremium.user.premium` / `.cracked` |
| Ayarları / mesajları yeniden yükle | `librelogin reload configuration` / `reload messages` | `librepremium.reload.*` |

**Premium hesap kuralı (yöneticiler için):**

- Premium bir hesapta **asla** `user unregister` ya da `user cracked` kullanmayın. Hesap cracked
  olur, bir sonraki girişte online mod zorlanmaz ve **herhangi bir cracked istemci o adı
  `/register` ile ele geçirebilir**.
- Premium bir hesabı sıfırlamanız gerekiyorsa `user delete` kullanın: bir sonraki girişte Mojang
  üzerinden yeniden otomatik kaydedilir.
- Yetkili hesapları premium olmalıdır ([docs/02](02-kurulum.md#13-yönetici-yetkisi-luckperms--op)).
  Cracked bir yetkili hesabı yalnız şifresi kadar güvenlidir ve ortak IP'lerde 30 dakikalık
  oturum özelliği risk taşır.

**Ad çakışması** ("İsim çakışması … yetkililere ulaş"): premium bir hesabın adı veritabanında
başka bir hesaba ait görünüyorsa (ör. biri o adı cracked olarak aldıktan sonra ad Mojang'da
satın alındı) LibreLogin ikisini de engeller (`profile-conflict-resolution-strategy = "BLOCK"`).
`user info` ile iki kaydı inceleyin, kimin gerçek sahip olduğunu belirleyin ve eski kaydı
`user migrate` ile başka bir ada taşıyın ya da `user delete` ile silin. Oyuncu verileri UUID'ye
bağlı olduğundan hangi kaydın neyi taşıdığına dikkat edin.

## config.conf anahtarları

`config/servers/velocity/files/plugins/librelogin/config.conf` **tam dosyadır**: her `mc apply
velocity` depodakini geri yazar. LibreLogin her açılışta dosyayı yeniden kaydeder ve yorumları
İngilizceye çevirir; değerler korunur. `revision = 8` satırını silmeyin (silinirse tüm göçler
yeniden çalışır).

| Anahtar | Değer | Anlamı |
|---|---|---|
| `limbo` | `["limbo"]` | Giriş yapmamış oyuncuların gönderileceği sunucu (velocity.toml'da kayıtlı, lobiyle aynı olamaz) |
| `lobby.root` | `["lobby"]` | Girişten sonra gidilecek sunucu. Forced host eklerseniz noktalar yerine `§`: `"survival§ornek§com" = ["survival"]` |
| `allowed-commands-while-unauthorized` | login, l, log, register, reg | Giriş yapmadan kullanılabilen komutlar |
| `default-crypto-provider` | `BCrypt-2A` | Şifre özeti (maliyet 10) |
| `new-uuid-creator` | `CRACKED` | Yeni hesapların UUID'si addan türetilir (Paper'ın offline UUID'siyle aynı). **Yalnız yeni hesapları etkiler; canlıya almadan önce karar verin**, sonradan değiştirmek pratikte mümkün değildir |
| `auto-register` | `true` | Premium adlar şifresiz kaydedilir ve ayrılır |
| `profile-conflict-resolution-strategy` | `BLOCK` | Ad çakışmasında ikisini de engelle, yetkili çözsün |
| `max-login-attempts` / `milliseconds-to-refresh-login-attempts` | 5 / 10000 | 5 yanlış şifrede at; sayaç 10 sn'de sıfırlanır |
| `seconds-to-authorize` | 90 | 90 sn içinde giriş yapmayanı at (limbo'da ad işgalini sınırlar) |
| `session-timeout` | 1800 | Aynı IP'den 30 dk içinde gelen cracked oyuncu şifresiz girer. Kötüye kullanılırsa `0` |
| `minimum-password-length` | 6 | En kısa şifre |
| `allowed-nickname-characters` | `^[a-zA-Z0-9_]{3,16}$` | İzin verilen adlar (Türkçe harf yok) |
| `ip-limit` | -1 (kapalı) | IP başına hesap sınırı yok: CGNAT ve internet kafeler aynı IP'yi paylaşır |
| `use-titles` / `use-action-bar` | true / false | Bekleyen oyuncuya başlıkla hatırlatma |
| `remember-last-server` | false | Her zaman lobiye |
| `fallback` | true | Survival çökerse/atarsa oyuncu lobiye düşer |
| `database.type` | `librelogin-sqlite` | `plugins/librelogin/user-data.db`; MariaDB'ye geçiş: [docs/07](07-olcekleme.md#veritabanı-notları-mariadb-librelogin) |
| `totp.enabled`, `mail.enabled` | false, false | 2FA (Protocolize gerekir, 26.x uyumu doğrulanmadı) ve e-postayla şifre sıfırlama kapalı |
| `limbo-port-range` | 31000-31010 | Yalnız NanoLimboPlugin için (kurulu değil) |

Mesajlar `messages.conf` içindedir (kısmi Türkçe; eksikleri İngilizce kalır). `prompt-register`
içindeki `ornek.com/kvkk` adresini kendi aydınlatma metninizle değiştirin.

**Yasaklı şifreler:** LibreLogin ilk açılışta yaygın şifre listesini (`forbidden-passwords.txt`)
indirir (internet gerekir); dosya zaten varsa indirmez. Velocity en az bir kez açıldıktan sonra
(dosya varken) Türkçe yaygın şifreleri ekleyebilirsiniz; dosya yokken eklerseniz büyük liste hiç
inmez. Karşılaştırma büyük/küçük harf duyarsızdır:

```bash
printf '%s\n' sifre şifre sifre123 parola parola123 galatasaray fenerbahce besiktas trabzonspor istanbul ankara 1905 1907 1903 1967 \
  | sudo -u minecraft tee -a /opt/minecraft/servers/velocity/plugins/librelogin/forbidden-passwords.txt >/dev/null
```

Bu dosya depoda değildir; sunucu dizininde kalır ve yedeğe girer.

### İlgili diğer ayarlar

| Dosya | Ayar | Neden |
|---|---|---|
| `velocity.toml` | `online-mode = false` | Doğrulamayı oyuncu bazında LibreLogin yapar. Açılışta "offline mode" uyarısı beklenen durumdur |
| `velocity.toml` | `force-key-authentication = false` | Açıkken anahtarsız (cracked) 1.19–1.19.2 istemcileri atılır |
| `velocity.toml` | `kick-existing-players = false` | Açık olsaydı cracked biri aynı adla bağlanıp oturumdaki oyuncuyu atabilirdi |
| `velocity.toml` | `log-command-executions = false` | Açık olsaydı `/login` ve `/register` şifreleriyle günlüğe düşerdi |
| `velocity.toml` | `[servers]`: limbo 30065, lobby 30066, survival 30067; `try = ["lobby"]` | limbo asla `try`'da değildir |
| Paper `paper-global.yml` | `proxies.velocity.online-mode: false` | Velocity ile aynı olmalı; Paper addan offline UUID üretir, LibreLogin'in `CRACKED` UUID'leriyle eşleşir |
| Paper `server.properties` | `online-mode=false`, `enforce-secure-profile=false` | Doğrulamayı proxy yapar; cracked ve Bedrock oyuncuları sohbet edebilsin |
| Floodgate `config.yml` | `player-link.enabled: false`, `send-floodgate-data: false` | Bağlı bir Bedrock hesabı Mojang UUID'siyle girerdi; Java tarafı offline UUID kullandığı için aynı kişi iki kimlik olurdu. Floodgate backend'lerde kurulu değil |
| Geyser `config.yml` | `java.auth-type: floodgate` | Bedrock oyuncuları Floodgate ile doğrulanır |
| Sonar `config.yml` | `check-geyser-players: false` | Bedrock adlarındaki `.` Sonar'ın ad desenine uymaz |
| LuckPerms (tümü) | `allow-invalid-usernames: true`; backend'lerde `use-server-uuid-cache: false` | `.Ad` biçimli Bedrock adları saklanabilsin; UUID'ler LibreLogin'den gelsin |

**UUID'ler:** Java oyuncuları (premium da olsa) addan türetilen offline UUID alır ve bu UUID
Mojang'da ad değişse bile sabit kalır. Bedrock oyuncuları `00000000-0000-0000-…` ile başlayan
Floodgate UUID'si alır. LuckPerms'e asla Mojang UUID'si yapıştırmayın; oyuncu bir kez girdikten
sonra adını kullanın ya da UUID'yi `librelogin user info <ad>` ile öğrenin.

## Türkçe dil hatası ve JVM bayrakları

Java'da Türkçe yerel ayar (`tr_TR`) açıkken `"I".toLowerCase()` noktasız **"ı"** üretir.
LibreLogin premium sorgusundan önce adı yerel ayar belirtmeden küçük harfe çevirir: `ILKER` →
`ılker` olur, Mojang bu adı bulamaz ve oyuncu cracked sayılır. Sonuç: **adında büyük "I" olan
premium adlar korunmaz** — herhangi biri o adı cracked olarak kaydedebilir. Aynı hata yasaklı
şifre denetimini de bozar.

Bu yüzden `config/jvm/velocity.flags` (ve genel önlem olarak `paper.flags`) JVM dilini sabitler:

```
-Duser.language=en
-Duser.country=US
-Dfile.encoding=UTF-8
```

Bu satırları **silmeyin** ve JVM'e hiçbir zaman `-Duser.language=tr` vermeyin. Türkçe mesajlar
her eklentinin kendi ayarından gelir. Duman testinin 7. maddesi bu düzeltmeyi doğrular.

## Duman testi (canlıya alma kapısı)

Canlıya almadan önce ve **Velocity, Floodgate, Geyser, Sonar ya da LibreLogin her güncellendiğinde**
tekrarlayın. Test sırasında `sudo mc log velocity`'yi ayrı bir pencerede izleyin.

| # | Test | Beklenen | Nasıl kontrol edilir |
|---|---|---|---|
| 1 | Premium 26.2 istemcisiyle bağlan | Doğrudan lobiye, "Premium hesabınla otomatik giriş yapıldı" | `sudo mc cmd velocity librelogin user info <ad>` → premium UUID dolu |
| 2 | Premium bir adı cracked istemciyle kullan | **Atılır** (ad online moda ayrılmış) | Oyuna girememeli |
| 3 | Yeni bir cracked adla bağlan | Sonar denetimi → tekrar bağlan → limbo → `/register` → lobi. Giriş öncesi `/server survival` ve sohbet engelli | Limbo'da `/server survival` dene |
| 4 | Aynı cracked oyuncu 30 dk içinde aynı IP'den, sonra başka IP'den (ör. mobil veri) | Aynı IP: otomatik giriş; başka IP: şifre sorulur | — |
| 5 | Bedrock (Geyser) ile bağlan | Şifresiz lobiye, adı `.Ad` | — |
| 6 | 26.3 istemcisiyle bağlan | Limbo'ya ve lobiye ulaşır | — |
| 7 | Adında büyük "I" olan premium bir test hesabıyla bağlan | Online moda zorlanır, otomatik giriş | Türkçe dil düzeltmesinin kanıtı |
| 8 | `sudo mc restart velocity` | `config.conf` yeniden üretilmez; günlükte "Failed to check if player is coming from Floodgate" **yok** (bu satır herkesin "Internal LibreLogin error" ile reddedilmesi demektir) | `sudo mc log velocity` |

Herhangi biri başarısızsa canlıya almayın: sorunu çözün ya da önceki (çalışan) jar'lara dönün
([docs/04](04-guvenlik-ddos.md#güncelleme-politikası)). Test geçtiyse test ettiğiniz Velocity
sürümünü `network.env`'de sabitleyin.

## Riskler ve önlemler

| Risk | Önlem |
|---|---|
| Geliştirme sürümü ya da Velocity iç yapısındaki bir değişiklik tüm girişleri bozar (LibreLogin "kapalı kalır": kimse giremez) | Sabit commit ve jar özeti; her güncellemede duman testi; önceki Velocity jar'ı `server.jar.old` olarak durur; Velocity sürümünü sabitleyin |
| Premium ad korunmuyor: Türkçe dil hatası; ad, bir cracked oyuncu kaydettikten sonra Mojang'da satın alındı; yedek API yanlışlıkla "bulunamadı" dedi | JVM dil bayrakları; ilk günden `auto-register = true`; çakışmada `BLOCK`; günlükte "Falling back to an alternative API" satırlarını izleyin |
| Mojang ve yedek API'lerin hepsi kapalı: önbellekte olmayan herkes reddedilir | Kabul edilen durum (güvenli tarafta kalır); önbellek 10 dakika |
| Zayıf cracked şifreler / kaba kuvvet (LibreLogin IP yasaklamaz) | BCrypt; en az 6 karakter; genişletilmiş yasaklı şifre listesi; 5 denemede atma; Velocity giriş hız sınırı; Sonar |
| Ortak IP'de oturum devralma (CGNAT, internet kafe) | `session-timeout = 1800`; kötüye kullanım görülürse `0` |
| Ad işgali: saldırgan kurbanın cracked adıyla limbo'da bekler, Velocity gerçek oyuncuyu reddeder | `seconds-to-authorize = 90`; Sonar |
| Limbo'dan kaçış: LibreLogin yalnız sohbet ve komutları engeller | Limbo ve backend'ler yalnız 127.0.0.1'de; modern forwarding HMAC'i; giriş öncesi oyuncuyu taşıyan proxy eklentisi kurmayın |
| Yöneticinin premium hesapta hata yapması | Kural: premium'da `delete`, asla `unregister`/`cracked` |
| LibreLogin'de açık bir güvenlik bildirimi (#372, "cracked oyuncular /premium hesaplarla girebiliyor", Ağustos 2025, yeniden üretilemedi) | Kod incelemesinde premium UUID'li her hesap online moda zorlanıyor (DOĞRULANMADI); yalnız 25565 ve 19132 açık; duman testinin 2. maddesi |
| İmzalı sohbet kopmaları | Sorun değil: giriş yapmamış oyuncular her zaman cracked'tir (imza yok) |

## Yedek plan: AuthMe 6.0.1

Duman testi LibreLogin ile geçmezse bilinen yedek: **AuthMe 6.0.1 + AuthMe'nin Velocity modülü**
(yalnız herkese açık API'leri kullanır, yayımlanmış bir sürümdür). Ama iki gereksinimi karşılamaz:

- **Premium otomatik giriş isteğe bağlı olur:** her premium oyuncu kendisi `/premium` ile açar;
  premium adlar kendiliğinden ayrılmaz.
- **Bedrock oyuncuları da şifre ister:** AuthMe'de Floodgate/Geyser desteği yok.

AuthMe Paper tarafında (bir giriş sunucusunda) çalışır; PicoLimbo'nun yerini bir Paper giriş
sunucusu alır. Bu depo AuthMe'yi otomatik kurmaz; geçiş, sunucu sahibinin bu kayıpları açıkça
kabul etmesini ve ayrı bir kurulum/test çalışmasını gerektirir (DOĞRULANMADI).

## Yalnız premium'a geçiş (ileride)

LibreLogin'in "yalnız premium" anahtarı yoktur. Velocity'yi `online-mode = true` yapmak da tek
başına yetmez: LibreLogin premium olmayan adlar için offline modu zorlar ve Velocity buna uyar.
Yol:

1. Duyurun. Oyunu satın almış cracked oyuncular `/premium` ile geçsin.
2. Eşlemeyi dışa aktarın (Velocity durdurulmuşken, yedek aldıktan sonra):

   ```sql
   SELECT uuid, premium_uuid, last_nickname FROM librepremium_data WHERE premium_uuid IS NOT NULL;
   ```

3. Tüm verinin **bir kopyası üzerinde** offline UUID → Mojang UUID dönüşümü yapın: dünyadaki
   `playerdata/`, `stats/`, `advancements/`; LuckPerms'teki UUID sütunları; diğer eklenti
   veritabanları. Bunun için hazır bir araç bu depoda yoktur; önce provasını yapın
   (DOĞRULANMADI).
4. LibreLogin'i kaldırın. Velocity: `online-mode = true`, `force-key-authentication = true`;
   Paper: `proxies.velocity.online-mode: true` (isteğe bağlı `enforce-secure-profile=true`).
   Floodgate etkilenmez.

Yakında yalnız premium'a geçmeyi düşünüyorsanız ve **hiç eski offline veriniz yoksa**, canlıya
almadan önce `new-uuid-creator = "MOJANG"` seçmek premium oyuncular için 3. adımı ortadan
kaldırır; bedeli, Paper `online-mode=false` iken addan UUID sorgularının tutmamasıdır.

## KVKK: saklanan veriler

(Genel KVKK notları: [docs/04](04-guvenlik-ddos.md#kvkk-kişisel-verilerin-korunması).)

- **LibreLogin satırı:** UUID, premium UUID, ad, şifre özeti (BCrypt, tuz, algoritma), kayıt ve
  son görülme zamanı, 2FA sırrı (kapalı), **son IP (düz metin)**, son doğrulama zamanı, son sunucu,
  e-posta (kapalı). Yetkililer düz şifreyi göremez.
- **Sonar H2:** doğrulanmış oyuncuların IP'leri, en çok 5 gün.
- **Yurt dışına aktarım:** premium denetimi için adlar `api.mojang.com`'a, gerekirse
  `playerdb.co` ve `api.minetools.eu`'ya gönderilir. Aydınlatma metninde belirtin.
- **Günlükler:** Velocity, Paper, Geyser ve Sonar IP yazmaz; Velocity komutları günlüğe yazmaz.
- **Dosya izinleri:** veritabanları `minecraft` kullanıcısına aittir; yedekler restic ile
  şifrelidir.
- **Silme talebi:** `sudo mc cmd velocity librelogin user delete <ad>`.
- **Kayıt olmadan ayrılanlar:** LibreLogin gördüğü her yeni ad için bir satır yazar; kayıt
  olmadan ayrılanların satırları birikir. Düzenli temizlik önerilir. Önce yedek alın ve Velocity'yi
  durdurun; tarih sütununun biçimi DOĞRULANMADI, bu yüzden önce yalnız sayın:

  ```bash
  sudo apt-get install -y sqlite3
  sudo mc backup velocity && sudo mc stop velocity
  sudo -u minecraft sqlite3 /opt/minecraft/servers/velocity/plugins/librelogin/user-data.db \
    "SELECT COUNT(*), MIN(last_seen), MAX(last_seen) FROM librepremium_data WHERE hashed_password IS NULL AND premium_uuid IS NULL;"
  # Biçimi gördükten sonra (ör. 30 günden eski olanlar) DELETE ile silin, sonra:
  sudo mc start velocity
  ```
