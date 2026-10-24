# TapVerse
Tek uygulamada mini oyunlar. İlk oyun: sonsuz koşu. Dosyalar `docs/` klasöründe.

## Derleme ve yayın
- Her push'ta GitHub Actions APK üretir. `KEYSTORE_B64` ve `KEYSTORE_PASS` secret'ları tanımlıysa imzalı APK + AAB üretir; yoksa test (debug) APK.
- versionCode her derlemede artar (Actions çalıştırma numarası).
- Play Store'a yeni sürüm çıkınca `docs/version.json` içindeki `code` değerini o derlemenin numarasına yükselt; uygulama Ayarlar'da "Yeni sürüm var" gösterir.

## Skor tablosu ve admin paneli
- Sunucu: `db/002_tapverse_players_admin.sql` dosyasını Supabase SQL Editor'de çalıştır, en alttaki `tv_set_admin_pass` satırıyla admin şifreni belirle.
- Skor tablosu her oyun için haftalık (Pazartesi 03:00 TR) ve tüm zamanlar sıralaması gösterir. İsimler benzersizdir.
- Admin paneli uygulamanın içinde değildir: `https://ahmetgntrk10.github.io/TapVerse/admin.html` adresinden şifreyle girilir.

## Kelime Çiçeği (kelime bulmaca)
- Kelime listeleri `docs/words/<dil>.json` (tr, en, es, pt, de, fr, ru). Endonezce için liste yok, İngilizceye düşer.
- Listeler: OpenSubtitles frekans listesi (FrequencyWords) + hunspell sözlükleriyle özel isim/gürültü filtresi + LDNOOBW küfür filtresi.
- APK build'i `docs/words` klasörünü `www/words` içine kopyalar.

## Yeni oyunlar
- **Yuva Birleştir** (`yv`): sürükle-birleştir, siparişler, enerji, koleksiyon (cüzdan: merge)
- **Su Sıralama Akvaryumu**: balık/süs al, seviye başına bonus (en fazla ödülün %60'ı)
- **Zaman Bahçesi** (`gd`): gerçek zamanlı büyüyen bahçe, bildirim id 6 (cüzdan: garden)
- **Ses Avcısı** (`av`): stereo ses + titreşimle gizli ateş böceğini bul (cüzdan: sound)
