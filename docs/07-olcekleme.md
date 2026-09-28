# 07 — Ölçekleme

Bu belge ağı büyütmenin yollarını anlatır: yeni bir oyun modu eklemek, VDS'i yerinde büyütmek,
backend'leri ikinci bir VDS'e taşımak, veritabanı notları, Folia ve Paper 26.3'e geçiş.

Ne zaman büyütmeniz gerektiği: [docs/01 — yükseltme tetikleyicileri](01-donanim-ve-kapasite.md#yükseltme-tetikleyicileri).
Kısaca: **RAM ilk sınırdır** (yeni mod = daha fazla heap), **survival'ın tek ana iş parçacığı
sunucu başına tavandır** (~100–130 oyuncu; daha büyük VDS bunu yükseltmez).

## Yeni oyun modu eklemek (mc new-server)

Örnek: 3 GB heap'li bir `skyblock` sunucusu, oyun portu 30068 (RCON otomatik 31068):

```bash
cd /opt/minecraft/kami
sudo mc new-server skyblock 30068 3G
# başka bir sunucuyu kopyalamak için:  sudo mc new-server skyblock 30068 3G --from lobby
```

Kurallar: ad küçük harf/rakam/tire, harfle başlar, 2–31 karakter; port 1024–64535 (RCON =
port + 1000); heap `2G` ya da `1536M` gibi.

Komut yalnız **depodaki `config/` ağacını** değiştirir:

- `config/servers/survival/` (ya da `--from` ile verilen Paper sunucusu) →
  `config/servers/skyblock/` kopyalanır; `server.env` içinde `PORT`, `RCON_PORT`, `HEAP`,
  `CPU_WEIGHT=100`, `OOM_SCORE_ADJUST=100` yazılır.
- `config/servers/velocity/files/velocity.toml` `[servers]` tablosuna
  `skyblock = "127.0.0.1:30068"` eklenir.
- Port çakışmaları (tüm `server.env`'ler, genel portlar, veritabanı portu) denetlenir.
- Sonda **RAM bütçesi** hesaplanır (toplam heap × 1,25 + 1,5 GB, `MemTotal` ile karşılaştırılır)
  ve yetmiyorsa uyarır.

**16 GB'ta RAM hesabı:** mevcut 9,5 GB heap'e 3 GB eklemek tahmini gereksinimi ~17,1 GiB'e
çıkarır; 16 GB'lık bir VDS'te `MemTotal` ~15–15,6 GiB olduğundan **sığmaz**. Ya survival'ı
küçültün (ör. 7G → 5G; ancak 100 oyuncu hedefiyle riskli) ya da önce 24 GB'a geçin (aşağıda).

Sonra komutun yazdırdığı adımları uygulayın:

1. `config/servers/skyblock/files/` ve `init-commands.txt` dosyalarını gözden geçirin (kaynağa
   özgü ayarlar kopyalandı: görüş mesafesi, `worker-threads`, oyun kuralları…). Oyun moduna göre
   `server.properties` (ör. `level-type`, `difficulty`) ayarlayın.
2. `config/plugins.list`: yalnız `survival` için tanımlı satırları (ör. Chunky) istiyorsanız
   sunucular sütununa `,skyblock` ekleyin. `backends` satırları zaten dahildir.
3. İndirin ve ilk kurulumu yapın:

   ```bash
   sudo mc download all skyblock
   sudo mc init skyblock --accept-eula
   ```

4. Velocity'ye yeni sunucuyu tanıtın (sunucu listesi + kapanış sırası):

   ```bash
   sudo mc apply velocity
   sudo mc cmd velocity velocity reload      # ya da: sudo mc restart velocity (oyuncular düşer)
   ```

5. Açılışta otomatik başlaması için birimi etkinleştirin ve başlatın. (`mc new-server` ve
   `mc init` birimi etkinleştirmez; install.sh'i yeniden çalıştırmak da `config/servers/`
   altındaki tüm sunucuları etkinleştirir.)

   ```bash
   sudo systemctl enable mc@skyblock.service
   sudo mc start skyblock
   sudo mc doctor
   ```

6. Değişiklikleri depoya işleyin:

   ```bash
   sudo git -C /opt/minecraft/kami add config/
   sudo git -C /opt/minecraft/kami commit -m "Yeni sunucu: skyblock"
   ```

   "Author identity unknown" hatası alırsanız git kimliğini bir kez tanımlayın
   ([docs/02, 4. adım](02-kurulum.md#4-depoyu-indirin)).

Oyuncular `/server skyblock` ile geçer. Yeni sunucu otomatik olarak saatlik yedeğe, günlük
yeniden başlatmaya ve `mc start/stop all`'a dahil olur.

## VDS'i yerinde büyütmek (24 / 32 GB)

DeHost Hybrid+ basamakları: 24 GB (8 vCPU, 300 GB), 32 GB (12 vCPU, 500 GB), 48 GB (14 vCPU),
64 GB (16 vCPU). 24 GB yalnız RAM ekler; CPU da darsa 32 GB daha mantıklıdır. Yeniden kurulum
gerekmediği, kesinti süresi ve diskin kendiliğinden büyüyüp büyümediği DOĞRULANMADI — önce sorun.

**Önce:**

```bash
sudo mc say "Sunucu bakım için birazdan kapanacak."   # önceden de duyurun
sudo mc stop all
sudo mc backup all               # sunucular kapalıyken tutarlı yedek
```

**Sonra:**

```bash
free -h            # yeni RAM görünüyor mu?
nproc              # vCPU sayısı
df -h /            # disk büyüdü mü? Büyümediyse bölüm/dosya sistemi genişletme için destek isteyin
```

Heap'leri `config/servers/<sunucu>/server.env` içindeki `HEAP` ile büyütün, uygulayın ve
başlatın:

```bash
sudo nano /opt/minecraft/kami/config/servers/survival/server.env
sudo mc apply all
sudo mc start all
sudo mc doctor
```

Önerilen başlangıç heap'leri (tahmin; spark ve `mc status` ile ölçüp ayarlayın):

| Paket | velocity | lobby | survival | yeni mod | Toplam heap | `mc doctor` gereksinimi |
|---|---|---|---|---|---|---|
| 16 GB | 1G | 1536M | 7G | — | 9,5 GB | ~13,4 GiB |
| 24 GB | 1G | 1536M | 8G | 4G | 14,5 GB | ~19,6 GiB |
| 32 GB | 1536M | 1536M | 10G | 6G | 19 GB | ~25,3 GiB |

- Survival'a 10 GB'tan fazlasını vermek genelde işe yaramaz (PaperMC 6–10 GB önerir); fazla RAM'i
  yeni modlara verin.
- Bedrock oyuncuları çoksa (≳30) Velocity'yi 1536M yapın.
- 32 GB / 12 vCPU'da survival `paper-global.yml` `chunk-system.worker-threads: 3` denenebilir.

## Backend'leri ikinci bir VDS'e taşımak

~150 oyuncuyu aşınca, ikinci bir survival parçası ya da birden fazla ağır mod gerektiğinde:
**Velocity, limbo, lobi ve MariaDB DDoS korumalı ilk makinede kalır; ağır backend'ler (survival,
yeni modlar) ikinci makineye taşınır.** İki makine aynı veri merkezinde olmalı (aralarında ping
< 1 ms ideal); DeHost özel ağ (private network) sunuyorsa onu kullanın.

> Bu depo tek makine için yazıldı; iki makineli düzen elle kurulur. Aşağıdaki adımlar bir
> taslaktır, önce geçici makinelerde deneyin.

| | VDS1 (mevcut) | VDS2 (yeni) |
|---|---|---|
| Sunucular | velocity, limbo, lobby | survival (+ diğer modlar) |
| Dışarıya açık | 25565/tcp, 19132/udp, SSH | yalnız SSH; oyun portu **yalnız VDS1'in IP'sine** |
| `config/servers/` | survival **silinir** | yalnız VDS2'deki sunucular kalır |

1. **VDS2'yi kurun:** [docs/02](02-kurulum.md) adımları 2–6. Depoyu ayrı bir git dalında (ör.
   `vds2`) tutun ve bu dalda `config/servers/` altından `velocity`, `limbo`, `lobby`'yi silin;
   VDS1'in dalında da `survival`'ı silin. Böylece her makinede `mc start all`, yedek ve
   `mc doctor` yalnız kendi sunucularını görür.
2. **Aynı iletim sırrı:** VDS1'deki `/etc/minecraft/secrets.env` içindeki
   `VELOCITY_FORWARDING_SECRET` ve `PAPER_VELOCITY_SECRET` değerlerini VDS2'deki dosyaya
   aynen yazın (güvenli kanaldan kopyalayın).
3. **VDS2'de survival dışarıdan (yalnız VDS1'den) erişilebilir olmalı:**
   `config/servers/survival/files/server.properties` içinde `server-ip=<VDS2'nin özel ya da
   genel IP'si>` (RCON için `rcon.ip=127.0.0.1` **kalır**). `mc doctor` bu portu "dış arayüzde
   dinleniyor" diye **kritik** gösterecektir; bu düzende beklenen durumdur, güvenlik duvarı
   kuralının doğru olduğundan emin olun:

   ```bash
   # VDS2'de: yalnız Velocity'nin makinesi bağlanabilsin
   sudo ufw allow from <VDS1_IP> to any port 30067 proto tcp comment 'Velocity (VDS1)'
   # VDS2'de oyuncu portlarına gerek yok:
   sudo ufw delete allow 25565/tcp
   sudo ufw delete allow 19132/udp
   ```

   VDS2'de `mc doctor`'ın "UFW: 25565/tcp açık değil" ve "UFW: 19132/udp açık değil" **kritik**
   satırları da bu düzende beklenen durumdur. install.sh'i yeniden çalıştırırsanız 25565/tcp ve
   19132/udp kurallarını **yeniden ekler**; ardından iki `ufw delete` komutunu tekrarlayın.

4. **LuckPerms veritabanı:** VDS2'deki LuckPerms, VDS1'deki MariaDB'ye bağlanmalıdır. VDS1'in
   dalında `host/mariadb-minecraft.cnf` içinde `bind-address = 127.0.0.1,<VDS1_özel_IP>` yapın
   (virgüllü liste MariaDB ≥ 10.11'de geçerlidir; `127.0.0.1` **kalmalı**, çünkü VDS1'in kendi
   LuckPerms'ü `DB_HOST="127.0.0.1"` ile bağlanır) ve install.sh'i yeniden çalıştırın (dosyayı
   `/etc/mysql/mariadb.conf.d/60-minecraft.cnf`'ye kopyalayıp MariaDB'yi yeniden başlatır;
   `/etc` altındaki dosyayı elle düzenlerseniz install.sh bir sonraki çalışmada üzerine yazar).
   Bu adres açılışta MariaDB'den önce hazır olmalıdır; WireGuard adresiyse
   `sudo systemctl edit mariadb` ile `[Unit]` altına `Wants=wg-quick@wg0.service` ve
   `After=wg-quick@wg0.service` ekleyin, yoksa MariaDB açılışta başlayamayabilir.
   Portu yalnız VDS2'ye açın (`sudo ufw allow from <VDS2_IP> to any port 3306 proto tcp`),
   VDS2'nin IP'si için bir MariaDB kullanıcısı tanımlayın; VDS2'nin `network.env` dosyasında
   `DB_HOST`'u VDS1'in IP'si, VDS2'nin `secrets.env` dosyasında `DB_PASSWORD`'u o kullanıcının
   parolası yapın. MariaDB trafiği şifresizdir: özel ağ yoksa iki makine arasına **WireGuard**
   tüneli kurun.
5. **Dünyayı taşıyın:** VDS1'de `sudo mc stop survival && sudo mc backup survival`. VDS2'ye aynı
   `backup.env` ve `restic.pass`'i koyun, `BACKUP_HOST=mc01` iken `sudo mc restore survival latest`,
   sonra VDS2'de `BACKUP_HOST=mc02` yapın (her makine kendi yedeklerini ayrı etiketlesin).
   `sudo mc apply survival` (yeni sırlar), `sudo mc download all survival`, `sudo mc start survival`.
6. **Velocity'yi yönlendirin (VDS1):** `velocity.toml`'da
   `survival = "<VDS2_IP>:30067"`; `sudo mc apply velocity && sudo mc restart velocity`.
7. Duman testi ve oyun testi; ardından VDS1'deki eski survival dizinini (yedek aldıktan sonra)
   silin.

Modern forwarding sırrı oyuncu bilgisinin **değiştirilmesini** engeller ama şifrelemez; oyuncu
adları/IP'leri iki makine arasında açık gider. Özel ağ ya da WireGuard bu yüzden de önerilir.

## Veritabanı notları (MariaDB, LibreLogin)

- **MariaDB** yalnız LuckPerms içindir (`DB_DATABASES="luckperms"`). `innodb_buffer_pool_size=384M`
  ve `max_connections=100` (`host/mariadb-minecraft.cnf`) birkaç sunucu için yeterlidir; her
  LuckPerms örneği kendi bağlantı havuzunu açar (varsayılan en çok 10 bağlantı), ~8 sunucuya
  kadar sorun olmaz.
- **LibreLogin** varsayılan olarak SQLite kullanır (`plugins/librelogin/user-data.db`): tek proxy
  ve ~100 oyuncu için yeterli, ayrı bir hizmet gerektirmez. Bağlantı koparsa LibreLogin proxy'yi
  kapatır; bu yüzden MariaDB'ye geçmek (MariaDB kesintisi = proxy kesintisi) ek bir risktir.
  **Yalnız** ikinci bir proxy ya da veriye erişen bir web paneli gerektiğinde geçin:

  1. `sudo mc backup velocity`
  2. `config/network.env`: `DB_DATABASES="luckperms librelogin"`; install.sh'i yeniden çalıştırın
     (veritabanını ve yetkileri oluşturur; `mc backup all` artık onu da döker).
  3. Depodaki `config/servers/velocity/files/plugins/librelogin/config.conf`:
     `database.type = "librelogin-mysql"` (mysql bloğu `@@DB_…@@` yer tutucularıyla hazır) ve
     `migration { on-next-startup = true, type = "librelogin-sqlite" }`.
  4. `sudo mc apply velocity && sudo mc restart velocity`; günlükte taşımanın başarılı olduğunu
     görün.
  5. **Hemen** depoda `on-next-startup = false` yapıp `sudo mc apply velocity` çalıştırın. Aksi
     halde `config.conf` her `mc apply`'da depodan geri yazıldığı için taşıma her yeniden
     başlatmada tekrar çalışır.
  6. Duman testi. Taşıma ayrıntıları LibreLogin'in belgesine göre değişebilir (DOĞRULANMADI).

- **LuckPerms verisini başka bir MariaDB'ye taşımak:** `mariadb-dump luckperms` ile alıp yeni
  sunucuya aktarın, `network.env`'de `DB_HOST`/`DB_PORT`'u değiştirin, `sudo mc apply all`,
  `sudo mc restart all`.

## Folia ne zaman düşünülmeli?

Folia, Paper'ın dünyayı bölgelere ayırıp farklı bölgeleri farklı iş parçacıklarında işleyen bir
çatalıdır. Tek bir dünyada tek ana iş parçacığı tavanını aşabilir, ama:

- **Eklentilerin çoğu uyumsuzdur**; yalnız Folia desteği bildiren eklentiler çalışır. Yönetim,
  koruma ve ekonomi eklentilerinin her biri tek tek doğrulanmalıdır.
- Kazanç, oyuncuların dünyaya **dağılmış** olmasına bağlıdır; herkes spawn'da toplanıyorsa
  fayda azdır.
- Çok sayıda **ayrılmış** çekirdek ister; paylaşımlı 8 vCPU'da anlamlı değildir.
- Bu deponun betikleri Folia'yı desteklemez (indirme betiği yalnız Paper ve Velocity projelerini
  bilir) ve test edilmemiştir.

Öneri: tek bir survival ~130–150 oyuncunun üstüne çıkmak zorundaysa önce **ikinci bir survival
parçası** (ör. `survival2`, ayrı dünya) ya da daha hızlı tek çekirdekli adanmış bir makine
düşünün. Folia'yı ancak adanmış, çok çekirdekli bir makinede ve tüm eklentiler denendikten sonra
değerlendirin.

## Paper 26.3'e geçiş kontrol listesi

26.3 (Eylül 2026) şu an **BETA**. 26.3 istemcileri bugün de ViaVersion sayesinde 26.2
sunuculara girebildiği için acele etmeyin.

**Geçmeden önce:**

- [ ] Paper 26.3'ün Fill'de **STABLE** bir build'i var. Denemek için `network.env`'de sürümü
      değiştirip `sudo mc download --dry-run core survival` çalıştırın; kararlı build yoksa
      "build seçilemedi" hatası verir. (Denedikten sonra değeri geri alın.)
- [ ] Geyser'in yayımlanmış bir sürümü Java 26.3'ü destekliyor (araştırma sırasında yalnız bir
      geliştirme dalındaydı). Desteklemiyorsa Bedrock oyuncuları backend'lerdeki ViaVersion'a
      muhtaç kalır; mutlaka test edin.
- [ ] Kullandığınız **tüm** eklentilerin 26.3 sürümü var: LuckPerms, ViaVersion, Chunky ve
      sonradan eklediğiniz her şey (EssentialsX, CoreProtect, WorldGuard, FAWE…).
- [ ] Velocity ≥ 4.2.0 (26.3 istemcileri için zaten gerekli) ve PicoLimbo 26.3'ü destekliyor
      (depodaki sürüm öyle).
- [ ] Mümkünse önce **geçici bir makinede** deneyin: son yedeği oraya geri yükleyip yükseltin,
      oynayın.

**Geçiş:**

1. Oyunculara duyurun. `sudo mc stop all` ve **sunucular kapalıyken** `sudo mc backup all`.
   `sudo mc backup list` ile anlık görüntü kimliklerini not edin.
2. `config/network.env`: `PAPER_MC_VERSION="26.3"`.
3. `sudo mc download` (yeni jar'lar `server.jar.new` olarak bekler, başlatmada devreye girer;
   eklenti güncellemeleri de iner).
4. `sudo mc apply all`. Bilinmeyen anahtar uyarılarını okuyun. 26.3'te
   `misc.fix-far-end-terrain-generation` ve `misc.send-full-pos-for-item-entities` kaldırıldı
   (depodaki ayarlarda yok; Paper kendisi siler).
5. `sudo mc start all` ve günlükleri izleyin: ilk açılışta dünya yeni biçime **dönüştürülür**,
   uzun sürebilir.
6. **`white-list` varsayılanı 26.3'te `true` oldu.** Depodaki `server.properties` bunu açıkça
   `false` yazar; yine de kontrol edin:

   ```bash
   # "*" root kabuğunda genişlemeli: servers/ yönetici kullanıcısına kapalıdır (0750).
   sudo sh -c "grep -H '^white-list' /opt/minecraft/servers/*/server.properties"
   ```

7. Duman testi ([docs/08](08-giris-sistemi.md#duman-testi-canlıya-alma-kapısı)) ve oyun testi
   (redstone, çiftlikler, eklenti komutları).
8. Değişikliği depoya işleyin.

**Geri dönüş yoktur.** Paper dünyayı yeni sürüme göre dönüştürür ve eski sürüm açamaz. Sorun
çıkarsa tek yol, yükseltmeden önce aldığınız yedeği geri yüklemektir (`sudo mc restore <sunucu>
<kimlik>`) ve `PAPER_MC_VERSION`'ı geri almaktır; aradaki oyun ilerlemesi kaybolur.
