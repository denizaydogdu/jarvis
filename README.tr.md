# Jarvis

[English](README.md) · **Türkçe**

Jarvis, Claude Code için bir macOS sesli asistan. Terminaldeki ajanın bir şey sormak için
durduğunda — izin, seçenek arasından bir tercih, işi bitirdiğinde bir bildiri — ekranında küçük bir
kedi paneli belirir, soruyu sesli okur, mikrofonu açar, söylediğin cevabı dinler ve kararını
terminale geri gönderir. Klavyeye dönmen gerekmez; ajan da seni sessizlik içinde beklemek zorunda
kalmaz.

Konuşmanın uygun olmadığı anlarda aynı panel butonlarla da cevap verir; aynı Mac'te ofis sunucusu
([Ofis](https://github.com/denizaydogdu/ofis)) çalışıyorsa Jarvis ofisin durumunu ve bekleyen
kararlarını da sesli okur ve cevaplarını A2A protokolüyle iletir.

Her şey kendi makinende çalışır: konuşma tanıma ve konuşma sentezi macOS sistem servisleri, Ofis
bağlantısı yalnızca loopback, kapı anahtarı hiçbir yerde saklanmaz, loglanmaz, yankılanmaz.

> **Dil:** panel yazıları, okunan sorular ve söylenen cevaplar **Türkçe**. Kod tanımlayıcıları,
> kod yorumları ve geliştirici belgeleri İngilizce.

## İçindekiler

- [Nasıl çalışır](#nasıl-çalışır)
- [Neler söyleyebilirsin](#neler-söyleyebilirsin)
- [Ofis bağlantısı (A2A)](#ofis-bağlantısı-a2a)
- [Gereksinimler](#gereksinimler)
- [Kurulum ve güncelleme](#kurulum-ve-güncelleme)
- [Günlük kullanım](#günlük-kullanım)
- [Gizlilik ve güvenlik](#gizlilik-ve-güvenlik)
- [Testleri çalıştırmak](#testleri-çalıştırmak)
- [Sorun giderme](#sorun-giderme)
- [Lisans](#lisans)

## Nasıl çalışır

1. `scripts/install.sh`, `jarvis-hook` binary'sini Claude Code'un hook'larına bağlar
   (`~/.claude/settings.json` — eski ayarlarının yedeği yazdırılır): `PermissionRequest`, `Stop` ve
   `AskUserQuestion` için `PreToolUse`.
2. Claude Code bu hook'lardan birini tetiklediğinde `jarvis-hook` soruyu yerel bir unix socket
   üzerinden menü çubuğundaki Jarvis uygulamasına yollar.
3. Panel proje adı ve kediyle belirir, soruyu macOS konuşma senteziyle sesli okur ve dinlemeye
   başlar. Mikrofon girişin macOS Speech framework'üyle (Türkçe dikte) yazıya çevrilir.
4. Söylediklerin bir karara dönüşür: izin cümlesi onaylar, "hayır" reddeder, bir seçeneğin adı ya
   da numarası ("ikinci", "2") o seçeneği seçer; kendi sorun sesli cevaplanır ve konuşmanın geri
   kalanı terminale bırakılır. Ajan, cevabını klavyeden yazmışsın gibi devam eder.
5. Konuşamadığın anlarda — toplantıda, kalabalıkta — panel butonlarla da cevap verir; "Konuşamam"
   (söyleyerek de olur) günün geri kalanı için bu buton moduna geçer.

## Neler söyleyebilirsin

Niyete göre tanınan (birebir kelime aramadan) sesli Türkçe cevaplar:

- **İzin:** "izin ver", "onaylıyorum", "evet" — istek onaylanır.
- **Ret:** "hayır" — istek reddedilir.
- **Seçim:** seçeneğin adı ya da numarası ("ikinci", "2") tercih sorusunu cevaplar.
- **Geriden soru:** kendi sorun sesli cevaplanır; panel konuşmayı terminale bırakır, klavyeyle devam
  edebilirsin.
- **"terminal"** soruyu cevapsız doğrudan terminale bırakır.
- **"Konuşamam"** günün geri kalanı için butonla cevap moduna geçer.

## Ofis bağlantısı (A2A)

Aynı Mac'te [Ofis](https://github.com/denizaydogdu/ofis) sunucusu çalışırken Jarvis,
`127.0.0.1:8800–8819` aralığında "Ofis" adlı bir Agent Card arayarak ofisin A2A kapısını bulur ve
ofisin sesli arayüzü olur:

- **"Ofis durumu"** (menü) ofisin anlık durumunu sesli okur.
- **"Ofis kararlarını sor"** (menü, varsayılan açık) ofisin beklediği her kararı sesli okur ve
  söylediğin cevabı kaydeder; tarayıcıdan uzak kaldığında da ofis yürümeye devam eder.

**Ofis tarafında kurulum.** Kapı varsayılan olarak kapalıdır. Ofis'in `ofis.json` dosyasında
`jarvis.acik` değerini `true` yapıp Ofis sunucusunu yeniden başlat; sunucu anahtar dosyasını
`<Ofis klasörü>/durum/jarvis_anahtari` yolunda (mod 0600) oluşturur. `jarvis.kapsam`, Jarvis'in ne
yapabileceğini belirler: yukarıdaki her şey için varsayılan `durum-karar` yeterlidir;
`durum-karar-is` ayrıca gelen "Ofise iş ver" ögesinin CEO'ya yeni iş iletmesine izin verir — bu her
zaman ekrandaki "Gönder" düğmesini ister, asla tek başına sesle olmaz. Ofis kapıyı hız sınırına
tabi tutar (`jarvis.dakika_sinir`, varsayılan dakikada 60 istek) ve sınır aşılırsa `Retry-After`
ile birlikte `429` döner.

**Ofis nerede duruyor.** Jarvis Ofis'i varsayılan olarak `~/Dev/ajan-ofisi` altında arar. Ofis'i
başka bir yere klonladıysan o klasörü `~/.jarvis/ofis-dir` dosyasına yaz (tek satır, mutlak yol;
`~` ev klasörün) ve Jarvis'i yeniden başlat.

Kapı anahtarı her istekten önce `<Ofis klasörü>/durum/jarvis_anahtari` dosyasından okunur,
yalnızca `Authorization` başlığına girer, hiçbir yerde saklanmaz ve loglanmaz, kapı cevaplarının
hepsinden ayrıştırılmadan önce silinir. Bağlantı yalnızca `127.0.0.1` üzerinde düz HTTP'dir: cookie
yok, önbellek yok, yönlendirme yok, başka hiçbir makineye istek yok.

## Gereksinimler

- macOS 14 veya üzeri
- Swift 6 araç zinciri (`xcode-select --install` yeterli)
- Claude Code
- **macOS Dikte AÇIK ve Türkçe**
  (Sistem Ayarları → Klavye → Dikte → Türkçe)
- İsteğe bağlı: ofis özellikleri için [Ofis](https://github.com/denizaydogdu/ofis) — Ofis için
  Jarvis isteğe bağlıdır, Jarvis için de Ofis; ikisi de tek başına çalışır, ikisi birden çalıştığında
  ofis özellikleri belirir.

## Kurulum ve güncelleme

```bash
git clone https://github.com/denizaydogdu/jarvis.git
cd jarvis
scripts/install.sh
```

Betik release binary'lerini derler, `Jarvis.app`'i `~/Applications` içine kurar, `jarvis-hook`'u
`~/.jarvis/bin` içine kurar, hook girdilerini `~/.claude/settings.json` ile birleştirir
(idempotent — yedek yolunu yazdırır), çalışan Jarvis'i kapatıp yeniden başlatır.

Şunu bil: `~/.claude/settings.json` Claude Code'un **global** ayar dosyasıdır; hook'lar makinedeki
**her Claude Code oturumunda** çalışır, tek bir projeye özgü değildir. Geri almak için betiğin
yazdırdığı yedeği geri yükle ya da `~/.claude/settings.json` içinden `jarvis-hook` girdilerini
kaldır.

Güncelleme: `git pull && scripts/install.sh`.

## Günlük kullanım

Menü çubuğundaki kedi arayüzün tamamı:

- **Sessiz** — sesi kapatır; panel yine belirir, cevaplar yine çalışır.
- **Girişte başlat** — girişte başlatma.
- **Ofis durumu** — ofis durumunu hemen oku (Ofis gerekir).
- **Ofis kararlarını sor** — ofis karar okuyucusunu aç/kapat (Ofis gerekir).
- **Rahatsız etme** (30 dakika / 1 saat) — sessiz mod: sorular butonlarla cevaplanır, kaçırılan her
  karar sayılır; **Devam et** süreden önce bitirir.

Panelde: kopyala düğmesi görünmeyen kısmı kesilmemiş tüm soruyu panoya koyar; cevap butonları
(`Onaylıyorum`, `Hayır`, …) sesli cevapların aynısıdır.

## Gizlilik ve güvenlik

- Her şey yereldir: telemetri yok, loopback Ofis kapısı dışında ağ yok, üçüncü taraf konuşma
  servisi yok — dikte ve sentez macOS sistem özellikleridir.
- Ofis anahtarı istek başına okunur, yalnızca `Authorization` başlığında kullanılır, loglanmaz ve
  kapı cevaplarından silinir; yankı yapan bir kapı bile sızmaz.
- Panel, Claude Code transkriptlerini kendi ev dizininden okur. Panelin sesli okumasını
  istemediğin projeleri `~/.jarvis/excluded-paths` dosyasına satır satır yazabilirsin.

## Testleri çalıştırmak

```bash
swift test
```

Çekirdek mantığın tamamı üzerine saf Swift testler (niyet ayrıştırma, tercih zamanlaması, konuşma
metni, hook'lar, mock A2A kapısına karşı Ofis istemcisi, sessiz mod, panel kopyası) — ağ yok,
mikrofon gerekmez.

## Sorun giderme

- **Kedi sessiz / yazıya çevrilmiyor:** Sistem Ayarları → Klavye → Dikte açık ve Türkçe mı, Jarvis'e
  Mikrofon ve Konuşma Tanıma izni verilmiş mi bak (Sistem Ayarları → Gizlilik ve Güvenlik).
- **Sorular görünmüyor:** `~/.claude/settings.json` içinde hook girdileri duruyor mu
  (`jarvis-hook install-settings` geri ekler, yedek yolunu yazdırır), tek bir Jarvis örneği
  çalışıyor mu bak.
- **Ofis ögeleri sessiz:** önce Ofis tarafına bak — `ofis.json` içinde `jarvis.acik` `true` olmalı
  (kapalı bir kapı her şeye 404 döner) ve sunucu çalışıyor olmalı. Sonra klasörü kontrol et: Ofis
  `~/Dev/ajan-ofisi` altında değilse klasörünü `~/.jarvis/ofis-dir` dosyasına yaz ve Jarvis'i
  yeniden başlat; Agent Card'ı `127.0.0.1:8800–8819` üzerinde, anahtar dosyasını
  `<Ofis klasörü>/durum/jarvis_anahtari` yolunda arar.

## Lisans

[MIT](LICENSE)
