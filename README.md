# TapVerse
Tek uygulamada mini oyunlar. İlk oyun: sonsuz koşu. Dosyalar `docs/` klasöründe.

## Derleme ve yayın
- Her push'ta GitHub Actions APK üretir. `KEYSTORE_B64` ve `KEYSTORE_PASS` secret'ları tanımlıysa imzalı APK + AAB üretir; yoksa test (debug) APK.
- versionCode her derlemede artar (Actions çalıştırma numarası).
- Play Store'a yeni sürüm çıkınca `docs/version.json` içindeki `code` değerini o derlemenin numarasına yükselt; uygulama Ayarlar'da "Yeni sürüm var" gösterir.
