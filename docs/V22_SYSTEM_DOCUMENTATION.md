# 🏆 Dokumentasi Sistem: V22 AI Adaptive Meta-Strategy Selector

Sistem **V22** adalah puncak dari riset optimasi meta-strategi kita. Sistem ini dirancang untuk bekerja sebagai "Manajer Investasi Otomatis" yang secara dinamis memilih strategi trading terbaik setiap harinya untuk memaksimalkan profit dan meminimalkan resiko (Drawdown).

---

## 1. Strategi Dasar (The Entry Strategies)
AI tidak membuat sinyal beli/jual sendiri, melainkan ia memilih dari **4 Strategi Spesialis** yang sudah Anda bangun:

1.  **Follow Trend (Stop Order):** Strategi yang masuk saat harga menembus level Support/Resistance (Breakout). Sangat kuat saat market sedang *trending* kencang.
2.  **Limit Order Reversal:** Strategi yang mencoba menangkap titik balik harga di level S/R menggunakan pending order. Cocok untuk market yang sedang *sideways*.
3.  **Mean Reversion Reversal:** Strategi yang mencari titik jenuh harga untuk melakukan "reversal" (balik arah) ke harga rata-ratanya.
4.  **Mean Reversion Trend:** Versi modifikasi dari mean reversion yang lebih mengikuti arah tren besar namun tetap mencari titik masuk saat harga terkoreksi.

---

## 2. Otak AI (The Algorithm: Decision Tree)
Sistem ini menggunakan algoritma **Decision Tree Classifier** sebagai pusat pengambilan keputusan.

*   **Kenapa Decision Tree?** Berdasarkan hasil turnamen ML kita, Decision Tree terbukti paling lincah dalam memetakan aturan (rules) yang sangat spesifik untuk market Gold saat ini.
*   **Adaptive Window (90 Hari):** AI hanya belajar dari **90 hari terakhir**. Ini fitur kunci agar AI tidak "baper" dengan masa lalu yang sudah tidak relevan. AI selalu menyesuaikan diri dengan "vibe" market paling baru.
*   **Max Depth = 5:** Kita membatasi kedalaman pohon keputusan agar AI tidak terlalu rumit (mencegah *Overfitting*), sehingga aturan yang ditemukan lebih solid untuk data masa depan.

---

## 3. Fitur yang Digunakan (The Senses)
AI "melihat" kondisi market melalui beberapa fitur (input) utama:

*   **Lagged Returns (1-Day):** AI melihat hasil profit/loss masing-masing strategi di hari kemarin.
*   **Rolling Volatility (10-Day):** AI mengukur seberapa stabil atau liar performa masing-masing strategi dalam 10 hari terakhir.
*   **Relative Momentum:** AI membandingkan siapa yang sedang "panas" dan siapa yang sedang "dingin" di antara ke-4 strategi tersebut.

---

## 4. Cara Kerja (The Decision Logic)
Setiap awal hari trading, AI melakukan langkah berikut:

1.  **Scanning:** Membaca data profit dan volatilitas 90 hari terakhir.
2.  **Prediction:** Menghitung peluang (probability) kemenangan untuk masing-masing strategi di hari tersebut.
3.  **Weighting (Power-4 Logic):** AI tidak hanya memilih satu, tapi memberikan bobot modal. Rumus **Power-4** memastikan strategi yang peluangnya paling besar akan mendapatkan porsi modal yang sangat dominan, namun tetap menyisakan sedikit "cadangan" di strategi lain jika terjadi anomali.
4.  **Execution:** Mengalokasikan modal sesuai bobot dan mencatat hasilnya.

---

## 5. Ringkasan Performa (The Results)
Hasil pengujian pada data riil menunjukkan angka yang sangat superior:

*   **Total Profit:** **44.66%**
*   **Max Drawdown:** **1.98%** (Sangat Aman)
*   **Sharpe Ratio:** **2.14** (Kategori Investasi Elite)
*   **Recovery Factor:** **22.5** (Kemampuan pemulihan modal sangat cepat)

---

## 6. Panduan Pemeliharaan (Maintenance)
Agar performa tetap gila seperti di atas, disarankan untuk:
*   **Retraining Mingguan:** Lakukan proses "Belajar Ulang" bagi AI setiap akhir pekan menggunakan data 90 hari terbaru.
*   **Monitoring Drawdown:** Jika Drawdown melebihi 5%, lakukan evaluasi terhadap masa belajar (Adaptive Window).

---
*Dokumen ini disusun oleh Antigravity AI sebagai panduan teknis Meta-Strategy Optimizer V22.*
